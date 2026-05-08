require_relative "helper"

# Status codes, custom headers, content-type, redirect, halt.
class TestResponse < TepTest
  app_source <<~RB
    get '/ok' do
      "ok"
    end

    get '/created' do
      status 201
      "made"
    end

    get '/no-content' do
      status 204
      ""
    end

    get '/server-err' do
      status 500
      "boom"
    end

    get '/plain' do
      content_type 'text/plain; charset=utf-8'
      "plain text"
    end

    get '/json' do
      content_type 'application/json'
      '{"ok":true}'
    end

    get '/custom-header' do
      headers["X-Tep-Test"] = "yep"
      "with header"
    end

    get '/redirect' do
      redirect '/ok'
    end

    get '/redirect-301' do
      redirect '/ok', 301
    end

    get '/halt-401' do
      halt 401, "denied"
    end

    get '/halt-bare' do
      halt 418
    end
  RB

  def test_default_200
    res = get("/ok")
    assert_equal "200", res.code
    assert_equal "OK", res.message
  end

  def test_status_201
    assert_equal "201", get("/created").code
  end

  def test_status_204
    assert_equal "204", get("/no-content").code
  end

  def test_status_500
    assert_equal "500", get("/server-err").code
  end

  def test_default_content_type_html
    res = get("/ok")
    assert_match(/text\/html/, res["content-type"])
  end

  def test_explicit_content_type_plain
    res = get("/plain")
    assert_equal "text/plain; charset=utf-8", res["content-type"]
  end

  def test_explicit_content_type_json
    res = get("/json")
    assert_equal "application/json", res["content-type"]
    assert_equal '{"ok":true}', res.body
  end

  def test_custom_header
    res = get("/custom-header")
    assert_equal "yep", res["x-tep-test"]
  end

  def test_redirect_default_302
    res = get("/redirect")
    assert_equal "302", res.code
    assert_equal "/ok", res["location"]
  end

  def test_redirect_explicit_301
    res = get("/redirect-301")
    assert_equal "301", res.code
    assert_equal "/ok", res["location"]
  end

  def test_halt_with_body
    res = get("/halt-401")
    assert_equal "401", res.code
    assert_equal "denied", res.body
  end

  def test_halt_status_only
    res = get("/halt-bare")
    assert_equal "418", res.code
  end

  def test_content_length
    res = get("/ok")
    assert_equal "2", res["content-length"]
  end
end
