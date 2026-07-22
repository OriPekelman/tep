require_relative "helper"

# Tep::Security::Cors + Tep::Security::Headers -- before / after
# filter classes that wire into Tep.before / Tep.after.
class TestSecurity < TepTest
  app_source <<~RB
    require 'sinatra'

    CORS = Tep::Security::Cors.new
    CORS.set_origin("https://app.example.com")
    CORS.set_allowed_verbs("GET,POST,DELETE,OPTIONS")
    CORS.set_allowed_headers("Content-Type,X-Custom")
    CORS.set_max_age(7200)
    Tep.before CORS

    HEADERS = Tep::Security::Headers.new
    HEADERS.set_hsts(31536000)   # 1 year
    Tep.after HEADERS

    get '/' do
      "ok"
    end

    # Route that pre-sets X-Frame-Options before the Headers
    # after-filter runs -- verifies the filter's
    # `unless res.headers.key?` guard preserves handler-set values.
    get '/custom_frame' do
      res.headers["X-Frame-Options"] = "DENY"
      "ok"
    end
  RB

  def test_cors_origin_on_get
    res = get("/")
    assert_equal "200", res.code
    assert_equal "https://app.example.com", res["Access-Control-Allow-Origin"]
    assert_equal "Origin",                  res["Vary"]
  end

  def test_cors_preflight_returns_204
    res = req(:options, "/", nil, {})
    assert_equal "204",                            res.code
    assert_equal "GET,POST,DELETE,OPTIONS",        res["Access-Control-Allow-Methods"]
    assert_equal "Content-Type,X-Custom",          res["Access-Control-Allow-Headers"]
    assert_equal "7200",                           res["Access-Control-Max-Age"]
    assert_equal "https://app.example.com",        res["Access-Control-Allow-Origin"]
  end

  def test_default_secure_headers_on_response
    res = get("/")
    assert_equal "nosniff",                          res["X-Content-Type-Options"]
    assert_equal "SAMEORIGIN",                       res["X-Frame-Options"]
    assert_equal "strict-origin-when-cross-origin", res["Referrer-Policy"]
    assert_equal "0",                                res["X-XSS-Protection"]
  end

  def test_hsts_when_configured
    res = get("/")
    assert_match(/max-age=31536000/, res["Strict-Transport-Security"])
    assert_match(/includeSubDomains/, res["Strict-Transport-Security"])
  end

  def test_handler_set_header_survives_after_filter
    # The Headers after-filter only sets each header when not already
    # present (`unless res.headers.key?`). /custom_frame pre-sets
    # X-Frame-Options to DENY; the filter must not overwrite it back
    # to SAMEORIGIN.
    res = get("/custom_frame")
    assert_equal "200", res.code
    assert_equal "DENY", res["X-Frame-Options"]
  end
end
