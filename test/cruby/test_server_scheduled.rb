# Smoke test for Tep::Server::Scheduled (fiber-per-connection server).
# Validates the basic HTTP request/response loop works under the
# scheduler. Concurrent-connection / slow-client cases are out of
# scope for this initial test -- they'll get their own coverage when
# the WebSocket battery lands and exercises that surface for real.
require_relative "helper"

class TestServerScheduled < TepTest
  app_source <<~RB
    require "sinatra"

    set :scheduler, :scheduled

    get "/ping" do
      "pong"
    end

    get "/echo/:word" do
      params[:word]
    end

    post "/upper" do
      request.body.upcase
    end

    get "/utf8" do
      "héllo wörld — ü"
    end

    post "/echo_body" do
      request.body
    end

    get "/sched_slots" do
      Tep::APP.sched_fibers.length.to_s
    end

    # Far larger than the loopback socket buffers, so writing it to a
    # client that isn't reading hits EAGAIN on the non-blocking fd.
    get "/big" do
      "x" * 67108864
    end
  RB

  def test_basic_get_through_scheduler
    res = get("/ping")
    assert_equal "200", res.code
    assert_equal "pong", res.body
  end

  def test_path_capture_through_scheduler
    res = get("/echo/hello")
    assert_equal "200", res.code
    assert_equal "hello", res.body
  end

  def test_post_body_through_scheduler
    res = post("/upper", "hello world")
    assert_equal "200", res.code
    assert_equal "HELLO WORLD", res.body
  end

  def test_two_sequential_requests
    # Same connection, two HTTP/1.1 keep-alive requests. The
    # scheduler's per-connection-fiber must handle the second
    # iteration of its keep-alive loop correctly.
    r1 = get("/ping")
    r2 = get("/echo/two")
    assert_equal "200", r1.code
    assert_equal "200", r2.code
    assert_equal "pong", r1.body
    assert_equal "two", r2.body
  end

  def test_multibyte_body_content_length_counts_bytes
    res = get("/utf8")
    assert_equal "200", res.code
    assert_equal "héllo wörld — ü", res.body.force_encoding("UTF-8")
    assert_equal "héllo wörld — ü".bytesize.to_s, res["content-length"]
  end

  def test_multibyte_request_body_is_read_in_full_without_stalling
    # The client's Content-Length is in bytes; counting the body in
    # characters made the server wait for bytes that never come (5s
    # io_wait timeout) before answering.
    body = "héllo wörld — ü"
    res = post("/echo_body", body, { "Content-Type" => "text/plain" })
    assert_equal "200", res.code
    assert_equal body, res.body.force_encoding("UTF-8")
  end

  def test_multibyte_body_keeps_keepalive_stream_in_sync
    # One persistent connection, a multibyte body first. If Content-Length
    # is counted in characters the body's trailing bytes spill into the
    # next response's status line and the client sees a corrupt stream.
    Net::HTTP.start("127.0.0.1", @port, read_timeout: 3) do |http|
      r1 = http.get("/utf8")
      r2 = http.get("/ping")
      assert_equal "200", r1.code
      assert_equal "200", r2.code
      assert_equal "pong", r2.body
    end
  end

  def test_connection_churn_does_not_grow_scheduler_slots
    # Overlapping connections: open the next one before closing the
    # previous, so a live connection fiber always sits at the tail of
    # the scheduler's slot arrays. Tail-only reclaim can't free the
    # dead slots behind it; without slot reuse every closed connection
    # leaves one behind (plus its fiber stack) for the worker's life.
    prev = nil
    60.times do
      h = Net::HTTP.new("127.0.0.1", @port)
      h.read_timeout = 3
      h.start
      assert_equal "pong", h.get("/ping").body
      prev.finish if prev
      prev = h
    end
    slots = get("/sched_slots").body.to_i
    prev.finish
    # accept fiber + the two overlapping connections + this request's.
    assert_operator slots, :<=, 8,
      "scheduler kept #{slots} slots after 60 churned connections"
  end

  def test_large_response_to_slow_reader_arrives_in_full
    sock = Socket.new(:INET, :STREAM)
    sock.setsockopt(:SOCKET, :RCVBUF, 65536)   # keep the kernel from absorbing it all
    sock.connect(Socket.sockaddr_in(@port, "127.0.0.1"))
    sock.write("GET /big HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
    # Don't read for a while: the server fills the socket buffer and
    # must park on write-readiness rather than drop the rest.
    sleep 1.5
    data = +""
    deadline = Time.now + 20
    while Time.now < deadline
      next unless IO.select([sock], nil, nil, 1)
      begin
        data << sock.read_nonblock(1 << 20)
      rescue EOFError
        break
      end
    end
    sock.close
    head, body = data.split("\r\n\r\n", 2)
    assert_equal "67108864", head[/Content-Length: (\d+)/i, 1]
    assert_equal 67108864, body.bytesize
  end
end
