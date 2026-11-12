# End-to-end smoke test for the bin/tep `websocket '/path' do ... end`
# DSL hook. Boots a translated echo app on a random port, opens a raw
# TCP socket, performs the RFC 6455 handshake, sends a masked TEXT
# frame, asserts the unmasked echo comes back.
#
# Lives next to the unit-level test/test_websocket.rb (which covers
# the codec + handshake math in isolation). This file covers the
# Driver+Connection+Server integration path that those tests skipped.
require_relative "helper"
require "socket"
require "securerandom"
require "base64"
require "digest/sha1"

class TestWebSocketEcho < TepTest
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze

  # Same app as examples/websocket_echo.rb. Built through the harness:
  # the old setup looked for a prebuilt examples/websocket_echo under
  # test/ (wrong root) and so skipped on every run.
  app_source <<~'RB'
    require "sinatra"
    set :scheduler, :scheduled

    websocket '/echo' do |ws|
      on_open do |evt|
        ws.text("welcome")
      end

      on_message do |evt|
        ws.text("echo: " + evt.data)
      end
    end
  RB

  def expected_accept(key)
    Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
  end

  def send_handshake(sock, key)
    req =
      "GET /echo HTTP/1.1\r\n" \
      "Host: 127.0.0.1:#{@port}\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\n" \
      "Sec-WebSocket-Version: 13\r\n" \
      "\r\n"
    sock.write(req)
  end

  def read_until_double_crlf(sock)
    buf = String.new
    while !buf.include?("\r\n\r\n")
      chunk = sock.readpartial(4096)
      buf << chunk
    end
    head, rest = buf.split("\r\n\r\n", 2)
    [head, rest || ""]
  end

  def encode_masked_text(payload)
    mask = SecureRandom.bytes(4)
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.bytes[i & 3] }.pack("C*")
    [0x81, 0x80 | payload.bytesize].pack("C*") + mask + masked
  end

  def parse_unmasked_text_frame(buf)
    raise "frame too short" if buf.bytesize < 2
    b0 = buf.getbyte(0)
    b1 = buf.getbyte(1)
    raise "expected FIN+text (0x81), got 0x#{b0.to_s(16)}" unless b0 == 0x81
    raise "server frame must not be masked" if (b1 & 0x80) != 0
    len = b1 & 0x7f
    pos = 2
    if len == 126
      len = (buf.getbyte(pos) << 8) | buf.getbyte(pos + 1)
      pos += 2
    elsif len == 127
      raise "64-bit length not expected in this test"
    end
    buf.byteslice(pos, len)
  end

  def test_handshake_and_echo_round_trip
    sock = TCPSocket.new("127.0.0.1", @port)
    key = Base64.strict_encode64(SecureRandom.bytes(16))
    send_handshake(sock, key)

    head, leftover = read_until_double_crlf(sock)
    assert_includes head, "HTTP/1.1 101 Switching Protocols", "handshake failed: #{head}"
    assert_includes head, "Upgrade: websocket"
    assert_includes head, "Sec-WebSocket-Accept: #{expected_accept(key)}"

    # Server emits a synthetic "welcome" on open.
    buf = leftover.dup
    deadline = Time.now + 2
    while buf.bytesize < 9 && Time.now < deadline
      buf << sock.readpartial(4096)
    end
    welcome = parse_unmasked_text_frame(buf)
    assert_equal "welcome", welcome

    sock.write(encode_masked_text("hello"))
    buf2 = String.new
    deadline = Time.now + 2
    while buf2.bytesize < 13 && Time.now < deadline
      buf2 << sock.readpartial(4096)
    end
    echo = parse_unmasked_text_frame(buf2)
    assert_equal "echo: hello", echo

    sock.close
  end

  # --- #260: frame-size cap + 64-bit length sanity -------------------

  # Handshake, swallow the "welcome" frame, return the open socket.
  def open_ws
    sock = TCPSocket.new("127.0.0.1", @port)
    send_handshake(sock, Base64.strict_encode64(SecureRandom.bytes(16)))
    _head, leftover = read_until_double_crlf(sock)
    buf = leftover.dup
    deadline = Time.now + 2
    while buf.bytesize < 9 && Time.now < deadline
      buf << sock.readpartial(4096)
    end
    assert_equal "welcome", parse_unmasked_text_frame(buf)
    sock
  end

  # Read one server CLOSE frame; return its status code.
  def read_close_code(sock)
    buf = String.new
    deadline = Time.now + 3
    while buf.bytesize < 4 && Time.now < deadline
      break unless IO.select([sock], nil, nil, 0.2)
      begin
        buf << sock.readpartial(4096)
      rescue EOFError
        break
      end
    end
    assert buf.bytesize >= 4, "expected a CLOSE frame, got #{buf.bytesize} bytes"
    assert_equal 0x88, buf.getbyte(0), "expected FIN+close (0x88)"
    (buf.getbyte(2) << 8) | buf.getbyte(3)
  end

  # Header only: FIN+text, masked, 64-bit length marker, the length,
  # the mask key -- and no payload. The server must refuse from the
  # length field alone.
  def header_with_64bit_len(len_bytes)
    [0x81, 0x80 | 127].pack("C*") + len_bytes + SecureRandom.bytes(4)
  end

  def test_oversized_frame_closes_with_1009_from_the_header_alone
    sock = open_ws
    # 32 MiB advertised, default cap is 16 MiB; no payload follows.
    sock.write(header_with_64bit_len([32 * 1024 * 1024].pack("Q>")))
    assert_equal 1009, read_close_code(sock)
    sock.close
  end

  def test_64bit_length_with_msb_set_closes_with_1002
    sock = open_ws
    sock.write(header_with_64bit_len([0x80, 0, 0, 0, 0, 0, 0, 1].pack("C*")))
    assert_equal 1002, read_close_code(sock)
    sock.close
  end

  def test_frame_under_the_cap_still_echoes_after_16bit_length
    sock = open_ws
    payload = "x" * 300
    mask = SecureRandom.bytes(4)
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i & 3) }.pack("C*")
    sock.write([0x81, 0x80 | 126, 300 >> 8, 300 & 0xff].pack("C*") + mask + masked)
    buf = String.new
    deadline = Time.now + 2
    while buf.bytesize < 4 + 306 && Time.now < deadline
      buf << sock.readpartial(4096)
    end
    assert_equal "echo: " + payload, parse_unmasked_text_frame(buf)
    sock.close
  end
end
