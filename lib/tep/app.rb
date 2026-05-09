# Tep::App -- the registered route table + filter slots + 404 handler.
#
# Each filter slot holds a single Tep::Filter instance. Spinel's
# `PtrArray` is homogeneously-typed and doesn't carry cls_id tags,
# so an array of mixed Filter subclasses falls through to base-class
# dispatch (the user's #before / #after never runs). A single slot
# typed as a union of subclasses keeps virtual dispatch working.
# Users compose multiple filters by writing one class that calls
# the others.
module Tep
  class App
    attr_accessor :router, :static_root, :session_secret
    attr_accessor :before_filter, :after_filter, :nf_handler
    attr_accessor :asset_bodies, :asset_mimes

    def initialize
      @router         = Router.new
      @static_root    = ""
      @session_secret = ""
      @before_filter  = Filter.new   # no-op default
      @after_filter   = Filter.new
      @nf_handler     = Handler.new
      @asset_bodies   = Tep.str_hash # path -> bytes (filled at boot
      @asset_mimes    = Tep.str_hash # by Tep::Assets._add lines
                                     # the bin/tep translator emits)
    end

    def add_asset(path, body, mime)
      @asset_bodies[path] = body
      @asset_mimes[path]  = mime
    end

    def set_session_secret(s)
      @session_secret = s
    end

    def add_route(verb, pattern, handler)
      @router.add(verb, pattern, handler)
    end

    def set_static_root(root); @static_root = root; end
    def set_before(f);         @before_filter = f; end
    def set_after(f);          @after_filter = f; end
    def set_not_found(h);      @nf_handler = h; end

    def dispatch(req, res)
      # Pull a signed session cookie into req.session, when configured.
      secret = Tep.session_secret
      if secret.length > 0
        cv = req.cookies[Tep::COOKIE_NAME]
        if cv.length > 0
          req.session.load_from(cv, secret)
        end
      end

      asset_served = false
      @before_filter.before(req, res)
      if !res.halted
        # Bundled assets (everything under <app>/assets/, baked into
        # the binary by bin/tep) take precedence over the route
        # table. Match by exact path; on hit we set the body + ct
        # and skip route dispatch + 404 fallback. The after-filter
        # and session cookie writing still run normally.
        if Tep::Assets.serve(req.path, res)
          asset_served = true
        end
      end
      if !res.halted && !asset_served
        route = @router.match(req)
        # `pass` loop: a handler can signal skip-to-next-route by
        # setting req.passed. Iterate until a handler doesn't pass,
        # or we run out of matching routes.
        served = false
        while route != nil && !served
          route.fold_captures(req)
          req.passed = false
          out = route.handler.handle(req, res)
          if req.passed
            idx   = @router.index_of(route)
            route = @router.match_after(req, idx)
          else
            res.set_body_if_empty(out)
            served = true
          end
        end
        if !served
          if !try_static(req, res)
            out = @nf_handler.handle(req, res)
            res.set_status(404)
            if out.length > 0
              res.set_body_if_empty(out)
            else
              res.set_body_if_empty("<h1>404 Not Found</h1><p>" +
                                    req.verb + " " + req.path + "</p>\n")
            end
          end
        end
      end
      @after_filter.after(req, res)

      # If the handler / filters mutated the session, sign + emit a
      # Set-Cookie line. Path=/ so the cookie applies to the whole
      # app; HttpOnly to keep it out of JS.
      secret_w = Tep.session_secret
      if secret_w.length > 0 && req.session.dirty
        opts = Tep.str_hash
        opts["Path"]      = "/"
        opts["HttpOnly"]  = ""
        opts["SameSite"]  = "Lax"
        res.set_cookie(Tep::COOKIE_NAME, req.session.to_cookie_value(secret_w), opts)
      end
    end

    def try_static(req, res)
      if @static_root.length == 0
        return false
      end
      if req.verb != "GET" && req.verb != "HEAD"
        return false
      end
      if req.path.index("..") >= 0
        return false
      end
      full = @static_root + req.path
      sz = Sock.sphttp_filesize(full)
      if sz < 0
        return false
      end
      res.headers["Content-Type"] = App.guess_mime(full)
      res.headers["X-Tep-Static"] = "1"
      res.send_file(full)
      true
    end

    def self.guess_mime(path)
      lower = path.downcase
      if lower.end_with?(".html") || lower.end_with?(".htm")
        return "text/html; charset=utf-8"
      end
      if lower.end_with?(".css");  return "text/css"; end
      if lower.end_with?(".js");   return "application/javascript"; end
      if lower.end_with?(".json"); return "application/json"; end
      if lower.end_with?(".png");  return "image/png"; end
      if lower.end_with?(".jpg") || lower.end_with?(".jpeg"); return "image/jpeg"; end
      if lower.end_with?(".gif");  return "image/gif"; end
      if lower.end_with?(".svg");  return "image/svg+xml"; end
      if lower.end_with?(".txt");  return "text/plain; charset=utf-8"; end
      "application/octet-stream"
    end
  end
end
