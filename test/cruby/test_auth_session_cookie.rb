require_relative "helper"

# Tep::AuthSessionCookie: signed-session-cookie auth provider.
# Round-trip an Identity via the tep.session cookie + verify it's
# read back through req.identity on the next request.
class TestAuthSessionCookie < TepTest
  app_source <<~RB
    require 'sinatra'

    Tep.session_secret = "test-session-secret-do-not-use-in-prod"
    Tep::Auth.install!

    # ---- write paths: the test harness calls these to seed a
    # session cookie. POST body is irrelevant; the route hardcodes
    # the identity it sets so the test can predict the readback.

    before do
      res.headers["Content-Type"] = "text/plain"
    end

    post '/login_human' do
      caps = [:read, :write]
      ident = Tep::Identity.new("user:42", nil, caps)
      Tep::AuthSessionCookie.set(req, ident, 0)
      "ok"
    end

    post '/login_human_with_exp' do
      # Expiry 600s in the future -- valid for the immediate readback.
      caps = [:read]
      ident = Tep::Identity.new("user:42", nil, caps)
      Tep::AuthSessionCookie.set(req, ident, Time.now.to_i + 600)
      "ok"
    end

    post '/login_human_expired' do
      # Expiry 60s in the PAST -- readback rejects.
      caps = [:read]
      ident = Tep::Identity.new("user:42", nil, caps)
      Tep::AuthSessionCookie.set(req, ident, Time.now.to_i - 60)
      "ok"
    end

    post '/login_agent' do
      caps = [:read]
      delegation = Tep::AgentDelegation.new(
        "summarizer-bot", 1000, 9999999999, :token)
      ident = Tep::Identity.new("user:42", delegation, caps)
      Tep::AuthSessionCookie.set(req, ident, 0)
      "ok"
    end

    post '/logout' do
      Tep::AuthSessionCookie.clear(req)
      "ok"
    end

    # ---- read paths ----

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

    get '/agent_id' do
      if req.identity.acting_via == nil
        ""
      else
        req.identity.acting_via.agent_id
      end
    end
  RB

  # Pull the tep.session cookie out of a Set-Cookie header and
  # return the "tep.session=..." string suitable for a Cookie:
  # request header.
  def session_cookie_from(res)
    raw = res["set-cookie"]
    return nil if raw.nil? || raw.empty?
    pair = raw.split(";").first
    pair.strip
  end

  # POST to a login route, then GET `path` with the resulting
  # session cookie. Returns the GET response.
  def with_session_from(login_path, path)
    login_res = post(login_path)
    cookie = session_cookie_from(login_res)
    assert cookie, "expected tep.session cookie in #{login_path} response, got: #{login_res['set-cookie'].inspect}"
    get(path, "Cookie" => cookie)
  end

  # ---- anonymous (no session cookie at all) ----

  def test_anonymous_when_no_cookie
    assert_equal "user:", get("/whoami").body
  end

  def test_anonymous_has_no_caps
    assert_equal "no", get("/may_read").body
  end

  # ---- human identity round-trips through the session ----

  def test_human_subject_round_trips
    res = with_session_from("/login_human", "/whoami")
    assert_equal "user:user:42", res.body
  end

  def test_human_marked_human
    res = with_session_from("/login_human", "/is_human")
    assert_equal "yes", res.body
  end

  def test_human_caps_round_trip
    res = with_session_from("/login_human", "/may_read")
    assert_equal "yes", res.body
    res = with_session_from("/login_human", "/may_write")
    assert_equal "yes", res.body
  end

  # ---- agent identity round-trips ----

  def test_agent_subject_round_trips
    res = with_session_from("/login_agent", "/whoami")
    assert_equal "agent:summarizer-bot/user:42", res.body
  end

  def test_agent_marked_agent
    res = with_session_from("/login_agent", "/is_agent")
    assert_equal "yes", res.body
  end

  def test_agent_id_round_trips
    res = with_session_from("/login_agent", "/agent_id")
    assert_equal "summarizer-bot", res.body
  end

  # ---- expiry ----

  def test_valid_exp_still_works
    res = with_session_from("/login_human_with_exp", "/whoami")
    assert_equal "user:user:42", res.body
  end

  def test_expired_identity_falls_back_to_anonymous
    res = with_session_from("/login_human_expired", "/whoami")
    assert_equal "user:", res.body
  end

  # ---- logout ----

  def test_logout_clears_identity
    # Step 1: log in
    login_res = post("/login_human")
    logged_in_cookie = session_cookie_from(login_res)

    # Step 2: verify identity is set
    res = get("/whoami", "Cookie" => logged_in_cookie)
    assert_equal "user:user:42", res.body

    # Step 3: logout (server clears the identity_* keys; the response
    # re-signs the cleared cookie and returns it).
    logout_res = post("/logout", "", "Cookie" => logged_in_cookie)
    logged_out_cookie = session_cookie_from(logout_res)

    # Step 4: subsequent request with the post-logout cookie sees
    # anonymous.
    res = get("/whoami", "Cookie" => logged_out_cookie)
    assert_equal "user:", res.body
  end

  # ---- tampering ----

  def test_tampered_cookie_falls_back_to_anonymous
    login_res = post("/login_human")
    cookie = session_cookie_from(login_res)
    # Mangle the signature half (everything after the last dot).
    tampered = cookie.sub(/\.[^.]+\z/, ".aaaaaaaa")
    res = get("/whoami", "Cookie" => tampered)
    assert_equal "user:", res.body
  end
end
