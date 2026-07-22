require_relative "helper"

# Tep::Proxy streaming (chunk 6.2, #81). Self-calling scheduled-server
# shape like test_http.rb / test_proxy.rb: the app boots an SSE
# upstream producer (/sse_upstream) and proxy routes that forward to
# 127.0.0.1:<own-port> with stream_request? => true, exercising
# on_stream_chunk per event + on_stream_end once at the end.
#
# Requires the scheduled server (proxy streaming parks on io_wait,
# same constraint as WebSocket). workers=1 so the upstream-producer
# fiber and the proxy-consumer fiber cooperate on one worker.
class TestProxyStreaming < TepTest
  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    # ---- upstream: emits three SSE events then closes ----
    class SseTicks < Tep::Streamer
      def pump(out)
        out.write("data: a\\n\\n")
        out.write("data: b\\n\\n")
        out.write("data: c\\n\\n")
      end
    end

    get '/sse_upstream' do
      res.headers["Content-Type"] = "text/event-stream"
      stream SseTicks.new
    end

    # ---- proxy subclasses (streaming hooks) ----

    # Plain pass-through.
    class PassProxy < Tep::Proxy
      def rewrite_path(path)
        "/sse_upstream"
      end
      def stream_request?(req)
        true
      end
    end

    # Finalizer: emit a closing event carrying the framework's
    # chunk_count, proving on_stream_end fires once with live stats.
    class FinalizeProxy < Tep::Proxy
      def rewrite_path(path)
        "/sse_upstream"
      end
      def stream_request?(req)
        true
      end
      def on_stream_end(req, out, stats)
        out.write("data: count=" + stats.chunk_count.to_s + "\\n\\n")
        0
      end
    end

    # Transform: prefix every event, proving on_stream_chunk can
    # rewrite bytes on the way through.
    class PrefixProxy < Tep::Proxy
      def rewrite_path(path)
        "/sse_upstream"
      end
      def stream_request?(req)
        true
      end
      def on_stream_chunk(chunk, out, stats)
        out.write("x-" + chunk.chunk_text)
        0
      end
    end

    # Drop: forward only events whose payload contains "b".
    class DropProxy < Tep::Proxy
      def rewrite_path(path)
        "/sse_upstream"
      end
      def stream_request?(req)
        true
      end
      def on_stream_chunk(chunk, out, stats)
        if chunk.chunk_text.include?("b")
          out.write(chunk.chunk_text)
        end
        0
      end
    end

    # ---- mount routes (build proxy with runtime port) ----

    get '/p/pass/:port' do
      PassProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/finalize/:port' do
      FinalizeProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/prefix/:port' do
      PrefixProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    get '/p/drop/:port' do
      DropProxy.new("http://127.0.0.1:" + params[:port]).handle(req, res)
      res.body
    end

    # Control: the upstream itself, fetched directly.
    get '/direct/:port' do
      r = Tep::Http.get("http://127.0.0.1:" + params[:port] + "/sse_upstream")
      "status=" + r.status.to_s
    end
  RB

  def test_streams_all_events_through
    res = get("/p/pass/#{@port}")
    assert_equal "200", res.code
    assert_equal "chunked", res["transfer-encoding"]
    assert_equal "data: a\n\ndata: b\n\ndata: c\n\n", res.body
  end

  def test_on_stream_end_fires_once_with_stats
    res = get("/p/finalize/#{@port}")
    assert_equal "200", res.code
    # Three upstream events, then exactly one finalizer event carrying
    # the chunk count.
    assert_equal "data: a\n\ndata: b\n\ndata: c\n\ndata: count=3\n\n", res.body
  end

  def test_on_stream_chunk_can_transform
    res = get("/p/prefix/#{@port}")
    assert_equal "200", res.code
    assert_equal "x-data: a\n\nx-data: b\n\nx-data: c\n\n", res.body
  end

  def test_on_stream_chunk_can_drop
    res = get("/p/drop/#{@port}")
    assert_equal "200", res.code
    assert_equal "data: b\n\n", res.body
  end
end
