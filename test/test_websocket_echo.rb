# End-to-end smoke test for the bin/tep `websocket '/path' do ... end`
# DSL hook. Boots a translated echo app on a random port, opens a raw
# TCP socket, performs the RFC 6455 handshake, sends a masked TEXT
# frame, asserts the unmasked echo comes back.
#
# Lives next to the unit-level test/test_websocket.rb (which covers
# the codec + handshake math in isolation). This file covers the
# Driver+Connection+Server integration path that those tests skipped.
require "minitest/autorun"
require "socket"
require "securerandom"
require "base64"
require "digest/sha1"

class TestWebSocketEcho < Minitest::Test
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze
  ROOT = File.expand_path("..", __dir__)
  BIN  = File.join(ROOT, "examples", "websocket_echo")

  def setup
    skip "examples/websocket_echo not built" unless File.executable?(BIN)
    @port = 40000 + rand(10_000)
    @pid = spawn(BIN, "-p", @port.to_s, "-q", out: "/dev/null", err: "/dev/null")
    deadline = Time.now + 5
    loop do
      begin
        s = TCPSocket.new("127.0.0.1", @port)
        s.close
        break
      rescue Errno::ECONNREFUSED
        raise "server failed to start" if Time.now > deadline
        sleep 0.05
      end
    end
  end

  def teardown
    if @pid
      Process.kill("TERM", @pid) rescue nil
      Process.wait(@pid) rescue nil
    end
  end

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
end
