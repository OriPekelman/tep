require_relative "helper"
require "json"

# examples/llm_gateway integration: a Tep::Proxy that streams an SSE
# upstream through to the client AND emits one toy/v1 inference event
# at end-of-stream via Tep::Events. Self-contained (self-call SSE
# upstream, like test_proxy_streaming): proves proxy streaming +
# Tep::Events compose -- the chunk-6.3 payoff.
#
# The example app itself uses the block DSL; here the gateway is the
# subclass-override form so it can be built per-request with the
# harness's runtime port (block-DSL proxies construct at load time,
# before the port is known -- same reason test_proxy_streaming uses
# in-handler construction).
class TestLlmGateway < TepTest
  EV_PATH = "/tmp/tep_gateway_test.jsonl"

  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    PATH = "#{EV_PATH}"
    EVENTS = Tep::Events.new(PATH)

    # Upstream: an OpenAI-shaped streaming chat completion.
    class ChatSse < Tep::Streamer
      def pump(out)
        out.write("data: {\\"choices\\":[{\\"delta\\":{\\"content\\":\\"He\\"}}]}\\n\\n")
        out.write("data: {\\"choices\\":[{\\"delta\\":{\\"content\\":\\"llo\\"}}]}\\n\\n")
        out.write("data: [DONE]\\n\\n")
      end
    end

    post '/v1/upstream' do
      res.headers["Content-Type"] = "text/event-stream"
      stream ChatSse.new
    end

    # The gateway: stream through + emit one inference event at end.
    class Gateway < Tep::Proxy
      def rewrite_path(path)
        "/v1/upstream"
      end
      def stream_request?(req)
        true
      end
      def on_stream_chunk(chunk, out, stats)
        out.write(chunk.chunk_text)
        0
      end
      def on_stream_end(req, out, stats)
        model = SpinelKit::Json.get_str(req.raw_body, "model")
        extra = "{" + SpinelKit::Json.encode_pair_str("request_id", "req-1") + "}"
        EVENTS.inference(model, 0, stats.chunk_count, 1000000, extra)
        0
      end
    end

    post '/gw/:port' do
      File.write(PATH, "")
      Gateway.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/events' do
      File.read(PATH)
    end
  RB

  def test_streams_upstream_through_gateway
    res = post("/gw/#{@port}", "{\"model\":\"demo-llm\",\"stream\":true}")
    assert_equal "200", res.code
    # The three upstream SSE events pass through unchanged.
    assert_equal "data: {\"choices\":[{\"delta\":{\"content\":\"He\"}}]}\n\n" \
                 "data: {\"choices\":[{\"delta\":{\"content\":\"llo\"}}]}\n\n" \
                 "data: [DONE]\n\n", res.body
  end

  def test_emits_one_inference_event
    post("/gw/#{@port}", "{\"model\":\"demo-llm\",\"stream\":true}")
    lines = get("/events").body.split("\n").reject(&:empty?)
    assert_equal 1, lines.length, "expected exactly one inference event"
    ev = JSON.parse(lines[0])
    # toy/v1 inference shape (migrated in #136): kind "eval", name
    # "request", and model/token fields nested under "extra".
    assert_equal "eval", ev["kind"]
    assert_equal "serve", ev["phase"]
    assert_equal "request", ev["name"]
    assert_equal "demo-llm", ev["extra"]["model"]
    assert_equal 3, ev["extra"]["completion_tokens"]   # 3 SSE events dispatched
    assert_equal "req-1", ev["extra"]["request_id"]
  end
end
