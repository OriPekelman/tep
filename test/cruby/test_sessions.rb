require_relative "helper"

class TestSessions < TepTest
  app_source <<~RB
    Tep.session_secret = "test-secret-1234567890abcdef"

    get '/login' do
      session["user"]  = "alice"
      session["plan"]  = "pro"
      "logged in"
    end

    get '/whoami' do
      "user=" + session["user"] + " plan=" + session["plan"]
    end

    # Multi-byte values (#259): SpinelKit::Url.escape used to keep only
    # the first byte of each character, and the HMAC was computed over
    # the truncated payload, so the loss was silent.
    get '/login-utf8' do
      session["user"] = "caf\u00e9 \u{1F600}"
      "logged in"
    end

    get '/whoami-utf8' do
      session["user"]
    end

    get '/cookie-utf8' do
      set_cookie "name", "caf\u00e9"
      "ok"
    end

    get '/no-session-write' do
      "ok"
    end
  RB

  def test_login_sets_signed_cookie
    res = get("/login")
    assert_equal "200", res.code
    assert_match(/^tep\.session=/, res["set-cookie"])
    assert_match(/HttpOnly/, res["set-cookie"])
    assert_match(/SameSite=Lax/, res["set-cookie"])
  end

  def test_session_round_trip
    login = get("/login")
    cookie_line = login["set-cookie"]
    # Extract the Cookie name=value before the first ';'.
    cookie_pair = cookie_line.split(";").first
    res = get("/whoami", "Cookie" => cookie_pair)
    assert_equal "200", res.code
    assert_equal "user=alice plan=pro", res.body
  end

  def test_multibyte_session_value_round_trips
    login = get("/login-utf8")
    cookie_pair = login["set-cookie"].split(";").first
    res = get("/whoami-utf8", "Cookie" => cookie_pair)
    assert_equal "200", res.code
    assert_equal "caf\u00e9 \u{1F600}".b, res.body.b
  end

  def test_multibyte_cookie_value_is_fully_percent_encoded
    res = get("/cookie-utf8")
    assert_match(/^name=caf%C3%A9(;|$)/, res["set-cookie"])
  end

  def test_no_write_no_set_cookie
    res = get("/no-session-write")
    assert_equal "200", res.code
    assert_nil res["set-cookie"]
  end

  def test_tampered_cookie_rejected
    # Take a real session cookie, corrupt the signature, and expect
    # whoami to see no session data.
    login    = get("/login")
    line     = login["set-cookie"]
    pair     = line.split(";").first
    name, val = pair.split("=", 2)
    # Flip a bit in the signature (last char): should fail HMAC verify.
    tampered = val[0...-1] + (val[-1] == "0" ? "1" : "0")
    res = get("/whoami", "Cookie" => "#{name}=#{tampered}")
    # Session is rejected -> empty values for both keys.
    assert_equal "user= plan=", res.body
  end
end
