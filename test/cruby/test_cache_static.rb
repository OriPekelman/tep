require_relative "helper"

# Caching phase 2 (#152): static files served via send_file (public_dir)
# carry a size-mtime ETag + Last-Modified and revalidate to 304.
class TestCacheStatic < TepTest
  app_source <<~RB
    set :public_dir, '#{File.expand_path("../../public", __dir__)}'

    get '/' do
      "root"
    end
  RB

  def test_static_file_has_validators
    res = get("/hello.txt")
    assert_equal "200", res.code
    refute_nil res["ETag"]
    assert_match(/GMT\z/, res["Last-Modified"])
    assert_match(/static file serving/, res.body)
  end

  def test_static_if_none_match_returns_304
    etag = get("/hello.txt")["ETag"]
    res = get("/hello.txt", {"If-None-Match" => etag})
    assert_equal "304", res.code
    assert_equal "", res.body.to_s
    assert_equal etag, res["ETag"]   # validator preserved on 304
  end

  def test_static_if_modified_since_equal_returns_304
    lm = get("/hello.txt")["Last-Modified"]
    res = get("/hello.txt", {"If-Modified-Since" => lm})
    assert_equal "304", res.code
    assert_equal "", res.body.to_s
  end

  def test_static_if_modified_since_old_returns_200
    res = get("/hello.txt", {"If-Modified-Since" => "Sat, 01 Jan 2000 00:00:00 GMT"})
    assert_equal "200", res.code
    assert_match(/static file serving/, res.body)
  end

  def test_static_if_none_match_mismatch_returns_200
    res = get("/hello.txt", {"If-None-Match" => "\"nope\""})
    assert_equal "200", res.code
    assert_match(/static file serving/, res.body)
  end
end
