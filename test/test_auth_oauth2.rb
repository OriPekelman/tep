require_relative "helper"

# Tep::AuthOAuth2: OAuth2-style authorization-code issuance. tep
# acts as the authorization server -- registers bot clients, issues
# short-lived codes after consent, exchanges codes for JWTs. The
# downstream identity surface is the same as direct bearer-token
# auth: the resulting JWT carries `delegate` and BearerToken parses
# it into a delegated Tep::Identity.
class TestAuthOAuth2 < TepTest
  app_source <<~RB
    require 'sinatra'

    SECRET = "test-oauth2-shared-secret"
    Tep::AuthBearerToken.set_secret(SECRET)
    Tep::Auth.install!

    # Register one bot client at boot.
    Tep::AuthOAuth2.register_client(
      "summarizer-bot",
      "Summarizer Bot",
      "https://bot.example/oauth/callback",
      [:read, :post_summary])

    before do
      res.headers["Content-Type"] = "text/plain"
    end

    # ---- consent endpoint: caller passes the principal + granted
    # caps; app's real implementation would render a consent UI +
    # only reach here on user-approve. The test stub skips the UI.

    post '/consent' do
      principal_id = Tep::Json.get_str(req.raw_body, "principal_id")
      client_id    = Tep::Json.get_str(req.raw_body, "client_id")
      caps_str     = Tep::Json.get_str(req.raw_body, "caps")
      Tep::AuthOAuth2.issue_code(principal_id, client_id, caps_str, 0)
    end

    # ---- token-exchange endpoint: bot redeems code for JWT.

    post '/token' do
      code      = Tep::Json.get_str(req.raw_body, "code")
      client_id = Tep::Json.get_str(req.raw_body, "client_id")
      Tep::AuthOAuth2.exchange_code(code, client_id, 0)
    end

    # ---- client lookup (sanity check the registry).

    get '/client/:id' do
      c = Tep::AuthOAuth2.find_client(params[:id])
      if c == nil
        "missing"
      else
        c.name + "|" + c.redirect_uri
      end
    end

    # ---- identity-introspection endpoints (mirrors test_auth).

    get '/whoami' do
      req.identity.subject
    end

    get '/is_agent' do
      req.identity.agent? ? "yes" : "no"
    end

    get '/agent_id' do
      if req.identity.acting_via == nil
        ""
      else
        req.identity.acting_via.agent_id
      end
    end

    get '/origin' do
      if req.identity.acting_via == nil
        ""
      else
        req.identity.acting_via.origin.to_s
      end
    end

    get '/may_read' do
      req.identity.may?(:read) ? "yes" : "no"
    end

    get '/may_post_summary' do
      req.identity.may?(:post_summary) ? "yes" : "no"
    end

    get '/may_write' do
      req.identity.may?(:write) ? "yes" : "no"
    end
  RB

  # ---- helpers ----

  def consent_body(principal_id, client_id, caps)
    "{" +
      "\"principal_id\":\"" + principal_id + "\"," +
      "\"client_id\":\"" + client_id + "\"," +
      "\"caps\":\"" + caps + "\"}"
  end

  def token_body(code, client_id)
    "{\"code\":\"" + code + "\",\"client_id\":\"" + client_id + "\"}"
  end

  def consent(principal_id, client_id, caps)
    post("/consent", consent_body(principal_id, client_id, caps)).body
  end

  def exchange(code, client_id)
    post("/token", token_body(code, client_id)).body
  end

  def authed(path, token)
    get(path, "Authorization" => "Bearer " + token)
  end

  # ---- client registry ----

  def test_registered_client_lookup
    assert_equal "Summarizer Bot|https://bot.example/oauth/callback",
      get("/client/summarizer-bot").body
  end

  def test_unregistered_client_lookup
    assert_equal "missing", get("/client/never-registered").body
  end

  # ---- happy path: issue + exchange ----

  def test_issue_code_returns_nonempty
    code = consent("user:42", "summarizer-bot", "read")
    refute_equal "", code
    # base64url, 24 random bytes -> ~32 chars
    assert code.length >= 28, "code too short: #{code.inspect}"
  end

  def test_exchange_code_returns_jwt
    code = consent("user:42", "summarizer-bot", "read,post_summary")
    token = exchange(code, "summarizer-bot")
    refute_equal "", token
    # JWT shape: three dot-separated segments.
    assert_equal 2, token.count("."), "token: #{token.inspect}"
  end

  def test_exchanged_jwt_authenticates_as_agent
    code = consent("user:42", "summarizer-bot", "read,post_summary")
    token = exchange(code, "summarizer-bot")
    assert_equal "agent:summarizer-bot/user:42",
      authed("/whoami", token).body
  end

  def test_exchanged_jwt_marked_agent
    code = consent("user:42", "summarizer-bot", "read")
    token = exchange(code, "summarizer-bot")
    assert_equal "yes", authed("/is_agent", token).body
  end

  def test_exchanged_jwt_carries_agent_id
    code = consent("user:42", "summarizer-bot", "read")
    token = exchange(code, "summarizer-bot")
    assert_equal "summarizer-bot", authed("/agent_id", token).body
  end

  def test_exchanged_jwt_origin_is_oauth_grant
    code = consent("user:42", "summarizer-bot", "read")
    token = exchange(code, "summarizer-bot")
    assert_equal "oauth_grant", authed("/origin", token).body
  end

  def test_exchanged_jwt_caps_granted
    code = consent("user:42", "summarizer-bot", "read,post_summary")
    token = exchange(code, "summarizer-bot")
    assert_equal "yes", authed("/may_read", token).body
    assert_equal "yes", authed("/may_post_summary", token).body
  end

  def test_exchanged_jwt_caps_not_in_grant_are_rejected
    # User granted only :read. The JWT should NOT carry :write.
    code = consent("user:42", "summarizer-bot", "read")
    token = exchange(code, "summarizer-bot")
    assert_equal "no", authed("/may_write", token).body
  end

  # ---- rejections ----

  def test_exchange_unknown_code_returns_empty
    assert_equal "", exchange("never-issued-code", "summarizer-bot")
  end

  def test_exchange_wrong_client_id_returns_empty
    code = consent("user:42", "summarizer-bot", "read")
    # Try to redeem against a different client_id.
    assert_equal "", exchange(code, "different-bot")
  end

  def test_exchange_is_single_use
    code = consent("user:42", "summarizer-bot", "read")
    # First exchange succeeds.
    refute_equal "", exchange(code, "summarizer-bot")
    # Second exchange of the same code fails.
    assert_equal "", exchange(code, "summarizer-bot")
  end
end
