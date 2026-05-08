require_relative "helper"

# Features Sinatra has and tep doesn't yet. Tests that have moved
# into the supported column live in their own file (test_cookies.rb,
# test_sessions.rb, test_streaming.rb, test_regex_routes.rb,
# test_modular.rb, test_erb.rb).
class TestUnsupported < TepTest
  app_source <<~RB
    get '/' do
      "tep skip stub"
    end
  RB

  def test_haml_templates
    skip "Haml -- depends on a gem; out of scope for spinel-AOT"
  end

  def test_helpers_block
    skip "`helpers do ... end` -- closures not first-class in spinel; would need translator support to define methods on Tep::Handler"
  end

  def test_send_file_helper
    skip "`send_file 'path'` from inside a handler not yet wired (Tep does static-dir serving, not arbitrary send_file)"
  end

  def test_optional_segments
    skip "Optional path segments (`get '/say(/:greeting)'`) -- Mustermann syntax not implemented (regex routes work as a workaround)"
  end

  def test_multiple_filters
    skip "Multiple before/after filters chained -- Tep has single-slot filters; user composes by subclassing"
  end

  def test_request_object_methods
    skip "Full Sinatra request object (Rack::Request methods like .ip, .scheme, .ssl?) -- Tep::Request is a thin subset"
  end

  def test_configure_block
    skip "`configure { ... }` and `configure :production { ... }` -- environment switching not implemented"
  end

  def test_per_request_locals_with_ivars
    skip "ERB locals via `@ivar` style -- v0.1 only supports the explicit `locals: {...}` hash form"
  end
end
