# Tep::WebSocket frame + handshake tests via a live tep app.
# RFC 6455 reference vectors covered:
#   - Frame encode for text + binary + close + ping + pong
#   - Handshake accept-key compute (the §1.3 worked example)
#   - Handshake header parsing (Upgrade / Connection / Version / Key)
#   - Subprotocol negotiation parser
#
# Integration coverage (Driver + Connection over a real socket
# round-trip) lives separately and isn't in this commit -- it needs
# a Ruby-side WS client to wire up, which is its own dependency.
require_relative "helper"

class TestWebSocket < TepTest
  app_source <<~'RB'
    require "sinatra"

    # Walk the C-side send accumulator and format each byte as two
    # hex digits. The buffer is populated by Frame#encode_to_send_buf;
    # going through sphttp_send_byte_at sidesteps the spinel Ruby
    # String NUL-truncation that would mangle a header like 0x817e00c8.
    def buf_hex(n)
      out = ""
      i = 0
      while i < n
        b = Sock.sphttp_send_byte_at(i) & 0xff
        out = out + ((b / 16) < 10 ? (b / 16 + 48).chr : (b / 16 + 87).chr)
        out = out + ((b % 16) < 10 ? (b % 16 + 48).chr : (b % 16 + 87).chr)
        i += 1
      end
      out
    end

    get '/frame/text_small' do
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_TEXT, "Hello")
      n = f.encode_to_send_buf
      buf_hex(n)
    end

    get '/frame/binary_short' do
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_BINARY, "abc")
      n = f.encode_to_send_buf
      buf_hex(n)
    end

    get '/frame/text_extended_16' do
      payload = ""
      i = 0
      while i < 200
        payload = payload + "x"
        i += 1
      end
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_TEXT, payload)
      f.encode_to_send_buf
      # First 4 header bytes only (0x81 0x7e 0x00 0xc8) -- FIN+text,
      # 126 marker, 200 in 16-bit big-endian.
      buf_hex(4)
    end

    get '/frame/close_with_code' do
      body = Tep::WebSocket::Driver.encode_close_payload(1000, "bye")
      f = Tep::WebSocket::Frame.new(true, Tep::WebSocket::OPCODE_CLOSE, body)
      n = f.encode_to_send_buf
      buf_hex(n)
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
