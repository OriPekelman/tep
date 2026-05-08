require_relative "helper"

# Features Sinatra has and tep doesn't yet. Tests that have moved
# into the supported column live in their own file (test_cookies.rb,
# test_sessions.rb, test_streaming.rb, test_regex_routes.rb,
# test_modular.rb, test_erb.rb, test_misc_v02.rb, test_pass.rb,
# test_multi_filters.rb, test_optional_segments.rb,
# test_request_methods.rb).
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

  def test_request_ip
    skip "request.ip / request.remote_ip -- needs an sphttp_accept_with_peer C helper. Other Rack::Request methods (host, user_agent, scheme, ssl?, etc.) are supported -- see test_request_methods.rb."
  end

  def test_per_request_locals_with_ivars
    skip "ERB locals via `@ivar` style (Sinatra default) -- tep ERB only supports the explicit `locals: {...}` hash form"
  end

  # send_file, configure, pass, multiple filters, optional segments
  # have all moved into supported and have their own test files.
end
