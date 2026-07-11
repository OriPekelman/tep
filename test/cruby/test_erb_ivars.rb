require_relative "helper"

# Sinatra-style `@ivar` template locals: a handler (or `before`
# filter) sets `@name = ...`, and the template reads it via
# `<%= @name %>`. The translator stores ivars on a per-request bag
# (req.ivars) and threads it as a second arg to `tep_view_<name>`.
class TestErbIvars < TepTest
  app_source <<~RB
    require 'sinatra'

    set :views, '#{File.expand_path("views", __dir__)}'

    before do
      @greeting = "filter-said-hi"
    end

    get '/greet/:who/:n' do
      @name  = params[:who]
      @count = params[:n]
      erb :greet
    end

    get '/mixed/:who' do
      @name = params[:who]
      erb :mixed, locals: { greeting: "from-explicit-locals" }
    end
  RB

  def test_ivar_threading
    res = get("/greet/alice/1")
    assert_equal "200", res.code
    assert_match(/hi, alice!/, res.body)
    assert_match(/visited 1 times/, res.body)
    assert_match(/welcome\./, res.body)
  end

  def test_ivar_int_to_s_coercion
    # @count = params[:n] writes a string already, but the rewriter's
    # `.to_s` wrap means the same code would still work if @count
    # held a literal integer (which the template's <%= ... %> renders
    # back to a string).
    res = get("/greet/bob/3")
    assert_equal "200", res.code
    assert_match(/visited 3 times/, res.body)
    refute_match(/welcome\./, res.body)  # only renders for count == "1"
  end

  def test_locals_and_ivars_coexist
    res = get("/mixed/charlie")
    assert_equal "200", res.code
    assert_match(/hello, charlie/, res.body)
    assert_match(/locals greeting: from-explicit-locals/, res.body)
    # The before-filter set @greeting; the explicit `locals: {...}`
    # call doesn't shadow it because they're separate hashes in the
    # template signature.
    assert_match(/ivar greeting: filter-said-hi/, res.body)
  end
end
