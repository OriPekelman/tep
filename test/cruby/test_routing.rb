require_relative "helper"

# Routing checklist: verbs, path params, query, splat, 404, method
# mismatch. Mirrors the surface in Sinatra's routing_test.rb that
# matches our v0.1 scope.
class TestRouting < TepTest
  app_source <<~RB
    get '/' do
      "root"
    end

    get '/hi/:name' do
      "hi, " + params[:name]
    end

    get '/users/:id/posts/:post_id' do
      "user " + params[:id] + " post " + params[:post_id]
    end

    get '/search' do
      params[:q] + "/" + params[:page]
    end

    get '/files/*' do
      "splat"
    end

    post '/echo' do
      params[:msg]
    end

    put '/widgets/:id' do
      "put " + params[:id]
    end

    patch '/widgets/:id' do
      "patch " + params[:id]
    end

    delete '/widgets/:id' do
      "delete " + params[:id]
    end
  RB

  def test_root
    res = get("/")
    assert_equal "200", res.code
    assert_equal "root", res.body
  end

  def test_path_param
    res = get("/hi/world")
    assert_equal "200", res.code
    assert_equal "hi, world", res.body
  end

  def test_two_path_params
    res = get("/users/42/posts/7")
    assert_equal "200", res.code
    assert_equal "user 42 post 7", res.body
  end

  def test_query_string
    res = get("/search?q=ruby&page=2")
    assert_equal "200", res.code
    assert_equal "ruby/2", res.body
  end

  def test_splat
    res = get("/files/anything")
    assert_equal "200", res.code
    assert_equal "splat", res.body
  end

  def test_post_form
    res = post("/echo", "msg=hello",
               "Content-Type" => "application/x-www-form-urlencoded")
    assert_equal "200", res.code
    assert_equal "hello", res.body
  end

  def test_put
    res = put("/widgets/1")
    assert_equal "200", res.code
    assert_equal "put 1", res.body
  end

  def test_patch
    res = patch("/widgets/1")
    assert_equal "200", res.code
    assert_equal "patch 1", res.body
  end

  def test_delete
    res = delete("/widgets/1")
    assert_equal "200", res.code
    assert_equal "delete 1", res.body
  end

  def test_404_unknown_path
    res = get("/nowhere")
    assert_equal "404", res.code
  end

  def test_404_method_mismatch
    res = post("/", "")
    assert_equal "404", res.code
  end
end
