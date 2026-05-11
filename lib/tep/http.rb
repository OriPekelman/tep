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
# the bare Faraday names) so they don't collide with
# `Tep::Session#get` in spinel's type-inference unifier -- see
# spinel #429. The class-level shortcuts (`Tep::Http.get(url)`)
# keep the Faraday spelling because cmeth names live in a separate
# namespace.
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
    # `do_` because bare `get` collides with `Tep::Session#get` in
    # the type-inference unifier (spinel #429: same-named imeths
    # across unrelated classes merge return types). The shape is
    # the same as Faraday's; spelling differs.
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

    # The workhorse. Returns a Tep::Http::Response in all cases --
    # on connect or send failure, `.status` is 0 and `.body` is "".
    def self.send_req(verb, url, body, headers)
      out = Tep::Http::Response.new
      parts = Tep::Url.split_url(url)
      if parts["scheme"] != "http"
        # HTTPS / unknown scheme -- not in v1.
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

      # Request: VERB path HTTP/1.0\r\nHost: ...\r\n(headers)\r\nContent-Length: N\r\n\r\nBODY
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
      eol = raw.index("\r\n")
      if eol < 0
        return out
      end
      line = raw[0, eol]
      sp1 = line.index(" ")
      if sp1 < 0
        return out
      end
      rest = line[sp1 + 1, line.length - sp1 - 1]
      sp2 = rest.index(" ")
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
        next_eol = Http.index_from(raw, "\r\n", pos)
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
        ci = line2.index(":")
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

    # String#index doesn't take a start-position offset in spinel's
    # current coverage, so we slice + adjust.
    def self.index_from(s, needle, start)
      if start >= s.length
        return -1
      end
      tail = s[start, s.length - start]
      hit = tail.index(needle)
      if hit < 0
        return -1
      end
      hit + start
    end

    class Response
      attr_accessor :status, :headers, :body
      def initialize
        @status  = 0
        @headers = Tep.str_hash
        @body    = ""
      end
    end
  end
end
