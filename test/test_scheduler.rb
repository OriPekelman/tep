require_relative "helper"

# Tep::Scheduler -- cooperative fiber scheduler. End-to-end tests
# covering both parking modes:
#
#   * Time-driven (run_until_empty / Fiber.yield)
#   * I/O-driven (io_wait + poll(2)) -- a fiber parks on a listening
#     socket, the handler issues an outbound connect against itself
#     (sphttp_connect) to make the listener readable, the scheduler's
#     next tick picks up the readiness and resumes the fiber.
class TestScheduler < TepTest
  # Upstream still has issues: matz/spinel#641 (per-fiber GC root)
  # is now merged, but the prefork handler in /cooperate still
  # SIGSEGVs on the Tep::Scheduler.clear + spawn_fiber +
  # run_until_empty path. Likely a separate spinel issue worth
  # filing once we have a smaller standalone repro; for now the
  # class stays skipped so the suite's signal stays useful.
  def setup
    skip "blocked on a separate spinel issue (#641 merged but " \
         "Tep::Scheduler primitives still SIGSEGV in prefork handlers)"
    super
  end

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

    # Park a fiber on a listening socket via io_wait. From outside the
    # fiber the handler kicks an outbound TCP connect against the same
    # listener -- now `lfd` is read-ready (pending accept), the next
    # tick's poll(2) round sees POLLIN, and resumes the fiber with
    # the ready bits.
    class IoWorker
      attr_accessor :result, :lfd, :timeout, :fiber
      def initialize(lfd, timeout)
        @lfd = lfd
        @timeout = timeout
        @result = -1
        @fiber = Fiber.new { run }
      end
      def run
        @result = Tep::Scheduler.io_wait(@lfd, Tep::Scheduler::READ, @timeout)
      end
    end

    get '/io_wait_ready' do
      Tep::Scheduler.clear
      lfd = Sock.sphttp_listen(15999, 0)
      w = IoWorker.new(lfd, 3)
      Tep::Scheduler.spawn_fiber(w.fiber)
      cfd = Sock.sphttp_connect("127.0.0.1", 15999)
      Tep::Scheduler.run_for(3)
      Sock.sphttp_close(cfd)
      Sock.sphttp_close(lfd)
      "result=" + w.result.to_s + " cfd=" + (cfd > 0 ? "ok" : "fail")
    end

    get '/io_wait_timeout' do
      Tep::Scheduler.clear
      lfd = Sock.sphttp_listen(15998, 0)
      t0 = Time.now.to_i
      w = IoWorker.new(lfd, 1)
      Tep::Scheduler.spawn_fiber(w.fiber)
      Tep::Scheduler.run_for(2)
      elapsed = Time.now.to_i - t0
      Sock.sphttp_close(lfd)
      "result=" + w.result.to_s + " elapsed=" + elapsed.to_s
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

  def test_io_wait_resumes_when_socket_becomes_readable
    res = get("/io_wait_ready")
    assert_equal "200", res.code
    # READ bit is 1; the connect made the listener accept-ready, so
    # the fiber should resume with result=1. cfd should be a real fd
    # (> 0); if connect failed we'd see cfd=fail.
    assert_match(/result=1/, res.body)
    assert_match(/cfd=ok/,   res.body)
  end

  def test_io_wait_returns_zero_on_timeout
    res = get("/io_wait_timeout")
    assert_equal "200", res.code
    # No connect happens, so the listener never becomes readable.
    # After ~1s the timeout fires and io_wait returns 0.
    assert_match(/result=0/, res.body)
    # 1s timeout, run_for cap 2s, allow either 1 or 2 elapsed seconds
    # (poll wake-up + clock granularity).
    assert_match(/elapsed=[12]/, res.body)
  end
end
