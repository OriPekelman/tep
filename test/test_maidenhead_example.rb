require "minitest/autorun"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"

# Companion to test_geohash_example.rb, but for the example whose ENTIRE
# gem API compiles: examples/maidenhead/app.rb runs on the unmodified
# published maidenhead 1.0.1 gem (MIT), vendored + require_relative'd.
# Every route is checked against CRuby's Maidenhead.* output. Builds the
# real example in place so the relative require_relative resolves.
class TestMaidenheadExample < Minitest::Test
  TEP_BIN = File.expand_path("../bin/tep", __dir__)
  APP     = File.expand_path("../examples/maidenhead/app.rb", __dir__)

  def setup
    @tmp  = Dir.mktmpdir("tep-maidenhead")
    @bin  = File.join(@tmp, "maidenhead")
    out   = `#{TEP_BIN} build #{APP} -o #{@bin} 2>&1`
    raise "maidenhead example build failed:\n#{out}" unless $?.success? && File.executable?(@bin)
    @port = 4960 + (Process.pid % 80)
    @log  = File.join(@tmp, "app.log")
    @pid  = Process.spawn(@bin, "-p", @port.to_s, out: @log, err: [:child, :out], pgroup: true)
    wait_for_port(@port)
  end

  def teardown
    if @pid
      Process.kill("TERM", -@pid) rescue nil
      Process.wait(@pid) rescue nil
    end
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  def wait_for_port(port, timeout: 10.0)
    deadline = Time.now + timeout
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue
        sleep 0.05
      end
    end
    raise "maidenhead app never bound :#{port}\n#{File.read(@log) rescue ''}"
  end

  def get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}#{path}")).body
  end

  def test_valid_true
    assert_equal "true", get("/valid?loc=FN31pr")
  end

  def test_valid_false
    assert_equal "false", get("/valid?loc=invalid")
  end

  def test_to_latlon
    assert_equal "41.731076,-72.704514", get("/to_latlon?loc=FN31pr")
  end

  def test_to_grid_precision_3
    assert_equal "FN20xr", get("/to_grid?lat=40.7128&lon=-74.0060&precision=3")
  end

  def test_to_grid_precision_2
    assert_equal "IO91", get("/to_grid?lat=51.5074&lon=-0.1278&precision=2")
  end
end
