# Tep::WebSocket::Driver -- Faye-shape state machine + event dispatch.
#
# Constructed AFTER the handshake completes, before the recv loop
# starts. Holds per-connection state + outbound write methods +
# the event-callback registry that the handler (or the Phase 3 DSL)
# populates.
#
# Faye-shape API (matches faye/websocket-driver-ruby's surface for
# the parts tep ships -- single-frame text/binary, ping/pong, close):
#
#     drv = Tep::WebSocket::Driver.new(fd)
#     drv.on_message    do |evt| ... end    # block-based on:open/on:message etc
#     drv.on_close      do |evt| ... end    #   are syntactic sugar; tep ships
#     drv.text("hi")                        #   the explicit setters instead
#     drv.binary(bytes)
#     drv.ping("")
#     drv.close(1000, "bye")
#
# In Phase 2, callbacks are set via explicit setters (`set_on_message`)
# rather than `on(:message) { block }` since spinel's block-with-
# closure-on-locals support is still uneven outside Fiber.new bodies.
# Phase 3's DSL hides this behind `ws.on(:message) { ... }` once we
# decide on the lowering shape.
module Tep
  module WebSocket
    class Driver
      attr_accessor :fd, :max_frame_size, :subprotocol
      # Callback slots. Each holds a subclass of Tep::WebSocket::Handler
      # (or the base) that gets `handle_event(event)` called when the
      # corresponding wire event arrives. Defaults to a no-op base
      # so the slot is type-safe pre-set.
      attr_accessor :h_open, :h_message, :h_close, :h_ping, :h_pong, :h_error

      def initialize(fd)
        @fd             = fd
        @max_frame_size = Tep::WebSocket::DEFAULT_MAX_FRAME
        @subprotocol    = ""
        @h_open    = Tep::WebSocket::Handler.new
        @h_message = Tep::WebSocket::Handler.new
        @h_close   = Tep::WebSocket::Handler.new
        @h_ping    = Tep::WebSocket::Handler.new
        @h_pong    = Tep::WebSocket::Handler.new
        @h_error   = Tep::WebSocket::Handler.new
      end

      def set_max_frame_size(n)
        @max_frame_size = n
      end

      # Reassign the underlying fd. Used by the server-side upgrade
      # path: the user handler builds the Driver with a placeholder
      # fd (since the client fd isn't visible at handler-dispatch
      # time), and the write_response branch sets the real fd here
      # right before constructing the Connection.
      def set_fd(new_fd)
        @fd = new_fd
      end

      def set_subprotocol(name)
        @subprotocol = name
      end

      def set_on_open(h);    @h_open = h;    end
      def set_on_message(h); @h_message = h; end
      def set_on_close(h);   @h_close = h;   end
      def set_on_ping(h);    @h_ping = h;    end
      def set_on_pong(h);    @h_pong = h;    end
      def set_on_error(h);   @h_error = h;   end

      # Send a text frame.
      def text(s)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_TEXT, s)
      end

      # Send a binary frame.
      def binary(bytes)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_BINARY, bytes)
      end

      # Send a ping with optional payload (<=125 bytes).
      def ping(payload)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_PING, payload)
      end

      # Send a pong with the matching ping's payload (per §5.5.3).
      def pong(payload)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_PONG, payload)
      end

      # Send a close frame with code + reason. Reason capped at
      # 123 bytes so the 2-byte code + reason fits in a control
      # frame's 125-byte payload limit.
      def close(code, reason)
        body = Driver.encode_close_payload(code, reason)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_CLOSE, body)
      end

      # Build the frame into the sphttp send accumulator and flush
      # to the fd. Frame.encode_to_send_buf handles the NUL-byte
      # gauntlet (see frame.rb for why we can't just String-concat
      # and call sphttp_write_bytes here).
      def self.send_frame(fd, opcode, payload)
        frame = Tep::WebSocket::Frame.new(true, opcode, payload)
        frame.encode_to_send_buf
        Sock.sphttp_send_flush(fd)
      end

      # Close payload: 2-byte big-endian code + UTF-8 reason.
      #
      # CLOSE has the same NUL-binding constraint -- 0x03e8 (1000) is
      # fine, but e.g. 0x0064 (100, hypothetical extension code) would
      # truncate at the high-byte NUL via String concat. So we route
      # the 2 code bytes through the send buffer too, then read them
      # back as a String via per-byte query.
      #
      # This is a transitional shape: as long as ALL close-payload
      # construction stays inside Driver.encode_close_payload, callers
      # can keep treating it as a String (which Frame then writes via
      # sphttp_send_append_bytes -- :str NUL-bound, same as text). For
      # the close codes RFC 6455 §7.4.1 defines (1000-1015, all with
      # nonzero high byte), this round-trip is lossless.
      def self.encode_close_payload(code, reason)
        if code == 0
          return ""
        end
        hi = (code >> 8) & 0xff
        lo = code & 0xff
        # All RFC-defined close codes have hi != 0. Future extension
        # codes < 256 would hit the NUL truncation in the return
        # String; revisit when we add an extension that needs it.
        out = hi.chr + lo.chr
        if reason.length > 123
          out + reason[0, 123]
        else
          out + reason
        end
      end
    end

    # Event passed to handler callbacks. Holds `data` (the payload
    # as String for text/binary, raw bytes for ping/pong, or the
    # close code+reason for close) and a numeric `code` for close.
    class Event
      attr_accessor :data, :code, :reason

      def initialize
        @data   = ""
        @code   = 0
        @reason = ""
      end
    end

    # Base class for event handlers. Subclass + override
    # `handle_event(event)`. The Driver stores one Handler instance
    # per event type and dispatches via `@h_message.handle_event(evt)`.
    # Spinel's block-based callback shape (faye's `driver.on(:msg)
    # { ... }`) wraps a closure with captured locals -- workable
    # post-matz/spinel#564 but the explicit-Handler shape is simpler
    # for now and stays compatible with Fiber.storage when Phase 3
    # routes per-connection state through it.
    class Handler
      def handle_event(event)
        0
      end
    end
  end
end
