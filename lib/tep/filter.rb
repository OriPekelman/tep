# Tep::Filter -- before/after hooks. Override #before(req, res) and/or
# #after(req, res). The default base methods are non-empty (they touch
# their parameters) so Spinel correctly registers them as the dispatch
# fallback; an empty base method body confuses the codegen and causes
# overrides to be silently dropped.
#
#   class TimerFilter < Tep::Filter
#     def after(req, res); res.headers["X-Took"] = "ok"; end
#   end
#   Tep.before TimerFilter.new
module Tep
  class Filter
    def before(req, res)
      0   # explicit no-op return; non-empty body keeps spinel happy
    end

    def after(req, res)
      0
    end
  end
end
