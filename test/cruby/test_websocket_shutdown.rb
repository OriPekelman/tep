# Given parked connections, one SIGTERM must drain without waiting for idle timeouts.
require_relative "helper"
require "timeout"

class TestWebSocketShutdown < TepTest
  app_source <<~'RB'
    require "sinatra"
    set :scheduler, :scheduled

    get '/ping' do
      "pong"
    end

    post '/body' do
      "received"
    end

    websocket '/shutdown' do |ws|
      on_open do |evt|
        ws.text("eleven")
      end
    end
  RB

  def test_sigterm_drains_websocket_keepalive_and_partial_requests
    record = TepHarness.find_by_port(@port)
    websocket = TCPSocket.new("127.0.0.1", @port)
    idle = partial = body = nil
    Timeout.timeout(10) do
      websocket.write("GET /shutdown HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
      assert_includes websocket.gets("\r\n\r\n"), "101 Switching Protocols"
      assert_equal [0x81, 6].pack("C*") + "eleven", websocket.read(8)
      idle = TCPSocket.new("127.0.0.1", @port)
      idle.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n")
      assert_includes idle.gets("\r\n\r\n"), "200 OK"
      assert_equal "pong", idle.read(4)
      partial = TCPSocket.new("127.0.0.1", @port)
      partial.write("GET /ping HTTP/1.1\r\nHost:")
      body = TCPSocket.new("127.0.0.1", @port)
      body.write("POST /body HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\na")
      assert_equal "pong", get("/ping").body

      status = TepHarness.terminate_status(@port, timeout: 3)
      assert status.success?, "shutdown required a signal: #{status.inspect}"
      header = websocket.read(2)
      refute_nil header, "server must send a going-away close frame"
      assert_equal 0x88, header.getbyte(0)
      payload = websocket.read(header.getbyte(1) & 0x7f)
      assert_equal 1001, payload.unpack1("n")
      assert_equal "server shutdown", payload.byteslice(2..)
      assert_equal "", body.read, "an incomplete body must not reach its route during shutdown"
    end
  ensure
    [websocket, idle, partial, body].each { |socket| socket&.close }
    if record && !TepHarness.find_by_port(@port)
      FileUtils.rm_rf(record[:tmp])
    end
  end
end
