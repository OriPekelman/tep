require_relative "helper"
require "json"

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

# Tep::Proxy 6.4: per-request upstream routing via pick_upstream(req).
# Two faux backends (/srv-a/info, /srv-b/info) on the same server are
# routed through a Router proxy whose pick_upstream branches by path.
# Demonstrates the override path and that the default (returning
# @upstream) is preserved when not overridden.
class TestProxyMultiUpstream < TepTest
  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    # Two upstream "backends" on the same server, distinguished by
    # path prefix. In a real deployment these would be separate hosts;
    # the test framework runs one app per class so we collapse them
    # onto distinct routes that pick_upstream + rewrite_path can
    # treat as logically separate upstreams.
    get '/srv-a/info' do
      "from-a"
    end
    get '/srv-b/info' do
      "from-b"
    end

    # Routes /p/route/:port/a -> srv-a's /info, /p/route/:port/b ->
    # srv-b's /info. pick_upstream picks the BASE URL (host+port +
    # the fixed /srv-X prefix); rewrite_path produces the suffix.
    # Composed: pick_upstream(req) + rewrite_path(raw_path).
    class Router < Tep::Proxy
      def pick_upstream(req)
        if Tep.str_find(req.path, "/a", 0) >= 0
          @upstream + "/srv-a"
        else
          @upstream + "/srv-b"
        end
      end
      def rewrite_path(path)
        "/info"
      end
    end

    get '/p/route/:port/:where' do
      Router.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end
  RB

  def test_pick_upstream_routes_to_srv_a
    res = get("/p/route/#{@port}/a")
    assert_equal "200", res.code
    assert_equal "from-a", res.body
  end

  def test_pick_upstream_routes_to_srv_b
    res = get("/p/route/#{@port}/b")
    assert_equal "200", res.code
    assert_equal "from-b", res.body
  end
end

# Tep::Proxy 6.6: body size caps. max_request_body_bytes rejects
# oversize POSTs with 413 before any upstream call; max_response_body_bytes
# rejects oversize upstream responses with 502 + proxy_error JSON.
class TestProxyBodyCaps < TepTest
  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    # Two upstream endpoints with hardcoded sizes -- 50-byte (under
    # the 200-byte response cap) and 500-byte (over).
    get '/upstream/small' do
      res.headers["Content-Type"] = "application/octet-stream"
      "x" * 50
    end

    get '/upstream/large' do
      res.headers["Content-Type"] = "application/octet-stream"
      "x" * 500
    end

    post '/upstream/echo' do
      res.headers["Content-Type"] = "application/octet-stream"
      req.raw_body
    end

    # Proxies with tiny caps to make over/under testable. 100-byte
    # request cap; 200-byte response cap. Each one extends Tep::Proxy
    # DIRECTLY (not via a shared intermediate parent) -- spinel's
    # widening over an intermediate-class initialize that sets the
    # new attrs lets the upstream dispatch widen and Tep::Http.send_req
    # returns status=0 / connect-failure 502. Three direct subclasses
    # type-pin cleanly; the duplicated initialize is a deliberate
    # workaround.
    class TinyEchoProxy < Tep::Proxy
      def initialize(upstream)
        super
        self.max_request_body_bytes  = 100
        self.max_response_body_bytes = 200
      end
      def rewrite_path(path)
        "/upstream/echo"
      end
    end

    class TinySmallProxy < Tep::Proxy
      def initialize(upstream)
        super
        self.max_request_body_bytes  = 100
        self.max_response_body_bytes = 200
      end
      def rewrite_path(path)
        "/upstream/small"
      end
    end

    class TinyLargeProxy < Tep::Proxy
      def initialize(upstream)
        super
        self.max_request_body_bytes  = 100
        self.max_response_body_bytes = 200
      end
      def rewrite_path(path)
        "/upstream/large"
      end
    end

    post '/p/tiny-echo/:port' do
      TinyEchoProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/tiny-small/:port' do
      TinySmallProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/tiny-large/:port' do
      TinyLargeProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end
  RB

  def test_request_under_cap_passes
    res = post("/p/tiny-echo/#{@port}", "x" * 50)
    assert_equal "200", res.code
    assert_equal "x" * 50, res.body
  end

  def test_request_over_cap_returns_413
    res = post("/p/tiny-echo/#{@port}", "x" * 500)
    assert_equal "413", res.code
    body = JSON.parse(res.body)
    assert_equal "payload_too_large", body["error"]["type"]
    assert_match(/proxy cap of 100 bytes/, body["error"]["message"])
  end

  def test_response_under_cap_passes
    res = get("/p/tiny-small/#{@port}")
    assert_equal "200", res.code
    assert_equal 50, res.body.length
  end

  def test_response_over_cap_returns_502
    res = get("/p/tiny-large/#{@port}")
    assert_equal "502", res.code
    refute_empty res.body, "expected an error-shape body, got empty (502 from connect failure path?)"
    body = JSON.parse(res.body)
    assert_equal "upstream_body_too_large", body["error"]["type"]
    assert_match(/upstream response body exceeds proxy cap of 200 bytes/,
                 body["error"]["message"])
  end
end
