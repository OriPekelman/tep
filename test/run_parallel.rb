#!/usr/bin/env ruby
# run_parallel.rb -- run each test/test_*.rb in its own process, in
# parallel, and aggregate the per-file summaries into one overall line.
#
# Why this exists: `make test` (test/run_all.rb) is serial and runs in
# one process because the per-class boot harness expects one thread
# touching state at a time. The wall time is dominated by ~54 test
# classes each doing a `bin/tep build` (~12 s of spinel codegen per
# class) sequentially -- around 11 min of pure compilation on the gx10.
# Separate processes sidestep the threading constraint cleanly: each
# worker runs one test file (its own minitest), with its own port base,
# so N classes compile + run concurrently.
#
#   make test-parallel
#   TEP_TEST_PROCS=8 make test-parallel    # cap concurrency (default: Etc.nprocessors)
#
# Output: one tick (`✓` / `✗`) per test file with a per-file run/assertion
# tally, full output dumped for failing files, then one aggregate
# summary line. Exit 0 iff every file passed.
require "etc"
require "shellwords"

ROOT  = File.expand_path("..", __dir__)
TESTS = Dir[File.join(ROOT, "test", "test_*.rb")].sort
# Default below core count: each worker's Spinel compile is CPU-bound, and the
# booted test servers + their HTTP clients also need cycles -- saturating every
# core just trades compile parallelism for boot-timeout/build-kill flakes (the
# build retry absorbs those, but at the cost of a re-compile). ~60% of cores is
# the sweet spot here (12 on a 20-core box: 0F/0E, ~7.6min vs ~30min serial).
PROCS = (ENV["TEP_TEST_PROCS"] || [Etc.nprocessors * 3 / 5, 2].max.to_s).to_i

# Each test class boots its own app on a port = PORT_BASE_START + idx*STEP
# (+1 per extra class in the file). Files have at most ~9 classes, so STEP=50
# is ample disjoint headroom per file. With 64 files the window spans
# 10000..13200 -- chosen to sit BELOW the OS ephemeral range
# (/proc/sys/net/ipv4/ip_local_port_range, 32768+ here): a server bound in the
# ephemeral range collides with another test's *outbound* HTTP client source
# port (EADDRINUSE bind failures). It's also clear of the legacy 4900 base.
#
# Cross-run safety (a server can outlive its worker -- tep #188 leaks one under
# load, and tep binds prefork listeners SO_REUSEPORT, so a surviving orphan on
# a reused port would be silently shared / connected-to instead of this run's
# server -> cross-talk) is handled by SIGKILL reaping (reap_tep_test_procs),
# up-front and at end, not by moving the window: SIGKILL can't be ignored, so
# the prior run's orphans are gone before this run binds.
PORT_BASE_STEP  = 50
PORT_BASE_START = (ENV["TEP_TEST_PORT_BASE"] || "10000").to_i

queue   = TESTS.each_with_index.to_a
mutex   = Mutex.new
results = []

# Reap stray tep-test servers by PID with SIGKILL (SIGTERM is unreliable here,
# tep #188). pgrep/Process.kill, not `pkill -f tep-test` -- the latter spawns a
# shell whose own cmdline contains the pattern and self-matches. run_parallel's
# cmdline ("ruby test/run_parallel.rb") doesn't contain "tep-test", so it's
# never a target.
def reap_tep_test_procs
  `pgrep -f tep-test 2>/dev/null`.split.map(&:to_i).each do |pid|
    Process.kill("KILL", pid) rescue nil
  end
end

# Up-front: clear orphans from a previous run. Workers set TEP_PARALLEL so their
# helper.rb skips its own global pgrep-kill (which would TERM sibling workers'
# live servers). Per-worker cleanup still runs via Minitest.after_run; this
# reap is the backstop for what #188 leaks.
reap_tep_test_procs

workers = PROCS.times.map do
  Thread.new do
    loop do
      job = mutex.synchronize { queue.shift }
      break unless job
      path, idx = job
      port_base = PORT_BASE_START + idx * PORT_BASE_STEP
      env = { "TEP_TEST_PORT_BASE" => port_base.to_s, "TEP_PARALLEL" => "1" }
      # Honor TEP_SKIP_SPINEL_FRESH if the caller set it (Makefile
      # handles the freshness check once; per-process would be wasteful).
      ["TEP_SKIP_SPINEL_FRESH", "SPINEL", "TEP_KEEP_TMP"].each do |k|
        env[k] = ENV[k] if ENV[k]
      end
      output = nil
      start  = Time.now
      IO.popen(env, ["ruby", path], err: [:child, :out]) { |io| output = io.read }
      ok     = $?.success?
      elapsed = Time.now - start
      mutex.synchronize do
        results << { path: path, ok: ok, output: output, elapsed: elapsed }
      end
    end
  end
end
workers.each(&:join)

# Reap any servers a worker leaked (tep #188) so they don't accumulate across
# runs or hold the random window's ports.
reap_tep_test_procs

# Sort so the printed order is deterministic (queue order), not
# completion order.
results.sort_by! { |r| TESTS.index(r[:path]) }

totals = { runs: 0, assertions: 0, failures: 0, errors: 0, skips: 0 }
results.each do |r|
  m = r[:output].to_s.match(/(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/)
  if m
    totals[:runs]       += m[1].to_i
    totals[:assertions] += m[2].to_i
    totals[:failures]   += m[3].to_i
    totals[:errors]     += m[4].to_i
    totals[:skips]      += m[5].to_i
  end
  rel  = r[:path].sub(ROOT + "/", "")
  mark = r[:ok] ? "✓" : "✗"   # ✓ / ✗
  tally = m ? " #{m[1]}r/#{m[2]}a/#{m[3]}f/#{m[4]}e/#{m[5]}s" : ""
  puts "%s %s%s  [%.1fs]" % [mark, rel, tally, r[:elapsed]]
  unless r[:ok]
    puts r[:output]
  end
end

puts ""
puts "%d runs, %d assertions, %d failures, %d errors, %d skips" % \
  [totals[:runs], totals[:assertions], totals[:failures], totals[:errors], totals[:skips]]
exit(results.all? { |r| r[:ok] } ? 0 : 1)
