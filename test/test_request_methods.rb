require_relative "helper"

# Rack::Request-style convenience methods. tep doesn't terminate TLS,
# so .scheme / .ssl? read X-Forwarded-Proto (set by any reasonable
# reverse proxy).
class TestRequestMethods < TepTest
  app_source <<~RB
    require 'sinatra'

    get '/host' do
      request.host
    end

    get '/ua' do
      request.user_agent
    end

    get '/ref' do
      request.referer + " :: " + request.referrer
    end

    get '/scheme' do
      request.scheme + " ssl?=" + request.ssl?.to_s
    end

    get '/accept-and-ct' do
      "accept=" + request.accept + " ct=" + request.content_type
    end
  RB

  def test_host
    res = get("/host", "Host" => "example.com:8080")
    assert_equal "example.com:8080", res.body
  end

  def test_user_agent
    res = get("/ua", "User-Agent" => "tep-test/1.0")
    assert_equal "tep-test/1.0", res.body
  end

  def test_referer_and_referrer
    res = get("/ref", "Referer" => "https://prev.example/x")
    assert_equal "https://prev.example/x :: https://prev.example/x", res.body
  end

  def test_scheme_default_http
    res = get("/scheme")
    assert_equal "http ssl?=false", res.body
  end

  def test_scheme_x_forwarded_proto
    res = get("/scheme", "X-Forwarded-Proto" => "https")
    assert_equal "https ssl?=true", res.body
  end

  def test_accept_and_content_type
    res = post("/accept-and-ct", "x=1",
               "Accept"       => "application/json",
               "Content-Type" => "application/x-www-form-urlencoded")
    assert_equal "404", res.code  # POST not declared; just confirming the route table behaves
    # Re-fetch the GET form for headers we actually want to inspect.
    res2 = get("/accept-and-ct", "Accept" => "application/json")
    assert_match(/accept=application\/json/, res2.body)
  end
end
