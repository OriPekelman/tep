# Tep::Security -- before-filter helpers for the two middleware
# patterns Sinatra apps almost always reach for: CORS and a
# default-secure header bundle. The Rack::Cors / rack-protection
# gems do the same things via runtime middleware registration
# (`use Rack::Cors`); spinel can't do dynamic dispatch into a Rack
# stack, so we expose the behaviour as small filter classes the
# user wires with `Tep.before(...)`.
#
# Usage
# =====
#
#   # CORS, allowing one origin.
#   cors = Tep::Security::Cors.new
#   cors.set_origin("https://app.example.com")
#   cors.set_allowed_verbs("GET,POST,DELETE,OPTIONS")
#   Tep.before cors
#
#   # Default-secure headers on every response. Apps can still
#   # override individual headers in handlers.
#   Tep.after Tep::Security::Headers.new
#
# Both classes are explicit Filter subclasses so they slot into
# tep's existing single-before / single-after slots cleanly.
# Multi-filter chains stack via `Tep.before` setting one chain
# class (the bin/tep translator already composes multiple
# `before do ... end` blocks; library-side filters can be added
# alongside via subclassing).
module Tep
  module Security

    # CORS preflight + same-origin response decoration.
    #
    # Configurable bits:
    #   - origin: a single allowed origin URL ("*" allowed for
    #     fully open APIs; not recommended for any endpoint that
    #     uses cookies / Authorization headers).
    #   - methods: comma-separated. Default "GET,POST,OPTIONS".
    #   - headers: comma-separated. Default "Content-Type,Authorization".
    #   - max_age: number of seconds the browser caches the
    #     preflight result. Default 3600.
    #
    # Behaviour:
    #   - On any request: emits `Access-Control-Allow-Origin` plus
    #     credential / vary headers.
    #   - On `OPTIONS` preflight: short-circuits to a 204 with
    #     `Access-Control-Allow-Methods` / `-Headers` / `-Max-Age`.
    class Cors < Tep::Filter
      # Field names are deliberately distinctive (not `methods` /
      # `headers`) -- spinel's per-method type inference unifies
      # method names across classes, and `Object#methods` /
      # `Tep::Response#headers` would widen the dispatch return
      # to poly and break res.headers writes downstream.
      attr_accessor :origin, :allowed_verbs, :allowed_headers, :max_age

      def initialize
        @origin          = "*"
        @allowed_verbs   = "GET,POST,OPTIONS"
        @allowed_headers = "Content-Type,Authorization"
        @max_age         = 3600
      end

      def set_origin(o);          @origin          = o; end
      def set_allowed_verbs(m);   @allowed_verbs   = m; end
      def set_allowed_headers(h); @allowed_headers = h; end
      def set_max_age(n);         @max_age         = n; end

      def before(req, res)
        res.headers["Access-Control-Allow-Origin"] = @origin
        res.headers["Vary"] = "Origin"
        if req.verb == "OPTIONS"
          res.headers["Access-Control-Allow-Methods"] = @allowed_verbs
          res.headers["Access-Control-Allow-Headers"] = @allowed_headers
          res.headers["Access-Control-Max-Age"]      = @max_age.to_s
          res.set_status(204)
          res.set_body_if_empty("")
          # `res.halted = true` short-circuits the dispatch loop
          # (see App#dispatch) so the no-route fallthrough doesn't
          # overwrite our 204 with a 404.
          res.halted = true
        end
        0
      end
    end

    # Default-secure response headers. Mirrors what
    # rack-protection sets out of the box, minus the parts that
    # need stateful middleware (CSRF token threading is its own
    # feature; tep handlers can opt in with `<form><input type=
    # "hidden" name="_csrf" value="..."></form>` + a session
    # check on POST routes).
    #
    # Headers set:
    #   X-Content-Type-Options: nosniff
    #   X-Frame-Options: SAMEORIGIN
    #   Referrer-Policy: strict-origin-when-cross-origin
    #   X-XSS-Protection: 0      (modern browsers ignore; "0"
    #                             is current OWASP guidance over
    #                             "1; mode=block" which causes
    #                             reflected XSS injection bugs)
    #
    # Optional, off by default:
    #   Strict-Transport-Security
    #     -- enable via `set_hsts(seconds)`. Setting on plain HTTP
    #        is ineffective; only emit when you've actually got
    #        TLS termination upstream.
    #
    # Wiring: register as an `after` filter so it runs after the
    # handler can override Content-Type etc.
    class Headers < Tep::Filter
      attr_accessor :hsts_seconds

      def initialize
        @hsts_seconds = 0
      end

      def set_hsts(seconds); @hsts_seconds = seconds; end

      def after(req, res)
        if !res.headers.key?("X-Content-Type-Options")
          res.headers["X-Content-Type-Options"] = "nosniff"
        end
        if !res.headers.key?("X-Frame-Options")
          res.headers["X-Frame-Options"] = "SAMEORIGIN"
        end
        if !res.headers.key?("Referrer-Policy")
          res.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        end
        if !res.headers.key?("X-XSS-Protection")
          res.headers["X-XSS-Protection"] = "0"
        end
        if @hsts_seconds > 0 && !res.headers.key?("Strict-Transport-Security")
          res.headers["Strict-Transport-Security"] =
            "max-age=" + @hsts_seconds.to_s + "; includeSubDomains"
        end
        0
      end
    end

  end
end
