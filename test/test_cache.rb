require_relative "helper"

# HTTP caching battery (issue #152): Cache-Control / ETag / Last-Modified
# response helpers + conditional-GET 304 short-circuit.
class TestCache < TepTest
  app_source <<~RB
    require 'sinatra'

    get '/etag' do
      res.etag("v1")
      "etag-body"
    end

    get '/lastmod' do
      res.last_modified(1700000000)   # fixed epoch -> stable Last-Modified
      "lastmod-body"
    end

    get '/cc' do
      res.cache_control("public, max-age=60")
      "cc-body"
    end

    get '/exp' do
      res.expires(60)
      "exp-body"
    end

    get '/nostore' do
      res.no_store
      "ns-body"
    end
  RB

  # ---- ETag / If-None-Match ----

  def test_etag_present_on_normal_get
    res = get("/etag")
    assert_equal "200", res.code
    assert_equal "\"v1\"", res["ETag"]
    assert_equal "etag-body", res.body
  end

  def test_if_none_match_match_returns_304_no_body
    res = get("/etag", {"If-None-Match" => "\"v1\""})
    assert_equal "304", res.code
    assert_equal "", res.body.to_s
    assert_equal "\"v1\"", res["ETag"]   # validator preserved on 304
  end

  def test_if_none_match_star_returns_304
    res = get("/etag", {"If-None-Match" => "*"})
    assert_equal "304", res.code
  end

  def test_if_none_match_mismatch_returns_200
    res = get("/etag", {"If-None-Match" => "\"other\""})
    assert_equal "200", res.code
    assert_equal "etag-body", res.body
  end

  # ---- Last-Modified / If-Modified-Since ----

  def test_last_modified_header_is_http_date
    res = get("/lastmod")
    assert_equal "200", res.code
    assert_match(/GMT\z/, res["Last-Modified"])
  end

  def test_if_modified_since_equal_returns_304
    first = get("/lastmod")
    res = get("/lastmod", {"If-Modified-Since" => first["Last-Modified"]})
    assert_equal "304", res.code
    assert_equal "", res.body.to_s
  end

  def test_if_modified_since_older_returns_200
    res = get("/lastmod", {"If-Modified-Since" => "Sat, 01 Jan 2000 00:00:00 GMT"})
    assert_equal "200", res.code
    assert_equal "lastmod-body", res.body
  end

  # ---- Cache-Control / Expires ----

  def test_cache_control_verbatim
    assert_equal "public, max-age=60", get("/cc")["Cache-Control"]
  end

  def test_expires_sets_expires_and_max_age
    res = get("/exp")
    assert_equal "max-age=60", res["Cache-Control"]
    assert_match(/GMT\z/, res["Expires"])
  end

  def test_no_store_shortcut
    assert_equal "no-store", get("/nostore")["Cache-Control"]
  end
end
