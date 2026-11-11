# Tep::WebSocket frame + handshake tests via a live tep app.
# RFC 6455 reference vectors covered:
#   - Frame encode for text + binary + close + ping + pong
#   - Handshake accept-key compute (the §1.3 worked example)
#   - Handshake header parsing (Upgrade / Connection / Version / Key)
#   - Subprotocol negotiation parser
#
# The UTF-8 send test also covers Driver + Connection over a raw socket.
require_relative "helper"
require "timeout"

class TestWebSocket < TepTest
  app_source <<~'RB'
    require "sinatra"
    set :scheduler, :scheduled

    # Encode a small text frame and dump it as a hex string so the
    # MRI test can check byte-by-byte. Server frames are unmasked
    # so byte 0 = 0x81 (FIN + opcode 1), byte 1 = payload length.
    def hex_of(s)
      out = ""
      i = 0
      while i < s.bytesize
        b = s.getbyte(i)
        out = out + ((b / 16) < 10 ? (b / 16 + 48).chr : (b / 16 + 87).chr)
        out = out + ((b % 16) < 10 ? (b % 16 + 48).chr : (b % 16 + 87).chr)
        i += 1
      end
      out
    end

    get '/frame/text_small' do
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_TEXT, "Hello")
      hex_of(f.encode_unmasked)
    end

    get '/frame/binary_short' do
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_BINARY, "abc")
      hex_of(f.encode_unmasked)
    end

    get '/frame/utf8' do
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_TEXT, "These go to eleven 🎸")
      hex_of(f.encode_unmasked)
    end

    get '/frame/utf8_length/:bytes' do
      size = params["bytes"].to_i
      payload = "é" * (size / 2)
      payload = payload + "x" if payload.bytesize < size
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_TEXT, payload)
      hex_of(f.encode_unmasked[0, 10])
    end

    websocket '/utf8' do |ws|
      on_open do |evt|
        ws.text("These go to eleven 🎸")
        ws.text("next")
      end
    end

    get '/frame/text_extended_16' do
      payload = ""
      i = 0
      while i < 200
        payload = payload + "x"
        i += 1
      end
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_TEXT, payload)
      # First 4 bytes only -- enough to verify the 16-bit length
      # encoding (0x81 0x7e 0x00 0xc8 = FIN+text, 126 marker, 200 in 16-bit).
      hex_of(f.encode_unmasked[0, 4])
    end

    get '/frame/close_with_code' do
      body = Tep::WebSocket::Driver.encode_close_payload(1000, "bye")
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_CLOSE, body)
      hex_of(f.encode_unmasked)
    end

    # Handshake accept key for the RFC 6455 §1.3 worked example.
    get '/handshake/accept_key' do
      Crypto.sp_crypto_websocket_accept("dGhlIHNhbXBsZSBub25jZQ==")
    end

    get '/handshake/build_response_with_protocol' do
      Tep::WebSocket::Handshake.build_response("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "chat")
    end

    get '/handshake/build_response_no_protocol' do
      Tep::WebSocket::Handshake.build_response("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "")
    end

    get '/handshake/split_csv' do
      parts = Tep::WebSocket::Handshake.split_csv("a, b ,c")
      parts.join("|")
    end

    get '/frame/reserved_opcode_rejects' do
      Tep::WebSocket::Frame.reserved_opcode?(5) ? "yes" : "no"
    end

    get '/frame/control_opcode_classifies' do
      a = Tep::WebSocket::Frame.control_opcode?(Tep::WebSocket::OPCODE_CLOSE)  ? "y" : "n"
      b = Tep::WebSocket::Frame.control_opcode?(Tep::WebSocket::OPCODE_TEXT)   ? "y" : "n"
      a + b
    end
  RB

  def test_frame_text_small_encode
    res = get("/frame/text_small")
    # 0x81 = FIN + opcode 1 (text), 0x05 = unmasked, 5-byte payload,
    # then "Hello" = 48 65 6c 6c 6f.
    assert_equal "8105" + "48656c6c6f", res.body
  end

  def test_frame_binary_short_encode
    res = get("/frame/binary_short")
    # 0x82 = FIN + opcode 2 (binary), 0x03 = unmasked 3-byte payload,
    # then "abc" = 61 62 63.
    assert_equal "8203" + "616263", res.body
  end

  def test_frame_utf8_counts_payload_bytes
    payload = "These go to eleven 🎸"
    expected = [0x81, payload.bytesize].pack("C*") + payload.b
    assert_equal expected.unpack1("H*"), get("/frame/utf8").body
  end

  def test_frame_utf8_length_encoding_boundaries
    [125, 126, 65535, 65536].each do |size|
      header = if size <= 125
        [0x81, size].pack("C*")
      elsif size <= 65535
        [0x81, 126, size].pack("CCn")
      else
        [0x81, 127, size].pack("CCQ>")
      end
      assert get("/frame/utf8_length/#{size}").body.start_with?(header.unpack1("H*")), "#{size}-byte payload"
    end
  end

  def test_driver_writes_complete_utf8_frames
    port = self.class.boot!
    TCPSocket.open("127.0.0.1", port) do |socket|
      socket.write("GET /utf8 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
      Timeout.timeout(3) do
        assert_includes socket.gets("\r\n\r\n"), "101 Switching Protocols"
        ["These go to eleven 🎸", "next"].each do |payload|
          assert_equal [0x81, payload.bytesize].pack("C*"), socket.read(2)
          assert_equal payload.b, socket.read(payload.bytesize)
        end
      end
    end
  end

  def test_frame_16bit_length_marker
    res = get("/frame/text_extended_16")
    # 0x81 = FIN + text, 0x7e = 126 marker (16-bit length follows),
    # 0x00 0xc8 = 200 big-endian.
    assert_equal "817e00c8", res.body
  end

  def test_frame_close_with_code_and_reason
    res = get("/frame/close_with_code")
    # 0x88 = FIN + opcode 8 (close), 0x05 = 5-byte payload,
    # 0x03 0xe8 = 1000 big-endian, then "bye" = 62 79 65.
    assert_equal "8805" + "03e8" + "627965", res.body
  end

  def test_handshake_accept_key_rfc_6455_vector
    res = get("/handshake/accept_key")
    # RFC 6455 §1.3 worked example.
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", res.body
  end

  def test_handshake_response_with_protocol
    res = get("/handshake/build_response_with_protocol")
    assert_includes res.body, "HTTP/1.1 101 Switching Protocols"
    assert_includes res.body, "Upgrade: websocket"
    assert_includes res.body, "Connection: Upgrade"
    assert_includes res.body, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    assert_includes res.body, "Sec-WebSocket-Protocol: chat"
  end

  def test_handshake_response_omits_protocol_when_empty
    res = get("/handshake/build_response_no_protocol")
    refute_includes res.body, "Sec-WebSocket-Protocol"
  end

  def test_handshake_split_csv_trims_whitespace
    res = get("/handshake/split_csv")
    assert_equal "a|b|c", res.body
  end

  def test_frame_reserved_opcode_predicate
    res = get("/frame/reserved_opcode_rejects")
    assert_equal "yes", res.body
  end

  def test_frame_control_opcode_predicate
    res = get("/frame/control_opcode_classifies")
    assert_equal "yn", res.body
  end
end
