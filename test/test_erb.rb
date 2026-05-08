require_relative "helper"

class TestErb < TepTest
  app_source <<~RB
    require 'sinatra'

    set :views, '#{File.expand_path("views", __dir__)}'

    get '/hello/:who' do
      erb :hello, locals: { name: params[:who], mood: "happy" }
    end

    get '/sober/:who' do
      erb :hello, locals: { name: params[:who], mood: "neutral" }
    end

    get '/list/:n' do
      erb :list, locals: { count: params[:n] }
    end

    get '/no-locals' do
      erb :hello
    end
  RB

  def test_simple_interpolation
    res = get("/hello/world")
    assert_equal "200", res.code
    assert_match(/hello, world!/, res.body)
  end

  def test_conditional_block
    happy = get("/hello/world")
    assert_match(/cheerful/, happy.body)
    sober = get("/sober/world")
    refute_match(/cheerful/, sober.body)
  end

  def test_loop_block
    res = get("/list/3")
    assert_equal "200", res.code
    assert_match(/<li>item 0</, res.body)
    assert_match(/<li>item 1</, res.body)
    assert_match(/<li>item 2</, res.body)
    refute_match(/<li>item 3</, res.body)
  end

  def test_no_locals_renders_empty_for_missing_keys
    res = get("/no-locals")
    assert_equal "200", res.code
    assert_match(/hello, !/, res.body)
  end
end
