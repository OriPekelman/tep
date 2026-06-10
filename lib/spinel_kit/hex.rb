# VENDORED from OriPekelman/spinelkit @ 09e8558 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
# SpinelKit::Hex -- hex digit/byte encode + decode: the pieces every Spinel
# project re-rolls. The decode nibble appeared BYTE-IDENTICAL in Tep::Url,
# inside SpinelKit::Json's string decoder, and (as a multi-digit variant) in
# Tep::Llm's chunked-transfer size parser. Pure string/byte ops, Spinel-safe.
#
# NOTE on the Json overlap: SpinelKit::Json keeps its OWN private `hex2`/
# `hex_nibble` so a JSON-only consumer never compiles this file (Spinel has no
# tree-shaking — see json.rb). Hex is the shared surface for everyone else,
# e.g. SpinelKit::Url.
module SpinelKit
  class Hex
    # Hex digit char -> int 0..15, or -1 if not a hex digit (upper or lower).
    def self.nibble(c)
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

    # Int nibble 0..15 -> single UPPERCASE hex char ("0".."9","A".."F").
    # (RFC 3986 percent-encoding uses uppercase.)
    def self.nibble_char(n)
      if n < 10
        return ("0".getbyte(0) + n).chr
      end
      ("A".getbyte(0) + n - 10).chr
    end

    # Int byte 0..255 -> two-char LOWERCASE hex (15 -> "0f"). (JSON \u00XX
    # and similar use lowercase.)
    def self.byte2(n)
      hex = "0123456789abcdef"
      out = ""
      out = out + hex[(n / 16) % 16, 1]
      out = out + hex[n % 16, 1]
      out
    end

    # Parse the leading hex digits of `s` -> int ("1a3" -> 419). Stops at the
    # first non-hex char; returns 0 if there is no leading hex digit. Useful
    # for chunked-transfer sizes and the like.
    def self.to_int(s)
      n = 0
      i = 0
      len = s.length
      while i < len
        v = Hex.nibble(s[i])
        if v < 0
          return n
        end
        n = n * 16 + v
        i += 1
      end
      n
    end
  end
end
