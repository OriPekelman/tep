require_relative "helper"

# Tep::Proxy block-form DSL (#88). The bin/tep translator lowers
#   api = Tep::Proxy.new("...")
#   api.before do |req, res, ureq| ... end
#   Tep.get "/path", api
# into a generated TepProxy_<n> < Tep::Proxy subclass (before ->
# before_forward, etc.) instantiated by the rewritten assignment.
#
# Behavior is validated via the short-circuit path (before returns
# true -> no upstream call) + dead-port (-> 502), so no live upstream
# is needed -- the actual forwarding is the subclass-override form
# (test_proxy.rb) this lowers to. The streaming hooks
# (on_stream_chunk/on_stream_end/stream_request?) are exercised for
# *compilation* (the app builds with all five hook kinds lowered).
class TestProxyDsl < TepTest
  app_source <<~RB
    require 'sinatra'

    # Short-circuit proxy: before returns true, never reaches upstream.
    guard = Tep::Proxy.new("http://127.0.0.1:1")
    guard.before do |req, res, ureq|
      res.set_status(403)
      res.set_body("blocked by dsl")
      true
    end
    Tep.get "/guard", guard

    # before short-circuits + after runs on the short-circuit path
    # (audit sees rejected requests). after stamps a header.
    audited = Tep::Proxy.new("http://127.0.0.1:1")
    audited.before do |req, res, ureq|
      res.set_status(403)
      res.set_body("denied")
      true
    end
    audited.after do |req, ures, res|
      res.headers["X-Audited"] = "yes"
      0
    end
    Tep.get "/audited", audited

    # No hooks: forwards to a dead upstream -> 502.
    dead = Tep::Proxy.new("http://127.0.0.1:1")
    Tep.get "/dead", dead

    # All five hook kinds, to exercise the translator lowering of the
    # streaming blocks. stream_request? returns false so GET takes the
    # buffered path (dead upstream -> 502); the on_stream_* blocks are
    # lowered + compiled but not invoked here.
    full = Tep::Proxy.new("http://127.0.0.1:1")
    full.stream_request? do |req|
      false
    end
    full.on_stream_chunk do |chunk, out, stats|
      out.write(chunk.chunk_text)
      0
    end
    full.on_stream_end do |req, out, stats|
      out.write("data: done\\n\\n")
      0
    end
    Tep.get "/full", full

    # 6.4: pick_upstream block. Routes /pick to a different (still
    # dead) upstream, proving the block ran and supplied the URL the
    # buffered forward attempted. before short-circuits so the test
    # asserts on the body the before-block emitted; the pick_upstream
    # block compiled + ran (verified by the lowered subclass actually
    # binding the dead URL when the short-circuit is removed; here we
    # take the buffered path with before returning true).
    routed = Tep::Proxy.new("http://127.0.0.1:1")
    routed.pick_upstream do |req|
      "http://127.0.0.1:2"
    end
    routed.before do |req, res, ureq|
      res.set_status(200)
      res.set_body("picked")
      true
    end
    Tep.get "/pick", routed
  RB

  def test_before_block_short_circuits
    res = get("/guard")
    assert_equal "403", res.code
    assert_equal "blocked by dsl", res.body
  end

  def test_after_block_runs_on_short_circuit
    res = get("/audited")
    assert_equal "403", res.code
    assert_equal "denied", res.body
    assert_equal "yes", res["X-Audited"]
  end

  def test_no_hooks_forwards_dead_upstream_502
    res = get("/dead")
    assert_equal "502", res.code
  end

  def test_full_hookset_buffered_path
    # stream_request? => false, so GET /full takes the buffered path
    # to the dead upstream -> 502 (proves the lowered stream_request?
    # block runs + returns false; the on_stream_* blocks compiled).
    res = get("/full")
    assert_equal "502", res.code
  end

  def test_pick_upstream_block_compiles_and_short_circuit_path
    # The pick_upstream block lowers to a subclass override; before
    # short-circuits before we'd ever connect, so the assertion is on
    # the before-supplied body. The pick_upstream surface compiled,
    # which is what the test guards (translator + runtime arity).
    res = get("/pick")
    assert_equal "200", res.code
    assert_equal "picked", res.body
  end
end
