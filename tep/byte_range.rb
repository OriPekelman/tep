# Tep::ByteRange -- single-range HTTP Range (RFC 7233) for send_file.
#
# `apply(req, res, size)` is called by both servers once the file size is
# known. For a GET carrying `Range: bytes=a-b` / `bytes=a-` / `bytes=-n`
# that is satisfiable it turns the response into 206: sets
# file_offset/file_length and Content-Range. Anything else (no header,
# other unit, multi-range, malformed, unsatisfiable) is left alone and the
# full 200 goes out -- Rack::Files-compatible. A handler that already set
# file_offset (explicit slice) is respected.
module Tep
  module ByteRange
    def self.apply(req, res, size)
      return if res.file_offset >= 0
      return if size <= 0
      return if res.status != 200
      return if req.verb != "GET"
      range = req.req_headers["range"]
      range = "" if range.nil?
      return if !range.start_with?("bytes=")
      spec = range[6, range.length - 6].strip
      return if Tep.str_find(spec, ",", 0) >= 0
      dash = Tep.str_find(spec, "-", 0)
      return if dash < 0
      a = spec[0, dash].strip
      b = spec[dash + 1, spec.length - dash - 1].strip
      return if !digits?(a) || !digits?(b)
      first = 0
      last = size - 1
      if a.length == 0
        return if b.length == 0
        n = b.to_i
        return if n <= 0
        first = n >= size ? 0 : size - n
      else
        first = a.to_i
        return if first >= size
        if b.length > 0
          l = b.to_i
          return if l < first
          last = l if l < size
        end
      end
      res.set_status(206)
      res.headers["Content-Range"] = "bytes " + first.to_s + "-" + last.to_s + "/" + size.to_s
      res.file_offset = first
      res.file_length = last - first + 1
    end

    def self.digits?(s)
      i = 0
      while i < s.length
        c = s[i, 1]
        return false if c < "0" || c > "9"
        i += 1
      end
      true
    end
  end
end
