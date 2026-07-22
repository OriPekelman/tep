require_relative "helper"

class TestStreaming < TepTest
  app_source <<~RB
    require 'sinatra'

    class Ticks < Tep::Streamer
      def pump(out)
        out.write("data: 1\\n\\n")
        out.write("data: 2\\n\\n")
        out.write("data: 3\\n\\n")
      end
    end

    get '/stream' do
      stream Ticks.new
    end

    get '/normal' do
      "regular response"
    end
  RB

  def test_stream_uses_chunked_encoding
    res = get("/stream")
    assert_equal "200", res.code
    assert_equal "chunked", res["transfer-encoding"]
    assert_nil res["content-length"]
  end

  def test_stream_default_content_type
    res = get("/stream")
    assert_match(%r{text/event-stream}, res["content-type"])
  end

  def test_stream_emits_all_chunks
    res = get("/stream")
    assert_equal "data: 1\n\ndata: 2\n\ndata: 3\n\n", res.body
  end

  def test_normal_route_still_buffered
    res = get("/normal")
    assert_equal "200", res.code
    assert_nil res["transfer-encoding"]
    assert_equal "16", res["content-length"]
    assert_equal "regular response", res.body
  end
end

# Same streaming surface under Tep::Server::Scheduled. Regression
# guard for #90: the scheduled server's write_response had no
# res.streaming branch, so streamed responses came back with
# Content-Length: 0 and an empty body (the Streamer never pumped).
class TestStreamingScheduled < TepTest
  app_source <<~RB
    require 'sinatra'

    set :scheduler, :scheduled
    set :workers, 1

    class Ticks < Tep::Streamer
      def pump(out)
        out.write("data: 1\\n\\n")
        out.write("data: 2\\n\\n")
        out.write("data: 3\\n\\n")
      end
    end

    get '/stream' do
      stream Ticks.new
    end

    get '/normal' do
      "regular response"
    end
  RB

  def test_scheduled_stream_uses_chunked_encoding
    res = get("/stream")
    assert_equal "200", res.code
    assert_equal "chunked", res["transfer-encoding"]
    assert_nil res["content-length"]
  end

  def test_scheduled_stream_emits_all_chunks
    res = get("/stream")
    assert_equal "data: 1\n\ndata: 2\n\ndata: 3\n\n", res.body
  end

  def test_scheduled_normal_route_still_buffered
    res = get("/normal")
    assert_equal "200", res.code
    assert_nil res["transfer-encoding"]
    assert_equal "regular response", res.body
  end
end
