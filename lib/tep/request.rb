# Tep::Request -- what the handler reads off the wire.
module Tep
  class Request
    attr_accessor :verb, :path, :raw_path, :http_version
    attr_accessor :params, :query, :req_headers, :raw_body
    attr_accessor :remote_host

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
      @raw_body     = ""             # same reasoning as req_headers
      @remote_host  = ""
    end

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
  end
end
