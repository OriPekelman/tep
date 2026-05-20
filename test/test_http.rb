require_relative "helper"

# Tep::Http -- outbound HTTP client tests. Boots a tep app with both
# "target" endpoints (/ping, /echo, /headers, /404) and a "client"
# endpoint (/selfcall/:port) that uses Tep::Http to call its own
# server. The test passes its bound port to the handler via path
# capture, which side-steps the test harness's lack of "tell the
# handler its own port" plumbing.
#
# Runs under Tep::Server::Scheduled with workers=1. The handlers do
# outbound HTTP back to the same server -- under cooperative I/O the
# outer fiber parks on io_wait while the accept fiber accepts the
# inner connection, which is the only shape that works on macOS
# (SO_REUSEPORT doesn't load-balance on Darwin). See
# docs/MACOS-CONCURRENCY.md.
class TestHttp < TepTest
  app_source <<~RB
    require 'sinatra'

    # Cooperative server + single worker. The two-fiber dance is
    # what unblocks self-calling handlers; see
    # docs/MACOS-CONCURRENCY.md for the full path.
    set :scheduler, :scheduled
    set :workers, 1

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

  def test_selfcall_returns_pong
    res = get("/selfcall/#{@port}")
    assert_equal "200", res.code
    assert_equal "status=200 body=pong", res.body
  end

  def test_instance_sends_default_header
    res = get("/instance/#{@port}")
    assert_equal "200", res.code
    # The target's /headers_back echoes the X-Custom header it saw.
    assert_equal "status=200 body=x-custom=hello-from-tep", res.body
  end

  def test_post_body_round_trips
    res = get("/post_echo/#{@port}")
    assert_equal "200", res.code
    assert_equal "status=200 body=round trip body", res.body
  end

  def test_non_2xx_status_propagates
    res = get("/teapot_from/#{@port}")
    assert_equal "200", res.code
    assert_equal "status=418 body=i'm a teapot", res.body
  end

  def test_response_headers_parsed
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
