require_relative "helper"

# Tep's Mustache subset (build-time AOT). Documented surface:
# `{{var}}` (escaped), `{{{var}}}` / `{{& var}}` (raw),
# `{{@ivar}}` (escaped or raw via triple-stache), `{{!comment}}`
# (dropped). Sections / partials / delimiter swaps are deliberately
# unsupported and the compiler raises at build time if reached.
class TestMustache < TepTest
  app_source <<~RB
    require 'sinatra'

    set :views, '#{File.expand_path("views", __dir__)}'

    get '/m/simple/:who' do
      mustache :m_simple, locals: { name: params[:who], greeting: "hi", snippet: "<b>BOLD</b>" }
    end

    before do
      @raw = "<i>I</i>"
    end

    get '/m/ivars/:who/:n' do
      @name  = params[:who]
      @count = params[:n]
      mustache :m_ivars
    end
  RB

  def test_simple_escaped_and_raw
    res = get("/m/simple/alice")
    assert_equal "200", res.code
    assert_match(/hello, alice!/, res.body)
    assert_match(/greeting: hi/, res.body)
    # `{{{snippet}}}` (raw) keeps the live tag.
    assert_match(/<p>raw html: <b>BOLD<\/b><\/p>/, res.body)
    # comment line is dropped
    refute_match(/this comment is dropped/, res.body)
  end

  def test_html_escape_dangerous_chars
    # `<` and `>` need URL-encoding to even reach the server. The
    # escaped `{{name}}` form must then render `&lt;script&gt;`,
    # not the live tag.
    res = get("/m/simple/%3Cscript%3E")
    assert_match(/hello, &lt;script&gt;!/, res.body)
    refute_match(/hello, <script>/, res.body)
  end

  def test_ivar_via_at_prefix
    res = get("/m/ivars/bob/4")
    assert_equal "200", res.code
    assert_match(/hi, bob/, res.body)
    assert_match(/visited: 4/, res.body)
    # `{{{@raw}}}` (raw ivar) keeps the `<i>I</i>` literal
    assert_match(/raw ivar: <i>I<\/i>/, res.body)
  end
end
