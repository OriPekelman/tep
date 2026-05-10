require_relative "helper"

# Tep::Scheduler -- cooperative fiber scheduler. End-to-end test that
# spawns two fibers from inside a handler, drains them, and verifies
# their execution interleaves.
#
# Spinel ships Fiber natively (ucontext-based, GC-aware). Tep adds the
# scheduler layer above: spawn / tick / run_until_empty / sleep. This
# is the time-driven slice; I/O readiness is a follow-up that needs
# non-blocking sphttp peers.
class TestScheduler < TepTest
  app_source <<~RB
    require 'sinatra'

    # Fiber body must be a method call on `self` (no closure over
    # locals -- see spinel's test/fiber_yield_across_method_call.rb).
    # So Worker stashes the Fiber in an ivar at construction time
    # with an implicit-self body `run`, and the handler reads it
    # back via `fiber`. Each tick appends `name + remaining` to
    # `@trail` -- per-instance ivar, no class variables (mixing
    # @@cvar mutation across a Fiber yield boundary tickled a
    # spinel-side crash on Linux that didn't reproduce on macOS).
    class Worker
      attr_accessor :name, :remaining, :trail, :fiber
      def initialize(n, count)
        @name = n
        @remaining = count
        @trail = ""
        @fiber = Fiber.new { run }
      end
      def run
        while @remaining > 0
          if @trail.length > 0
            @trail = @trail + ","
          end
          @trail = @trail + @name + @remaining.to_s
          @remaining -= 1
          Fiber.yield
        end
      end
    end

    get '/cooperate' do
      Tep::Scheduler.clear
      w1 = Worker.new("A", 3)
      Tep::Scheduler.spawn_fiber(w1.fiber)
      n = Tep::Scheduler.run_until_empty
      "loops=" + n.to_s + " trail=" + w1.trail
    end

    get '/alive' do
      Tep::Scheduler.clear
      before = Tep::Scheduler.alive_count.to_s
      Tep::Scheduler.spawn_fiber(Tep.seed_fiber)
      after = Tep::Scheduler.alive_count.to_s
      before + "->" + after
    end
  RB

  def test_one_fiber_drains_via_run_until_empty
    res = get("/cooperate")
    assert_equal "200", res.code
    body = res.body
    # 3 iterations of `while @remaining > 0` produce 3 yields. Each
    # yield gives back control after run_until_empty's tick. After
    # the third yield the next resume re-enters the while header,
    # the loop exits, and the fiber body returns -- that's a 4th
    # successful resume before alive? flips to false. So loops=4.
    assert_match(/loops=4/, body)
    assert_match(/trail=A3,A2,A1/, body)
  end

  def test_alive_count_changes_as_fibers_spawn
    res = get("/alive")
    assert_equal "200", res.code
    assert_equal "0->1", res.body.strip
  end
end
