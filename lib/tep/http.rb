# Tep::Http -- a small outbound HTTP client, Faraday-shaped.
#
# Why
# ---
# Pure-Ruby HTTP clients (net/http, faraday, http.rb, httparty) all
# pull in things spinel can't lower: `Net::HTTP`'s subclass-per-verb
# wiring, faraday's middleware DSL (closures + define_method), the
# `http.rb` gem's MIME parser. tep's runtime already has the socket
# plumbing (sphttp_connect, sphttp_set_nonblock, sphttp_recv_*); the
# missing piece is the HTTP/1.0 client on top.
#
# Scope (v1)
# ----------
# * **HTTP only** -- no TLS. Talk to internal services, the local
#   Ollama API, vLLM, your own tep-backed sidecars.
# * **HTTP/1.0 + Connection: close** -- one socket per request,
#   read until EOF. No keep-alive, no pipelining.
# * **No chunked-transfer reading** -- assumes Content-Length or
#   close-delimited body. Most APIs do one or the other.
# * **No automatic redirects** -- callers inspect `.status` and
#   `.headers["location"]` and re-issue if they want.
# * **No streaming** -- whole response materialises in memory
#   (sphttp_recv_all caps at ~64 KB).
#
# These limits cover the dashboard's needs (talking to local
# inference backends) and the bulk of "hit an internal API"
# workloads. HTTPS + keep-alive + chunked land as a v2 surface.
#
# API shape
# ---------
# Faraday-style class shortcuts:
#
#   res = Tep::Http.get("http://api.local/users/42")
#   res = Tep::Http.post("http://api.local/users", '{"name":"a"}')
#   res.status  # Integer
#   res.headers # Hash<String,String>  (downcased keys)
#   res.body    # String
#
# Reusable client with a base URL + default headers:
#
#   c = Tep::Http.new("http://api.local")
#   c.set_header("Authorization", "Bearer tok")
#   res = c.do_get("/users/42")
#   res = c.do_post("/users", body)
#
# The instance verbs are `do_get` / `do_post` / `do_put` etc. (not
# the bare Faraday names) so a call like `http.get(path)` doesn't
# read as a Sinatra route inside an app. The class-level shortcuts
# (`Tep::Http.get(url)`) keep the Faraday spelling because cmeth
# names live in a separate namespace.
#
# Request-specific headers pass through the lower-level `send_req`:
#
#   h = Tep.str_hash
#   h["Accept"] = "application/json"
#   res = Tep::Http.send_req("GET", url, "", h)
module Tep
  class Http
    attr_accessor :base_url, :default_headers

    def initialize(base_url)
      @base_url = base_url
      @default_headers = Tep.str_hash
    end

    def set_header(k, v)
      @default_headers[k] = v
    end

    # Instance verbs. `path` is appended to `base_url` if it starts
    # with "/", or used as-is if it's a full URL. Prefixed with
    # `do_` to avoid the cmeth / imeth ambiguity at the call site:
    # `http.get(path)` reads like a Sinatra route in apps, whereas
    # `http.do_get(path)` does not.
    def do_get(path);         do_req(path, "GET",    ""); end
    def do_head(path);        do_req(path, "HEAD",   ""); end
    def do_delete(path);      do_req(path, "DELETE", ""); end
    def do_post(path, body);  do_req(path, "POST",   body); end
    def do_put(path, body);   do_req(path, "PUT",    body); end
    def do_patch(path, body); do_req(path, "PATCH",  body); end

    def do_req(path, verb, body)
      url = path
      if path.length > 0 && path[0] == "/"
        url = @base_url + path
      end
      Http.send_req(verb, url, body, @default_headers)
    end

    # Class-level one-shots. Build a default empty headers hash and
    # dispatch through send_req.
    def self.get(url);          Http.send_req("GET",    url, "", Http.empty_headers); end
    def self.head(url);         Http.send_req("HEAD",   url, "", Http.empty_headers); end
    def self.delete(url);       Http.send_req("DELETE", url, "", Http.empty_headers); end
    def self.post(url, body);   Http.send_req("POST",   url, body, Http.empty_headers); end
    def self.put(url, body);    Http.send_req("PUT",    url, body, Http.empty_headers); end
    def self.patch(url, body);  Http.send_req("PATCH",  url, body, Http.empty_headers); end

    def self.empty_headers
      Tep.str_hash
    end

    # Per-recv timeout in the cooperative path. Bounds how long a
    # parked fiber will wait for the next chunk from the peer before
    # giving up and returning status=0. 30s matches the scheduled
    # server's KEEPALIVE_TIMEOUT; loud failure beats a wedged fiber.
    COOP_RECV_TIMEOUT = 30

    # Hard cap on total response bytes accumulated by the cooperative
    # path. Mirrors sphttp_recv_all's static-buffer cap (~64 KiB) so
    # the two paths impose the same upper bound. Bigger responses
    # need streaming, which v1 doesn't ship.
    COOP_RESPONSE_MAX = 65535

    # The workhorse. Returns a Tep::Http::Response in all cases --
    # on connect or send failure, `.status` is 0 and `.body` is "".
    #
    # When called from inside a Tep::Scheduler fiber (i.e. running
    # under Tep::Server::Scheduled), routes through `send_req_coop`,
    # which parks on `Tep::Scheduler.io_wait` between recv calls so
    # the worker fiber doesn't hog the scheduler while waiting for
    # peer bytes. Outside scheduler context the call falls through to
    # `send_req_blocking`, which is the original sphttp_recv_all path.
    #
    # Why split rather than always-async: outside a scheduled context
    # (the default Tep::Server prefork model, scripts, REPL), io_wait
    # falls back to a single-shot poll per call which would add an
    # extra poll(2) round per chunk for no benefit. Keeping the
    # blocking path keeps the cheap case cheap.
    def self.send_req(verb, url, body, headers)
      # TLS currently has only a blocking path (the SSL handshake runs
      # over a blocking socket), so route https through send_req_blocking
      # even under the scheduler. Caveat: an https call inside
      # Tep::Server::Scheduled blocks the worker for that request;
      # plaintext keeps the cooperative path. (Non-blocking TLS is the
      # phase-1b follow-up on tep#148.)
      is_https = Tep::Url.split_url(url)["scheme"] == "https"
      if Tep::Scheduler.scheduled_context? && !is_https
        Http.send_req_coop(verb, url, body, headers)
      else
        Http.send_req_blocking(verb, url, body, headers)
      end
    end

    def self.send_req_blocking(verb, url, body, headers)
      out = Tep::Http::Response.new
      parts = Tep::Url.split_url(url)
      scheme = parts["scheme"]
      if scheme != "http" && scheme != "https"
        # Unknown scheme.
        return out
      end
      host = parts["host"]
      port = parts["port"].to_i
      path = parts["path"]
      if parts["query"].length > 0
        path = path + "?" + parts["query"]
      end

      fd = -1
      if scheme == "https"
        fd = Sock.sphttp_connect_tls(host, port)   # verified TLS (port 443 via Tep::Url)
      else
        fd = Sock.sphttp_connect(host, port)
      end
      if fd < 0
        return out
      end

      # Request head inlined (not extracted to a helper): spinel's
      # cross-method type inference picks one type per param name
      # across the whole file, and `path`/`host` collide with
      # int-typed uses elsewhere, breaking the build.
      head = verb + " " + path + " HTTP/1.0\r\n" +
             "Host: " + host + "\r\n" +
             "Connection: close\r\n"
      headers.each do |k, v|
        head = head + k + ": " + v + "\r\n"
      end
      if body.length > 0
        head = head + "Content-Length: " + body.length.to_s + "\r\n"
      end
      head = head + "\r\n"

      if Sock.sphttp_write_str(fd, head) < 0
        Sock.sphttp_close(fd)
        return out
      end
      if body.length > 0
        if Sock.sphttp_write_str(fd, body) < 0
          Sock.sphttp_close(fd)
          return out
        end
      end

      raw = Sock.sphttp_recv_all(fd, 0)  # 0 -> cap at sphttp internal max
      Sock.sphttp_close(fd)

      Http.parse_response(raw)
    end

    # Cooperative variant. Same wire shape, same parse, but:
    #   * flips the fd to non-blocking after connect, and
    #   * replaces the synchronous sphttp_recv_all with a parked
    #     io_wait(READ) + sphttp_recv_some loop that yields the
    #     worker fiber back to the scheduler between recvs.
    #
    # This is what closes the macOS self-call deadlock: while the
    # outer handler fiber is parked here, the worker's accept fiber
    # can run, accept the inner request, dispatch its handler, and
    # write the response -- which unblocks our io_wait. See
    # docs/MACOS-CONCURRENCY.md for the why.
    def self.send_req_coop(verb, url, body, headers)
      out = Tep::Http::Response.new
      parts = Tep::Url.split_url(url)
      if parts["scheme"] != "http"
        return out
      end
      host = parts["host"]
      port = parts["port"].to_i
      path = parts["path"]
      if parts["query"].length > 0
        path = path + "?" + parts["query"]
      end

      fd = Sock.sphttp_connect(host, port)
      if fd < 0
        return out
      end
      Sock.sphttp_set_nonblock(fd)

      # Same head shape as send_req_blocking; inlined for the same
      # spinel-type-inference reason (see that path's comment).
      head = verb + " " + path + " HTTP/1.0\r\n" +
             "Host: " + host + "\r\n" +
             "Connection: close\r\n"
      headers.each do |k, v|
        head = head + k + ": " + v + "\r\n"
      end
      if body.length > 0
        head = head + "Content-Length: " + body.length.to_s + "\r\n"
      end
      head = head + "\r\n"

      # send(2) on a non-blocking localhost socket with a small
      # request (start line + few headers, well under the kernel's
      # ~16 KiB socket buffer) returns immediately. If it ever
      # surfaces EAGAIN we'll need a write-side park; for v1 the
      # bounded request size makes that path dead code.
      if Sock.sphttp_write_str(fd, head) < 0
        Sock.sphttp_close(fd)
        return out
      end
      if body.length > 0
        if Sock.sphttp_write_str(fd, body) < 0
          Sock.sphttp_close(fd)
          return out
        end
      end

      raw = ""
      while raw.length < COOP_RESPONSE_MAX
        ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, COOP_RECV_TIMEOUT)
        if ready == 0
          # Timeout -- bail with whatever we have so far. An
          # incomplete response will surface as status=0 from
          # parse_response if the status line never arrived.
          break
        end
        chunk = Sock.sphttp_recv_some(fd, 4096)
        if chunk.length == 0
          # EOF (or transient EAGAIN that recv_some swallows). For
          # HTTP/1.0 + Connection: close that's the end-of-response
          # signal.
          break
        end
        raw = raw + chunk
      end

      Sock.sphttp_close(fd)
      Http.parse_response(raw)
    end

    # Parse a raw HTTP/1.0 or 1.1 response. Status line + headers
    # (terminated by \r\n\r\n) + body. Header names are downcased
    # so callers don't have to worry about case. Allocates and
    # returns a fresh Response (rather than mutating one passed in
    # by reference -- the mutation pattern widens the param to
    # poly in spinel's analyzer).
    def self.parse_response(raw)
      out = Tep::Http::Response.new
      if raw.length < 12
        return out
      end
      # Status line: "HTTP/1.x SSS reason\r\n"
      eol = Tep.str_find(raw, "\r\n", 0)
      if eol < 0
        return out
      end
      line = raw[0, eol]
      sp1 = Tep.str_find(line, " ", 0)
      if sp1 < 0
        return out
      end
      rest = line[sp1 + 1, line.length - sp1 - 1]
      sp2 = Tep.str_find(rest, " ", 0)
      code_str = ""
      if sp2 >= 0
        code_str = rest[0, sp2]
      else
        code_str = rest
      end
      out.status = code_str.to_i

      # Walk header lines until empty line.
      pos = eol + 2
      while pos < raw.length
        next_eol = Tep.str_find(raw, "\r\n", pos)
        if next_eol < 0
          return out
        end
        if next_eol == pos
          # blank line -- body starts at pos+2
          body_start = pos + 2
          if body_start < raw.length
            out.body = raw[body_start, raw.length - body_start]
          end
          return out
        end
        line2 = raw[pos, next_eol - pos]
        ci = Tep.str_find(line2, ":", 0)
        if ci > 0
          k = line2[0, ci].downcase
          # Skip leading space after the colon.
          v_start = ci + 1
          if v_start < line2.length && line2[v_start] == " "
            v_start += 1
          end
          v = line2[v_start, line2.length - v_start]
          out.headers[k] = v
        end
        pos = next_eol + 2
      end
      out
    end

    class Response
      attr_accessor :status, :headers, :body
      def initialize
        @status  = 0
        @headers = Tep.str_hash
        @body    = ""
      end
    end

    # HTTP/1.1 outbound connection pool (chunk 6.7a -- design lands
    # ahead of Tep::Http.send_req integration in 6.7b). Per-process,
    # keyed by (host, port). Thin Ruby surface over the C primitives
    # in sphttp.c.
    #
    # Method names are `claim` / `release` (NOT `checkout` / `checkin`)
    # to avoid colliding with `PG::Pool#checkin` -- spinel unifies
    # parameter types across same-named methods, so reusing the names
    # widens PG::Pool's `c` (a PG::Connection) and our `fd` (an int)
    # into a poly type and breaks the codegen.
    #
    # In 6.7a, this module is callable but NOT YET wired into
    # send_req -- Tep::Http still opens a fresh socket per request +
    # closes it. The 6.7b chunk lands the integration once the
    # HTTP/1.1 keep-alive recv-N-bytes path is in place. Apps can
    # already use Pool directly for their own outbound clients.
    class Pool
      # Try to claim an idle keep-alive fd for (host, port). Returns
      # the fd (>=0) on hit, -1 on miss. The caller owns the fd on
      # hit -- close it explicitly if the request fails, or
      # `release` it for reuse.
      def self.claim(host, port)
        Sock.sphttp_pool_checkout(host, port)
      end

      # Register `fd` as an idle keep-alive socket for (host, port).
      # Returns 0 on success, -1 on failure (pool full -- the LRU
      # gets evicted internally, so failures are rare). Don't release
      # after a 5xx that triggered retries (the half-broken socket
      # would poison the pool) -- close directly via Sock.sphttp_close.
      def self.release(fd, host, port)
        Sock.sphttp_pool_checkin(fd, host, port)
      end

      # Close idle fds older than `idle_seconds`. Returns the count
      # closed. Call periodically from the server's idle path; not
      # called automatically yet.
      def self.close_idle(idle_seconds)
        Sock.sphttp_pool_close_idle(idle_seconds)
      end

      # Stats snapshot -- returns a Tep.str_hash with the four
      # counters. checkouts/checkins are total calls; hits/misses
      # are subsets of checkouts (hit + miss = checkouts). The
      # C-side primitives keep the underlying counter names; this
      # surface uses the same names for clarity.
      def self.stats
        h = Tep.str_hash
        h["checkouts"] = Sock.sphttp_pool_stat_checkouts.to_s
        h["checkins"]  = Sock.sphttp_pool_stat_checkins.to_s
        h["hits"]      = Sock.sphttp_pool_stat_hits.to_s
        h["misses"]    = Sock.sphttp_pool_stat_misses.to_s
        h
      end
    end
  end
end
