# VENDORED from OriPekelman/spinelkit @ a103445 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
# SpinelKit::Json -- Spinel-safe JSON DECODERS (flat-key, top-level only).
#
# The decode half of the codec; encoders are in spinel_kit/json.rb. Split out
# so an encode-only consumer never compiles these walkers (their dead-code
# degradation otherwise widens the encoders' string args to int -- see the
# header of json.rb and docs/spinel-discipline.md).
#
# `get_str(s, key)` finds the entry for `key` in the top-level object literal
# `s` and returns its value as a string. Returns "" when `key` is absent or
# the value isn't a string. Same shape for `get_int`. `has_key?(s, key)`
# returns a boolean independent of value type. The parser is a hand-rolled
# state machine that walks one `{ "k": <value>, ... }` pair at a time,
# skipping over any value (including nested objects / arrays) it doesn't need.
# Strings inside values are honoured for escape sequences so that `\"` doesn't
# terminate the string and corrupt the walk. Decodes the escape sequences
# `SpinelKit::Json.escape` produces.
module SpinelKit
  class Json
    def self.get_str(s, key)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return ""
      end
      Json.parse_str_value(s, pos)
    end

    def self.get_int(s, key)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return 0
      end
      Json.parse_int_value(s, pos)
    end

    # Decode a JSON number value at `key` -> Float. Accepts both
    # integer-literal (`42`) and float-literal (`3.14`, `-0.5`, `1e2`)
    # JSON-number syntax; the integer form returns N.0. Missing key or
    # malformed value returns 0.0 (consistent with the other getters'
    # missing-key defaults).
    #
    # Implementation: delegates the value-span walking to skip_value (already
    # handles all JSON-number syntax + structural-char boundaries), then
    # String#to_f on the substring. Inlined rather than factored into a
    # parse_float_value helper because spinel's type inference mis-widens `s`
    # to int through the indirection. NOTE: that is a value-walk indirection
    # concern, NOT the name-collision bug (which was fixed) -- keep it inlined.
    def self.get_float(s, key)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return 0.0
      end
      pos = Json.skip_ws(s, pos)
      if pos >= s.length
        return 0.0
      end
      end_pos = Json.skip_value(s, pos)
      if end_pos <= pos
        return 0.0
      end
      s[pos, end_pos - pos].to_f
    end

    def self.has_key?(s, key)
      Json.find_value_start(s, key) >= 0
    end

    # Decode a flat JSON array of integers at `key` -> Array[Integer].
    # A missing or non-array value yields [] (the typed-empty-array idiom);
    # non-int elements are skipped.
    def self.get_int_array(s, key)
      out = [0]
      out.delete_at(0)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return out
      end
      pos = Json.skip_ws(s, pos)
      if pos >= s.length || s[pos] != "["
        return out
      end
      pos += 1
      while pos < s.length
        pos = Json.skip_ws(s, pos)
        if pos >= s.length
          return out
        end
        c = s[pos]
        if c == "]"
          return out
        elsif c == ","
          pos += 1
        elsif (c >= "0" && c <= "9") || c == "-"
          out.push(Json.parse_int_value(s, pos))
          # Advance past the number parse_int_value just consumed
          # (optional '-' then digits).
          if s[pos] == "-"
            pos += 1
          end
          while pos < s.length && s[pos] >= "0" && s[pos] <= "9"
            pos += 1
          end
        else
          # Non-int element (string / object / etc.): skip it.
          pos = Json.skip_value(s, pos)
        end
      end
      out
    end

    # ---- Internal helpers ----

    # Skip whitespace starting at `pos`, return the new position.
    def self.skip_ws(s, pos)
      while pos < s.length
        c = s[pos]
        if c == " " || c == "\t" || c == "\n" || c == "\r"
          pos += 1
        else
          return pos
        end
      end
      pos
    end

    # Walk a JSON-quoted string starting at `pos` (which must point at the
    # opening `"`). Returns the position one past the closing `"`. Returns
    # -1 on malformed input.
    def self.skip_str(s, pos)
      if pos >= s.length || s[pos] != "\""
        return -1
      end
      pos += 1
      while pos < s.length
        c = s[pos]
        if c == "\\"
          # Skip the escape and the escaped character. \uXXXX spans 6
          # chars total but skipping 2 still keeps us inside the string
          # for the rest of the walk -- the remaining 4 hex digits look
          # like ordinary string bytes and won't terminate the literal.
          pos += 2
        elsif c == "\""
          return pos + 1
        else
          pos += 1
        end
      end
      -1
    end

    # Walk a JSON value starting at `pos` (which must point at the first
    # non-ws char of the value). Returns the position one past the value
    # (or the input length on truncation).
    def self.skip_value(s, pos)
      pos = Json.skip_ws(s, pos)
      if pos >= s.length
        return pos
      end
      c = s[pos]
      if c == "\""
        return Json.skip_str(s, pos)
      end
      if c == "{" || c == "["
        return Json.skip_container(s, pos)
      end
      # number / true / false / null -- read until the next structural /
      # whitespace char.
      while pos < s.length
        c = s[pos]
        if c == "," || c == "}" || c == "]" ||
           c == " " || c == "\t" || c == "\n" || c == "\r"
          return pos
        end
        pos += 1
      end
      pos
    end

    # Walk a balanced { ... } or [ ... ] starting at `pos`. Honours string
    # literals so that `{` / `}` inside a value-string don't confuse the
    # brace counter. Returns position one past the matching closer.
    def self.skip_container(s, pos)
      open_c = s[pos]
      close_c = open_c == "{" ? "}" : "]"
      depth = 1
      pos += 1
      while pos < s.length && depth > 0
        c = s[pos]
        if c == "\""
          # whole nested string -- skip past it
          npos = Json.skip_str(s, pos)
          if npos < 0
            return s.length
          end
          pos = npos
        elsif c == open_c
          depth += 1
          pos += 1
        elsif c == close_c
          depth -= 1
          pos += 1
        else
          pos += 1
        end
      end
      pos
    end

    # Read a JSON-quoted string at `pos` and return its decoded contents
    # (no surrounding quotes). Decodes the same escape sequences that
    # `escape` produces. Returns "" on malformed input.
    def self.parse_str_value(s, pos)
      pos = Json.skip_ws(s, pos)
      if pos >= s.length || s[pos] != "\""
        return ""
      end
      pos += 1
      out = ""
      while pos < s.length
        c = s[pos]
        if c == "\""
          return out
        end
        if c == "\\"
          if pos + 1 >= s.length
            return out
          end
          esc = s[pos + 1]
          if esc == "\""
            out = out + "\""
          elsif esc == "\\"
            out = out + "\\"
          elsif esc == "/"
            out = out + "/"
          elsif esc == "n"
            out = out + "\n"
          elsif esc == "r"
            out = out + "\r"
          elsif esc == "t"
            out = out + "\t"
          elsif esc == "b"
            out = out + "\b"
          elsif esc == "f"
            out = out + "\f"
          elsif esc == "u"
            # \u00XX -> map the two-digit hex back to a byte. Wider
            # codepoints (U+0100+ or surrogate pairs) aren't decoded; the
            # byte we emit is the low byte of the codepoint, which
            # round-trips ASCII at minimum.
            if pos + 5 < s.length
              h1 = Json.hex_nibble(s[pos + 4])
              h2 = Json.hex_nibble(s[pos + 5])
              if h1 >= 0 && h2 >= 0
                # rebuild the byte and push it -- spinel strings are
                # byte-blobs, so this works for ASCII; for non-ASCII the
                # original encoder would have used a passthrough byte
                # anyway.
                b = h1 * 16 + h2
                out = out + Json.byte_to_chr(b)
                pos += 6
                next
              end
            end
            out = out + "?"
            pos += 2
            next
          else
            out = out + esc
          end
          pos += 2
        else
          out = out + c
          pos += 1
        end
      end
      out
    end

    def self.hex_nibble(c)
      if c >= "0" && c <= "9"
        return c.getbyte(0) - "0".getbyte(0)
      end
      if c >= "a" && c <= "f"
        return c.getbyte(0) - "a".getbyte(0) + 10
      end
      if c >= "A" && c <= "F"
        return c.getbyte(0) - "A".getbyte(0) + 10
      end
      -1
    end

    # Build a single-byte string from an integer 0..255. Spinel doesn't
    # expose `n.chr` for arbitrary bytes uniformly; the table covers the
    # ASCII printable range and falls back to "?" for anything else (the
    # JSON encoder side never produces non-ASCII via \u, so the fallback
    # is reachable only for malformed input).
    def self.byte_to_chr(n)
      printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
      if n >= 32 && n < 127
        return printable[n - 32, 1]
      end
      if n == 9
        return "\t"
      end
      if n == 10
        return "\n"
      end
      if n == 13
        return "\r"
      end
      "?"
    end

    # Read an integer at `pos`. Accepts an optional leading `-`. Returns 0
    # on no-digit / non-numeric input (caller can use `has_key?` first if
    # 0-vs-absent matters).
    def self.parse_int_value(s, pos)
      pos = Json.skip_ws(s, pos)
      if pos >= s.length
        return 0
      end
      neg = false
      if s[pos] == "-"
        neg = true
        pos += 1
      end
      n = 0
      saw_digit = false
      while pos < s.length
        c = s[pos]
        if c >= "0" && c <= "9"
          n = n * 10 + (c.getbyte(0) - "0".getbyte(0))
          saw_digit = true
          pos += 1
        else
          break
        end
      end
      if !saw_digit
        return 0
      end
      neg ? -n : n
    end

    # Walk the top-level object looking for the entry whose key matches
    # `target_key`; return the position of the value's first non-ws
    # character. Returns -1 if not found.
    def self.find_value_start(s, target_key)
      pos = Json.skip_ws(s, 0)
      if pos >= s.length || s[pos] != "{"
        return -1
      end
      pos += 1
      while pos < s.length
        pos = Json.skip_ws(s, pos)
        if pos >= s.length
          return -1
        end
        if s[pos] == "}"
          return -1
        end
        # Read a key.
        if s[pos] != "\""
          return -1
        end
        key_start = pos
        pos = Json.skip_str(s, pos)
        if pos < 0
          return -1
        end
        # Decode the key for comparison (handles \" inside keys).
        key = Json.parse_str_value(s, key_start)
        # Skip ws, ":".
        pos = Json.skip_ws(s, pos)
        if pos >= s.length || s[pos] != ":"
          return -1
        end
        pos += 1
        pos = Json.skip_ws(s, pos)
        if key == target_key
          return pos
        end
        # Skip the value, then the comma (if any).
        pos = Json.skip_value(s, pos)
        pos = Json.skip_ws(s, pos)
        if pos < s.length && s[pos] == ","
          pos += 1
        elsif pos < s.length && s[pos] == "}"
          return -1
        end
      end
      -1
    end
  end
end
