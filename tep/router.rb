# Matches incoming requests against a static Route table built up
# by the Tep.<verb> DSL. Path patterns: literal segments + ":name"
# captures + "*" splat, OR a regex (via the handler's `is_regex?`).
#
# Spinel's type inference unifies parameters across classes that
# share an ivar name. So Route uses `r_verb` / `r_pat` rather than
# the more readable `verb` / `pattern` -- otherwise `req.verb` and
# `route.verb` would make `req` and `route` indistinguishable to
# the codegen and break ivar writes downstream.
module Tep
  class Route
    attr_accessor :r_verb, :r_pat, :r_handler, :r_params

    def initialize(verb, pattern, handler)
      @r_verb    = verb
      @r_pat     = pattern
      @r_handler = handler
      @r_params  = []
      pattern.split("/").each do |part|
        if part.length > 0 && part[0] == ":"
          @r_params.push(part[1, part.length - 1])
        end
      end
    end

    def handler; @r_handler; end

    def matches?(req_verb, req_path)
      if req_verb != @r_verb
        return false
      end
      if @r_handler.is_regex?
        return @r_handler.re_match?(req_path)
      end
      pat = @r_pat.split("/")
      req = req_path.split("/")
      if pat.length != req.length
        return false
      end
      i = 0
      while i < pat.length
        pp = pat[i]
        rp = req[i]
        if pp.length > 0 && pp[0] == ":"
          if rp.length == 0
            return false
          end
        elsif pp == "*"
          if rp.length == 0
            return false
          end
        else
          if pp != rp
            return false
          end
        end
        i += 1
      end
      true
    end

    def fold_captures(req)
      if @r_handler.is_regex?
        caps = @r_handler.re_capture(req.path)
        i = 0
        while i < caps.length
          req.params[(i + 1).to_s] = caps[i]
          i += 1
        end
        return
      end
      pat = @r_pat.split("/")
      rp  = req.path.split("/")
      pi  = 0
      i = 0
      while i < pat.length
        pp = pat[i]
        if pp.length > 0 && pp[0] == ":"
          name = @r_params[pi]
          req.params[name] = SpinelKit::Url.unescape(rp[i])
          pi += 1
        end
        i += 1
      end
    end
  end

  class Router
    attr_accessor :routes

    def initialize
      @routes = [Route.new("", "", Handler.new)]   # type-seed sentinel
    end

    def add(verb, pattern, handler)
      @routes.push(Route.new(verb, pattern, handler))
    end

    def match(req)
      i = 1                       # skip the seed at index 0
      while i < @routes.length
        r = @routes[i]
        if r.matches?(req.verb, req.path)
          return r
        end
        i += 1
      end
      nil
    end

    # Find the next matching route after `start_idx` (1-based; the
    # seed at 0 is skipped). Used by `pass` to step to the next
    # candidate. Returns the Route + its index, or nil + -1.
    def match_after(req, start_idx)
      i = start_idx + 1
      while i < @routes.length
        r = @routes[i]
        if r.matches?(req.verb, req.path)
          return r
        end
        i += 1
      end
      nil
    end

    def index_of(route)
      i = 0
      while i < @routes.length
        if @routes[i] == route
          return i
        end
        i += 1
      end
      -1
    end
  end
end
