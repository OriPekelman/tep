require_relative "helper"
require "json"

# 6.7b: Tep::Http.send_req reuses pooled keep-alive connections.
#
# Pooling lives in the BLOCKING send path (prefork), and pool state is
# per-worker -- so the two send_req calls must share one worker. We
# can't self-call here (blocking + workers=1 would deadlock; multi-
# worker makes pool hits nondeterministic), so the client makes both
# calls to a SEPARATE upstream process within one handler. One worker,
# one pool: the second call reuses the connection the first released.
class TestHttpPoolSend < TepTest
  UPSTREAM = <<~UP
    require 'sinatra'
    set :workers, 1
    get '/ping' do
      "pong"
    end
  UP

  app_source <<~RB
    require 'sinatra'
    set :workers, 1

    # Two sequential GETs to the same upstream in ONE handler (one
    # worker -> one pool). Reports the hits delta + both bodies so the
    # test asserts both reuse and correctness.
    get '/twocalls/:uport' do
      res.headers["Content-Type"] = "application/json"
      base = "http://127.0.0.1:" + params[:uport]
      h0 = Tep::Http::Pool.stats["hits"].to_i
      r1 = Tep::Http.get(base + "/ping")
      r2 = Tep::Http.get(base + "/ping")
      h1 = Tep::Http::Pool.stats["hits"].to_i
      "{" +
        Tep::Json.encode_pair_int("hits_delta", h1 - h0) + "," +
        Tep::Json.encode_pair_str("b1", r1.body) + "," +
        Tep::Json.encode_pair_str("b2", r2.body) +
      "}"
    end
  RB

  def setup
    super
    @up_port = TepHarness.spawn_app(UPSTREAM, mode: :sinatra, workers: 1)
  end

  def test_send_req_reuses_pooled_connection
    res = get("/twocalls/#{@up_port}")
    assert_equal "200", res.code
    j = JSON.parse(res.body)
    assert_equal "pong", j["b1"]
    assert_equal "pong", j["b2"]
    assert_equal 1, j["hits_delta"],
      "second send_req to the same upstream should reuse the pooled connection"
  end
end
