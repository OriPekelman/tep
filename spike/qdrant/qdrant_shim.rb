# Faraday-shaped transport shim for the qdrant-ruby gem, backed by
# Tep::Http instead of Faraday. The gem's resource classes
# (Qdrant::Collections / Points / Service, vendored verbatim) call
# `client.connection.<verb>(path) { |req| ... }` and read
# `response.body` -- this provides exactly that surface.
#
# SPIKE SCOPE: the READ path (GET, no request body) is fully wired.
# Body verbs (POST/PUT/PATCH) are intentionally NOT implemented for
# real: the gem builds heterogeneous request bodies (arrays of floats,
# ints, nested hashes, bools in one Hash) and relies on Faraday's
# :json middleware to serialize an arbitrary structure. spinel can
# build such a poly Hash but cannot generically serialize it
# (JSON.generate over a poly Hash returns garbage; Tep::Json only
# encodes typed/homogeneous shapes). So body verbs raise to mark the
# boundary explicitly rather than silently sending nothing.
require_relative "../../lib/tep"

module Qdrant
  # Mutable request object yielded to the gem's `{ |req| ... }` blocks.
  class QReq
    attr_accessor :body
    def initialize
      @params = Tep.str_hash   # query params: String => String
      @body   = ""
    end
    def params
      @params
    end
    def params=(h)
      @params = h
    end
  end

  # Response wrapper: the gem reads `response.body`.
  class QResponse
    attr_accessor :status, :body
    def initialize
      @status = 0
      @body   = ""
    end
  end

  # Faraday-shaped connection over Tep::Http. base_url like
  # "http://127.0.0.1:6333"; api_key sent as the "api-key" header.
  class Connection
    def initialize(base_url, api_key)
      @base_url = base_url
      @api_key  = api_key
    end

    def headers
      h = Tep.str_hash
      if @api_key.length > 0
        h["api-key"] = @api_key
      end
      h
    end

    # Build "base/path?query" from the req's param hash.
    def build_url(path, params)
      url = @base_url + "/" + path
      q = ""
      params.each do |k, v|
        sep = "&"
        sep = "?" if q.length == 0
        q = q + sep + k + "=" + v
      end
      url + q
    end

    def get(path)
      req = QReq.new
      yield req if block_given?
      url  = build_url(path, req.params)
      resp = Tep::Http.send_req("GET", url, "", headers)
      out = QResponse.new
      out.status = resp.status
      out.body   = resp.body          # raw JSON string; caller parses
      out
    end

    def post(path)
      raise Qdrant::Error, "shim: POST body encoding unsupported (heterogeneous JSON; see SPIKE.md)"
    end

    def put(path)
      raise Qdrant::Error, "shim: PUT body encoding unsupported (heterogeneous JSON; see SPIKE.md)"
    end

    def patch(path)
      raise Qdrant::Error, "shim: PATCH body encoding unsupported (heterogeneous JSON; see SPIKE.md)"
    end

    def delete(path)
      url  = build_url(path, Tep.str_hash)
      resp = Tep::Http.send_req("DELETE", url, "", headers)
      out = QResponse.new
      out.status = resp.status
      out.body   = resp.body
      out
    end
  end

  # Minimal Client (replaces the gem's Faraday-based client.rb). Keeps
  # the same accessor surface the gem exposes (collections/points/etc).
  class Client
    attr_reader :connection
    def initialize(url, api_key)
      @connection = Qdrant::Connection.new(url, api_key)
    end

    def collections
      Qdrant::Collections.new(client: self)
    end

    def points
      Qdrant::Points.new(client: self)
    end

    def service
      Qdrant::Service.new(client: self)
    end
  end

  # The gem's error class (vendored client.rb references Qdrant::Error).
  class Error < StandardError; end
end
