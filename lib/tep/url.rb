# Percent-decoding + form-urlencoded query parser.
module Tep
  class Url
    # "%41+b" -> "A b"
    def self.unescape(s)
      out = ""
      i = 0
      n = s.length
      while i < n
        c = s[i]
        if c == "+"
          out = out + " "
          i += 1
        elsif c == "%" && i + 2 < n
          hi = Url.hex_nibble(s[i + 1])
          lo = Url.hex_nibble(s[i + 2])
          if hi >= 0 && lo >= 0
            out = out + ((hi * 16 + lo).chr)
            i += 3
          else
            out = out + c
            i += 1
          end
        else
          out = out + c
          i += 1
        end
      end
      out
    end

    def self.hex_nibble(c)
      if c >= "0" && c <= "9"
        return c.bytes[0] - "0".bytes[0]
      end
      if c >= "a" && c <= "f"
        return c.bytes[0] - "a".bytes[0] + 10
      end
      if c >= "A" && c <= "F"
        return c.bytes[0] - "A".bytes[0] + 10
      end
      -1
    end

    # "a=1&b=2&c" -> Hash {"a"=>"1","b"=>"2","c"=>""}
    def self.parse_query(s)
      h = Tep.str_hash
      if s.length == 0
        return h
      end
      pairs = s.split("&")
      pairs.each do |pair|
        if pair.length > 0
          eq = pair.index("=")
          if eq < 0
            h[Url.unescape(pair)] = ""
          else
            k = pair[0, eq]
            v = pair[eq + 1, pair.length - eq - 1]
            h[Url.unescape(k)] = Url.unescape(v)
          end
        end
      end
      h
    end
  end
end
