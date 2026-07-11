require_relative "helper"

# Static file serving + custom 404 handler.
class TestStatic < TepTest
  app_source <<~RB
    set :public_dir, '#{File.expand_path("../../public", __dir__)}'

    not_found do
      "tep-404 " + request.path
    end

    get '/' do
      "root"
    end
  RB

  def test_static_text_file
    res = get("/hello.txt")
    assert_equal "200", res.code
    assert_match(/text\/plain/, res["content-type"])
    assert_match(/static file serving/, res.body)
  end

  def test_static_css
    res = get("/style.css")
    assert_equal "200", res.code
    assert_equal "text/css", res["content-type"]
  end

  def test_static_x_tep_marker
    res = get("/hello.txt")
    assert_equal "1", res["x-tep-static"]
  end

  def test_404_for_unknown_path
    res = get("/no-such-file.txt")
    assert_equal "404", res.code
  end

  def test_custom_404_body
    res = get("/no-such-file.txt")
    assert_match(/tep-404/, res.body)
    assert_match(%r{/no-such-file\.txt}, res.body)
  end

  def test_path_traversal_rejected
    res = get("/../etc/passwd")
    assert_equal "404", res.code
    refute_match(/root:/, res.body)
  end

  def test_get_route_still_wins_over_static
    res = get("/")
    assert_equal "200", res.code
    assert_equal "root", res.body
  end
end
