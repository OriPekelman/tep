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
PROCS = (ENV["TEP_TEST_PROCS"] || Etc.nprocessors.to_s).to_i

# Each test class boots its own app on a port from the harness's
# next_port counter; spacing 100 per file is comfy headroom (test
# files have at most a couple of classes).
PORT_BASE_STEP = 100
PORT_BASE_START = (ENV["TEP_TEST_PORT_BASE"] || "4900").to_i

queue   = TESTS.each_with_index.to_a
mutex   = Mutex.new
results = []

workers = PROCS.times.map do
  Thread.new do
    loop do
      job = mutex.synchronize { queue.shift }
      break unless job
      path, idx = job
      port_base = PORT_BASE_START + idx * PORT_BASE_STEP
      env = { "TEP_TEST_PORT_BASE" => port_base.to_s }
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
