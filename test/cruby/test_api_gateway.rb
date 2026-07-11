require_relative "helper"

# examples/api_gateway integration: a non-streaming Tep::Proxy that
# gates on a capability (before_forward short-circuit), swaps the
# upstream credential, and stamps observability headers in
# after_forward -- which must run on BOTH the forwarded and the
# short-circuited (denied) paths.
#
# Self-call shape (scheduled + workers=1, like test_http/test_proxy):
# the upstream echoes the Authorization header it received, so the
# test can confirm the credential swap; the gateway is the
# subclass-override form, built per-request with the runtime port
# (the example app uses the block DSL).
class TestApiGateway < TepTest
  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    # Upstream: echo the Authorization header the gateway attached.
    get '/up/echo' do
      "auth=" + req.req_headers["authorization"]
    end

    # Grant :call_upstream when the request carries ?auth=ok (stands in
    # for the Auth battery populating req.identity).
    before do
      if params[:auth] == "ok"
        req.identity = Tep::Identity.new("client:test", nil, [:call_upstream])
      end
    end

    class ApiGw < Tep::Proxy
      def rewrite_path(path)
        "/up/echo"
      end
      def before_forward(req, res, ureq)
        if !req.identity.may?(:call_upstream)
          res.set_status(403)
          res.set_body("denied")
          true
        else
          ureq.set_header("Authorization", "Bearer upstream-secret")
          false
        end
      end
      def after_forward(req, ures, res)
        res.headers["X-Proxy-Status"] = ures.status.to_s
        0
      end
    end

    get '/gw/:port' do
      ApiGw.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end
  RB

  def test_forwards_with_credential_when_capable
    res = get("/gw/#{@port}?auth=ok")
    assert_equal "200", res.code
    # Upstream saw the gateway's attached credential, not the client's.
    assert_equal "auth=Bearer upstream-secret", res.body
    # after_forward stamped the real upstream status.
    assert_equal "200", res["X-Proxy-Status"]
  end

  def test_rejects_without_capability
    res = get("/gw/#{@port}")           # no ?auth=ok -> no capability
    assert_equal "403", res.code
    assert_equal "denied", res.body
    # after_forward ran on the short-circuit path too (ures.status 0).
    assert_equal "0", res["X-Proxy-Status"]
  end
end
