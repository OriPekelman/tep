require_relative "helper"

# HTTP Range (206) for send_file / static files, on both servers.
module SendFileRangeCases
  FILE = File.expand_path("../../public/hello.txt", __dir__)

  def body_bytes; @body_bytes ||= File.binread(FILE); end

  def test_no_range_is_full_200_with_accept_ranges
    res = get("/hello.txt")
    assert_equal "200", res.code
    assert_equal "bytes", res["Accept-Ranges"]
    assert_nil res["Content-Range"]
    assert_equal body_bytes, res.body.b
  end

  def test_closed_range_returns_206
    res = get("/hello.txt", {"Range" => "bytes=2-6"})
    assert_equal "206", res.code
    assert_equal "Partial Content", res.message if res.message && !res.message.empty?
    assert_equal "bytes 2-6/#{body_bytes.bytesize}", res["Content-Range"]
    assert_equal "5", res["Content-Length"]
    assert_equal body_bytes.byteslice(2, 5), res.body.b
  end

  def test_open_ended_range
    res = get("/hello.txt", {"Range" => "bytes=10-"})
    n = body_bytes.bytesize
    assert_equal "206", res.code
    assert_equal "bytes 10-#{n - 1}/#{n}", res["Content-Range"]
    assert_equal body_bytes.byteslice(10..), res.body.b
  end

  def test_suffix_range
    res = get("/hello.txt", {"Range" => "bytes=-4"})
    n = body_bytes.bytesize
    assert_equal "206", res.code
    assert_equal "bytes #{n - 4}-#{n - 1}/#{n}", res["Content-Range"]
    assert_equal body_bytes.byteslice(-4, 4), res.body.b
  end

  def test_end_past_eof_is_clamped
    res = get("/hello.txt", {"Range" => "bytes=0-99999"})
    n = body_bytes.bytesize
    assert_equal "206", res.code
    assert_equal "bytes 0-#{n - 1}/#{n}", res["Content-Range"]
    assert_equal body_bytes, res.body.b
  end

  def test_range_skips_conditional_304
    etag = get("/hello.txt")["ETag"]
    res = get("/hello.txt", {"Range" => "bytes=0-3", "If-None-Match" => etag})
    assert_equal "206", res.code
    assert_equal body_bytes.byteslice(0, 4), res.body.b
  end

  def test_unsatisfiable_range_falls_back_to_200
    res = get("/hello.txt", {"Range" => "bytes=99999-"})
    assert_equal "200", res.code
    assert_equal body_bytes, res.body.b
  end

  def test_malformed_ranges_fall_back_to_200
    ["bytes=abc", "bytes=5-2", "bytes=-", "items=0-3", "bytes=0-1,3-4", "bytes=-0"].each do |r|
      res = get("/hello.txt", {"Range" => r})
      assert_equal "200", res.code, "Range: #{r}"
      assert_equal body_bytes, res.body.b, "Range: #{r}"
    end
  end

  def test_keep_alive_survives_partial
    uri = URI("http://127.0.0.1:#{@port}/hello.txt")
    Net::HTTP.start(uri.host, uri.port, read_timeout: 3) do |http|
      r1 = Net::HTTP::Get.new(uri); r1["Range"] = "bytes=0-4"
      assert_equal "206", http.request(r1).code
      assert_equal "200", http.request(Net::HTTP::Get.new(uri)).code
    end
  end
end

class TestSendFileRange < TepTest
  include SendFileRangeCases
  app_source <<~RB
    set :public_dir, '#{File.expand_path("../../public", __dir__)}'
  RB
end

class TestSendFileRangeScheduled < TepTest
  include SendFileRangeCases
  app_source <<~RB
    set :public_dir, '#{File.expand_path("../../public", __dir__)}'
    set :scheduler, :scheduled
  RB
end
