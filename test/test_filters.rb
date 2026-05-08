require_relative "helper"

# before / after filters. The translator wraps blocks into Tep::Filter
# subclasses; spinel restricts a single filter slot per kind, so
# multi-filter chaining is composed by the user, not registered N
# times.
class TestFilters < TepTest
  app_source <<~RB
    before do
      response.headers["X-Before"] = "1"
    end

    after do
      response.headers["X-After"] = "2"
    end

    get '/' do
      "ok"
    end

    get '/echo-before' do
      response.headers["X-Before"]
    end
  RB

  def test_before_runs
    res = get("/")
    assert_equal "1", res["x-before"]
  end

  def test_after_runs
    res = get("/")
    assert_equal "2", res["x-after"]
  end

  def test_before_runs_before_handler
    # The handler can read the X-Before header that the before filter set.
    res = get("/echo-before")
    assert_equal "1", res.body
  end
end
