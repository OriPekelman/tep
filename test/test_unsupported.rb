require_relative "helper"

# Features Sinatra has and tep v0.1 doesn't. Each is a `skip` until
# implemented, with a TODO that names the feature and how it'd land.
# Running these alongside the supported tests gives us an accurate
# compat dashboard.
class TestUnsupported < TepTest
  # We don't even boot a server here; these are spec stubs.
  app_source <<~RB
    get '/' do
      "tep skip stub"
    end
  RB

  def test_erb_templates
    skip "ERB not wired (spinel ships erb.rb; needs `erb :name` translator support)"
  end

  def test_haml_templates
    skip "Haml -- depends on a gem; out of scope for spinel-AOT"
  end

  def test_helpers_block
    skip "`helpers do ... end` -- closures not first-class in spinel; would need translator support to define methods on Tep::Handler"
  end

  def test_sessions
    skip "Sessions: cookies + signed/encrypted store not yet implemented"
  end

  def test_cookies
    skip "Cookies: Set-Cookie writer + parser not yet implemented"
  end

  def test_modular_app
    skip "`Sinatra::Base` modular subclasses -- v0.1 only handles top-level classic style"
  end

  def test_streaming
    skip "`stream do |out| ... end` -- chunked Transfer-Encoding not implemented"
  end

  def test_send_file_helper
    skip "`send_file 'path'` from inside a handler not yet wired (Tep does static-dir serving, not arbitrary send_file)"
  end

  def test_regex_routes
    skip "Regex routes (`get %r{/posts/(\\d+)}`) -- Tep router only does literal segments + `:` captures + `*` splat"
  end

  def test_optional_segments
    skip "Optional path segments (`get '/say(/:greeting)'`) -- Mustermann syntax not implemented"
  end

  def test_multiple_filters
    skip "Multiple before/after filters chained -- Tep has single-slot filters; user composes by subclassing"
  end

  def test_pass_to_next_route
    skip "`pass` -- skipping to next matching route not implemented"
  end

  def test_request_object_methods
    skip "Full Sinatra request object (Rack::Request methods like .ip, .scheme, .ssl?) -- Tep::Request is a thin subset"
  end

  def test_set_view_path
    skip "View paths (`set :views, ...`) -- depends on template engine support"
  end

  def test_configure_block
    skip "`configure { ... }` and `configure :production { ... }` -- environment switching not implemented"
  end
end
