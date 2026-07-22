# Tep::Server::Scheduled -- Falcon-shape fiber-per-connection HTTP
# server, built on Tep::Scheduler + sphttp non-blocking accept/recv.
#
# Why this exists
# ---------------
# The default Tep::Server (in server.rb) is prefork + blocking per
# worker -- N workers <=> N concurrent connections. WebSockets and
# slow keep-alive clients tie up a worker for the full connection
# duration, so the prefork pool's effective concurrency degrades
# to N regardless of actual CPU work. The scheduled variant accepts
# in a fiber, spawns one fiber per accepted connection, and parks
# all I/O on Tep::Scheduler.io_wait -- N workers serve M >> N
# concurrent connections, bounded only by per-fiber memory.
#
# Fiber bodies use ordinary closure capture for sfd / client now
# (matz/spinel#564 + #1007 both closed; the heap-cell-reset fix
# in spinel commit 48594d6 lets multi-method capture chains lower
# correctly). cmeths still preferred for accept_loop /
# handle_connection so the bodies read cleanly without per-instance
# state, but the per-connection fd flows through closure capture,
# not the earlier `Tep::APP.pending_*` stash + pause(0) handoff.
module Tep
  class Server
    class Scheduled
      # Max bytes accepted from a single request's start-line +
      # headers. Bigger requests get 413; matches the blocking
      # server's SPHTTP_BUFSIZE cap (64 KiB).
      MAX_REQUEST_BYTES = 65535

      # Idle keep-alive timeout between requests on the same
      # connection. 30s matches nginx; bump from app code as needed.
      KEEPALIVE_TIMEOUT = 30

      # Slow-headers DoS guard.
      HEADER_READ_TIMEOUT = 10

      attr_accessor :app

      def initialize(app)
        @app = app
      end

      def run(port, workers, quiet)
        sfd = Sock.sphttp_listen(port, workers > 1 ? 1 : 0)
        if sfd < 0
          return 1
        end
        Sock.sphttp_set_nonblock(sfd)

        # Install SIGTERM/SIGINT handlers BEFORE fork so children
        # inherit them; accept_loop checks the term flag once per
        # second and runs Tep.on_shutdown (run_end + future hooks).
        Sock.sphttp_install_term_handlers

        # Inbound TLS (tep#148 phase 2, scheduled variant): load the
        # server cert/key once before forking so every worker inherits
        # the SSL_CTX. A bad cert/key is fatal -- never silently serve
        # plaintext on a port the operator believes is TLS. The handshake
        # itself runs non-blocking per-connection (handle_connection).
        if Tep::APP.tls_cert.length > 0 && Tep::APP.tls_key.length > 0
          if Sock.sphttp_tls_server_init(Tep::APP.tls_cert, Tep::APP.tls_key) < 0
            return 1
          end
        end

        if workers > 1
          i = 0
          while i < workers
            pid = Sock.sphttp_fork
            if pid == 0
              Tep::Server::Scheduled.run_worker(sfd)
              Sock.sphttp_exit(0)
            end
            i += 1
          end
          # Reap children until none remain. After all workers exit,
          # emit the single aggregated run_end (see #128 / Tep::Events
          # #run_end_aggregated).
          loop do
            gone = Sock.sphttp_wait_any
            if gone < 0
              break
            end
          end
          if Sock.sphttp_shutdown_requested != 0
            Tep.on_shutdown
          end
        else
          Tep::Server::Scheduled.run_worker(sfd)
          # Single-process: this IS the parent; emit run_end here.
          if Sock.sphttp_shutdown_requested != 0
            Tep.on_shutdown
          end
        end
        0
      end

      # Spawn the accept fiber + pump the scheduler. Called inside
      # each prefork child. Loops directly on `tick` rather than
      # `run_until_empty` because the accept fiber parks on io_wait
      # indefinitely -- run_until_empty bails when no fiber is ready
      # to resume THIS pass; we need to keep polling so parked
      # accept-on-sfd fibers get woken when a connection arrives.
      def self.run_worker(sfd)
        f = Fiber.new { Tep::Server::Scheduled.accept_loop(sfd) }
        Tep::Scheduler.spawn_fiber(f)
        while Tep::Scheduler.alive_count > 0
          Tep::Scheduler.tick(1000)
        end
        0
      end

      # Accept loop. Each accepted connection becomes its own fiber
      # that closes over the just-accepted `client` fd.
      def self.accept_loop(sfd)
        while true
          # SIGTERM/SIGINT: sphttp's term flag is set by the signal
          # handler; check before parking on io_wait so we don't sleep
          # past a shutdown request. The 1s io_wait timeout below
          # bounds the sleep-side latency. The parent (or this same
          # process for workers=1) emits the aggregated run_end after
          # all workers exit (#128).
          if Sock.sphttp_shutdown_requested != 0
            break
          end
          # Bounded wait so the flag check above runs once per second
          # even when traffic is idle (was -1 = wait forever).
          ready = Tep::Scheduler.io_wait(sfd, Tep::Scheduler::READ, 1)
          if ready == 0
            next
          end
          client = Sock.sphttp_accept_nb(sfd)
          if client < 0
            next
          end
          Sock.sphttp_set_nonblock(client)
          conn = Fiber.new { Tep::Server::Scheduled.handle_connection(client) }
          Tep::Scheduler.spawn_fiber(conn)
        end
      end

      # Non-blocking server-side TLS handshake on an accepted fd.
      # Returns 1 on success (SSL* registered -- reads/writes are now
      # transparent), 0 on failure. Drives SSL_do_handshake, parking on
      # io_wait for the direction OpenSSL asks for, bounded by
      # HEADER_READ_TIMEOUT so a connection that opens but never
      # completes the handshake (port probe, slowloris, plain-HTTP
      # client) can't pin the fiber.
      def self.tls_handshake(client)
        if Sock.sphttp_tls_accept_start(client) < 0
          return 0
        end
        deadline = Time.now.to_i + HEADER_READ_TIMEOUT
        hs = Sock.sphttp_tls_handshake_step(client)
        while hs == 1 || hs == 2
          remaining = deadline - Time.now.to_i
          if remaining <= 0
            return 0
          end
          mode = Tep::Scheduler::READ
          if hs == 2
            mode = Tep::Scheduler::WRITE
          end
          ready = Tep::Scheduler.io_wait(client, mode, remaining)
          if ready == 0
            return 0
          end
          hs = Sock.sphttp_tls_handshake_step(client)
        end
        if hs < 0
          return 0
        end
        1
      end

      # Per-connection lifecycle.
      def self.handle_connection(client)
        # Inbound TLS: complete a non-blocking server handshake before
        # reading anything. Runs inside this per-connection fiber so a
        # slow handshake parks cooperatively instead of blocking the
        # accept loop. On failure (incl. a plaintext client hitting the
        # TLS port) drop the connection.
        if Tep::APP.tls_cert.length > 0
          if Tep::Server::Scheduled.tls_handshake(client) == 0
            Sock.sphttp_close(client)
            return 0
          end
        end
        keep_going = true
        while keep_going
          blob = Tep::Server::Scheduled.read_request_blob(client, KEEPALIVE_TIMEOUT)
          if blob.length == 0
            break
          end
          req = Parser.parse(blob)
          if req == nil
            Tep::Server::Scheduled.send_simple(client, 400, "bad request")
            break
          end

          req.consume_body_via_scheduler(client)

          res = Response.new
          Tep::APP.dispatch(req, res)

          # Streaming responses use chunked Connection: close (same
          # simplification as the prefork server) -- force the
          # keep-alive loop to end after this response so the stream's
          # terminator isn't followed by a stale read on the same fd.
          keep_alive = req.keep_alive? && !res.halted_close? && !res.streaming
          Tep::Server::Scheduled.write_response(client, req, res, keep_alive)
          keep_going = keep_alive
        end
        Sock.sphttp_close(client)
        0
      end

      # Non-blocking request reader. Returns the accumulated blob
      # once "\r\n\r\n" is seen, or "" on timeout / EOF / oversize.
      def self.read_request_blob(fd, timeout_seconds)
        buf = ""
        deadline = Time.now.to_i + timeout_seconds
        while buf.length < MAX_REQUEST_BYTES
          remaining = deadline - Time.now.to_i
          if remaining <= 0
            return ""
          end
          ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, remaining)
          if ready == 0
            return ""
          end
          chunk = Sock.sphttp_recv_some(fd, 4096)
          if chunk.length == 0
            # Over TLS an empty read can be a partial record (SSL_read
            # WANT_READ/WANT_WRITE), not EOF -- re-park on the indicated
            # direction and retry rather than dropping the request. The
            # loop top re-applies the deadline on the want-read path.
            st = Sock.sphttp_io_status
            if st == 1
              next
            end
            if st == 2
              Tep::Scheduler.io_wait(fd, Tep::Scheduler::WRITE, remaining)
              next
            end
            return ""
          end
          buf = buf + chunk
          if buf.length >= 4 && buf.include?("\r\n\r\n")
            return buf
          end
        end
        ""
      end

      # Body-shape mirror of Tep::Server#write_response. Lifted into
      # a cmeth so the connection fiber can call it without a captured
      # `self`.
      def self.write_response(client, req, res, keep_alive)
        # WebSocket upgrade branch. Set by res.start_websocket in the
        # user's handler after a successful Handshake.check. Writes
        # the 101 Switching Protocols head, then assigns the client
        # fd onto the driver and runs the recv loop. The recv loop
        # returns when the connection closes (peer EOF, idle timeout,
        # or a CLOSE frame round-trip). After return, the caller's
        # handle_connection closes the fd as usual.
        if res.upgrading_ws
          head = Tep::WebSocket::Handshake.build_response(
            res.ws_accept_key, res.ws_driver.subprotocol)
          Sock.sphttp_write_str(client, head)
          res.ws_driver.set_fd(client)
          conn = Tep::WebSocket::Connection.new(res.ws_driver)
          conn.run
          return 0
        end

        # Streaming branch -- cooperative mirror of Tep::Server's
        # streaming path (server.rb). Set by res.start_stream(streamer)
        # in the handler. Writes a chunked-encoding head immediately,
        # hands a Tep::Stream writer to the user's Streamer#pump, then
        # emits the end-of-stream terminator. pump runs cooperatively:
        # it parks on Tep::Scheduler.io_wait between writes (e.g. the
        # proxy streamer waits on the upstream fd), so other fibers keep
        # running while this stream is in flight. Connection: close --
        # chunked keep-alive is legal but we keep it simple, matching
        # the prefork server.
        if res.streaming
          res.headers["Transfer-Encoding"] = "chunked"
          if !res.headers.key?("Content-Type")
            res.headers["Content-Type"] = "text/event-stream"
          end
          reason = Tep.reason(res.status)
          head = req.http_version + " " + res.status.to_s + " " + reason + "\r\n"
          res.headers.each do |k, v|
            head = head + k + ": " + v + "\r\n"
          end
          res.set_cookies.each do |line|
            head = head + "Set-Cookie: " + line + "\r\n"
          end
          head = head + "Connection: close\r\n\r\n"
          Sock.sphttp_write_str(client, head)
          out = Tep::Stream.new(client)
          res.streamer.pump(out)
          Sock.sphttp_write_chunk_end(client)
          return 0
        end

        # File validators for cache revalidation (#152): a size-mtime
        # ETag + Last-Modified, set before headers are serialized below.
        if res.file_path.length > 0
          fsz = Sock.sphttp_filesize(res.file_path)
          fmt = Sock.sphttp_file_mtime(res.file_path)
          if fsz >= 0 && fmt >= 0
            res.etag(fsz.to_s + "-" + fmt.to_s)
            res.last_modified(fmt)
          end
        end

        # Conditional GET (issue #152): 304 + no body when the request's
        # precondition matches the response's validator (ETag /
        # Last-Modified, whether set by the handler or for a file above).
        # For a file we also clear file_path so the sendfile branch below
        # is skipped and the empty 304 goes out the inline-body path.
        if Tep::Cache.not_modified?(req, res)
          res.set_status(304)
          res.set_body("")
          res.file_path = ""
        end

        # Default Content-Type for inline-body responses -- including
        # empty ones (redirects), for sinatra/Rack parity (differential
        # oracle finding; matches Tep::Server). 204/304 excepted: Rack
        # strips entity headers there. Without a Content-Type, the
        # Security::Headers nosniff default leaves the browser refusing
        # to interpret an erb response as HTML.
        if res.file_path.length == 0 && !res.headers.key?("Content-Type") &&
           res.status != 204 && res.status != 304
          res.headers["Content-Type"] = "text/html; charset=utf-8"
        end
        reason = Tep.reason(res.status)
        head = req.http_version + " " + res.status.to_s + " " + reason + "\r\n"
        res.headers.each do |k, v|
          head = head + k + ": " + v + "\r\n"
        end
        res.set_cookies.each do |line|
          head = head + "Set-Cookie: " + line + "\r\n"
        end
        if keep_alive
          head = head + "Connection: keep-alive\r\n"
        else
          head = head + "Connection: close\r\n"
        end
        if res.file_path.length > 0
          fs = Sock.sphttp_filesize(res.file_path)
          head = head + "Content-Length: " + fs.to_s + "\r\n\r\n"
          Sock.sphttp_write_str(client, head)
          Sock.sphttp_sendfile(client, res.file_path)
        else
          head = head + "Content-Length: " + res.body.length.to_s + "\r\n\r\n"
          Sock.sphttp_write_str(client, head)
          if res.body.length > 0
            Sock.sphttp_write_str(client, res.body)
          end
        end
        0
      end

      def self.send_simple(client, status, msg)
        reason = Tep.reason(status)
        head = "HTTP/1.0 " + status.to_s + " " + reason + "\r\n" +
               "Content-Length: " + msg.length.to_s + "\r\n" +
               "Connection: close\r\n\r\n" + msg
        Sock.sphttp_write_str(client, head)
        0
      end
    end
  end
end
