require_relative "helper"

# Tep::Http -- outbound HTTP client tests. Boots a tep app with both
# "target" endpoints (/ping, /echo, /headers, /404) and a "client"
# endpoint (/selfcall/:port) that uses Tep::Http to call its own
# server. The test passes its bound port to the handler via path
# capture, which side-steps the test harness's lack of "tell the
# handler its own port" plumbing.
class TestHttp < TepTest
  # macOS doesn't load-balance SO_REUSEPORT (see docs/MACOS-CONCURRENCY.md);
  # 4 workers + self-calling handlers deadlocks. Drop to 1 worker on
  # darwin -- the 5 self-call tests still need to skip (workers=1
  # serializes the outer handler, and Tep::Http isn't cooperative-aware
  # yet -- Phase 1 in MACOS-CONCURRENCY.md). The 2 non-self-call
  # tests run cleanly with workers=1.
  TEST_WORKERS = RUBY_PLATFORM =~ /darwin/ ? 1 : 4

  app_source <<~RB
    require 'sinatra'

    # #{RUBY_PLATFORM =~ /darwin/ ? '1 worker on macOS' : '4 workers on Linux'}:
    # the test handlers make outbound HTTP back to the same server.
    # On Linux SO_REUSEPORT distributes by 4-tuple hash, so the
    # inner call lands on a free worker; on Darwin SO_REUSEPORT
    # doesn't load-balance and any pool >1 collapses to a single
    # hot worker. workers=1 on Mac makes the deadlock loud +
    # deterministic; the self-call tests skip there pending a
    # cooperative Tep::Http (see docs/MACOS-CONCURRENCY.md).
    set :workers, #{TEST_WORKERS}

    get '/ping' do
      "pong"
    end

    get '/echo/:msg' do
      res.headers["X-Tep-Echo"] = params[:msg]
      params[:msg]
    end

    post '/echo_body' do
      res.headers["Content-Type"] = "text/plain"
      req.raw_body
    end

    get '/headers_back' do
      h = req.req_headers["x-custom"]
      "x-custom=" + h
    end

    get '/teapot' do
      res.set_status(418)
      "i'm a teapot"
    end

    # The "client" endpoint -- uses Tep::Http against itself.
    get '/selfcall/:port' do
      r = Tep::Http.get("http://127.0.0.1:" + params[:port] + "/ping")
      "status=" + r.status.to_s + " body=" + r.body
    end

    # Reusable client with base URL and a default header.
    get '/instance/:port' do
      c = Tep::Http.new("http://127.0.0.1:" + params[:port])
      c.set_header("X-Custom", "hello-from-tep")
      r = c.do_get("/headers_back")
      "status=" + r.status.to_s + " body=" + r.body
    end

    # POST with a body, read it back from the echo endpoint.
    get '/post_echo/:port' do
      c = Tep::Http.new("http://127.0.0.1:" + params[:port])
      r = c.do_post("/echo_body", "round trip body")
      "status=" + r.status.to_s + " body=" + r.body
    end

    # Non-2xx round trip.
    get '/teapot_from/:port' do
      r = Tep::Http.get("http://127.0.0.1:" + params[:port] + "/teapot")
      "status=" + r.status.to_s + " body=" + r.body
    end

    # Verify header parsing on the inbound side: hit /echo/<msg>
    # which sets an X-Tep-Echo response header, then read it back.
    get '/header_parse/:port' do
      r = Tep::Http.get("http://127.0.0.1:" + params[:port] + "/echo/hi")
      "echo_header=" + r.headers["x-tep-echo"]
    end

    # Bad URL: scheme not http -- send_req returns Response with status=0.
    get '/bad_scheme' do
      r = Tep::Http.get("ftp://127.0.0.1/")
      "status=" + r.status.to_s
    end

    # Connect failure: nothing's listening on this port.
    get '/connect_fail' do
      r = Tep::Http.get("http://127.0.0.1:1/ping")
      "status=" + r.status.to_s
    end
  RB

  # Skip the self-calling subset on macOS: the outer handler blocks
  # waiting for the inner request, which can't be accepted because
  # workers=1 on darwin (and even >1 doesn't help thanks to
  # SO_REUSEPORT not load-balancing). Closes once Tep::Http grows a
  # cooperative path under Tep::Server::Scheduled -- see
  # docs/MACOS-CONCURRENCY.md.
  MAC_SELFCALL_SKIP = "macOS: self-call deadlocks; needs cooperative Tep::Http (docs/MACOS-CONCURRENCY.md)"

  def test_selfcall_returns_pong
    skip MAC_SELFCALL_SKIP if RUBY_PLATFORM =~ /darwin/
    res = get("/selfcall/#{@port}")
    assert_equal "200", res.code
    assert_equal "status=200 body=pong", res.body
  end

  def test_instance_sends_default_header
    skip MAC_SELFCALL_SKIP if RUBY_PLATFORM =~ /darwin/
    res = get("/instance/#{@port}")
    assert_equal "200", res.code
    # The target's /headers_back echoes the X-Custom header it saw.
    assert_equal "status=200 body=x-custom=hello-from-tep", res.body
  end

  def test_post_body_round_trips
    skip MAC_SELFCALL_SKIP if RUBY_PLATFORM =~ /darwin/
    res = get("/post_echo/#{@port}")
    assert_equal "200", res.code
    assert_equal "status=200 body=round trip body", res.body
  end

  def test_non_2xx_status_propagates
    skip MAC_SELFCALL_SKIP if RUBY_PLATFORM =~ /darwin/
    res = get("/teapot_from/#{@port}")
    assert_equal "200", res.code
    assert_equal "status=418 body=i'm a teapot", res.body
  end

  def test_response_headers_parsed
    skip MAC_SELFCALL_SKIP if RUBY_PLATFORM =~ /darwin/
    res = get("/header_parse/#{@port}")
    assert_equal "200", res.code
    assert_equal "echo_header=hi", res.body
  end

  def test_https_or_unknown_scheme_returns_zero
    res = get("/bad_scheme")
    assert_equal "status=0", res.body
  end

  def test_connect_failure_returns_zero
    res = get("/connect_fail")
    assert_equal "status=0", res.body
  end
end
