require_relative "helper"
require "base64"
require "digest"
require "timeout"

# Byte-exact responses and independent connections on the scheduled server.
class TestScheduledBinary < TepTest
  FIXTURE_DIR = Dir.mktmpdir("tep-binary-")
  FIXTURE_PATH = File.join(FIXTURE_DIR, "bytes.bin")
  FIXTURE_BYTES = (0..255).to_a.pack("C*") * 65536
  File.binwrite(FIXTURE_PATH, FIXTURE_BYTES)
  Minitest.after_run { FileUtils.rm_rf(FIXTURE_DIR) }

  app_source <<~RB
    require "sinatra"
    set :scheduler, :scheduled

    get "/ping" do
      "pong"
    end

    get "/echo/:word" do
      params[:word]
    end

    post "/binary" do
      req.raw_body
    end

    post "/decode_bytes" do
      Crypto.sp_crypto_b64url_decode(req.raw_body).bytes.join(",")
    end

    get "/file" do
      res.send_file("#{FIXTURE_PATH}")
      ""
    end
  RB

  def test_inline_body_preserves_nuls_and_keepalive
    Net::HTTP.start("127.0.0.1", @port, read_timeout: 3) do |http|
      ["\0hello", "hello\0world", "hello\0"].each do |body|
        response = http.post("/binary", body, "Content-Type" => "application/octet-stream")
        assert_equal "200", response.code
        assert_equal body.bytesize.to_s, response["Content-Length"]
        assert_equal body.b, response.body.b
      end
      assert_equal "pong", http.get("/ping").body
    end
  end

  def test_base64_decode_preserves_all_bytes
    ["\0ab", "a\0b", "ab\0"].each do |body|
      response = post("/decode_bytes", Base64.urlsafe_encode64(body, padding: false))
      assert_equal "200", response.code
      assert_equal body.bytes.join(","), response.body
    end
  end

  def test_parallel_connections_do_not_share_the_accepted_descriptor
    sockets = []
    4.times do |round|
      # Keep the previous wave alive so completed low scheduler slots get reused.
      wave = Array.new(12) { TCPSocket.new("127.0.0.1", @port) }
      sockets.concat(wave)
      wave.each_with_index do |socket, i|
        word = "wave-#{round}-#{i}"
        socket.write("GET /echo/#{word} HTTP/1.1\r\nHost: t\r\n\r\n")
      end
      wave.each_with_index do |socket, i|
        head = Timeout.timeout(3) { socket.gets("\r\n\r\n") }
        refute_nil head
        assert_match(/HTTP\/1.1 200/, head)
        length = head[/Content-Length: (\d+)/i, 1].to_i
        assert_equal "wave-#{round}-#{i}", Timeout.timeout(3) { socket.read(length) }
      end
      sockets.shift(12).each(&:close) if round > 0
    end
  ensure
    sockets&.each { |socket| socket.close unless socket.closed? }
  end

  def test_file_to_slow_reader_preserves_bytes_and_other_connections
    assert_slow_file
  end

  def test_range_to_slow_reader_preserves_bytes_and_other_connections
    assert_slow_file(first: 257, length: FIXTURE_BYTES.bytesize - 514)
  end

  def test_abandoned_file_does_not_stop_the_server
    socket = TCPSocket.new("127.0.0.1", @port)
    socket.write("GET /file HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
    header = Timeout.timeout(3) { socket.gets("\r\n\r\n") }
    assert_match(/HTTP\/1.1 200/, header)
    socket.close
    assert_equal "pong", get("/ping").body
  ensure
    socket&.close unless socket&.closed?
  end

  def test_file_head_and_conditional_response
    response = head("/file")
    assert_equal "200", response.code
    assert_equal FIXTURE_BYTES.bytesize.to_s, response["Content-Length"]
    assert_nil response.body
    cached = get("/file", "If-None-Match" => response["ETag"])
    assert_equal "304", cached.code
    assert_empty cached.body.to_s
  end

  private

  def assert_slow_file(first: 0, length: FIXTURE_BYTES.bytesize)
    socket = Socket.new(:INET, :STREAM)
    socket.setsockopt(:SOCKET, :RCVBUF, 65536)
    socket.connect(Socket.sockaddr_in(@port, "127.0.0.1"))
    range = first == 0 ? "" : "Range: bytes=#{first}-#{first + length - 1}\r\n"
    socket.write("GET /file HTTP/1.1\r\nHost: t\r\n#{range}Connection: close\r\n\r\n")
    header = Timeout.timeout(3) { socket.gets("\r\n\r\n") }
    assert_equal length.to_s, header[/Content-Length: (\d+)/i, 1]
    assert_match(first == 0 ? /HTTP\/1.1 200/ : /HTTP\/1.1 206/, header)
    sleep 0.2
    assert_equal "pong", get("/ping").body, "a paused download must leave other connections responsive"

    digest = Digest::SHA256.new
    received = 0
    Timeout.timeout(20) do
      loop do
        chunk = socket.readpartial(65536)
        received += chunk.bytesize
        digest.update(chunk)
      end
    rescue EOFError
      # Connection: close marks the end of this response.
    end
    assert_equal length, received
    assert_equal Digest::SHA256.hexdigest(FIXTURE_BYTES.byteslice(first, length)), digest.hexdigest
  ensure
    socket&.close
  end
end
