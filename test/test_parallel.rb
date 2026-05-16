require_relative "helper"

# Tep::Parallel -- fork-based fan-out. Boots a tep app that runs a
# Worker against a small input list and checks both the
# result-collecting and fire-and-forget shapes.
class TestParallel < TepTest
  app_source <<~RB
    require 'sinatra'

    class Doubler < Tep::ParallelWorker
      def run(item)
        # Item is a small integer-as-string; double it and emit the
        # child's pid so the test can verify each result came from a
        # distinct process.
        n = item.to_i
        (n * 2).to_s + ":" + Sock.sphttp_getpid.to_s
      end
    end

    class Echoer < Tep::ParallelWorker
      def run(item)
        item
      end
    end

    # Two workers so we can ensure the result order matches the
    # input order even though forks complete out of order.
    get '/map_doubled' do
      items = ["1", "2", "3", "4"]
      p = Tep::Parallel.new(Doubler.new)
      results = p.map_processes(items)
      out = ""
      i = 0
      while i < results.length
        if out.length > 0
          out = out + ","
        end
        out = out + results[i]
        i += 1
      end
      out
    end

    get '/map_echo' do
      items = ["alpha", "beta", "gamma"]
      p = Tep::Parallel.new(Echoer.new)
      results = p.map_processes(items)
      results.join("|")
    end

    get '/each' do
      # Fire-and-forget: writes a sentinel file in each child;
      # parent then asserts the files exist.
      items = ["x", "y"]
      p = Tep::Parallel.new(FileSentinel.new)
      p.each_process(items)
      ok = "yes"
      if Tep::Shell.read("/tmp/tep_par_test_each_x").length == 0
        ok = "missing_x"
      end
      if Tep::Shell.read("/tmp/tep_par_test_each_y").length == 0
        ok = "missing_y"
      end
      Tep::Shell.run("rm -f /tmp/tep_par_test_each_x /tmp/tep_par_test_each_y")
      ok
    end

    class FileSentinel < Tep::ParallelWorker
      def run(item)
        File.write("/tmp/tep_par_test_each_" + item, "done")
        ""
      end
    end
  RB

  def test_map_processes_returns_ordered_results
    res = get("/map_doubled")
    assert_equal "200", res.code
    body  = res.body
    parts = body.split(",")
    assert_equal 4, parts.length
    # Each entry: "doubled:pid". The doubled values must be 2,4,6,8.
    doubled = parts.map { |s| s.split(":")[0] }
    assert_equal %w[2 4 6 8], doubled
    # The pids should all be distinct -- one process per item.
    pids = parts.map { |s| s.split(":")[1] }
    assert_equal pids.uniq.length, pids.length, "expected distinct child pids, got #{pids.inspect}"
  end

  def test_map_processes_preserves_strings
    res = get("/map_echo")
    assert_equal "200", res.code
    assert_equal "alpha|beta|gamma", res.body
  end

  def test_each_process_runs_workers_for_side_effects
    res = get("/each")
    assert_equal "200", res.code
    assert_equal "yes", res.body
  end
end
