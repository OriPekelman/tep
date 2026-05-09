require_relative "helper"

# Tep::Jwt -- HS256 encode + decode + verify, plus the b64url
# helpers in sphttp.c that back it.
class TestJwt < TepTest
  app_source <<~RB
    require 'sinatra'

    SECRET = "supersecret"

    post '/issue' do
      res.headers["Content-Type"] = "text/plain"
      user = Tep::Json.get_str(req.raw_body, "user")
      payload = "{" + Tep::Json.encode_pair_str("sub", user) + "}"
      Tep::Jwt.encode_hs256(payload, SECRET)
    end

    post '/verify' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Jwt.verify_hs256(req.raw_body, SECRET) ? "ok" : "bad"
    end

    post '/decode' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Jwt.decode_payload(req.raw_body)
    end

    post '/verify_and_decode' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Jwt.verify_and_decode(req.raw_body, SECRET)
    end

    post '/b64u_encode' do
      res.headers["Content-Type"] = "text/plain"
      Sock.sphttp_b64url_encode(req.raw_body)
    end

    post '/b64u_decode' do
      res.headers["Content-Type"] = "text/plain"
      Sock.sphttp_b64url_decode(req.raw_body)
    end

    post '/timing_eq' do
      res.headers["Content-Type"] = "text/plain"
      a = Tep::Json.get_str(req.raw_body, "a")
      b = Tep::Json.get_str(req.raw_body, "b")
      Tep::Jwt.timing_safe_eq(a, b) ? "yes" : "no"
    end
  RB

  def issue(user)
    post("/issue", %({"user":"#{user}"})).body.strip
  end

  def test_encode_decode_round_trip
    token = issue("alice")
    parts = token.split(".")
    assert_equal 3, parts.length
    # Decode the payload via the route -- exercises sphttp_b64url_decode
    # in the same path the verify uses.
    res = post("/decode", token)
    assert_match(/"sub":"alice"/, res.body)
  end

  def test_verify_signature_match
    token = issue("alice")
    res = post("/verify", token)
    assert_equal "ok", res.body.strip
  end

  def test_verify_rejects_tampered_signature
    token = issue("alice")
    # Flip a byte in the signature segment.
    bad = token + "x"
    res = post("/verify", bad)
    assert_equal "bad", res.body.strip
  end

  def test_verify_rejects_tampered_payload
    token = issue("alice")
    # Replace "alice" in the encoded payload with a different
    # subject and re-stitch -- signature should no longer match.
    parts = token.split(".")
    new_payload = '{"sub":"mallory"}'
    require "base64"
    new_b64 = Base64.urlsafe_encode64(new_payload, padding: false)
    forged = parts[0] + "." + new_b64 + "." + parts[2]
    res = post("/verify", forged)
    assert_equal "bad", res.body.strip
  end

  def test_verify_and_decode_one_shot
    token = issue("alice")
    res = post("/verify_and_decode", token)
    assert_match(/"sub":"alice"/, res.body)
  end

  def test_verify_and_decode_returns_empty_on_bad_sig
    token = issue("alice")
    res = post("/verify_and_decode", token + "x")
    assert_equal "", res.body.strip
  end

  def test_b64url_encode_round_trip
    plain = "hello, world!"
    enc = post("/b64u_encode", plain).body.strip
    # JWT-style: no padding.
    refute_match(/=/, enc)
    dec = post("/b64u_decode", enc).body.strip
    assert_equal plain, dec
  end

  def test_b64url_round_trip_with_special_chars
    plain = '{"a":"x?y","z":1}'
    enc = post("/b64u_encode", plain).body.strip
    dec = post("/b64u_decode", enc).body.strip
    assert_equal plain, dec
  end

  def test_timing_safe_eq
    res = post("/timing_eq", '{"a":"hello","b":"hello"}')
    assert_equal "yes", res.body.strip
    res = post("/timing_eq", '{"a":"hello","b":"world"}')
    assert_equal "no", res.body.strip
    res = post("/timing_eq", '{"a":"hello","b":"hi"}')
    assert_equal "no", res.body.strip
  end

  # Interop: the canonical CRuby `jwt` gem must be able to verify
  # tokens we issue. Skipped if the gem isn't installed locally.
  def test_interop_with_jwt_gem
    begin
      require "jwt"
    rescue LoadError
      skip "jwt gem not installed locally"
    end
    token = issue("alice")
    payload, header = JWT.decode(token, "supersecret", true, { algorithm: "HS256" })
    assert_equal "alice", payload["sub"]
    assert_equal "HS256", header["alg"]
    assert_equal "JWT",   header["typ"]
  end
end
