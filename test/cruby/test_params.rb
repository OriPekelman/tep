require_relative "helper"

# Sinatra-style params: path captures, query string, form body merging.
class TestParams < TepTest
  app_source <<~RB
    get '/path/:a/:b' do
      "" + params[:a] + "/" + params[:b]
    end

    get '/q' do
      "" + params[:foo]
    end

    get '/multi' do
      "" + params[:a] + "+" + params[:b]
    end

    post '/form' do
      "" + params[:name] + "=" + params[:age]
    end

    post '/multipart' do
      "" + params[:name] + "=" + params[:age]
    end

    get '/encoded/:name' do
      "" + params[:name]
    end

    get '/missing' do
      v = params[:nope]
      v.length.to_s + ":" + v
    end

    get '/q-and-path/:id' do
      "" + params[:id] + "+" + params[:tag]
    end
  RB

  def test_path_capture_two
    res = get("/path/foo/bar")
    assert_equal "foo/bar", res.body
  end

  def test_query_single
    res = get("/q?foo=hello")
    assert_equal "hello", res.body
  end

  def test_query_multiple
    res = get("/multi?a=1&b=2")
    assert_equal "1+2", res.body
  end

  def test_form_body
    res = post("/form", "name=alice&age=30",
               "Content-Type" => "application/x-www-form-urlencoded")
    assert_equal "alice=30", res.body
  end

  def test_multipart_body
    # Browsers send multipart/form-data for any form using FormData
    # or carrying a file input. The text fields land in req.params;
    # file-upload parts are skipped in v1.
    bnd  = "----TepTestBoundary"
    body = "--#{bnd}\r\n" \
           "Content-Disposition: form-data; name=\"name\"\r\n" \
           "\r\n" \
           "alice\r\n" \
           "--#{bnd}\r\n" \
           "Content-Disposition: form-data; name=\"age\"\r\n" \
           "\r\n" \
           "30\r\n" \
           "--#{bnd}--\r\n"
    res = post("/multipart", body,
               "Content-Type" => "multipart/form-data; boundary=#{bnd}")
    assert_equal "alice=30", res.body
  end

  def test_url_encoded_path
    res = get("/encoded/hello%20world")
    assert_equal "hello world", res.body
  end

  def test_url_encoded_plus
    res = get("/q?foo=hello+world")
    assert_equal "hello world", res.body
  end

  def test_missing_param_is_empty_string
    res = get("/missing")
    assert_equal "0:", res.body
  end

  def test_query_overlays_path
    res = get("/q-and-path/42?tag=ruby")
    assert_equal "42+ruby", res.body
  end
end
