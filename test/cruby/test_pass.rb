require_relative "helper"

# `pass` skips to the next matching route. Sinatra raises
# Sinatra::Pass internally; tep just sets a flag and the dispatcher
# walks to the next match.
class TestPass < TepTest
  app_source <<~RB
    require 'sinatra'

    # First definition wins, but it can pass for `/admin/special`.
    get '/admin/:section' do
      pass if params[:section] == "special"
      "default admin: " + params[:section]
    end

    get '/admin/special' do
      "special admin handler"
    end

    # If every match passes, default 404 fires.
    get '/skip' do
      pass
    end
  RB

  def test_pass_falls_through_to_next_match
    res = get("/admin/special")
    assert_equal "200", res.code
    assert_equal "special admin handler", res.body
  end

  def test_no_pass_returns_first_match
    res = get("/admin/users")
    assert_equal "200", res.code
    assert_equal "default admin: users", res.body
  end

  def test_pass_with_no_more_matches_404s
    res = get("/skip")
    assert_equal "404", res.code
  end
end
