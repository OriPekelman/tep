# Tep::WebSocket::Frame -- single-frame codec.
#
# Phase 2 surface:
#   - Frame.new(fin, opcode, payload)             build for emit
#   - frame.encode_to_send_buf -> Integer (len)   fill sphttp_send_buf
#   - Frame.parse_from_buf(bytes_at, bytes_len)   parse a recv'd frame
#       returns a ParseResult (frame + bytes_consumed, OR an error code).
#
# Server-side emit: never masks (RFC 6455 §5.3 -- server MUST NOT
# mask). Client-side emit isn't shipped here; tep is server-shaped.
#
# Why encode_to_send_buf instead of a String-returning encode_unmasked:
# Ruby Strings under spinel master are NUL-bound at the value level
# (0.chr is "", "abc" + 0.chr truncates -- confirmed by probe). WS
# frame headers contain 0x00 bytes routinely (16-bit and 64-bit length
# encodings), so they cannot be built via Ruby String concatenation.
# Frame.encode_to_send_buf walks the header byte-by-byte into the
# sphttp send accumulator (a C-side static buffer), then appends the
# payload via sphttp_send_append_bytes. Driver.send_frame finishes
# with sphttp_send_flush(fd). Tests read back via sphttp_send_byte_at.
#
# Payload caveat: the payload pass-through still goes through :str FFI
# which is NUL-bound, so binary frames whose payload contains 0x00 are
# truncated at the first NUL on the wire. Server-side TEXT/PING/PONG/
# CLOSE in tep don't currently emit NULs; full binary payload support
# is Phase 3 (requires a Ruby-side ByteArray or similar).
#
# Parse handles three length encodings (7-bit / 16-bit / 64-bit),
# the 4-byte mask key, and applies the mask to recover the plaintext
# payload. Returns a structural error code (close-code-shaped) for
# the family of malformed-frame cases that warrant a 1002 close:
#   - reserved bits set
#   - reserved opcode
#   - client frame not masked
#   - control frame payload > 125
#   - control frame fragmented
module Tep
  module WebSocket
    class Frame
      attr_accessor :fin, :opcode, :payload

      def initialize(fin, opcode, payload)
        @fin     = fin
        @opcode  = opcode
        @payload = payload
      end

      # Build the unmasked server-side wire bytes into sphttp_send_buf
      # (the C-side static accumulator). Clears the buffer first, then
      # appends header bytes one-at-a-time (so 0x00 bytes in the
      # length-encoding don't get truncated by spinel's NUL-bound
      # Ruby Strings) and finally appends the payload via the bulk
      # :str path. Returns the total byte count written to the buffer
      # (matches sphttp_send_len_get afterwards). Caller flushes via
      # Sock.sphttp_send_flush(fd).
      def encode_to_send_buf
        Sock.sphttp_send_clear
        b0 = (@fin ? 0x80 : 0x00) | (@opcode & 0x0f)
        Sock.sphttp_send_append_byte(b0)

        plen = @payload.length
        if plen <= 125
          Sock.sphttp_send_append_byte(plen)
        elsif plen <= 65535
          Sock.sphttp_send_append_byte(126)
          Sock.sphttp_send_append_byte((plen >> 8) & 0xff)
          Sock.sphttp_send_append_byte(plen & 0xff)
        else
          Sock.sphttp_send_append_byte(127)
          i = 7
          while i >= 0
            Sock.sphttp_send_append_byte((plen >> (i * 8)) & 0xff)
            i -= 1
          end
        end
        # Payload through :str FFI is NUL-bound (binary payloads with
        # embedded 0x00 truncate at the NUL). Acceptable for the WS
        # surface tep ships today (TEXT / PING / PONG / CLOSE with
        # no-NUL payloads). Full binary support is Phase 3.
        if plen > 0
          Sock.sphttp_send_append_bytes(@payload, plen)
        end
        Sock.sphttp_send_len_get
      end

      # Convert a single byte value (0..255) to a 1-char String. NB:
      # under spinel master, 0.chr returns an empty String -- callers
      # that need a NUL byte must go via Sock.sphttp_send_append_byte
      # instead of String concat (see encode_to_send_buf).
      def self.byte_to_chr(n)
        (n & 0xff).chr
      end

      # Parse one frame from the sphttp recv frame buffer (accessed
      # via Sock.sphttp_recv_frame_byte_at because the :str FFI is
      # NUL-bound under spinel master). `start` is the byte offset
      # to begin reading; `avail` is the count of valid bytes in the
      # buffer.
      #
      # Returns a ParseResult with one of three shapes:
      #   .status == "ok"      -> .frame populated + .consumed bytes used
      #   .status == "need"    -> need more bytes (consumed == 0)
      #   .status == "close"   -> protocol violation; close with .close_code
      def self.parse_from_buf(start, avail)
        out = Tep::WebSocket::ParseResult.new
        if avail - start < 2
          out.outcome = "need"
          return out
        end

        b0 = Sock.sphttp_recv_frame_byte_at(start)
        b1 = Sock.sphttp_recv_frame_byte_at(start + 1)
        fin    = (b0 & 0x80) != 0
        rsv    = b0 & 0x70
        opcode = b0 & 0x0f
        masked = (b1 & 0x80) != 0
        len7   = b1 & 0x7f

        if rsv != 0
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end
        if Frame.reserved_opcode?(opcode)
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end
        if Frame.control_opcode?(opcode)
          if !fin
            out.outcome = "close"
            out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
            return out
          end
          if len7 > 125
            out.outcome = "close"
            out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
            return out
          end
        end
        if !masked
          # Server MUST close on unmasked client frame (§5.3).
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end

        # Decode payload length.
        pos = start + 2
        plen = 0
        if len7 < 126
          plen = len7
        elsif len7 == 126
          if avail - pos < 2
            out.outcome = "need"
            return out
          end
          h = Sock.sphttp_recv_frame_byte_at(pos)
          l = Sock.sphttp_recv_frame_byte_at(pos + 1)
          plen = (h << 8) | l
          pos += 2
        else
          # 64-bit length
          if avail - pos < 8
            out.outcome = "need"
            return out
          end
          plen = 0
          i = 0
          while i < 8
            plen = (plen << 8) | Sock.sphttp_recv_frame_byte_at(pos + i)
            i += 1
          end
          pos += 8
        end

        # 4-byte mask key.
        if avail - pos < 4
          out.outcome = "need"
          return out
        end
        m0 = Sock.sphttp_recv_frame_byte_at(pos)
        m1 = Sock.sphttp_recv_frame_byte_at(pos + 1)
        m2 = Sock.sphttp_recv_frame_byte_at(pos + 2)
        m3 = Sock.sphttp_recv_frame_byte_at(pos + 3)
        pos += 4

        # Payload bytes.
        if avail - pos < plen
          out.outcome = "need"
          return out
        end

        # Decode + unmask in one pass.
        payload = ""
        i = 0
        while i < plen
          b = Sock.sphttp_recv_frame_byte_at(pos + i)
          mask_byte = 0
          if (i & 3) == 0
            mask_byte = m0
          elsif (i & 3) == 1
            mask_byte = m1
          elsif (i & 3) == 2
            mask_byte = m2
          else
            mask_byte = m3
          end
          payload = payload + Frame.byte_to_chr(b ^ mask_byte)
          i += 1
        end

        out.outcome   = "ok"
        out.frame    = Tep::WebSocket::Frame.new(fin, opcode, payload)
        out.consumed = pos + plen - start
        out
      end

      def self.reserved_opcode?(op)
        if op == Tep::WebSocket::OPCODE_CONTINUATION
          return false
        end
        if op == Tep::WebSocket::OPCODE_TEXT
          return false
        end
        if op == Tep::WebSocket::OPCODE_BINARY
          return false
        end
        if op == Tep::WebSocket::OPCODE_CLOSE
          return false
        end
        if op == Tep::WebSocket::OPCODE_PING
          return false
        end
        if op == Tep::WebSocket::OPCODE_PONG
          return false
        end
        true
      end

      def self.control_opcode?(op)
        op == Tep::WebSocket::OPCODE_CLOSE ||
          op == Tep::WebSocket::OPCODE_PING ||
          op == Tep::WebSocket::OPCODE_PONG
      end
    end

    # ParseResult carries either a parsed frame, a "need more
    # bytes" signal, or a close-code for a protocol violation.
    # Field is named `outcome` (not `status`) because attr_accessor
    # :status collides with Tep::Response.status (Integer) under
    # spinel's same-name-attr unification family
    # (matz/spinel#537 / #538), widening Tep.reason(status) to
    # accept poly and breaking the build.
    class ParseResult
      attr_accessor :outcome, :frame, :consumed, :close_code

      def initialize
        @outcome    = ""
        @frame      = Tep::WebSocket::Frame.new(true, 0, "")
        @consumed   = 0
        @close_code = 0
      end
    end
  end
end
