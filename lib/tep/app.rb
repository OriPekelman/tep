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
    attr_accessor :router, :static_root
    attr_accessor :before_filter, :after_filter, :nf_handler

    def initialize
      @router        = Router.new
      @static_root   = ""
      @before_filter = Filter.new   # no-op default
      @after_filter  = Filter.new
      @nf_handler    = Handler.new
    end

    def add_route(verb, pattern, handler)
      @router.add(verb, pattern, handler)
    end

    def set_static_root(root); @static_root = root; end
    def set_before(f);         @before_filter = f; end
    def set_after(f);          @after_filter = f; end
    def set_not_found(h);      @nf_handler = h; end

    def dispatch(req, res)
      @before_filter.before(req, res)
      if !res.halted
        route = @router.match(req)
        if route != nil
          route.fold_captures(req)
          out = route.handler.handle(req, res)
          res.set_body_if_empty(out)
        else
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
