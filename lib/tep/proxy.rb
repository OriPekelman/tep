# Tep::Proxy -- HTTP reverse proxy battery (chunk 6.1).
#
# A Tep::Handler subclass that forwards a request to an upstream
# HTTP server, runs user hooks in both directions, and copies the
# response back to the client. Mount it at any route like a normal
# handler; one instance can serve many paths:
#
#   class OpenAIProxy < Tep::Proxy
#     def before_forward(req, res, ureq)
#       ureq.set_header("Authorization", "Bearer " + ENV["OPENAI_KEY"])
#       false   # forward (return true to short-circuit)
#     end
#
#     def after_forward(req, ures, res)
#       LOGGER.info("upstream " + ures.status.to_s)   # LOGGER = SpinelKit::Log.new
#       0
#     end
#   end
#
#   api = OpenAIProxy.new("http://api.internal:8080")
#   Tep.post "/v1/chat/completions", api
#   Tep.get  "/v1/models",           api
#
# Why subclass-and-override instead of the `api.before do ... end`
# block DSL in docs/PROXY-BATTERY.md: that block form needs the
# bin/tep translator to recognise `<proxyvar>.before do ... end`
# (a receiver-method call with a block) and lower it into instance
# methods on a generated subclass -- spinel can't store a
# PtrArray<Block> on the instance. Until that translator chunk
# lands, overriding `before_forward` / `after_forward` on a
# subclass IS the lowering target, just hand-authored. This mirrors
# how Tep::LiveView shipped its overridable hooks before the
# `Tep.live` auto-wire helper (see lib/tep/live_view.rb).
#
# The hook names are `before_forward` / `after_forward` rather than
# bare `before` / `after` on purpose: Tep::Filter / Tep::Security /
# Tep::Auth already define 2-arg `before(req, res)` / `after(req,
# res)` imeths, and spinel's virtual-imeth dispatch unifies on the
# method name -- a 3-arg `before` here would collide with those
# (see [[spinel-widening-dispatch]]). Distinct names sidestep it.
#
# Scope (6.1): non-streaming bodies only. Streaming (chunked / SSE
# pass-through) + the on_stream_chunk / on_stream_end hooks land in
# chunk 6.2. Outbound is HTTP/1.0 via Tep::Http, so the upstream
# must be reachable over plaintext http:// (https:// upstreams need
# the TLS-capable outbound client deferred to a later chunk).
module Tep
  # Retry behaviour for the buffered forward path (chunk 6.5).
  # Returned by Tep::Proxy#retry_policy(req); fresh instance per
  # request so the policy can be derived from the request (e.g.
  # idempotent verbs get more attempts, POSTs none).
  #
  # Backoff is integer-MILLISECONDS via Sock.sphttp_sleep_ms (a
  # nanosleep-backed C helper). Sub-second pacing is the right
  # default for HTTP retries -- whole-second backoffs throw away
  # throughput on transient blips that resolve quickly. Two setters
  # for the base backoff:
  #   * base_backoff_ms = 100              # int, direct ms.
  #   * base_backoff_secs = 0.1            # Float, converted to ms.
  # Set whichever reads better at the call site; both feed the same
  # ms-int through backoff_for. If both are set, the LAST write
  # wins (whichever setter you called second).
  #
  # Default shape: max_attempts=1 (no retry, back-compat).
  class Proxy < Tep::Handler
    class RetryPolicy
      attr_accessor :max_attempts, :base_backoff_ms, :backoff_multiplier
      attr_accessor :retry_on_status

      def initialize
        @max_attempts        = 1
        @base_backoff_ms     = 0
        @backoff_multiplier  = 2
        # Default: transient upstream errors (gateway / unavailable /
        # timeout). 502 also catches our own connect-failure mapping.
        @retry_on_status = [502, 503, 504]
      end

      # Float-seconds convenience setter (e.g. 0.5 -> 500ms). Stores
      # the value in @base_backoff_ms as an int so backoff_for / the
      # sleep call stay int-only on the hot path.
      def base_backoff_secs=(f)
        @base_backoff_ms = (f * 1000.0).to_i
      end

      # Reader symmetric to the setter (Float seconds derived from
      # the stored ms). Cheap; only the setter does the conversion
      # in the common case.
      def base_backoff_secs
        @base_backoff_ms.to_f / 1000.0
      end

      # Milliseconds to sleep BEFORE attempt N (0-indexed). attempt=0
      # is the first retry's pre-delay; attempt=1 the second's, etc.
      # Returns 0 when base is 0 (test-friendly: no delay between
      # retries by default).
      def backoff_for(attempt)
        if @base_backoff_ms <= 0
          return 0
        end
        d = @base_backoff_ms
        i = 0
        while i < attempt
          d = d * @backoff_multiplier
          i += 1
        end
        d
      end

      # Should the proxy retry given the upstream response status?
      # Connect/send failures (status == 0) always count as retriable.
      def retriable?(status)
        if status == 0
          return true
        end
        i = 0
        while i < @retry_on_status.length
          if @retry_on_status[i] == status
            return true
          end
          i += 1
        end
        false
      end
    end
  end

  class Proxy
    attr_accessor :upstream, :timeout
    # Body size caps (chunk 6.6). max_request_body_bytes bounds the
    # inbound body the proxy will accept (over -> 413 Payload Too
    # Large before any upstream call). max_response_body_bytes
    # bounds the upstream response body the proxy will forward
    # (over -> 502 with a proxy_error JSON). Defaults: 1 MiB request
    # / 8 MiB response -- enough for typical JSON-API gateway use,
    # small enough that a malicious / malfunctioning peer can't
    # easily OOM the worker. Override in initialize() (or expose a
    # block-DSL setter) for larger / smaller caps per deployment.
    # Set either to 0 to disable that cap (not recommended).
    attr_accessor :max_request_body_bytes, :max_response_body_bytes

    def initialize(upstream)
      @upstream = upstream
      @timeout  = 30
      @max_request_body_bytes  = 1 * 1024 * 1024
      @max_response_body_bytes = 8 * 1024 * 1024
    end

    # ---- Overridable hooks (subclasses customise these) ----

    # Per-request retry policy (chunk 6.5). Return a
    # Tep::Proxy::RetryPolicy whose max_attempts > 1 to retry the
    # buffered forward on transient upstream failure. Default: 1
    # attempt (no retry). Override to enable retries; gate on the
    # request shape so non-idempotent POSTs can skip retries while
    # GETs use them:
    #
    #   class ApiGateway < Tep::Proxy
    #     def retry_policy(req)
    #       p = Tep::Proxy::RetryPolicy.new
    #       p.max_attempts     = 3
    #       p.base_backoff_ms  = 100   # exponential: 100ms, 200ms, 400ms
    #       p
    #     end
    #   end
    #
    # Also available as a block-DSL hook (lowered by bin/tep).
    # Streaming requests don't retry (the stream may have already
    # written bytes to the client when failure occurs); only the
    # buffered path consults the policy.
    def retry_policy(req)
      Tep::Proxy::RetryPolicy.new
    end

    # Per-request upstream selection (chunk 6.4). Return the URL of
    # the upstream this request should be forwarded to. Default
    # returns @upstream (the constructor's single-upstream value),
    # preserving back-compat. Override to route by path / header /
    # tenant / capability:
    #
    #   class ApiGateway < Tep::Proxy
    #     def pick_upstream(req)
    #       if req.path.start_with?("/api/v1/")
    #         "http://upstream-v1.local:8080"
    #       else
    #         "http://upstream-v2.local:8080"
    #       end
    #     end
    #   end
    #
    # Also available as a block-DSL hook (lowered by bin/tep):
    #
    #   gw = Tep::Proxy.new("http://default.local:8080")
    #   gw.pick_upstream do |req|
    #     ...
    #   end
    #
    # The returned URL is prefix-joined with the rewrite_path output,
    # so it should NOT include the request path (just scheme://host:port
    # + optional fixed prefix).
    def pick_upstream(req)
      @upstream
    end

    # Map the inbound request's path+query to the upstream
    # path+query. Default: forward verbatim. Override to strip a
    # mount prefix, pin a fixed upstream path, etc.
    def rewrite_path(path)
      path
    end

    # Runs after the request body is fully received, before
    # forwarding. `ureq` is a mutable Tep::Proxy::UpstreamRequest
    # (verb / path / headers / body) pre-filled from the inbound
    # request with hop-by-hop headers stripped. Mutate it to tweak
    # what the upstream sees. Return `true` to short-circuit -- the
    # upstream call is skipped and `res` (which you set) is sent to
    # the client. Return `false` to forward. Default: forward.
    def before_forward(req, res, ureq)
      false
    end

    # Runs after the upstream responds, before `res` is written to
    # the client. `ures` is the Tep::Http::Response from upstream
    # (status 0 + empty body on connect failure; an empty Response
    # when a before_forward short-circuited). `res` is mutable and
    # already carries the upstream status / headers / body. Use this
    # to transform the final response or emit logs/metrics. Runs on
    # the short-circuit path too, so audit logging sees rejected
    # requests. Default: no-op.
    def after_forward(req, ures, res)
      0
    end

    # Streaming opt-in predicate. Return true to forward this request
    # over a held-open connection and pump the upstream response
    # through on_stream_chunk / on_stream_end (chunk 6.2) instead of
    # the buffered before/after path. Default: false (buffered).
    #
    # tep uses a request-side opt-in rather than sniffing the upstream
    # response Content-Type because (a) it keeps the non-streaming path
    # on the unchanged buffered Tep::Http.send_req (no manual-connect
    # tax on the common case), and (b) it matches how streaming APIs
    # actually signal intent -- an OpenAI client sets `"stream": true`
    # in the request body, so the proxy knows before it connects.
    # An LLM gateway typically overrides this as:
    #
    #   def stream_request?(req)
    #     SpinelKit::Json.get_bool(req.raw_body, "stream")
    #   end
    def stream_request?(req)
      false
    end

    # Per-chunk streaming hook (chunk 6.2). Called once per upstream
    # body chunk -- one dechunked HTTP chunk for a chunked upstream,
    # or one complete SSE event record ("...\n\n", including the
    # trailing blank line) for a text/event-stream upstream. `out` is
    # the Tep::Stream writer to the client; `stats` is a
    # Tep::Proxy::StreamStats carried across the whole stream (the
    # framework maintains stats.byte_count / stats.chunk_count;
    # accumulate your own counters in stats.meta_bag["key"]). Default:
    # pass the chunk through unchanged. Drop it by not calling
    # out.write; transform by writing modified bytes; fan out by
    # writing more than once.
    #
    # `chunk` is a Tep::Proxy::StreamChunk, NOT a bare String: read
    # the bytes via `chunk.chunk_text`. The wrapper exists because spinel
    # boxes a primitive String arg to poly when it flows through the
    # poly-receiver dispatch into this overridable hook -- a bare
    # String param would arrive poly and block String methods
    # (chunk.include? etc.). An object param survives the dispatch as
    # a typed pointer (same reason Tep::WebSocket passes `evt` with an
    # evt.data accessor). See [[spinel-widening-dispatch]].
    def on_stream_chunk(chunk, out, stats)
      out.write(chunk.chunk_text)
      0
    end

    # End-of-stream finalizer (chunk 6.2, #81). Fires exactly once
    # after the last chunk has been emitted and the upstream closed
    # (cleanly or via error -- stats.errored distinguishes). `out` is
    # still writable, so a finalizer can emit one last frame (e.g. a
    # closing SSE event). `stats` is the same object on_stream_chunk
    # accumulated into. Default: no-op.
    def on_stream_end(req, out, stats)
      0
    end

    # ---- Tep::Handler interface ----

    def handle(req, res)
      # Request-body cap (chunk 6.6). Reject oversize bodies BEFORE
      # any upstream call. 413 Payload Too Large with an OpenAI-shape
      # error JSON for symmetry with the other handler error paths.
      # max_request_body_bytes == 0 disables the cap.
      if @max_request_body_bytes > 0 && req.raw_body.length > @max_request_body_bytes
        res.set_status(413)
        res.headers["Content-Type"] = "application/json"
        err_body = "{\"error\":{" +
          SpinelKit::Json.encode_pair_str("message",
            "request body exceeds proxy cap of " +
            @max_request_body_bytes.to_s + " bytes") + "," +
          SpinelKit::Json.encode_pair_str("type", "payload_too_large") +
        "}}"
        res.set_body(err_body)
        return err_body
      end

      ureq = Tep::Proxy::UpstreamRequest.new
      ureq.verb = req.verb
      ureq.path = rewrite_path(req.raw_path)
      ureq.body = req.raw_body
      # Copy inbound headers minus: hop-by-hop (RFC 7230), `host`
      # (Tep::Http derives Host from the upstream URL -- forwarding
      # the client's Host would emit a duplicate, which nginx-class
      # upstreams 400), and `content-length` (Tep::Http computes its
      # own from the body, same duplicate risk).
      req.req_headers.each do |k, v|
        lc = k.downcase
        if !Tep::Proxy.hop_by_hop?(k) && lc != "host" && lc != "content-length"
          ureq.headers[k] = v
        end
      end

      short = before_forward(req, res, ureq)
      if short
        # Short-circuited: no upstream call. after_forward still
        # runs (audit), with an empty upstream Response.
        after_forward(req, Tep::Http::Response.new, res)
        return res.body
      end

      # Streaming branch (chunk 6.2). When the handler opts the
      # request into streaming, forward over a held-open connection
      # and pump the upstream body through on_stream_chunk to the
      # client, firing on_stream_end once at the end. Requires the
      # scheduled server (cooperative io_wait), same constraint as
      # WebSocket. after_forward is NOT run for streamed responses
      # (it's the non-streaming analog; on_stream_end is its
      # streaming counterpart).
      if stream_request?(req)
        return start_streaming_forward(req, res, ureq)
      end

      url    = pick_upstream(req) + ureq.path
      policy = retry_policy(req)
      attempt = 0
      ures = Tep::Http::Response.new
      while attempt < policy.max_attempts
        ures = Tep::Http.send_req(ureq.verb, url, ureq.body, ureq.headers)
        # Success or non-retriable failure -- done.
        if !policy.retriable?(ures.status)
          break
        end
        attempt += 1
        # Sleep before the NEXT attempt, only if there is one. Backoff
        # is integer milliseconds via the nanosleep-backed C helper;
        # default 0 (no delay) keeps tests fast.
        if attempt < policy.max_attempts
          backoff = policy.backoff_for(attempt - 1)
          if backoff > 0
            Sock.sphttp_sleep_ms(backoff)
          end
        end
      end
      # Expose retry count to observability filters via req.ivars.
      req.ivars["proxy_retry_count"] = attempt.to_s

      # Response-body cap (chunk 6.6). If the upstream returned more
      # bytes than the proxy will forward, fail with 502 + a
      # proxy_error JSON. The body has already been buffered by
      # Tep::Http (no streaming on the buffered path), so this is a
      # post-hoc reject -- worst case the worker briefly holds the
      # large body then drops it. A future streaming-aware cap can
      # bail mid-recv.
      if @max_response_body_bytes > 0 && ures.body.length > @max_response_body_bytes
        res.set_status(502)
        res.headers["Content-Type"] = "application/json"
        err_body = "{\"error\":{" +
          SpinelKit::Json.encode_pair_str("message",
            "upstream response body exceeds proxy cap of " +
            @max_response_body_bytes.to_s + " bytes") + "," +
          SpinelKit::Json.encode_pair_str("type", "upstream_body_too_large") +
        "}}"
        res.set_body(err_body)
        return err_body
      end

      if ures.status > 0
        res.set_status(ures.status)
      else
        # Connect / send failure, or non-http upstream scheme.
        res.set_status(502)
      end

      # Copy upstream response headers, minus hop-by-hop AND
      # content-length: the tep server writer computes its own
      # Content-Length from res.body, so a copied one would
      # duplicate the header.
      ures.headers.each do |k, v|
        if !Tep::Proxy.hop_by_hop?(k) && k.downcase != "content-length"
          res.headers[k] = v
        end
      end

      # Force the body assignment through a Response method (self is
      # unambiguously Response there) -- a direct `res.body =` from
      # this poly-dispatched handle() mis-codegens under spinel.
      res.set_body(ures.body)

      after_forward(req, ures, res)
      res.body
    end

    # Streaming forward (chunk 6.2). Connects to the upstream, writes
    # the request, reads just the response head, then hands the still-
    # open fd to a ProxyStreamer via res.start_stream -- the server
    # later drives streamer.pump, which recv-loops the upstream body
    # and dispatches it through on_stream_chunk / on_stream_end.
    #
    # Returns "" (the streamed body goes out via the streamer, not the
    # buffered res.body). On connect/scheme/head-read failure, sets a
    # 502 and returns "" without starting a stream.
    def start_streaming_forward(req, res, ureq)
      url   = pick_upstream(req) + ureq.path
      parts = SpinelKit::Url.split_url(url)
      if parts["scheme"] != "http"
        res.set_status(502)
        return ""
      end
      host = parts["host"]
      port = parts["port"].to_i
      path = parts["path"]
      if parts["query"].length > 0
        path = path + "?" + parts["query"]
      end

      fd = Sock.sphttp_connect(host, port)
      if fd < 0
        res.set_status(502)
        return ""
      end
      Sock.sphttp_set_nonblock(fd)

      head = ureq.verb + " " + path + " HTTP/1.1\r\n" +
             "Host: " + host + "\r\n" +
             "Connection: close\r\n"
      ureq.headers.each do |k, v|
        head = head + k + ": " + v + "\r\n"
      end
      if ureq.body.length > 0
        head = head + "Content-Length: " + ureq.body.length.to_s + "\r\n"
      end
      head = head + "\r\n"
      if Sock.sphttp_write_str(fd, head) < 0
        Sock.sphttp_close(fd)
        res.set_status(502)
        return ""
      end
      if ureq.body.length > 0
        if Sock.sphttp_write_str(fd, ureq.body) < 0
          Sock.sphttp_close(fd)
          res.set_status(502)
          return ""
        end
      end

      uh = Tep::Proxy.read_upstream_head(fd)
      if !uh.ok
        Sock.sphttp_close(fd)
        res.set_status(502)
        return ""
      end

      res.set_status(uh.status)
      # Copy upstream headers minus hop-by-hop, content-length (the
      # client side is chunked -- no fixed length), and transfer-
      # encoding (the server writer re-applies chunked itself).
      uh.headers.each do |k, v|
        lc = k.downcase
        if !Tep::Proxy.hop_by_hop?(k) && lc != "content-length"
          res.headers[k] = v
        end
      end

      streamer = Tep::Proxy::ProxyStreamer.new
      streamer.proxy      = self
      streamer.fd         = fd
      streamer.leftover   = uh.leftover
      streamer.is_chunked = uh.is_chunked
      streamer.is_sse     = uh.is_sse
      streamer.req        = req
      res.start_stream(streamer)
      ""
    end

    # The streaming pump, called from ProxyStreamer#pump as
    # @proxy.run_stream(...). It lives here, on Tep::Proxy, rather
    # than on the streamer so that on_stream_chunk / on_stream_end
    # below are invoked as plain (implicit-self) calls. spinel
    # resolves an implicit-self call inside a base-class method
    # polymorphically -- it includes every subclass arm -- so a
    # subclass's overrides are reached. A call through the streamer's
    # @proxy slot (statically Tep::Proxy) would bind only the base
    # hooks. Same reason rewrite_path / stream_request? (implicit-self
    # from handle) dispatch to overrides but a slot call would not.
    #
    # Recv-loops the held-open upstream fd: dechunks (chunked
    # upstream), splits SSE event records (text/event-stream), and
    # dispatches each unit through dispatch_one. Fires on_stream_end
    # once at EOF / timeout. Cooperative -- parks on io_wait between
    # recvs, so requires Tep::Server::Scheduled.
    def run_stream(out, fd, leftover, is_chunked, is_sse, req)
      stats    = Tep::Proxy::StreamStats.new
      buf      = leftover    # raw (possibly chunked) bytes
      body_buf = ""          # dechunked bytes awaiting SSE split
      done     = false
      while !done
        if is_chunked
          consumed = Tep::Llm.dechunk_consume(buf)
          buf      = Tep::Llm.dechunk_leftover(buf)
          if consumed.length > 0
            body_buf = body_buf + consumed
          end
        else
          body_buf = body_buf + buf
          buf      = ""
        end

        if is_sse
          body_buf = drain_events(out, stats, body_buf)
        else
          if body_buf.length > 0
            dispatch_one(out, stats, body_buf)
            body_buf = ""
          end
        end

        ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, 60)
        if ready == 0
          stats.errored = true
          done = true
        else
          more = Sock.sphttp_recv_some(fd, 4096)
          if more.length == 0
            done = true        # clean EOF
          else
            buf = buf + more
          end
        end
      end

      # Flush a trailing partial SSE event (some upstreams omit the
      # final blank line before closing).
      if is_sse && body_buf.length > 0
        drain_events(out, stats, body_buf + "\n\n")
      end

      Sock.sphttp_close(fd)
      on_stream_end(req, out, stats)
      0
    end

    # Split body_buf into complete "\n\n"-terminated SSE event records
    # and dispatch each (the record includes the trailing blank line,
    # per the doc's "data: {...}\n\n" contract). Returns the
    # unconsumed tail.
    def drain_events(out, stats, body_buf)
      while true
        sep = Tep.str_find(body_buf, "\n\n", 0)
        if sep < 0
          return body_buf
        end
        relay_buf = body_buf[0, sep + 2]
        body_buf  = body_buf[sep + 2, body_buf.length - sep - 2]
        dispatch_one(out, stats, relay_buf)
      end
      body_buf
    end

    # Count one unit + dispatch it to on_stream_chunk via implicit
    # self (polymorphic -- reaches subclass overrides). `relay_buf`
    # is named distinctly from `chunk` / `frame`: spinel unifies
    # param types by name file-wide, and both of those names carry
    # foreign types (poly hook param / WS int-array) that would
    # mis-type this String. See [[spinel-widening-dispatch]].
    def dispatch_one(out, stats, relay_buf)
      stats.byte_count  = stats.byte_count + relay_buf.length
      stats.chunk_count = stats.chunk_count + 1
      on_stream_chunk(Tep::Proxy::StreamChunk.new(relay_buf), out, stats)
      0
    end

    # Read an upstream response head (status line + headers up to the
    # blank line) cooperatively. Returns a Tep::Proxy::UpstreamHead
    # carrying the parsed status, the per-name header bag, the
    # chunked / SSE flags, the body bytes already read past the head
    # (leftover -- handed to the streamer so no bytes are lost), and
    # an ok flag (false on timeout / EOF before the head completed).
    def self.read_upstream_head(fd)
      out = Tep::Proxy::UpstreamHead.new
      buf = ""
      while true
        ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, 60)
        if ready == 0
          return out          # timeout -- ok stays false
        end
        chunk = Sock.sphttp_recv_some(fd, 4096)
        if chunk.length == 0
          return out          # EOF before head completed
        end
        buf = buf + chunk
        eoh = Tep.str_find(buf, "\r\n\r\n", 0)
        if eoh >= 0
          header_blob = buf[0, eoh]
          out.leftover = buf[eoh + 4, buf.length - eoh - 4]
          out.fill_from(header_blob)
          out.ok = true
          return out
        end
        if buf.length > 65535
          return out          # head too large -- bail
        end
      end
      out
    end

    # RFC 7230 §6.1 hop-by-hop headers: meaningful only for a single
    # transport-level connection, never forwarded by a proxy. Lower-
    # cased compare since both inbound and upstream header names are
    # downcased by tep's parsers.
    def self.hop_by_hop?(name)
      lc = name.downcase
      lc == "connection" ||
        lc == "keep-alive" ||
        lc == "transfer-encoding" ||
        lc == "upgrade" ||
        lc == "proxy-authorization" ||
        lc == "proxy-authenticate" ||
        lc == "te" ||
        lc == "trailer"
    end

    # Mutable descriptor of the outbound request, handed to
    # before_forward so hooks can rewrite verb / path / headers /
    # body before the upstream call. `set_header` mirrors
    # Tep::Http#set_header for muscle-memory parity.
    class UpstreamRequest
      attr_accessor :verb, :path, :headers, :body

      def initialize
        @verb    = "GET"
        @path    = "/"
        @headers = Tep.str_hash
        @body    = ""
      end

      def set_header(k, v)
        @headers[k] = v
      end
    end

    # Parsed upstream response head, produced by read_upstream_head.
    # `fill_from` parses a header blob ("Status-Line\r\nH: v\r\n...",
    # no trailing blank line) into status + the downcased-name header
    # bag + the chunked / SSE transport flags.
    class UpstreamHead
      attr_accessor :status, :headers, :is_chunked, :is_sse, :leftover, :ok

      def initialize
        @status     = 0
        @headers    = Tep.str_hash
        @is_chunked = false
        @is_sse     = false
        @leftover   = ""
        @ok         = false
      end

      def fill_from(blob)
        eol = Tep.str_find(blob, "\r\n", 0)
        if eol < 0
          return 0
        end
        line = blob[0, eol]
        sp1 = Tep.str_find(line, " ", 0)
        if sp1 >= 0
          rest = line[sp1 + 1, line.length - sp1 - 1]
          sp2 = Tep.str_find(rest, " ", 0)
          if sp2 >= 0
            @status = rest[0, sp2].to_i
          else
            @status = rest.to_i
          end
        end
        # Header lines.
        pos = eol + 2
        while pos < blob.length
          neol = Tep.str_find(blob, "\r\n", pos)
          stop = neol
          if stop < 0
            stop = blob.length
          end
          line2 = blob[pos, stop - pos]
          ci = Tep.str_find(line2, ":", 0)
          if ci > 0
            name = line2[0, ci].downcase
            vpos = ci + 1
            # skip one leading space
            if vpos < line2.length && line2[vpos, 1] == " "
              vpos += 1
            end
            val = line2[vpos, line2.length - vpos]
            @headers[name] = val
            if name == "transfer-encoding" && Tep.str_find(val.downcase, "chunked", 0) >= 0
              @is_chunked = true
            end
            if name == "content-type" && val.downcase.start_with?("text/event-stream")
              @is_sse = true
            end
          end
          if neol < 0
            return 0
          end
          pos = neol + 2
        end
        0
      end
    end

    # One unit handed to on_stream_chunk: a dechunked HTTP chunk or a
    # complete SSE event record. Read the bytes via `chunk_text`.
    #
    # Two spinel constraints shape this:
    #  * The hook param is poly-boxed (it flows through the poly
    #    on_stream_chunk dispatch), so a bare String would arrive poly
    #    and block String methods. Wrapping in an object lets the hook
    #    recover a concrete String via the accessor.
    #  * The accessor is named `chunk_text`, not `text`: a poly value's
    #    method call resolves by name across ALL classes, and `text`
    #    collides with Tep::WebSocket::Driver#text (returns int). A
    #    name with exactly one definition resolves cleanly to a String.
    #    See [[spinel-widening-dispatch]].
    class StreamChunk
      attr_accessor :chunk_text

      def initialize(chunk_text)
        @chunk_text = chunk_text
      end
    end

    # Per-stream telemetry, carried across every on_stream_chunk call
    # and into on_stream_end. The framework maintains byte_count /
    # chunk_count (input bytes dispatched, chunk/event count) and
    # errored (set when the upstream stalls past the io_wait timeout
    # or closes mid-frame). Accumulate custom counters (tokens, etc.)
    # in the `meta_bag` bag -- a typed object rather than the doc's
    # stats[:sym] hash because spinel hashes are single-value-typed
    # (same reason Tep::Llm::StreamState is a class).
    #
    # Field names are deliberately collision-free: spinel unifies
    # field/accessor types by NAME file-wide. `bytes` collides with
    # String#bytes (int-array) and `data` collides with WebSocket
    # Event#data (String) -- either would mis-type these fields. Hence
    # byte_count / chunk_count / meta_bag. See [[spinel-widening-dispatch]].
    class StreamStats
      attr_accessor :byte_count, :chunk_count, :errored, :meta_bag

      def initialize
        @byte_count  = 0
        @chunk_count = 0
        @errored     = false
        @meta_bag    = Tep.str_hash
      end
    end

    # Thin Streamer shim. Holds the held-open upstream fd + state and
    # delegates the actual pump to @proxy.run_stream. The work lives
    # on Tep::Proxy (not here) so the per-chunk / end hooks dispatch
    # through `self` -- a polymorphic-self call inside a base-Proxy
    # method reaches subclass overrides, whereas a call through this
    # object's @proxy slot (statically base-typed) would only ever hit
    # the base hooks. See run_stream's comment + [[spinel-widening-dispatch]].
    class ProxyStreamer < Tep::Streamer
      attr_accessor :proxy, :fd, :leftover, :is_chunked, :is_sse, :req

      def initialize
        @proxy      = Tep::Proxy.new("")
        @fd         = -1
        @leftover   = ""
        @is_chunked = false
        @is_sse     = false
        @req        = Tep::Request.new
      end

      def pump(out)
        @proxy.run_stream(out, @fd, @leftover, @is_chunked, @is_sse, @req)
      end
    end
  end
end
