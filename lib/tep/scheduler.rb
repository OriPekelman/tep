# Tep::Scheduler -- a tiny fiber-based cooperative scheduler.
#
# Spinel ships Fiber today (ucontext-based, GC-aware, ivars persist
# across yields). What was missing was the layer above: a way to run
# multiple cooperating fibers within a single worker process so a
# long-running response (SSE stream, long-poll, slow batch) doesn't
# pin the worker for the whole connection lifetime.
#
# This v1 covers the **time-driven** case: register a fiber to be
# resumed at-or-after `wake_at`, the scheduler picks the next ready
# one and resumes it. Fibers cooperate by calling
# `Tep::Scheduler.sleep(seconds)` (which yields under the hood)
# instead of POSIX `sleep`.
#
# Storage shape
# -------------
# Two parallel arrays on the Tep::APP singleton: `sched_fibers`
# (Fiber instances) + `sched_wake_at` (Unix-second timestamps;
# -1 means "ready immediately"). Spinel handles same-shaped
# typed arrays cleanly; using a single array of structs would
# force a poly_array. Same App-instance pattern as Tep::Assets.
#
# What it doesn't do (yet)
# ------------------------
# **I/O readiness.** A real fiber scheduler hooks into accept /
# read / write so a fiber blocked on a socket only resumes once the
# fd is ready. That needs non-blocking-aware sphttp primitives
# (e.g. `sphttp_select_read(fd, timeout_ms)`); the worker loop
# would interleave it with `Scheduler.tick`.
#
# **Implicit yield on blocking calls.** Ruby 3.0's
# `Fiber::SchedulerInterface` makes every blocking I/O auto-yield
# to a registered scheduler. Spinel doesn't recognise that hook;
# we yield explicitly via `Tep::Scheduler.sleep`.
module Tep
  class Scheduler
    def self.spawn_fiber(f)
      Tep::APP.sched_fibers.push(Tep::FiberSlot.new(f))
      Tep::APP.sched_wake_at.push(-1)
      f
    end

    # Resume the fiber whose wake_at is soonest-due (and <= now).
    # Returns true if it resumed something, false if everything is
    # either done or waiting for the future.
    def self.tick
      now  = Time.now.to_i
      best = -1
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? && Tep::APP.sched_wake_at[i] <= now
          if best < 0 || Tep::APP.sched_wake_at[i] < Tep::APP.sched_wake_at[best]
            best = i
          end
        end
        i += 1
      end
      if best < 0
        return false
      end
      Tep::APP.sched_current = best
      Tep::APP.sched_wake_at[best] = -1
      Tep::APP.sched_fibers[best].f.resume
      Tep::APP.sched_current = -1
      true
    end

    # Drain. Resumes everything ready until the schedulable set
    # is empty (every fiber finished or all are waiting for a
    # future wake_at). Returns the number of resumes performed.
    def self.run_until_empty
      n = 0
      while Scheduler.tick
        n += 1
      end
      n
    end

    # Drain until `seconds` has elapsed OR every fiber's done.
    # Sleeps a small amount between ticks if no fibers are due
    # right now, so a fiber waiting for `wake_at = now + 5`
    # doesn't spin the CPU while waiting.
    def self.run_for(seconds)
      deadline = Time.now.to_i + seconds
      while Time.now.to_i < deadline
        if !Scheduler.tick
          # Nothing ready; wait until the next-due fiber's
          # wake_at, capped at the overall deadline.
          next_at = Scheduler.next_wake
          if next_at < 0
            return 0
          end
          gap = next_at - Time.now.to_i
          if gap < 1
            gap = 1
          end
          if Time.now.to_i + gap > deadline
            gap = deadline - Time.now.to_i
          end
          if gap > 0
            sleep gap
          end
        end
      end
      0
    end

    def self.next_wake
      best = -1
      i = 0
      n = Tep::APP.sched_fibers.length
      while i < n
        if Tep::APP.sched_fibers[i].f.alive?
          if best < 0 || Tep::APP.sched_wake_at[i] < Tep::APP.sched_wake_at[best]
            best = i
          end
        end
        i += 1
      end
      if best < 0
        return -1
      end
      Tep::APP.sched_wake_at[best]
    end

    # Called from within a fiber's body to suspend until at-or-
    # after `seconds` from now.
    def self.sleep(seconds)
      idx = Tep::APP.sched_current
      if idx < 0
        # Called from outside any fiber -- fall back to POSIX sleep.
        Kernel.sleep(seconds)
        return 0
      end
      Tep::APP.sched_wake_at[idx] = Time.now.to_i + seconds
      Fiber.yield
      0
    end

    # Reset the schedulable set. Useful between worker-loop
    # iterations or between tests.
    def self.clear
      while Tep::APP.sched_fibers.length > 0
        Tep::APP.sched_fibers.delete_at(0)
        Tep::APP.sched_wake_at.delete_at(0)
      end
      0
    end

    def self.alive_count
      n = 0
      i = 0
      total = Tep::APP.sched_fibers.length
      while i < total
        if Tep::APP.sched_fibers[i].f.alive?
          n += 1
        end
        i += 1
      end
      n
    end
  end
end
