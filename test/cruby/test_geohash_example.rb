require "minitest/autorun"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"

# Proves tep can compile + run an app that uses a REAL, unmodified
# published Ruby gem (pr_geohash 1.0.0, MIT) vendored next to the app and
# pulled in with `require_relative`. `bin/tep build` inlines app-local
# require_relative targets into the AOT binary (no runtime gem loader),
# so GeoHash.encode runs as native compiled code. Reference outputs below
# are CRuby's (ruby -I lib + GeoHash.encode) -- the spinel-compiled binary
# must match them byte-for-byte.
#
# Unlike the other suites this builds the real examples/geohash/app.rb in
# place (not an app_source heredoc in a tmpdir) so the relative
# require_relative resolves against the vendored gem.
class TestGeohashExample < Minitest::Test
  TEP_BIN = File.expand_path("../../bin/tep", __dir__)
  APP     = File.expand_path("../../examples/geohash/app.rb", __dir__)
  EX_DIR  = File.dirname(APP)

  # vendor/spinel is generated from Gemfile.lock by bundler-spinel
  # (`spinel-compat vendor`), not committed. Regenerate before building;
  # skip if spinelgems isn't reachable (suite run outside the dev
  # container, which mounts /spinelgems).
  def ensure_vendored
    deps = File.join(EX_DIR, "vendor", "spinel", "deps.rb")
    return if File.exist?(deps)
    sg = ENV["SPINELGEMS"] || "/spinelgems"
    skip "spinelgems not at #{sg}; run `make vendor-examples`" unless File.directory?(File.join(sg, "exe"))
    out = `cd #{EX_DIR} && ruby -I #{sg}/lib #{sg}/exe/spinel-compat vendor 2>&1`
    skip "spinel-compat vendor failed (offline?):\n#{out}" unless $?.success? && File.exist?(deps)
  end

  def setup
    ensure_vendored
    @tmp  = Dir.mktmpdir("tep-geohash")
    @bin  = File.join(@tmp, "geohash")
    out   = `#{TEP_BIN} build #{APP} -o #{@bin} 2>&1`
    raise "geohash example build failed:\n#{out}" unless $?.success? && File.executable?(@bin)
    @port = 4970 + (Process.pid % 80)
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
    raise "geohash app never bound :#{port}\n#{File.read(@log) rescue ''}"
  end

  def get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}#{path}")).body
  end

  # GeoHash.encode reference values (computed under CRuby).
  def test_encode_paris_precision_8
    assert_equal "u09tunqu", get("/geohash?lat=48.8584&lon=2.2945&precision=8")
  end

  def test_encode_tokyo_default_precision
    assert_equal "xn76urx0zhkz", get("/geohash?lat=35.681&lon=139.767")
  end

  def test_encode_sydney_precision_6
    assert_equal "r3gx2f", get("/geohash?lat=-33.8688&lon=151.2093&precision=6")
  end

  def test_index_mentions_the_gem
    assert_match(/pr_geohash 1\.0\.0/, get("/"))
  end
end
