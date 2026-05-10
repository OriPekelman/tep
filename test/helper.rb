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

  # Compile `source` (Sinatra-classic by default) and return the bound port.
  def self.spawn_app(source, mode: :sinatra)
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
    pid  = Process.spawn(bin, "-p", port.to_s, out: log, err: [:child, :out])
    wait_for_port(port, tmp: tmp, pid: pid)
    @running << { pid: pid, tmp: tmp, log: log }
    port
  end

  def self.kill_all
    @running.each do |s|
      begin
        Process.kill("TERM", s[:pid])
      rescue Errno::ESRCH
      end
      begin
        Process.wait(s[:pid])
      rescue Errno::ECHILD
      end
      FileUtils.rm_rf(s[:tmp])
    end
    @running.clear
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

at_exit { TepHarness.kill_all }

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

  @@boot_lock = Mutex.new

  def self.boot!
    @@boot_lock.synchronize do
      return @port if @port
      src, mode = app_source
      raise "#{name}: app_source not set" unless src
      @port = TepHarness.spawn_app(src, mode: mode)
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
      http.request(r)
    end
  end
end
