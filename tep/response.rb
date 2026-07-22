# Tep::Response -- what the handler writes back. Headers are a Bag
# (string-keyed); the framework adds Content-Length / Connection
# automatically when serializing.
module Tep
  class Response
    attr_accessor :status, :headers, :body, :halted, :file_path, :set_cookies

    def initialize
      @status      = 200
      @headers     = Tep.str_hash
      @body        = ""
      @halted      = false
      @file_path   = ""
      # `Set-Cookie` is a header that can repeat; can't shove multiple
      # values into a Hash slot. Each entry here is one fully-formatted
      # Set-Cookie line, emitted verbatim by the writer.
      @set_cookies = [""]
      @set_cookies.delete_at(0)
      @streamer    = Streamer.new   # default no-op; only used when @streaming
      @streaming   = false
      # WebSocket upgrade slots. The Tep::Server::Scheduled write
      # path sees @upgrading_ws and, instead of writing the normal
      # status-line response body, emits the 101 handshake response
      # then drives the recv loop via Tep::WebSocket::Connection
      # until the connection closes.
      @upgrading_ws    = false
      @ws_accept_key   = ""
      @ws_driver       = Tep::WebSocket::Driver.new(0)
      # Last-Modified validator as epoch seconds (0 = unset). The header
      # carries the formatted date; this is kept for the conditional-GET
      # comparison against If-Modified-Since (issue #152).
      @lastmod_epoch   = 0
    end

    attr_accessor :streamer, :streaming
    attr_accessor :upgrading_ws, :ws_accept_key, :ws_driver
    attr_reader :lastmod_epoch

    # ---- HTTP caching helpers (issue #152) ----

    # Set the Cache-Control header verbatim.
    def cache_control(v)
      @headers["Cache-Control"] = v
      self
    end

    # Common Cache-Control shortcuts.
    def no_store; cache_control("no-store"); end
    def no_cache; cache_control("no-cache"); end

    # Cacheable for `secs` seconds: set both Expires (absolute HTTP-date)
    # and Cache-Control: max-age (relative).
    def expires(secs)
      @headers["Expires"]       = Sock.sphttp_http_date(Time.now.to_i + secs)
      @headers["Cache-Control"] = "max-age=" + secs.to_s
      self
    end

    # Strong ETag validator (quoted per RFC 7232).
    def etag(value)
      @headers["ETag"] = "\"" + value + "\""
      self
    end

    # Last-Modified validator from Unix epoch seconds. Remembers the
    # epoch so conditional GET can compare it to If-Modified-Since.
    def last_modified(epoch)
      @lastmod_epoch            = epoch
      @headers["Last-Modified"] = Sock.sphttp_http_date(epoch)
      self
    end

    def start_stream(streamer)
      @streamer  = streamer
      @streaming = true
    end

    # Mark the response as a WebSocket upgrade. The server writes a
    # 101 Switching Protocols response with the accept-key, assigns
    # the live client fd onto the driver, then runs the recv loop.
    def start_websocket(accept_key, driver)
      @upgrading_ws  = true
      @ws_accept_key = accept_key
      @ws_driver     = driver
    end

    # Sinatra-style cookie writer. `opts` is a Bag-of-strings
    # (path, expires, max-age, domain, samesite, httponly, secure).
    # Empty `opts` is fine: just writes "name=value".
    def set_cookie(name, value, opts)
      line = name + "=" + SpinelKit::Url.escape(value)
      if opts.length > 0
        opts.each do |k, v|
          if v.length == 0
            line = line + "; " + k          # bare flag (HttpOnly, Secure)
          else
            line = line + "; " + k + "=" + v
          end
        end
      end
      @set_cookies.push(line)
    end

    def send_file(path)
      @file_path = path
      @body = ""
    end

    # Spinel's polymorphic-receiver write codegen emits a no-op for
    # `res.body = x` when called from a context that has a poly
    # value, so we force the assignment through this method (where
    # `self` is unambiguously Response).
    def set_body_if_empty(s)
      if @body.length == 0 && s.length > 0
        @body = s
      end
    end

    # Unconditional body setter. Same poly-write rationale as
    # set_body_if_empty (self is unambiguously Response here, so the
    # `@body = s` codegens correctly), but always assigns -- used by
    # Tep::Proxy, which writes the upstream body whether or not it's
    # empty (a 204 / empty upstream body must overwrite, not skip).
    def set_body(s)
      @body = s
    end

    def set_status(n); @status = n; end

    def halted_close?
      @halted && @status >= 300
    end
  end
end
