require_relative "helper"

class TestCookies < TepTest
  app_source <<~RB
    get '/echo' do
      "name=" + cookies["name"] + " mood=" + cookies["mood"]
    end

    get '/set' do
      set_cookie "user", "alice"
      "ok"
    end

    get '/set-flagged' do
      set_cookie "session_id", "xyz"
      "ok"
    end
  RB

  def test_round_trip
    res = get("/echo", "Cookie" => "name=alice; mood=happy")
    assert_equal "200", res.code
    assert_equal "name=alice mood=happy", res.body
  end

  def test_url_decoded_value
    res = get("/echo", "Cookie" => "name=hello%20world; mood=ok")
    assert_equal "name=hello world mood=ok", res.body
  end

  def test_missing_cookie_is_empty
    res = get("/echo", "Cookie" => "name=alice")
    assert_equal "name=alice mood=", res.body
  end

  def test_set_cookie_writes_header
    res = get("/set")
    assert_equal "200", res.code
    assert_equal "user=alice", res["set-cookie"]
  end

  def test_set_cookie_value_is_url_encoded
    res = get("/set-flagged")
    assert_match(/^session_id=xyz/, res["set-cookie"])
  end

  def test_no_cookie_header_no_crash
    res = get("/echo")
    assert_equal "200", res.code
    assert_equal "name= mood=", res.body
  end
end
