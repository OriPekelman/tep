# Differential oracle: real sinatra vs tep (mirror condition 2,
# docs/mirrors/sinatra.md). Boots each fixture app twice -- once under
# CRuby + the real sinatra gem, once as a tep-compiled binary -- fires
# the same requests at both, and diffs status / body / declared
# headers. Any divergence not recorded in LEDGER is a failure: new
# divergences must be either fixed or explicitly ledgered with a
# reason (which then belongs in docs/mirrors/sinatra.md too).
#
# Not part of `rake test` (FileList only globs test/test_*.rb): the
# sinatra gem must never become a tep dependency. Run explicitly:
#
#   gem install sinatra rackup puma       # or bundle with ./Gemfile
#   ruby test/differential/runner.rb
#
# CI runs this as its own job (`differential` in ci.yml).

begin
  gem "sinatra"
rescue Gem::LoadError
  abort "differential runner needs the sinatra gem (gem install sinatra rackup puma)"
end

require "minitest/autorun"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require "shellwords"
require "rbconfig"

module Differential
  TEP_BIN   = File.expand_path("../../bin/tep", __dir__)
  ROOT      = File.expand_path("../..", __dir__)
  PORT_BASE = 5300 + ($$ % 100)

  @port = PORT_BASE
  def self.next_port
    @port += 1
  end

  # ---- the exclusion ledger, harness-side ----
  # Divergences we accept, keyed by response facet. Every entry needs a
  # reason and should be mirrored in docs/mirrors/sinatra.md. The
  # runner *normalizes* these away before diffing; anything left is a
  # real, unledgered divergence and fails the run.
  #
  # L1 content-type charset: sinatra appends ";charset=utf-8" to text
  #    types; tep emits the bare type.
  # L2 protection headers: sinatra ships rack-protection by default
  #    (x-xss-protection / x-content-type-options / x-frame-options);
  #    tep's Tep::Security::Headers is opt-in.
  # L3 server/date/connection/content-length: transport furniture --
  #    body equality already covers length.
  # L4 redirect Location absolutization: sinatra expands "/path" to an
  #    absolute http://host:port/path; tep echoes the path as given.
  #    Compare path component only.
  IGNORED_HEADERS = %w[
    server date connection content-length x-xss-protection
    x-content-type-options x-frame-options keep-alive
  ].freeze

  def self.normalize_content_type(v)
    v.to_s.split(";").first.to_s.strip.downcase # L1
  end

  def self.normalize_location(v)
    return "" if v.nil?
    v.sub(%r{\Ahttps?://[^/]+}, "") # L4
  end

  Server = Struct.new(:pid, :port, :log) do
    def stop
      return unless pid
      Process.kill("TERM", -pid) rescue Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  def self.wait_for_port(port, pid, timeout: 15.0)
    deadline = Time.now + timeout
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", port).close
        return true
      rescue Errno::ECONNREFUSED
        raise "server died before binding :#{port}" if Process.wait(pid, Process::WNOHANG) rescue nil
        sleep 0.05
      end
    end
    raise "server on :#{port} didn't come up"
  end

  def self.boot_sinatra(app_path)
    port = next_port
    log  = File.join(Dir.mktmpdir("diff-sin"), "sinatra.log")
    pid  = Process.spawn(
      RbConfig.ruby, app_path, "-p", port.to_s, "-o", "127.0.0.1", "-e", "production",
      out: log, err: [:child, :out], pgroup: true
    )
    wait_for_port(port, pid)
    Server.new(pid, port, log)
  end

  def self.boot_tep(app_path)
    tmp = Dir.mktmpdir("diff-tep")
    bin = File.join(tmp, "app")
    out = `#{Shellwords.escape(TEP_BIN)} build #{Shellwords.escape(app_path)} -o #{Shellwords.escape(bin)} 2>&1`
    raise "tep build failed for #{app_path}:\n#{out}" unless $?.success?
    port = next_port
    log  = File.join(tmp, "tep.log")
    pid  = Process.spawn(bin, "-p", port.to_s, "-q",
                         out: log, err: [:child, :out], pgroup: true)
    wait_for_port(port, pid)
    Server.new(pid, port, log)
  end

  def self.request(port, verb, path, body: nil, headers: {})
    http = Net::HTTP.new("127.0.0.1", port)
    http.open_timeout = 5
    http.read_timeout = 5
    klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post,
              "PUT" => Net::HTTP::Put, "DELETE" => Net::HTTP::Delete }.fetch(verb)
    req = klass.new(path)
    headers.each { |k, v| req[k] = v }
    if body
      req.body = body
      req["Content-Type"] ||= "application/x-www-form-urlencoded"
    end
    http.request(req)
  end
end

# One test class per fixture; each boots both servers once and replays
# the same request script against each.
class DifferentialCase < Minitest::Test
  FIXTURES = {
    File.expand_path("../real_world/01_simple.rb", __dir__) => [
      ["GET", "/"],
    ],
    File.expand_path("../real_world/04_health_api.rb", __dir__) => [
      ["GET", "/healthz"],
      ["GET", "/version"],
      ["GET", "/"],
      ["GET", "/missing"],          # custom not_found on both
    ],
    File.expand_path("../real_world/05_todo_api.rb", __dir__) => [
      ["GET", "/todos"],
      ["POST", "/todos", { body: "text=buy-milk" }],
      ["POST", "/todos", { body: "text=ship-tep" }],
      ["GET", "/todos"],
      ["DELETE", "/todos/1"],
      ["DELETE", "/todos/9999"],
      ["GET", "/todos"],
    ],
    File.expand_path("10_semantics.rb", __dir__) => [
      ["GET", "/hi/tep"],
      ["GET", "/two/a/b"],
      ["GET", "/q?q=hello"],
      ["GET", "/q"],                 # missing param -> ""
      ["POST", "/form", { body: "text=zap" }],
      ["GET", "/redir"],
      ["GET", "/redir301"],
      ["GET", "/teapot"],
      ["GET", "/halted"],
      ["GET", "/hdr", { expect_headers: ["x-custom"] }],
      ["GET", "/ct"],
      ["GET", "/hi%20there"],        # url-decoded 404 path via not_found
    ],
  }.freeze

  def compare(app, sin, tep, verb, path, opts)
    body    = opts[:body]
    headers = opts[:headers] || {}
    r_sin = Differential.request(sin.port, verb, path, body: body, headers: headers)
    r_tep = Differential.request(tep.port, verb, path, body: body, headers: headers)
    ctx = "#{File.basename(app)} #{verb} #{path}"

    assert_equal r_sin.code, r_tep.code, "#{ctx}: status diverged"
    assert_equal r_sin.body, r_tep.body, "#{ctx}: body diverged"
    assert_equal Differential.normalize_content_type(r_sin["content-type"]),
                 Differential.normalize_content_type(r_tep["content-type"]),
                 "#{ctx}: content-type diverged (post-normalization)"
    if %w[301 302 303 307 308].include?(r_sin.code)
      assert_equal Differential.normalize_location(r_sin["location"]),
                   Differential.normalize_location(r_tep["location"]),
                   "#{ctx}: redirect Location diverged (path component)"
    end
    (opts[:expect_headers] || []).each do |h|
      assert_equal r_sin[h], r_tep[h], "#{ctx}: declared header #{h} diverged"
    end
  end

  FIXTURES.each do |app, script|
    name = File.basename(app, ".rb")
    define_method("test_differential_#{name}") do
      sin = Differential.boot_sinatra(app)
      tep = Differential.boot_tep(app)
      begin
        script.each do |verb, path, opts|
          compare(app, sin, tep, verb, path, opts || {})
        end
      ensure
        sin.stop
        tep.stop
      end
    end
  end
end
