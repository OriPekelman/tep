require_relative "helper"

# send_file, configure, and __END__ inline templates -- the three small
# wins added on top of the v0.2 surface.
class TestMiscV02 < TepTest
  app_source <<~RB
    require 'sinatra'

    configure do
      $configured = "always"
    end

    configure :production do
      $configured = "prod"
    end

    get '/configured' do
      "configured=" + ($configured || "nil").to_s
    end

    get '/file' do
      send_file 'public/hello.txt'
    end

    get '/inline' do
      erb :inline_hi, locals: { who: "world" }
    end

    __END__

    @@ inline_hi
    <h1>hi <%= locals["who"] %> from inline</h1>
  RB

  def test_configure_always_runs
    res = get("/configured")
    # Both the bare and :production blocks ran in dev env: "always" set first,
    # then "prod" only if env=production. Default env is development, so the
    # :production block is gated off and the value stays "always".
    assert_equal "configured=always", res.body
  end

  def test_send_file_streams_static
    res = get("/file")
    assert_equal "200", res.code
    assert_match(/static file serving works/, res.body)
  end

  def test_inline_template_renders
    res = get("/inline")
    assert_equal "200", res.code
    assert_match(%r{hi world from inline}, res.body)
  end
end
