require_relative "helper"

# Tep::Proxy -- HTTP reverse-proxy battery (chunk 6.1, non-streaming).
#
# Same self-calling shape as test_http.rb: the app boots both the
# "upstream" endpoints (/ping, /echo_body, /headers_back, /teapot)
# and proxy routes that forward to 127.0.0.1:<own-port>. The proxy
# instance's upstream is fixed at construction, so each proxy route
# builds its Tep::Proxy subclass inside the handler with the runtime
# port from a path capture (the harness can't tell a load-time
# constructor its own port).
#
# Runs under Tep::Server::Scheduled with workers=1 -- the only shape
# where a handler can make an outbound call back to its own server
# under cooperative I/O (see docs/MACOS-CONCURRENCY.md, test_http.rb).
class TestProxy < TepTest
  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    # ---- upstream endpoints (what the proxies forward to) ----

    get '/ping' do
      "pong"
    end

    post '/echo_body' do
      res.headers["Content-Type"] = "text/plain"
      req.raw_body
    end

    get '/headers_back' do
      "x-custom=" + req.req_headers["x-custom"]
    end

    get '/teapot' do
      res.set_status(418)
      "i'm a teapot"
    end

    get '/sets_header' do
      res.headers["X-Upstream"] = "from-upstream"
      "ok"
    end

    # ---- proxy subclasses (the overridable-hook lowering target) ----

    # Forward to a fixed upstream path regardless of inbound path.
    class PingProxy < Tep::Proxy
      def rewrite_path(path)
        "/ping"
      end
    end

    class TeapotProxy < Tep::Proxy
      def rewrite_path(path)
        "/teapot"
      end
    end

    class HeaderBackProxy < Tep::Proxy
      def rewrite_path(path)
        "/headers_back"
      end
    end

    class SetsHeaderProxy < Tep::Proxy
      def rewrite_path(path)
        "/sets_header"
      end
    end

    # Inject a header into the upstream request.
    class InjectProxy < Tep::Proxy
      def rewrite_path(path)
        "/headers_back"
      end
      def before_forward(req, res, ureq)
        ureq.set_header("X-Custom", "injected-by-proxy")
        false
      end
    end

    # Short-circuit: never reach upstream.
    class GuardProxy < Tep::Proxy
      def before_forward(req, res, ureq)
        res.set_status(403)
        res.set_body("denied by proxy")
        true
      end
    end

    # Stamp the response on the way back out.
    class StampProxy < Tep::Proxy
      def rewrite_path(path)
        "/ping"
      end
      def after_forward(req, ures, res)
        res.headers["X-Proxied"] = "yes"
        0
      end
    end

    # Pass the request body straight through to /echo_body.
    class EchoProxy < Tep::Proxy
      def rewrite_path(path)
        "/echo_body"
      end
    end

    # ---- proxy mount routes (build with runtime port) ----

    get '/p/ping/:port' do
      PingProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/teapot/:port' do
      TeapotProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/inject/:port' do
      InjectProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/guard/:port' do
      GuardProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/stamp/:port' do
      StampProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/upstreamhdr/:port' do
      SetsHeaderProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    post '/p/echo/:port' do
      EchoProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    # Dead upstream port -> connect failure -> 502.
    get '/p/deadport' do
      PingProxy.new("http://127.0.0.1:1").handle(req, res)
      res.body
    end
  RB

  def test_forwards_get_and_returns_upstream_body
    res = get("/p/ping/#{@port}")
    assert_equal "200", res.code
    assert_equal "pong", res.body
  end

  def test_propagates_upstream_status
    res = get("/p/teapot/#{@port}")
    assert_equal "418", res.code
    assert_equal "i'm a teapot", res.body
  end

  def test_before_forward_can_inject_upstream_header
    res = get("/p/inject/#{@port}")
    assert_equal "200", res.code
    assert_equal "x-custom=injected-by-proxy", res.body
  end

  def test_before_forward_short_circuits
    res = get("/p/guard/#{@port}")
    assert_equal "403", res.code
    assert_equal "denied by proxy", res.body
  end

  def test_after_forward_can_stamp_response
    res = get("/p/stamp/#{@port}")
    assert_equal "200", res.code
    assert_equal "pong", res.body
    assert_equal "yes", res["X-Proxied"]
  end

  def test_propagates_upstream_response_headers
    res = get("/p/upstreamhdr/#{@port}")
    assert_equal "200", res.code
    assert_equal "from-upstream", res["X-Upstream"]
  end

  def test_forwards_post_body
    res = post("/p/echo/#{@port}", "round trip body")
    assert_equal "200", res.code
    assert_equal "round trip body", res.body
  end

  def test_connect_failure_maps_to_502
    res = get("/p/deadport")
    assert_equal "502", res.code
  end
end
