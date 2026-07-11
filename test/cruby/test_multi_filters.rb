require_relative "helper"

# Multiple `before do` / `after do` blocks should all run, in order.
class TestMultiFilters < TepTest
  app_source <<~RB
    require 'sinatra'

    before do
      response.headers["X-First"] = "1"
    end

    before do
      response.headers["X-Second"] = "2"
    end

    after do
      response.headers["X-After-A"] = "a"
    end

    after do
      response.headers["X-After-B"] = "b"
    end

    get '/' do
      "ok"
    end
  RB

  def test_both_before_filters_run
    res = get("/")
    assert_equal "1", res["x-first"]
    assert_equal "2", res["x-second"]
  end

  def test_both_after_filters_run
    res = get("/")
    assert_equal "a", res["x-after-a"]
    assert_equal "b", res["x-after-b"]
  end
end
