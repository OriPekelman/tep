# Test harness for the Sinatra compatibility checklist.
#
# Each test class declares one app source via `app_source <<~RB ... RB`,
# the harness compiles it once with bin/tep (Sinatra-classic style) or
# spinel directly (subclass style), starts the binary on a fresh port,
# and runs N tests against the live server. Cleanup happens at_exit.
#
# Per-class boot keeps total wall time reasonable -- one ~1s spinel
# compile per file, not per test.

ENV["MT_NO_PLUGINS"] ||= "1"   # avoid Rails minitest plugin autoload pulling in railties
require "minitest/autorun"
# Force serial execution -- per-class boot expects only one thread
# touching the class state at a time.
Minitest.parallel_executor = Minitest::Parallel::Executor.new(1) if defined?(Minitest::Parallel::Executor)
require "net/http"
require "uri"
require "socket"
require "fileutils"
require "tmpdir"

module TepHarness
  TEP_BIN = File.expand_path("../bin/tep", __dir__)
  SPINEL  = ENV.fetch("SPINEL", "spinel")

  @running = []
  @port    = (ENV["TEP_TEST_PORT_BASE"] || "4900").to_i

  class << self
    attr_reader :port
  end

  def self.next_port
    p = @port
    @port += 1
    p
  end

  # Compile `source` (Sinatra-classic by default) and return the bound
  # port. Pass `workers: N` to launch the binary in prefork mode --
  # used by tests that need to exercise cross-worker behaviour (e.g.
  # the #128 parent-only run_end emission).
  def self.spawn_app(source, mode: :sinatra, workers: 1)
    tmp  = Dir.mktmpdir("tep-test")
    src  = File.join(tmp, "app.rb")
    File.write(src, source)
    bin  = File.join(tmp, "app")
    case mode
    when :sinatra
      out = `#{TEP_BIN} build #{src} -o #{bin} 2>&1`
      raise "tep build failed:\n#{out}" unless $?.success?
    when :direct
      out = `#{SPINEL} #{src} -o #{bin} 2>&1`
      raise "spinel failed:\n#{out}" unless $?.success?
    else
      raise "unknown mode: #{mode}"
    end
    port = next_port
    log  = File.join(tmp, "app.log")
    args = [bin, "-p", port.to_s]
    args += ["-w", workers.to_s] if workers > 1
    # Spawn the app as its own process-group leader (pgroup: true ->
    # pgid == this pid). The server's shutdown contract is SIGTERM-to-
    # the-pgroup (lib/tep/server.rb): in prefork mode the parent forks
    # workers that block in accept(), and only a GROUP-wide signal
    # reaches them. Teardown signals the group (see #reap); the group
    # being distinct from the test runner's keeps that signal off us.
    pid  = Process.spawn(*args, out: log, err: [:child, :out], pgroup: true)
    wait_for_port(port, tmp: tmp, pid: pid)
    @running << { pid: pid, tmp: tmp, log: log, port: port }
    port
  end

  # Find the spawned record for a given bound port (used by tests
  # that need to send signals to the process they booted, e.g.
  # shutdown-hook tests asserting on run_end emission).
  def self.find_by_port(port)
    @running.find { |s| s[:port] == port }
  end

  # SIGTERM the process bound to `port` + wait for exit. Removes the
  # entry from @running so kill_all's at_exit doesn't double-reap.
  def self.terminate(port, timeout: 5.0)
    s = find_by_port(port)
    return unless s
    reap(s[:pid], timeout: timeout)
    @running.delete(s)
  end

  # Like terminate, but RETURNS the Process::Status of the SIGTERM'd
  # process (or nil if not found) so a test can assert on how it exited
  # -- e.g. that a no-events server doesn't SIGSEGV on shutdown (the #186
  # regression: termsig == SEGV => exit 139). Bounded: escalates to
  # SIGKILL after `timeout` so a wedged server can't hang the suite.
  def self.terminate_status(port, timeout: 5.0)
    s = find_by_port(port)
    return nil unless s
    pid = s[:pid]
    signal_group(pid, "TERM")
    deadline = Time.now + timeout
    status = nil
    loop do
      begin
        got, st = Process.waitpid2(pid, Process::WNOHANG)
        if got
          status = st
          break
        end
      rescue Errno::ECHILD
        break
      end
      if Time.now > deadline
        signal_group(pid, "KILL")
        _, status = (Process.waitpid2(pid) rescue [nil, nil])
        break
      end
      sleep 0.02
    end
    @running.delete(s)
    status
  end

  def self.kill_all
    @running.each do |s|
      reap(s[:pid])
      FileUtils.rm_rf(s[:tmp])
    end
    @running.clear
  end

  # Gracefully stop a spawned app and wait for it to exit, BOUNDED.
  # Signals the whole process group (negative pid) so prefork workers
  # blocked in accept() actually receive the signal -- a bare
  # `Process.kill("TERM", pid)` hits only the parent, leaving workers
  # wedged and the parent stuck in wait_any, which used to hang the
  # at_exit reap forever (test process in do_wait). Escalates to
  # SIGKILL if the graceful stop doesn't land in time, so no
  # misbehaving server can stall the suite.
  def self.reap(pid, timeout: 5.0)
    signal_group(pid, "TERM")
    return if wait_exit(pid, timeout)
    signal_group(pid, "KILL")
    wait_exit(pid, 2.0)
  end

  # Signal `pid`'s process group; fall back to the bare pid if the
  # group is already gone. Swallows ESRCH (already dead).
  def self.signal_group(pid, sig)
    begin
      Process.kill(sig, -pid)
    rescue Errno::ESRCH
      begin
        Process.kill(sig, pid)
      rescue Errno::ESRCH
      end
    end
  end

  # Poll-wait for `pid` to exit, up to `timeout` seconds. Returns true
  # if it was reaped (or is already gone), false on timeout.
  def self.wait_exit(pid, timeout)
    deadline = Time.now + timeout
    loop do
      begin
        got, _ = Process.waitpid2(pid, Process::WNOHANG)
        return true if got
      rescue Errno::ECHILD
        return true
      end
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  def self.wait_for_port(port, timeout: 5.0, tmp: nil, pid: nil)
    deadline = Time.now + timeout
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue Errno::ECONNREFUSED
        sleep 0.05
        if Time.now > deadline
          msg = "tep server failed to bind :#{port}"
          if tmp
            log = File.join(tmp, "app.log")
            if File.exist?(log)
              msg += "\n--- app log (#{log}) ---\n" + File.read(log)
            end
          end
          alive = pid && (Process.kill(0, pid) rescue false)
          msg += "\n--- pid #{pid} alive=#{!!alive}" if pid
          raise msg
        end
      end
    end
  end
end

# Tear down spawned apps AFTER Minitest finishes. A bare `at_exit`
# would fire BEFORE the test runner (Ruby at_exit is LIFO and
# require "minitest/autorun" registers its at_exit first), so
# @running would be empty and apps would leak as orphans to PID 1
# when ruby exits. Minitest.after_run fires post-suite, with the
# @running list populated. See #117 for the original investigation.
Minitest.after_run { TepHarness.kill_all }

# Kill any zombie tep test processes leaking from previous runs.
# Skip on hosts that don't ship `pgrep` (some slim containers don't).
if system("which pgrep >/dev/null 2>&1")
  `pgrep -f tep-test 2>/dev/null`.split.each do |pid|
    Process.kill("TERM", pid.to_i) rescue nil
  end
end

class TepTest < Minitest::Test
  # Class-level: capture `app_source` and `app_mode`. Boot lazily on
  # first `setup`. Per-class @port memoises the bound port.
  def self.app_source(src = nil, mode: :sinatra)
    if src
      @app_source = src
      @app_mode   = mode
    else
      [@app_source, @app_mode]
    end
  end

  # Number of prefork workers to launch the test binary with.
  # Defaults to 1 (the existing single-process shape). Tests that
  # need to exercise multi-worker behaviour (e.g. #128 run_end
  # aggregation across workers) call `workers 2` at class scope.
  def self.workers(n = nil)
    if n
      @workers = n
    else
      @workers || 1
    end
  end

  @@boot_lock = Mutex.new

  def self.boot!
    @@boot_lock.synchronize do
      return @port if @port
      src, mode = app_source
      raise "#{name}: app_source not set" unless src
      @port = TepHarness.spawn_app(src, mode: mode, workers: workers)
    end
  end

  def setup
    @port = self.class.boot!
  end

  # ---- HTTP helpers ----
  def get(path, headers = {})         req(:get,    path, nil, headers); end
  def post(path, body = "", headers = {}) req(:post,   path, body, headers); end
  def put(path, body = "", headers = {})  req(:put,    path, body, headers); end
  def patch(path, body = "", headers = {}) req(:patch,  path, body, headers); end
  def delete(path, headers = {})      req(:delete, path, nil, headers); end
  def head(path, headers = {})        req(:head,   path, nil, headers); end

  def req(method, path, body, headers)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    klass = {
      get:     Net::HTTP::Get,
      post:    Net::HTTP::Post,
      put:     Net::HTTP::Put,
      patch:   Net::HTTP::Patch,
      delete:  Net::HTTP::Delete,
      head:    Net::HTTP::Head,
      options: Net::HTTP::Options,
    }.fetch(method)
    Net::HTTP.start(uri.host, uri.port, read_timeout: 3) do |http|
      r = klass.new(uri)
      r.body = body if body && %i[post put patch].include?(method)
      headers.each { |k, v| r[k] = v }
      # Ruby <= 3.x's Net::HTTP auto-set Content-Type:
      # application/x-www-form-urlencoded whenever request.body was
      # assigned; Ruby 4.0 dropped that default, so a bodied POST goes
      # out with no Content-Type and tep (correctly) doesn't parse it as
      # form params. Restore the historical default for bodied requests
      # unless a test set its own Content-Type -- matches what real form
      # clients send and keeps the suite Ruby-version-agnostic.
      if r.body && !r["content-type"]
        r["Content-Type"] = "application/x-www-form-urlencoded"
      end
      http.request(r)
    end
  end
end
