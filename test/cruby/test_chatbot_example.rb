require_relative "helper"
require "socket"
require "json"
require "securerandom"
require "base64"
require "net/http"

# Builds and drives examples/chatbot/app.rb end to end against a fake
# OpenAI-compatible backend. The example had stopped compiling without
# anything noticing (no test built it), so this is both its build gate
# and a check of the paths it showcases: first-boot setup, WebSocket
# streaming through `ws.stream`, and the `job_worker` fiber running
# TitleJob in the background.
class TestChatbotExample < Minitest::Test
  APP_SRC = File.expand_path("../../examples/chatbot/app.rb", __dir__)

  # Minimal OpenAI-compatible backend: SSE deltas for stream:true,
  # a one-shot completion otherwise (the title request).
  def start_fake_backend
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          head = +""
          head << c.readpartial(4096) until head.include?("\r\n\r\n")
          header, body = head.split("\r\n\r\n", 2)
          want = header[/content-length:\s*(\d+)/i, 1].to_i
          body << c.readpartial(4096) while body.bytesize < want
          if body.include?('"stream":true')
            c.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
            ["Hel", "lo"].each do |d|
              c.write(%(data: {"choices":[{"index":0,"delta":{"content":"#{d}"},"finish_reason":null}]}\n\n))
            end
            c.write("data: [DONE]\n\n")
          else
            json = '{"choices":[{"index":0,"message":{"role":"assistant","content":"Tiny Test Title"},"finish_reason":"stop"}]}'
            c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
          end
        rescue StandardError
          nil
        ensure
          c.close rescue nil
        end
      end
    end
    [server, thread]
  end

  def setup
    @tmp = Dir.mktmpdir("tep-chatbot")
    bin = File.join(@tmp, "chatbot")
    TepHarness.build_with_retry("#{TepHarness::TEP_BIN} build #{APP_SRC} -o #{bin}", "tep build chatbot")
    @backend, @backend_thread = start_fake_backend
    @port = TepHarness.next_port
    env = {
      "CHAT_DB"      => File.join(@tmp, "chat.db"),
      "CHAT_BACKEND" => "http://127.0.0.1:#{@backend.addr[1]}",
      "CHAT_MODEL"   => "fake",
    }
    @pid = Process.spawn(env, bin, "-p", @port.to_s, "-q",
                         out: File.join(@tmp, "app.log"), err: [:child, :out], pgroup: true)
    TepHarness.wait_for_port(@port, tmp: @tmp, pid: @pid)
  end

  def teardown
    TepHarness.reap(@pid) if @pid
    @backend_thread&.kill
    @backend&.close
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def http(method, path, form: nil, cookie: nil)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    req["Cookie"] = cookie if cookie
    if form
      req["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = URI.encode_www_form(form)
    end
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def ws_open(path, cookie)
    sock = TCPSocket.new("127.0.0.1", @port)
    key = Base64.strict_encode64(SecureRandom.bytes(16))
    sock.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
               "Cookie: #{cookie}\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    assert_includes sock.gets("\r\n\r\n"), "101 Switching Protocols"
    sock
  end

  def ws_send(sock, payload)
    mask = SecureRandom.bytes(4)
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i & 3) }.pack("C*")
    sock.write([0x81, 0x80 | payload.bytesize].pack("C*") + mask + masked)
  end

  def ws_read(sock, timeout: 8)
    flunk "no WebSocket frame within #{timeout}s" unless IO.select([sock], nil, nil, timeout)
    head = sock.read(2)
    assert_equal 0x81, head.getbyte(0)
    sock.read(head.getbyte(1) & 0x7f)
  end

  def test_setup_ws_streaming_and_background_title_job
    assert_equal "ok", http(:get, "/healthz").body

    setup = http(:post, "/setup", form: { "password" => "sekrit-pw" })
    assert_equal "302", setup.code
    cookie = setup["set-cookie"].split(";").first

    conv = JSON.parse(http(:post, "/api/conversations", cookie: cookie).body)["id"]
    assert_operator conv, :>, 0

    sock = ws_open("/api/c/ws", cookie)
    ws_send(sock, JSON.generate("conv_id" => conv, "content" => "hi there"))
    assert_equal %(data: {"content":"Hel"}\n\n), ws_read(sock)
    assert_equal %(data: {"content":"lo"}\n\n), ws_read(sock)
    assert_equal "data: [DONE]\n\n", ws_read(sock)
    sock.close

    msgs = http(:get, "/api/c/#{conv}/messages", cookie: cookie).body
    assert_includes msgs, "hi there"
    assert_includes msgs, "Hello", "the streamed reply is persisted"

    # The job_worker fiber (poll: 2) titles the conversation.
    title = nil
    deadline = Time.now + 12
    until Time.now > deadline
      list = JSON.parse(http(:get, "/api/conversations", cookie: cookie).body)["conversations"]
      title = list.find { |c| c["id"] == conv }["title"]
      break unless title.empty?
      sleep 0.25
    end
    assert_equal "Tiny Test Title", title
  end
end
