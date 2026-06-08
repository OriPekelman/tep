require_relative "helper"

# Tep::Password -- PBKDF2-SHA256 password hashing.
class TestPassword < TepTest
  app_source <<~RB
    require 'sinatra'

    post '/hash' do
      res.headers["Content-Type"] = "text/plain"
      pwd = SpinelKit::Json.get_str(req.raw_body, "password")
      Tep::Password.hash(pwd)
    end

    post '/verify' do
      res.headers["Content-Type"] = "text/plain"
      pwd = SpinelKit::Json.get_str(req.raw_body, "password")
      hash = SpinelKit::Json.get_str(req.raw_body, "hash")
      Tep::Password.verify(pwd, hash) ? "ok" : "bad"
    end

    post '/split' do
      res.headers["Content-Type"] = "text/plain"
      parts = Tep::Password.split4(req.raw_body)
      parts[0] + "|" + parts[1] + "|" + parts[2] + "|" + parts[3]
    end

    post '/random' do
      res.headers["Content-Type"] = "text/plain"
      Crypto.sp_crypto_random_b64url(16)
    end
  RB

  def issue_hash(pwd)
    post("/hash", %({"password":"#{pwd}"})).body.strip
  end

  def verify_pwd(pwd, hash)
    body = '{"password":"' + pwd + '","hash":"' + hash + '"}'
    post("/verify", body).body.strip
  end

  def test_hash_format
    h = issue_hash("hunter2")
    # pbkdf2-sha256$<iters>$<salt>$<derived>
    parts = h.split("$")
    assert_equal 4, parts.length
    assert_equal "pbkdf2-sha256", parts[0]
    assert_equal "200000", parts[1]
    assert parts[2].length > 0, "salt should be non-empty"
    assert parts[3].length > 0, "derived should be non-empty"
  end

  def test_verify_good_password
    h = issue_hash("hunter2")
    assert_equal "ok", verify_pwd("hunter2", h)
  end

  def test_verify_wrong_password
    h = issue_hash("hunter2")
    assert_equal "bad", verify_pwd("not-the-password", h)
  end

  def test_random_salt_per_hash
    h1 = issue_hash("same-password")
    h2 = issue_hash("same-password")
    refute_equal h1, h2, "two hashes of the same password should differ (random salt)"
    # but BOTH must verify
    assert_equal "ok", verify_pwd("same-password", h1)
    assert_equal "ok", verify_pwd("same-password", h2)
  end

  def test_malformed_hash_returns_bad
    assert_equal "bad", verify_pwd("anything", "not-a-real-hash")
    assert_equal "bad", verify_pwd("anything", "pbkdf2-sha256$bad")
    assert_equal "bad", verify_pwd("anything", "")
  end

  def test_random_b64url_distinct
    r1 = post("/random", "").body.strip
    r2 = post("/random", "").body.strip
    refute_equal r1, r2
    # 16 bytes -> 22 b64url chars (no padding).
    assert_equal 22, r1.length
  end

  def test_split4_basic
    res = post("/split", "a$b$c$d")
    assert_equal "a|b|c|d", res.body.strip
  end

  def test_split4_with_empty_segments
    res = post("/split", "$$c$d")
    assert_equal "||c|d", res.body.strip
  end

  def test_split4_short_input
    # Fewer than 3 separators -- trailing slots stay "".
    res = post("/split", "x$y")
    assert_equal "x|y||", res.body.strip
  end
end
