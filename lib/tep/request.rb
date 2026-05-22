# Tep::Request -- what the handler reads off the wire.
module Tep
  class Request
    attr_accessor :verb, :path, :raw_path, :http_version
    attr_accessor :params, :query, :req_headers, :raw_body, :cookies, :session
    attr_accessor :remote_host
    attr_accessor :ivars
    # Set by the auth-filter (Tep::AuthFilter, run before the user's
    # before-filter -- see Tep::App#auth_filter). Always populated:
    # Tep::Identity.anonymous when no provider matched, otherwise
    # the matched provider's Identity. Handlers and filters can
    # rely on req.identity being non-nil.
    attr_accessor :identity

    def initialize
      @verb         = ""
      @path         = ""
      @raw_path     = ""
      @http_version = "HTTP/1.0"
      @params       = Tep.str_hash   # path captures + query + form merged
      @query        = Tep.str_hash   # raw query string only
      @req_headers  = Tep.str_hash   # downcased header names; renamed
                                     # from `headers` to avoid sharing
                                     # an ivar slot with Response (spinel
                                     # mis-codegens polymorphic ivar
                                     # writes when two classes share an
                                     # ivar name).
      @cookies      = Tep.str_hash   # parsed from Cookie: header
      @session      = Session.new    # signed cookie store
      @raw_body     = ""             # same reasoning as req_headers
      @remote_host  = ""
      @passed       = false          # `pass` flag: skip to the next matching route
      @ivars        = Tep.str_hash   # per-request bag for `@name = ...`
                                     # set by handlers and `before` filters,
                                     # read by templates as `ivars[k]`. The
                                     # Sinatra-compat translator rewrites
                                     # `@x = v` -> `req.ivars["x"] = (v).to_s`
                                     # in handler bodies and `@x` -> `ivars["x"]`
                                     # inside ERB chunks.
      @identity     = Tep::Identity.anonymous
    end

    attr_accessor :passed
    def set_passed; @passed = true; end

    # Sinatra-compat read aliases. Writers stay on the renamed slots
    # (req_headers, raw_body) -- a `req.headers["X"] = v` from user
    # code goes through these getters, but assignment back into the
    # request via this method name is intentionally not provided
    # (the framework doesn't expect handlers to mutate the request).
    def headers; @req_headers; end
    def body;    @raw_body;    end

    # Spinel's Hash[k] returns "" for missing string keys, not nil --
    # so an empty Connection header looks the same as no header at all.
    # We treat both as "use HTTP/1.1 default behaviour".
    def keep_alive?
      lc = @req_headers["connection"].downcase
      if lc == "close"
        return false
      end
      if lc == "keep-alive"
        return true
      end
      @http_version == "HTTP/1.1"
    end

    def content_length
      @req_headers["content-length"].to_i
    end

    def form?
      @req_headers["content-type"].downcase.start_with?("application/x-www-form-urlencoded")
    end

    # True when the request body is a multipart/form-data submission
    # (browsers use this for any form built via `new FormData(...)`
    # or carrying file inputs). Tep::Multipart.parse handles the
    # text fields; file-upload parts are skipped in v1.
    def multipart?
      @req_headers["content-type"].downcase.start_with?("multipart/form-data")
    end

    # ---- Rack::Request-style accessors (reads only, no .ip yet) ----
    # These are convenience getters over headers we already parse;
    # `.ip` would need a sphttp_accept_with_peer C helper before it
    # can land cleanly, so it's deferred.

    def host;          @req_headers["host"];        end
    def user_agent;    @req_headers["user-agent"];  end
    def referer;       @req_headers["referer"];     end
    def referrer;      @req_headers["referer"];     end   # spelling alias
    def accept;        @req_headers["accept"];      end
    def content_type;  @req_headers["content-type"]; end

    # tep doesn't terminate TLS itself; both flags reflect "is this
    # connection encrypted from the client's view?" via the
    # `X-Forwarded-Proto: https` header that any reasonable reverse
    # proxy sets.
    def scheme
      proto = @req_headers["x-forwarded-proto"]
      if proto.length > 0
        return proto.downcase
      end
      "http"
    end

    def ssl?
      scheme == "https"
    end

    # Pull any remaining body bytes from `client_fd` up to the
    # advertised Content-Length, then merge form / multipart fields
    # into @params. Called once per request by both the prefork and
    # scheduled servers right after Parser.parse populates the
    # request headers + the body bytes already in the recv buffer.
    #
    # No-op on bodyless requests. Form parsing handles
    # `application/x-www-form-urlencoded`; multipart handles
    # `multipart/form-data` (text fields only; file uploads skipped).
    # Other content types leave @raw_body intact for handlers that
    # want to consume it directly.
    def consume_body(client_fd)
      cl = content_length
      already = @raw_body.length
      if cl > already
        rest = Sock.sphttp_drain_body(client_fd, cl - already)
        @raw_body = @raw_body + rest
      end
      if form?
        Url.parse_query(@raw_body).each do |k, v|
          @params[k] = v
        end
      elsif multipart?
        Tep::Multipart.parse(@raw_body, @req_headers["content-type"]).each do |k, v|
          @params[k] = v
        end
      end
      0
    end
  end
end
