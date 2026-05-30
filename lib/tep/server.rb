# Tep::Server -- accept loop. Single-threaded inside one process;
# the perf model is "fork N workers, each runs its own Server"
# (-w workers) using SO_REUSEPORT so the kernel load-balances.
module Tep
  def self.reason(status)
    if status == 200; return "OK"; end
    if status == 201; return "Created"; end
    if status == 204; return "No Content"; end
    if status == 301; return "Moved Permanently"; end
    if status == 302; return "Found"; end
    if status == 304; return "Not Modified"; end
    if status == 400; return "Bad Request"; end
    if status == 401; return "Unauthorized"; end
    if status == 403; return "Forbidden"; end
    if status == 404; return "Not Found"; end
    if status == 500; return "Internal Server Error"; end
    "OK"
  end

  class Server
    attr_accessor :app

    def initialize(app)
      @app = app
    end

    def run(port, workers, quiet)
      scheme = "http"
      if Tep::APP.tls_cert.length > 0
        scheme = "https"
      end
      if !quiet
        puts "[tep " + VERSION + "] listening on " + scheme + "://0.0.0.0:" + port.to_s +
             " (workers=" + workers.to_s + ")"
      end

      # Install SIGTERM/SIGINT handlers BEFORE fork so children inherit
      # them; on signal, sphttp_accept returns -1 and the worker loop
      # runs Tep.on_shutdown (flushes events.run_end + future hooks).
      Sock.sphttp_install_term_handlers

      # Inbound TLS (tep#148 phase 2): load the server cert/key once
      # before forking so every worker inherits the SSL_CTX. A bad
      # cert/key is fatal -- fail loud rather than serve plaintext on a
      # port the operator believes is TLS.
      if Tep::APP.tls_cert.length > 0 && Tep::APP.tls_key.length > 0
        if Sock.sphttp_tls_server_init(Tep::APP.tls_cert, Tep::APP.tls_key) < 0
          puts "tep: TLS init failed (cert=" + Tep::APP.tls_cert + ", key=" + Tep::APP.tls_key + ")"
          exit(1)
        end
      end

      if workers <= 1
        sfd = Sock.sphttp_listen(port, 0)
        if sfd < 0
          puts "tep: bind failed on :" + port.to_s
          exit(1)
        end
        worker_loop(sfd)
        # Single-process is its own "parent" -- emit run_end here.
        if Sock.sphttp_shutdown_requested != 0
          Tep.on_shutdown
        end
        return
      end

      # Pre-fork. Each child opens its own SO_REUSEPORT listener so
      # the kernel load-balances accept() across workers.
      i = 0
      while i < workers
        pid = Sock.sphttp_fork
        if pid == 0
          sfd = Sock.sphttp_listen(port, 1)
          if sfd < 0
            puts "tep: worker " + Sock.sphttp_getpid.to_s + " bind failed"
            exit(1)
          end
          worker_loop(sfd)
          exit(0)
        end
        i += 1
      end
      # Parent: reap children until none remain (wait returns -1).
      # On SIGTERM-to-the-pgroup, children break their accept loops and
      # exit; parent's wait_any reaps them in order. Once all workers
      # are gone, emit the single aggregated run_end (re-reading the
      # JSONL for cross-worker stats; see Tep::Events#run_end_aggregated).
      loop do
        gone = Sock.sphttp_wait_any
        if gone < 0
          break
        end
      end
      if Sock.sphttp_shutdown_requested != 0
        Tep.on_shutdown
      end
    end

    def worker_loop(sfd)
      loop do
        client = Sock.sphttp_accept(sfd)
        if client < 0
          # accept returns -1 with the term flag set after the first
          # SIGTERM/SIGINT (sphttp_accept retries past unrelated
          # signals). Break here; the parent (or this same process for
          # workers=1) emits the aggregated run_end. Workers used to
          # call Tep.on_shutdown here too, which emitted N run_ends
          # in the JSONL for an N-worker deployment (#128).
          if Sock.sphttp_shutdown_requested != 0
            break
          end
          next
        end
        # Inbound TLS: complete the server-side handshake on the freshly
        # accepted fd before reading the request. Bound the handshake
        # with a recv timeout first -- otherwise a connection that opens
        # but never sends a ClientHello (a port probe, a slowloris, a
        # plain-HTTP client) blocks SSL_accept and wedges this worker.
        # Clear the timeout after a successful handshake so normal
        # (incl. keep-alive) request reads aren't bounded. On failure
        # drop the connection.
        if Tep::APP.tls_cert.length > 0
          Sock.sphttp_set_recv_timeout(client, 5000)
          if Sock.sphttp_accept_tls(client) < 0
            Sock.sphttp_close(client)
            next
          end
          Sock.sphttp_set_recv_timeout(client, 0)
        end
        handle_connection(client)
      end
    end

    # Keep-alive loop on a single accepted connection.
    def handle_connection(client)
      keep_going = true
      while keep_going
        n = Sock.sphttp_read_request(client)
        if n <= 0
          break
        end
        blob = Sock.sphttp_request_buf
        req = Parser.parse(blob)
        if req == nil
          send_simple(client, 400, "bad request")
          break
        end

        req.consume_body(client)

        res = Response.new
        @app.dispatch(req, res)

        keep_alive = req.keep_alive? && !res.halted_close?
        write_response(client, req, res, keep_alive)
        keep_going = keep_alive
      end
      Sock.sphttp_close(client)
    end

    def write_response(client, req, res, keep_alive)
      # WebSocket upgrade is only supported under Tep::Server::Scheduled
      # (the recv loop needs cooperative I/O via Tep::Scheduler.io_wait).
      # Under the prefork-blocking server, fail with 501 so the client
      # sees a clean refusal instead of a half-installed handshake.
      if res.upgrading_ws
        send_simple(client, 501, "WebSocket requires the scheduled server: set :scheduler, :scheduled")
        return
      end
      if res.streaming
        # Chunked-encoding stream. Send headers immediately, hand a
        # Stream writer to the user's Streamer.pump, emit terminator.
        # Connection is closed afterwards (keep-alive + chunked is
        # technically legal but we keep things simple).
        res.headers["Transfer-Encoding"] = "chunked"
        res.headers["Connection"] = "close"
        if !res.headers.key?("Content-Type")
          res.headers["Content-Type"] = "text/event-stream"
        end
        head = build_head(req, res)
        Sock.sphttp_write_str(client, head)
        out = Stream.new(client)
        res.streamer.pump(out)
        Sock.sphttp_write_chunk_end(client)
        return
      end

      if res.file_path.length > 0
        # send_file path -- compute size, emit headers, then stream.
        sz = Sock.sphttp_filesize(res.file_path)
        if sz < 0
          send_simple(client, 404, "file not found")
          return
        end
        # Cache validators for revalidation (#152): a size-mtime ETag +
        # Last-Modified, set before the conditional check.
        mt = Sock.sphttp_file_mtime(res.file_path)
        if mt >= 0
          res.etag(sz.to_s + "-" + mt.to_s)
          res.last_modified(mt)
        end
        if !res.headers.key?("Content-Type")
          res.headers["Content-Type"] = "application/octet-stream"
        end
        if keep_alive
          res.headers["Connection"] = "keep-alive"
        else
          res.headers["Connection"] = "close"
        end
        # Conditional GET: 304 + no body (no sendfile) when the client's
        # cached copy is still fresh.
        if Tep::Cache.not_modified?(req, res)
          res.set_status(304)
          res.headers["Content-Length"] = "0"
          Sock.sphttp_write_str(client, build_head(req, res))
          return
        end
        res.headers["Content-Length"] = sz.to_s
        head = build_head(req, res)
        Sock.sphttp_write_str(client, head)
        Sock.sphttp_sendfile(client, res.file_path)
        return
      end

      # Conditional GET: if the handler set a validator (ETag /
      # Last-Modified) that the request's precondition satisfies, drop to
      # 304 with no body. The validator + cache headers already on res
      # are still emitted; Content-Length becomes 0 below. (Issue #152.)
      if Tep::Cache.not_modified?(req, res)
        res.set_status(304)
        res.set_body("")
      end

      if res.body.length > 0 && !res.headers.key?("Content-Type")
        res.headers["Content-Type"] = "text/html; charset=utf-8"
      end
      res.headers["Content-Length"] = res.body.length.to_s
      if keep_alive
        res.headers["Connection"] = "keep-alive"
      else
        res.headers["Connection"] = "close"
      end

      head = build_head(req, res)
      Sock.sphttp_write_str(client, head)
      if res.body.length > 0
        Sock.sphttp_write_str(client, res.body)
      end
    end

    def build_head(req, res)
      reason = Tep.reason(res.status)
      head = req.http_version + " " + res.status.to_s + " " + reason + "\r\n"
      res.headers.each do |k, v|
        head = head + k + ": " + v + "\r\n"
      end
      # Set-Cookie can repeat; emit each on its own line.
      ci = 0
      while ci < res.set_cookies.length
        head = head + "Set-Cookie: " + res.set_cookies[ci] + "\r\n"
        ci += 1
      end
      head + "\r\n"
    end

    def send_simple(client, status, msg)
      reason = Tep.reason(status)
      body = "<h1>" + status.to_s + " " + reason + "</h1><p>" + msg + "</p>\n"
      head = "HTTP/1.0 " + status.to_s + " " + reason + "\r\n" +
             "Content-Type: text/html; charset=utf-8\r\n" +
             "Content-Length: " + body.length.to_s + "\r\n" +
             "Connection: close\r\n\r\n"
      Sock.sphttp_write_str(client, head + body)
    end
  end
end
