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
#       Tep::Logger.info("upstream " + ures.status.to_s)
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
  class Proxy < Tep::Handler
    attr_accessor :upstream, :timeout

    def initialize(upstream)
      @upstream = upstream
      @timeout  = 30
    end

    # ---- Overridable hooks (subclasses customise these) ----

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

    # ---- Tep::Handler interface ----

    def handle(req, res)
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

      url  = @upstream + ureq.path
      ures = Tep::Http.send_req(ureq.verb, url, ureq.body, ureq.headers)

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
  end
end
