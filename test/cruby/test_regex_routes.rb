require_relative "helper"

class TestRegexRoutes < TepTest
  app_source <<~'RB'
    require 'sinatra'

    get %r{^/posts/(\d+)$} do
      "post id=" + params["1"]
    end

    get %r{^/users/([a-z]+)/posts/(\d+)$} do
      "user=" + params["1"] + " post=" + params["2"]
    end

    get '/literal/path' do
      "literal wins"
    end

    # Regex that overlaps with the literal -- literal must take
    # precedence (we register it after, but match() tries all literal
    # routes before any regex one).
    get %r{^/literal/.+$} do
      "regex fallback"
    end
  RB

  def test_single_capture
    res = get("/posts/42")
    assert_equal "200", res.code
    assert_equal "post id=42", res.body
  end

  def test_two_captures
    res = get("/users/alice/posts/7")
    assert_equal "user=alice post=7", res.body
  end

  def test_no_match_falls_through_to_404
    res = get("/posts/abc")
    assert_equal "404", res.code
  end

  def test_literal_route_beats_regex
    res = get("/literal/path")
    assert_equal "literal wins", res.body
  end

  def test_regex_falls_through_when_literal_misses
    res = get("/literal/elsewhere")
    assert_equal "regex fallback", res.body
  end
end
