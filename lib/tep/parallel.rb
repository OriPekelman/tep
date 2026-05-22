# Tep::Parallel -- grosser/parallel-shaped process fan-out.
#
# Why
# ---
# Spinel doesn't ship Ractors, doesn't expose the GVL'd threading
# story, and the `parallel` gem (heavy use of `Marshal`,
# `IO.pipe`, dynamic `Proc` invocation) doesn't lower. Fork is
# however a perfectly cheap C call here, so the smallest useful
# slice of `parallel` -- "run this worker over a list of items,
# one child per item, collect the results" -- is implementable
# directly on top of sphttp's `sphttp_fork` + a tiny file-based
# IPC channel.
#
# API
# ---
#   results = Tep::Parallel.map_processes(items, worker)
#   #=> [String, String, ...]   -- one entry per input, in order
#
# `worker.run(item)` must return a String. Each child runs the
# worker once, writes its return value to a per-index file under
# /tmp, exits; the parent reaps everyone and reads the files
# back. The String constraint exists because passing structured
# data across fork would need Marshal, which spinel doesn't
# emit -- and HTTP-shaped APIs (the dashboard) round-trip
# strings naturally.
#
# Fire-and-forget shape:
#
#   Tep::Parallel.each_process(items, worker)
#
# Forks one child per item, doesn't capture results.
#
# Scope (v1)
# ----------
#   * One child per item -- no fixed-size pool. Fine up to a few
#     dozen items; for larger fan-outs the caller should chunk
#     beforehand or write the round-trip into Tep::Job.
#   * String return values only.
#   * No thread mode -- spinel doesn't lower MRI's Thread reliably.
#
# Closeness to grosser/parallel
# -----------------------------
# `parallel`'s top-level API is
#
#   Parallel.map(items, in_processes: N) { |x| ... }
#
# spinel can't take a block as a value, so we lift the body into
# a Worker class instead. Spinel also can't auto-cast subclass
# pointers at cmeth call sites (#429-shaped), which means cmeth
# args typed as a worker base class widen to poly at the call
# site and the C compile fails. The fix: store the worker in an
# instance field of `Tep::Parallel` -- typed-slot imeth dispatch
# works the same way `@before_filter.before(req, res)` does for
# `Tep::Filter`. Resulting shape:
#
#   p = Tep::Parallel.new(MyWorker.new)
#   results = p.map_processes(items)
#
# Worker base class
# -----------------
# Real workers subclass `Tep::ParallelWorker` and override `run(item)`.
# Two spinel landings made this name viable: matz/spinel#531 (270eceb)
# narrowed the poly-receiver dispatch table by ivar observed-class set
# (so `Tep::Server#run` no longer leaks into `@worker.run`'s switch),
# and matz/spinel#549 (1d561ad) collapsed the dispatch result to a
# scalar when all reachable arms agree on the return type (so the
# result lands as `const char *` instead of sp_RbVal).
module Tep
  # Base class for Tep::Parallel workers. Override `run(item)` in
  # subclasses; the default emits "" so a base-class instance used
  # for seeding stays type-safe.
  class ParallelWorker
    def run(item)
      ""
    end
  end

  class Parallel
    attr_accessor :worker

    def initialize(worker)
      @worker = worker
    end

    # Result-collecting fan-out. Returns an Array of Strings in
    # input order; one fork per item. See module doc for the
    # constraints (Strings only, no fixed pool).
    def map_processes(items)
      job_dir = Parallel.scratch_dir
      Tep::Shell.run("mkdir -p " + job_dir)

      n = items.length
      i = 0
      while i < n
        # Pull each fork into its own stack frame -- spinel's
        # codegen for the in-line fork-and-exec pattern was
        # observed to share locals across the parent loop and
        # the child body, so all children ended up processing
        # the same (last) item. Method-call boundary gives each
        # child a clean local snapshot.
        spawn_one(items[i], i, job_dir)
        i += 1
      end

      reaped = 0
      while reaped < n
        Sock.sphttp_wait_any
        reaped += 1
      end

      out = [""]
      out.delete_at(0)
      k = 0
      while k < n
        out.push(Tep::Shell.read(job_dir + "/" + k.to_s))
        k += 1
      end
      Tep::Shell.run("rm -rf " + job_dir)
      out
    end

    # Fork one child to process `item`. When `job_dir` is non-empty,
    # the child writes the worker's String result to `job_dir/idx`
    # (consumed by map_processes); otherwise the result is discarded
    # (fire-and-forget shape used by each_process). Returns the child
    # pid in the parent; the child never returns (exits when done).
    #
    # The method-call boundary is load-bearing: an inline fork-and-
    # exec loop body shared locals across iterations under spinel's
    # codegen, so every child processed the same (last) item. A
    # separate def gives each fork a clean local frame.
    def spawn_one(item, idx, job_dir)
      pid = Sock.sphttp_fork
      if pid == 0
        result = @worker.run(item)
        if job_dir.length > 0
          path = job_dir + "/" + idx.to_s
          File.write(path, result)
        end
        Sock.sphttp_exit(0)
      end
      pid
    end

    # Fire-and-forget version. Returns 0 once every child exits.
    def each_process(items)
      n = items.length
      i = 0
      while i < n
        spawn_one(items[i], 0, "")
        i += 1
      end
      reaped = 0
      while reaped < n
        Sock.sphttp_wait_any
        reaped += 1
      end
      0
    end

    # Per-invocation scratch directory. Uses pid + monotonic
    # timestamp so concurrent map_processes calls in different
    # workers don't trample each other.
    def self.scratch_dir
      "/tmp/tep_par_" + Sock.sphttp_getpid.to_s + "_" + Time.now.to_i.to_s
    end
  end
end
