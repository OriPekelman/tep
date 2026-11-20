require_relative "helper"
require "socket"

# The boot-time type seeds used to build a Stream and two WebSocket
# drivers on descriptor 0 and write test frames to it. With a socket on
# stdin those 54 bytes reached the peer, and once an unread socket
# filled, a later start blocked before serving (#283).
class TestBootSeedStdin < Minitest::Test
  def test_start_writes_nothing_to_a_socket_on_stdin
    tmp = Dir.mktmpdir("tep-seed-stdin")
    src = File.join(tmp, "app.rb")
    File.write(src, "require \"sinatra\"\nget \"/\" do\n  \"hi\"\nend\n")
    bin = File.join(tmp, "app")
    TepHarness.build_with_retry("#{TepHarness::TEP_BIN} build #{src} -o #{bin}", "tep build seed stdin app")
    ours, theirs = UNIXSocket.pair
    port = TepHarness.next_port
    pid = Process.spawn(bin, "-p", port.to_s, "-q", in: theirs,
                        out: File.join(tmp, "app.log"), err: [:child, :out], pgroup: true)
    theirs.close
    TepHarness.wait_for_port(port, tmp: tmp, pid: pid)
    TepHarness.reap(pid)
    pid = nil
    assert_equal "", ours.read, "the app wrote to its stdin socket at start"
  ensure
    TepHarness.reap(pid) if pid
    ours&.close
    FileUtils.rm_rf(tmp) if tmp
  end
end
