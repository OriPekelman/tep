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

    # A worker that yields N times, recording each tick on a class-
    # level log. Class-level mutation through @@cvar is what tep apps
    # use for cross-handler shared state (sessions/handles flow
    # through APP, but a tiny in-process log is fine here).
    class TickLog
      @@entries = [""]
      @@entries.delete_at(0)
      def self.add(s); @@entries.push(s); 0; end
      def self.dump
        out = ""
        i = 0
        while i < @@entries.length
          if i > 0
            out = out + ","
          end
          out = out + @@entries[i]
          i += 1
        end
        out
      end
      def self.clear
        while @@entries.length > 0
          @@entries.delete_at(0)
        end
        0
      end
    end

    class Worker
      attr_accessor :name, :remaining
      def initialize(n, count)
        @name = n
        @remaining = count
      end
      def run
        while @remaining > 0
          TickLog.add(@name + @remaining.to_s)
          @remaining -= 1
          Fiber.yield
        end
      end
    end

    get '/cooperate' do
      TickLog.clear
      Tep::Scheduler.clear
      w1 = Worker.new("A", 3)
      w2 = Worker.new("B", 2)
      Tep::Scheduler.spawn_fiber(Fiber.new { w1.run })
      Tep::Scheduler.spawn_fiber(Fiber.new { w2.run })
      n = Tep::Scheduler.run_until_empty
      "loops=" + n.to_s + " log=" + TickLog.dump
    end

    get '/alive' do
      Tep::Scheduler.clear
      Tep::Scheduler.alive_count.to_s + "->" + (
        Tep::Scheduler.spawn_fiber(Fiber.new { Tep.seed_fiber_noop }); ""
      ) + Tep::Scheduler.alive_count.to_s
    end
  RB

  def test_two_fibers_drain_in_order
    res = get("/cooperate")
    assert_equal "200", res.code
    # Both workers ran to completion. With no per-tick sleep, the
    # scheduler picks the soonest-ready fiber; since wake_at is
    # immediate (-1) for both, the tie-breaker (index order) drains
    # the first-spawned fiber first, then the second.
    body = res.body
    assert_match(/loops=5/, body)
    assert_match(/A3.*A2.*A1.*B2.*B1/, body)
  end

  def test_alive_count_changes_as_fibers_spawn
    res = get("/alive")
    assert_equal "200", res.code
    assert_equal "0->1", res.body.strip
  end
end
