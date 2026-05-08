# Tep::Handler -- subclass and override #handle(req, res). Return a
# string to set the body, or mutate `res` directly.
#
# Sinatra-style block syntax (`get '/' do ... end`) is supported via
# the `bin/tep` build-time translator, which rewrites the block body
# textually -- `params['name']` becomes `req.params['name']`,
# `redirect '/x'` becomes the appropriate res.set_status / headers
# pair, and so on -- and wraps each block in a Handler subclass.
module Tep
  class Handler
    def handle(req, res)
      ""
    end
  end
end
