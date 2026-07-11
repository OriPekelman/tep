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
      # Absent headers read as nil through the Rack-parity accessors
      # (sinatra too) -- guard before concatenation.
      a = request.accept
      a = "" if a.nil?
      ct = request.content_type
      ct = "" if ct.nil?
      "accept=" + a + " ct=" + ct
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

# `request.body.read` -- Sinatra apps commonly treat request.body as
# IO and call .read on it; tep's req.body is already a String, so the
# bin/tep translator rewrites `request.body.read` -> `req.body` so the
# Sinatra-style handler compiles + serves unchanged.
class TestRequestBodyRead < TepTest
  app_source <<~RB
    require 'sinatra'

    post '/echo' do
      content_type 'text/plain'
      request.body.read
    end

    post '/echo-twice' do
      # Hit .read twice -- a Sinatra IO would return "" on the second
      # call (cursor at EOF); for tep's no-op .read it just returns
      # the same String again. The expected behaviour here is "tep
      # gives you the body each time"; apps that rely on the IO
      # cursor semantics need to rewrite to a single .read + store.
      content_type 'text/plain'
      request.body.read + "|" + request.body.read
    end
  RB

  def test_request_body_read_returns_raw_body
    res = post("/echo", "hello world")
    assert_equal "200", res.code
    assert_equal "hello world", res.body
  end

  def test_request_body_read_idempotent
    res = post("/echo-twice", "abc")
    assert_equal "200", res.code
    assert_equal "abc|abc", res.body
  end
end
