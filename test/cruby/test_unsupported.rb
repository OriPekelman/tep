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

  # `@ivar` template locals are now supported -- see test_erb_ivars.rb.

  # send_file, configure, pass, multiple filters, optional segments
  # have all moved into supported and have their own test files.

  # ---- strict-by-default translator (mirror condition 3) ----
  # Out-of-contract constructs must FAIL the build, not silently
  # drop (docs/mirrors/sinatra.md). These assert at translate level,
  # so no spinel compile is needed. `--lax` restores warn-and-continue.

  def translate_out(source, flags: "")
    tmp = Dir.mktmpdir("tep-strict")
    src = File.join(tmp, "app.rb")
    File.write(src, "require 'sinatra'\n" + source + "\nget('/') { 'ok' }\n")
    out = `#{TepHarness::TEP_BIN} translate #{flags} #{src} 2>&1 >/dev/null`
    [$?.success?, out]
  ensure
    FileUtils.remove_entry(tmp) if tmp
  end

  def assert_strict_refusal(source, message_fragment)
    ok, out = translate_out(source)
    refute ok, "expected strict translate to fail, but it succeeded"
    assert_match(/error: .*#{Regexp.escape(message_fragment)}/, out)
    assert_match(/--lax/, out, "refusal should mention the --lax escape hatch")
  end

  def test_strict_rejects_rack_use
    assert_strict_refusal(%(use Rack::Session::Cookie, secret: "x"),
                          "unsupported `use`")
  end

  def test_strict_rejects_helpers_block
    assert_strict_refusal(%(helpers do\n  def shout(s); s.upcase; end\nend),
                          "unsupported `helpers do ... end`")
  end

  def test_strict_rejects_unknown_set_key
    assert_strict_refusal(%(set :sessions, true), "unsupported `set :sessions`")
  end

  def test_strict_rejects_on_stop
    assert_strict_refusal(%(on_stop do\n  puts "bye"\nend), "on_stop")
  end

  def test_lax_downgrades_to_warning
    ok, out = translate_out("use Rack::Head", flags: "--lax")
    assert ok, "expected --lax translate to succeed, got:\n#{out}"
    assert_match(/unsupported `use`/, out)
    refute_match(/error:/, out)
  end
end
