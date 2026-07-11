# Tep::Cache -- HTTP conditional-GET evaluation (issue #152).
#
# A response opts in by setting a validator (res.etag / res.last_modified).
# The server then short-circuits to 304 Not Modified (no body) when the
# request carries a matching precondition, so the client reuses its
# cached copy. Responses that set no validator are unaffected.
module Tep
  module Cache
    # True iff `req`'s precondition says the client's cached copy of
    # `res` is still fresh (=> answer 304). Safe methods (GET/HEAD) only.
    def self.not_modified?(req, res)
      v = req.verb
      if v != "GET" && v != "HEAD"
        return false
      end

      # ETag / If-None-Match. `*` matches anything; otherwise the quoted
      # tag is matched as a substring so a comma-separated list of tags
      # in If-None-Match works.
      etag = res.headers["ETag"]
      etag = "" if etag.nil?
      if etag.length > 0
        inm = req.headers["if-none-match"]
        inm = "" if inm.nil?
        if inm.length > 0
          if inm == "*"
            return true
          end
          if Tep.str_find(inm, etag, 0) >= 0
            return true
          end
        end
      end

      # Last-Modified / If-Modified-Since: fresh if our copy is no newer
      # than the client's cached date.
      lm = res.lastmod_epoch
      if lm > 0
        ims = req.headers["if-modified-since"]
        ims = "" if ims.nil?
        if ims.length > 0
          ims_epoch = Sock.sphttp_parse_http_date(ims)
          if ims_epoch >= 0 && lm <= ims_epoch
            return true
          end
        end
      end

      false
    end
  end
end
