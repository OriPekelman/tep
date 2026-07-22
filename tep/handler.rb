# Tep::Handler -- subclass and override #handle(req, res). Return a
# string to set the body, or mutate `res` directly.
#
# Sinatra-style block syntax (`get '/' do ... end`) is supported via
# the `bin/tep` build-time translator, which rewrites the block body
# textually and wraps each block in a Handler subclass.
#
# Regex routes (`get %r{...} do ... end`) also live as Handler
# subclasses: the translator emits `is_regex?` returning true plus
# `re_match?(path)` / `re_capture(path)` baking the literal regex
# into both methods. The literal is required because spinel can't
# build a Regexp from a string at runtime.
module Tep
  class Handler
    def handle(req, res)
      ""
    end

    def is_regex?
      false
    end

    def re_match?(path)
      false
    end

    # Default returns an empty str_array. Subclasses for regex routes
    # return up to 9 capture strings.
    def re_capture(path)
      empty = [""]
      empty.delete_at(0)
      empty
    end
  end
end
