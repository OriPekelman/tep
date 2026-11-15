# The default (blocking) server serves one connection per worker. An
# idle keep-alive client must not hold that worker indefinitely, and
# must not make it deaf to SIGTERM/SIGINT (#277).
require_relative "helper"
require "timeout"

class TestIdleKeepalive < TepTest
  app_source <<~'RB'
    require "sinatra"

    get '/ping' do
      "pong"
    end

    post '/body' do
      "received"
    end
  RB

  def idle_client
    s = TCPSocket.new("127.0.0.1", @port)
    s.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_includes s.gets("\r\n\r\n"), "200 OK"
    assert_equal "pong", s.read(4)
    s
  end

  def test_idle_client_releases_the_worker
    idle = idle_client
    t0 = Time.now
    # Single worker: this request waits behind the idle connection
    # until the server times it out (KEEPALIVE_TIMEOUT = 5s).
    res = Timeout.timeout(10) { get("/ping") }
    waited = Time.now - t0
    assert_equal "pong", res.body
    assert_operator waited, :<, 8, "second client waited #{waited}s"
    # The server closed the idle connection.
    assert_nil Timeout.timeout(2) { idle.read(1) }
  ensure
    idle&.close
  end

  def test_active_keepalive_connection_survives
    s = idle_client
    3.times do
      sleep 1
      s.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert_includes s.gets("\r\n\r\n"), "200 OK"
      assert_equal "pong", s.read(4)
    end
  ensure
    s&.close
  end
end

# Shutdown tests stop the server, so each gets its own class (and app).
class TestIdleKeepaliveSigterm < TepTest
  app_source <<~'RB'
    require "sinatra"

    get '/ping' do
      "pong"
    end

    post '/body' do
      "received"
    end
  RB

  def idle_client
    s = TCPSocket.new("127.0.0.1", @port)
    s.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_includes s.gets("\r\n\r\n"), "200 OK"
    assert_equal "pong", s.read(4)
    s
  end

  def test_sigterm_with_idle_keepalive_connection
    record = TepHarness.find_by_port(@port)
    idle = idle_client
    sleep 0.2 # let the worker block in recv for the next request
    status = TepHarness.terminate_status(@port, timeout: 3)
    assert status.success?, "shutdown needed SIGKILL: #{status.inspect}"
  ensure
    idle&.close
    if record && !TepHarness.find_by_port(@port)
      FileUtils.rm_rf(record[:tmp])
    end
  end
end

class TestPartialBodySigterm < TepTest
  app_source <<~'RB'
    require "sinatra"

    get '/ping' do
      "pong"
    end

    post '/body' do
      "received"
    end
  RB

  def test_sigterm_with_partial_body
    record = TepHarness.find_by_port(@port)
    partial = TCPSocket.new("127.0.0.1", @port)
    partial.write("POST /body HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\na")
    sleep 0.2
    status = TepHarness.terminate_status(@port, timeout: 3)
    assert status.success?, "shutdown needed SIGKILL: #{status.inspect}"
  ensure
    partial&.close
    if record && !TepHarness.find_by_port(@port)
      FileUtils.rm_rf(record[:tmp])
    end
  end
end
