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
end
