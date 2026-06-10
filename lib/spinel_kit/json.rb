# VENDORED from OriPekelman/spinelkit @ 09e8558 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
# SpinelKit::Json -- Spinel-safe JSON ENCODERS (stateless).
#
# This file holds the encode half of the codec; the decode half lives in
# spinel_kit/json_decoder.rb (also `SpinelKit::Json`), and the incremental
# object builder in spinel_kit/json_builder.rb (`SpinelKit::Json::Builder`).
# The three are split because Spinel has no tree-shaking: every loaded method
# is compiled, and a set of uncalled methods can degrade each other's params
# (e.g. the dead decoder walkers collectively widening `escape`'s string arg
# to int, which silently miscompiled string keys to ""). Keeping
# encode/decode/build in separate files means a consumer compiles only the
# surface it calls, and each surface is independently warning-clean. Require
# only what you use:
#
#   require "spinel_kit/json"          # encoders (this file)
#   require "spinel_kit/json_decoder"  # decoders
#   require "spinel_kit/json_builder"  # builder
#
# WHY HAND-ROLLED. Spinel cannot lower the stdlib `json` gem (C-ext fast path
# + metaprogrammed pure fallback); `oj`/`yajl`/`multi_json` are C extensions.
# The spinelgems catalog confirms no verified pure-Ruby JSON gem exists. This
# is tep's encoder, standardized (the `j_`/`tj_` prefixes that worked around a
# now-fixed Spinel inference bug are gone -- see docs/spinel-discipline.md).
#
# Compose objects in user code by concatenation:
#
#   "{" + SpinelKit::Json.encode_pair_str("name", name) + "," +
#         SpinelKit::Json.encode_pair_int("age", age) + "}"
module SpinelKit
  class Json
    # Escape a string for inclusion inside a JSON string literal (does NOT
    # add the surrounding quotes -- use `quote(s)` for that). Handles ", \,
    # and the JSON-required control-char escapes (\b, \f, \n, \r, \t);
    # other control bytes go through \u00XX. Forward slash is left
    # unescaped (legal either way; unescaped is shorter/readable).
    def self.escape(s)
      out = ""
      i = 0
      n = s.length
      while i < n
        c = s[i]
        if c == "\""
          out = out + "\\\""
        elsif c == "\\"
          out = out + "\\\\"
        elsif c == "\n"
          out = out + "\\n"
        elsif c == "\r"
          out = out + "\\r"
        elsif c == "\t"
          out = out + "\\t"
        elsif c == "\b"
          out = out + "\\b"
        elsif c == "\f"
          out = out + "\\f"
        elsif c < " "
          # Other control byte -- emit \u00XX. c.getbyte(0) is the raw
          # byte value, mapped to two hex digits.
          b = c.getbyte(0)
          out = out + "\\u00" + Json.hex2(b)
        else
          out = out + c
        end
        i += 1
      end
      out
    end

    # Two-digit lowercase hex of a byte (0..255).
    def self.hex2(n)
      hex = "0123456789abcdef"
      out = ""
      out = out + hex[(n / 16) % 16, 1]
      out = out + hex[n % 16, 1]
      out
    end

    # Wrap a string in JSON quotes, escaping its body.
    def self.quote(s)
      "\"" + Json.escape(s) + "\""
    end

    # Encode a single key/value pair as `"k":"v"` (escaped both sides).
    def self.encode_pair_str(k, v)
      Json.quote(k) + ":" + Json.quote(v)
    end

    # Same shape, integer value side. `v` is rendered via `.to_s` so
    # JSON-numeric output without quoting.
    def self.encode_pair_int(k, v)
      Json.quote(k) + ":" + v.to_s
    end

    # Encode a Hash<String,String> as a JSON object.
    def self.from_str_hash(h)
      out = "{"
      first = true
      h.each do |k, v|
        if !first
          out = out + ","
        end
        first = false
        out = out + Json.quote(k) + ":" + Json.quote(v)
      end
      out + "}"
    end

    # Same shape with integer values. JSON-numeric, no quoting.
    def self.from_int_hash(h)
      out = "{"
      first = true
      h.each do |k, v|
        if !first
          out = out + ","
        end
        first = false
        out = out + Json.quote(k) + ":" + v.to_s
      end
      out + "}"
    end

    # Encode a string array as a JSON array of quoted strings.
    def self.from_str_array(a)
      out = "["
      i = 0
      while i < a.length
        if i > 0
          out = out + ","
        end
        out = out + Json.quote(a[i])
        i += 1
      end
      out + "]"
    end

    # Encode an int array as a JSON array of numbers.
    def self.from_int_array(a)
      out = "["
      i = 0
      while i < a.length
        if i > 0
          out = out + ","
        end
        out = out + a[i].to_s
        i += 1
      end
      out + "]"
    end
  end
end
