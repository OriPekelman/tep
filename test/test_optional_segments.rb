require_relative "helper"

# Sinatra's `(/:foo)` optional path segments. The translator expands
# to multiple registrations sharing the same handler class.
class TestOptionalSegments < TepTest
  app_source <<~RB
    require 'sinatra'

    get '/say(/:greeting)' do
      g = params[:greeting]
      g.length > 0 ? "say " + g : "default greeting"
    end

    get '/items(/:id)(/:section)' do
      "id=" + params[:id] + " section=" + params[:section]
    end
  RB

  def test_optional_present
    res = get("/say/hi")
    assert_equal "200", res.code
    assert_equal "say hi", res.body
  end

  def test_optional_absent
    res = get("/say")
    assert_equal "200", res.code
    assert_equal "default greeting", res.body
  end

  def test_two_optionals_both_present
    res = get("/items/42/header")
    assert_equal "id=42 section=header", res.body
  end

  def test_two_optionals_first_only
    res = get("/items/42")
    assert_equal "id=42 section=", res.body
  end

  def test_two_optionals_neither
    res = get("/items")
    assert_equal "id= section=", res.body
  end
end
