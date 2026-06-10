# VENDORED from OriPekelman/spinelkit @ 09e8558 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
require_relative "hex"

# SpinelKit::Url -- percent-encode/decode (the CGI / URI-component surface
# Spinel can't get from stdlib) plus a form-query parser and a small URL
# splitter. Ported from Tep::Url; the hex digits now come from SpinelKit::Hex.
#
# Self-contained: the empty str=>str hashes are seeded inline (the
# `{"" => ""}`-then-delete idiom that pins Spinel's value type), and substring
# search is a private `find_idx` (the `< 0` callsites can't narrow against
# String#index's int|nil under Spinel's current model). All pure string ops.
module SpinelKit
  class Url
    # "%41+b" -> "A b" (form-decode: `+` is space, `%XX` is a byte).
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
          hi = Hex.nibble(s[i + 1])
          lo = Hex.nibble(s[i + 2])
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

    # Percent-encode everything outside the RFC 3986 unreserved set
    # (ALPHA / DIGIT / `-._~`); the rest becomes `%XX` with UPPERCASE hex.
    # (Space -> `%20`, not `+` -- this is the URI-component, not form, encoder.)
    #
    # Byte-oriented: under Spinel `String#[]` indexes BYTES, so a multi-byte
    # UTF-8 char is encoded byte-by-byte (correct %XX of each byte). Under CRuby,
    # pass a binary string for the same behaviour (else `[]` splits on chars).
    def self.escape(s)
      out = ""
      i = 0
      while i < s.length
        c = s[i]
        if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") ||
           (c >= "0" && c <= "9") || c == "-" || c == "." ||
           c == "_" || c == "~"
          out = out + c
        else
          b = c.getbyte(0)
          out = out + "%" + Hex.nibble_char(b / 16) + Hex.nibble_char(b % 16)
        end
        i += 1
      end
      out
    end

    # "a=1&b=2&c" -> {"a"=>"1","b"=>"2","c"=>""}. Keys + values are
    # form-decoded (`unescape`).
    def self.parse_query(s)
      h = {"" => ""}
      h.delete("")
      if s.length == 0
        return h
      end
      pairs = s.split("&")
      pairs.each do |pair|
        if pair.length > 0
          eq = Url.find_idx(pair, "=", 0)
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

    # Split `http(s)://host[:port]/path?query` into a str=>str hash keyed
    # scheme / host / port / path / query. Without a scheme the input is
    # treated as a path (host stays empty). Default ports follow the scheme
    # (80 / 443); `query` is the raw substring after `?` (not decoded).
    #
    # One body on purpose: Spinel widens a Hash-typed value when a helper
    # mutates it and the caller keeps reading, so `out` stays StrStrHash only
    # if nothing factors the mutation out (find_idx returns an int, no mutate).
    def self.split_url(u)
      out = {"" => ""}
      out.delete("")
      out["scheme"] = ""
      out["host"]   = ""
      out["port"]   = ""
      out["path"]   = "/"
      out["query"]  = ""

      rest = u
      if rest.length >= 7 && rest[0, 7] == "http://"
        out["scheme"] = "http"
        out["port"]   = "80"
        rest = rest[7, rest.length - 7]
      elsif rest.length >= 8 && rest[0, 8] == "https://"
        out["scheme"] = "https"
        out["port"]   = "443"
        rest = rest[8, rest.length - 8]
      end

      if out["scheme"].length > 0
        slash = Url.find_idx(rest, "/", 0)
        hostport = rest
        tail     = "/"
        if slash >= 0
          hostport = rest[0, slash]
          tail     = rest[slash, rest.length - slash]
        end
        colon = Url.find_idx(hostport, ":", 0)
        if colon >= 0
          out["host"] = hostport[0, colon]
          out["port"] = hostport[colon + 1, hostport.length - colon - 1]
        else
          out["host"] = hostport
        end
        rest = tail
      end

      qi = Url.find_idx(rest, "?", 0)
      if qi >= 0
        out["path"]  = rest[0, qi]
        out["query"] = rest[qi + 1, rest.length - qi - 1]
      else
        out["path"] = rest
      end
      if out["path"].length == 0
        out["path"] = "/"
      end
      out
    end

    # First index of `needle` in `s` at/after `start`, or -1. Internal
    # (Spinel-safe substring search; see the module comment).
    def self.find_idx(s, needle, start)
      nlen = needle.length
      slen = s.length
      pos = start
      while pos <= slen - nlen
        if s[pos, nlen] == needle
          return pos
        end
        pos += 1
      end
      -1
    end
  end
end
