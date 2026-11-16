require_relative "helper"
require "net/http"

# `tep build` compiles the optional native helpers (sqlite, pg) on demand
# into ~/.cache/tep/ext/<checkout basename>/. The slot used to be keyed by
# that basename plus an mtime check, so another tree with the same name
# could leave an object there that this tree then linked: it built fine
# and SQLite queries returned nothing. The object is now keyed by the
# source bytes and compile flags.
class TestExtCache < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  APP = <<~'RB'
    require "sinatra"
    get "/count" do
      db = Tep::SQLite.new
      db.open(ENV.fetch("DB_PATH", "/tmp/unset.db"))
      db.exec("CREATE TABLE n (id INTEGER PRIMARY KEY, b TEXT)")
      db.exec("INSERT INTO n (b) VALUES ('x')")
      db.exec("INSERT INTO n (b) VALUES ('y')")
      "count=" + db.first_int("SELECT COUNT(*) FROM n WHERE id > ?", "0").to_s
    end
  RB

  def setup
    skip "prebuilt native/sqlite/tep_sqlite.o present; the cache is bypassed" if File.exist?(File.join(REPO, "native/sqlite/tep_sqlite.o"))
    skip "TEP_SQLITE_O set; the cache is bypassed" unless ENV["TEP_SQLITE_O"].to_s.empty?
    @tmp = Dir.mktmpdir("tep-extcache")
    @home = File.join(@tmp, "home")
    @slot = File.join(@home, ".cache", "tep", "ext", File.basename(REPO))
    FileUtils.mkdir_p(@slot)
    @src = File.join(@tmp, "app.rb")
    File.write(@src, APP)
  end

  def teardown
    TepHarness.reap(@pid) if @pid
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def build(bin)
    out = `HOME=#{@home} #{TepHarness::TEP_BIN} build #{@src} -o #{bin} 2>&1`
    assert $?.success?, "tep build failed:\n#{out}"
    out
  end

  def test_foreign_object_in_the_slot_is_not_linked
    # What another same-named tree would have left behind under the old
    # scheme: an object at the unkeyed name, newer than our source. This
    # one defines nothing, so linking it cannot produce a working binary.
    decoy_c = File.join(@tmp, "decoy.c")
    File.write(decoy_c, "int tep_decoy_unused;\n")
    decoy = File.join(@slot, "tep_sqlite.o")
    assert system("cc", "-c", decoy_c, "-o", decoy)
    File.utime(Time.now + 3600, Time.now + 3600, decoy)

    bin = File.join(@tmp, "app")
    build(bin)

    keyed = Dir[File.join(@slot, "tep_sqlite-*.o")]
    assert_equal 1, keyed.length, "expected one content-keyed object, got #{Dir[File.join(@slot, '*')].inspect}"
    assert_match(/tep_sqlite-\h{16}\.o\z/, keyed[0])

    @port = TepHarness.next_port
    @pid = Process.spawn({ "DB_PATH" => File.join(@tmp, "t.db") }, bin, "-p", @port.to_s, "-q",
                         out: File.join(@tmp, "app.log"), err: [:child, :out], pgroup: true)
    TepHarness.wait_for_port(@port, tmp: @tmp, pid: @pid)
    assert_equal "count=2", Net::HTTP.get(URI("http://127.0.0.1:#{@port}/count"))

    # A second build reuses the keyed object.
    before = File.mtime(keyed[0])
    out = build(File.join(@tmp, "app2"))
    refute_match(/building ext 'sqlite'/, out)
    assert_equal before, File.mtime(keyed[0])
  end
end
