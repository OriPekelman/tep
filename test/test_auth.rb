require_relative "helper"

# Tep::Auth + Tep::AuthBearerToken: end-to-end JWT bearer-token
# auth flow. Boots a tep app that installs the auth filter, mints
# tokens via Tep::Jwt at request time, and exercises req.identity
# from handler bodies.
class TestAuth < TepTest
  app_source <<~RB
    require 'sinatra'

    SECRET = "test-shared-secret-do-not-use-in-prod"

    Tep::AuthBearerToken.set_secret(SECRET)
    Tep::Auth.install!

    # ---- mint endpoints (test harness uses these to get tokens) ----
    # The payload is SpinelKit::Json-friendly flat JSON: sub, exp, caps
    # (comma-separated), and optionally delegate (pipe-encoded).

    post '/mint_human' do
      res.headers["Content-Type"] = "text/plain"
      sub = SpinelKit::Json.get_str(req.raw_body, "sub")
      caps = SpinelKit::Json.get_str(req.raw_body, "caps")
      exp = Time.now.to_i + 600
      payload = "{" +
        SpinelKit::Json.encode_pair_str("sub", sub) + "," +
        SpinelKit::Json.encode_pair_int("exp", exp) + "," +
        SpinelKit::Json.encode_pair_str("caps", caps) +
      "}"
      Tep::Jwt.encode_hs256(payload, SECRET)
    end

    post '/mint_agent' do
      res.headers["Content-Type"] = "text/plain"
      sub = SpinelKit::Json.get_str(req.raw_body, "sub")
      caps = SpinelKit::Json.get_str(req.raw_body, "caps")
      delegate = SpinelKit::Json.get_str(req.raw_body, "delegate")
      exp = Time.now.to_i + 600
      payload = "{" +
        SpinelKit::Json.encode_pair_str("sub", sub) + "," +
        SpinelKit::Json.encode_pair_int("exp", exp) + "," +
        SpinelKit::Json.encode_pair_str("caps", caps) + "," +
        SpinelKit::Json.encode_pair_str("delegate", delegate) +
      "}"
      Tep::Jwt.encode_hs256(payload, SECRET)
    end

    post '/mint_expired' do
      res.headers["Content-Type"] = "text/plain"
      sub = SpinelKit::Json.get_str(req.raw_body, "sub")
      # Issued in the past, expired in the past.
      exp = Time.now.to_i - 60
      payload = "{" +
        SpinelKit::Json.encode_pair_str("sub", sub) + "," +
        SpinelKit::Json.encode_pair_int("exp", exp) + "," +
        SpinelKit::Json.encode_pair_str("caps", "read") +
      "}"
      Tep::Jwt.encode_hs256(payload, SECRET)
    end

    # ---- identity-introspection endpoints ----
    # Every route below reads req.identity (populated by the
    # auth-filter before this handler runs).

    before do
      res.headers["Content-Type"] = "text/plain"
    end

    get '/whoami' do
      req.identity.subject
    end

    get '/is_human' do
      req.identity.human? ? "yes" : "no"
    end

    get '/is_agent' do
      req.identity.agent? ? "yes" : "no"
    end

    get '/may_read' do
      req.identity.may?(:read) ? "yes" : "no"
    end

    get '/may_write' do
      req.identity.may?(:write) ? "yes" : "no"
    end

    get '/may_post_summary' do
      req.identity.may?(:post_summary) ? "yes" : "no"
    end

    get '/agent_id' do
      if req.identity.acting_via == nil
        ""
      else
        req.identity.acting_via.agent_id
      end
    end
  RB

  # ---- helper: mint a token, then call a route with it as Bearer ----

  def mint_human(sub, caps)
    body = "{" +
      "\"sub\":\"" + sub + "\"," +
      "\"caps\":\"" + caps + "\"}"
    post("/mint_human", body).body
  end

  def mint_agent(sub, caps, delegate)
    body = "{" +
      "\"sub\":\"" + sub + "\"," +
      "\"caps\":\"" + caps + "\"," +
      "\"delegate\":\"" + delegate + "\"}"
    post("/mint_agent", body).body
  end

  def mint_expired(sub)
    body = "{\"sub\":\"" + sub + "\"}"
    post("/mint_expired", body).body
  end

  def authed(path, token)
    get(path, "Authorization" => "Bearer " + token)
  end

  # ---- anonymous (no Authorization header) ----

  def test_anonymous_subject
    assert_equal "user:", get("/whoami").body
  end

  def test_anonymous_has_no_caps
    assert_equal "no", get("/may_read").body
  end

  # ---- valid human token ----

  def test_human_subject_via_bearer
    token = mint_human("user:42", "read,write")
    assert_equal "user:user:42", authed("/whoami", token).body
  end

  def test_human_marked_human
    token = mint_human("user:42", "read")
    assert_equal "yes", authed("/is_human", token).body
  end

  def test_human_not_agent
    token = mint_human("user:42", "read")
    assert_equal "no", authed("/is_agent", token).body
  end

  def test_human_granted_caps
    token = mint_human("user:42", "read,write")
    assert_equal "yes", authed("/may_read", token).body
    assert_equal "yes", authed("/may_write", token).body
  end

  def test_human_lacks_ungranted_cap
    token = mint_human("user:42", "read")
    assert_equal "no", authed("/may_write", token).body
  end

  # ---- valid agent token ----

  def test_agent_subject_format
    token = mint_agent(
      "user:42", "read",
      "summarizer-bot|1000|9999999999|token")
    assert_equal "agent:summarizer-bot/user:42",
      authed("/whoami", token).body
  end

  def test_agent_marked_agent
    token = mint_agent(
      "user:42", "read",
      "summarizer-bot|1000|9999999999|token")
    assert_equal "yes", authed("/is_agent", token).body
  end

  def test_agent_id_exposed
    token = mint_agent(
      "user:42", "read",
      "summarizer-bot|1000|9999999999|token")
    assert_equal "summarizer-bot", authed("/agent_id", token).body
  end

  def test_agent_caps_subset_of_principal
    # Principal would have :read + :write; this token grants :read only.
    # Auth doesn't enforce subset -- issuer does -- but tests that
    # whatever the token carries flows through.
    token = mint_agent(
      "user:42", "read",
      "summarizer-bot|1000|9999999999|token")
    assert_equal "yes", authed("/may_read", token).body
    assert_equal "no",  authed("/may_write", token).body
  end

  # ---- token rejections ----

  def test_expired_token_falls_back_to_anonymous
    token = mint_expired("user:42")
    assert_equal "user:", authed("/whoami", token).body
  end

  def test_bad_signature_falls_back_to_anonymous
    token = mint_human("user:42", "read")
    tampered = token + "x"
    assert_equal "user:", authed("/whoami", tampered).body
  end

  def test_malformed_bearer_header_falls_back_to_anonymous
    # No "Bearer " prefix.
    res = get("/whoami", "Authorization" => "Basic abcdef")
    assert_equal "user:", res.body
  end

  def test_missing_authorization_falls_back_to_anonymous
    assert_equal "user:", get("/whoami").body
  end
end
