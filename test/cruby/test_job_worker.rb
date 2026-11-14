require_relative "helper"
require "socket"
require "securerandom"
require "base64"

# Tep::Job worker (#230): `job_worker` runs a fiber in the scheduled
# server that claims jobs, dispatches them through the bin/tep-generated
# name -> subclass ladder, records the outcome, and publishes progress.
class TestJobWorker < TepTest
  DB = "/tmp/tep_job_worker_test_#{Process.pid}.db"
  File.delete(DB) if File.exist?(DB)
  Minitest.after_run { File.delete(DB) if File.exist?(DB) }

  app_source <<~RB
    require 'sinatra'
    set :scheduler, :scheduled

    DB_PATH = "#{DB}"

    on_start do
      Tep::Job.init_schema(DB_PATH)
    end

    class UpcaseJob < Tep::Job
      def perform(arg)
        arg.upcase
      end
    end

    class BoomJob < Tep::Job
      def perform(arg)
        raise "boom " + arg
        ""
      end
    end

    # Reports its own row id and two progress payloads.
    class StepJob < Tep::Job
      def perform(arg)
        progress("1/2 " + arg)
        Tep::Scheduler.pause(1)
        progress("2/2 " + arg)
        "jid=" + jid.to_s
      end
    end

    job_worker DB_PATH, poll: 1

    get '/enqueue/:name/:arg/:delay/:retries' do
      Tep::Job.enqueue_opts(params[:name], params[:arg], DB_PATH, params[:delay].to_i, params[:retries].to_i).to_s
    end

    get '/ping' do
      "pong"
    end

    # status|attempts|result|error|progress
    get '/row/:id' do
      db = Tep::SQLite.new
      db.open(DB_PATH)
      db.prepare("SELECT status, attempts, result, error, progress FROM tep_jobs WHERE id = ?")
      db.bind_int(1, params[:id].to_i)
      out = "missing"
      if db.step == 1
        out = db.col_str(0) + "|" + db.col_int(1).to_s + "|" + db.col_str(2) + "|" + db.col_str(3) + "|" + db.col_str(4)
      end
      db.finalize
      db.close
      out
    end

    websocket '/watch' do |ws|
      on_message do |evt|
        Tep::Broadcast.subscribe_ws("job:" + evt.data, ws.fd)
        Tep::Broadcast.subscribe_ws("job:" + evt.data + ":status", ws.fd)
        ws.text("watching " + evt.data)
      end
    end
  RB

  def row(id) = get("/row/#{id}").body.split("|", -1)

  def wait_for_status(id, want, timeout: 10)
    deadline = Time.now + timeout
    loop do
      r = row(id)
      return r if r[0] == want
      flunk "job #{id} never reached #{want}; last row #{r.inspect}" if Time.now > deadline
      sleep 0.1
    end
  end

  def test_worker_runs_an_enqueued_job_without_a_handwritten_ladder
    id = get("/enqueue/UpcaseJob/hello/0/0").body
    assert_equal ["done", "1", "HELLO"], wait_for_status(id, "done")[0, 3]
  end

  def test_a_raising_job_is_failed_with_its_message
    id = get("/enqueue/BoomJob/x/0/0").body
    assert_equal ["failed", "1", "", "boom x"], wait_for_status(id, "failed")[0, 4]
  end

  def test_a_raising_job_with_retries_is_requeued
    id = get("/enqueue/BoomJob/y/0/2").body
    # "queued" is also the state before the first claim, so wait for
    # the attempt to have been counted.
    deadline = Time.now + 10
    sleep 0.1 until row(id)[1] == "1" || Time.now > deadline
    assert_equal ["queued", "1", "", "boom y"], row(id)[0, 4]
  end

  def test_unknown_job_name_fails_instead_of_killing_the_worker
    bad = get("/enqueue/NoSuchJob/z/0/0").body
    assert_match(/unknown job NoSuchJob/, wait_for_status(bad, "failed")[3])
    ok = get("/enqueue/UpcaseJob/after/0/0").body
    assert_equal "AFTER", wait_for_status(ok, "done")[2], "worker survives a bad job"
  end

  def test_server_keeps_serving_while_a_job_is_paused
    id = get("/enqueue/StepJob/busy/0/0").body
    wait_for_status(id, "running")
    assert_equal "pong", get("/ping").body
    wait_for_status(id, "done")
  end

  # --- progress over a live WebSocket --------------------------------

  def ws_open
    sock = TCPSocket.new("127.0.0.1", @port)
    key = Base64.strict_encode64(SecureRandom.bytes(16))
    sock.write("GET /watch HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n" \
               "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    assert_includes sock.gets("\r\n\r\n"), "101 Switching Protocols"
    sock
  end

  def ws_send(sock, payload)
    mask = SecureRandom.bytes(4)
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i & 3) }.pack("C*")
    sock.write([0x81, 0x80 | payload.bytesize].pack("C*") + mask + masked)
  end

  # One unmasked server text frame (payloads here are < 126 bytes).
  def ws_read(sock, timeout: 8)
    flunk "no WebSocket frame within #{timeout}s" unless IO.select([sock], nil, nil, timeout)
    head = sock.read(2)
    assert_equal 0x81, head.getbyte(0)
    sock.read(head.getbyte(1) & 0x7f)
  end

  def test_progress_reaches_a_websocket_subscriber_and_the_row
    # Delay the job so the socket is subscribed before it starts.
    id = get("/enqueue/StepJob/run/2/0").body
    sock = ws_open
    ws_send(sock, id)
    assert_equal "watching #{id}", ws_read(sock)
    assert_equal "1/2 run", ws_read(sock)
    assert_equal "2/2 run", ws_read(sock)
    assert_equal "done", ws_read(sock)
    status, _attempts, result, _error, progress = row(id)
    assert_equal ["done", "jid=#{id}", "2/2 run"], [status, result, progress]
  ensure
    sock&.close
  end
end

# The worker fiber must not hold the server open at shutdown: it
# re-checks the shutdown flag each time its poll pause ends.
class TestJobWorkerShutdown < TepTest
  DB = "/tmp/tep_job_worker_shutdown_test_#{Process.pid}.db"
  File.delete(DB) if File.exist?(DB)
  Minitest.after_run { File.delete(DB) if File.exist?(DB) }

  app_source <<~RB
    require 'sinatra'
    set :scheduler, :scheduled

    DB_PATH = "#{DB}"

    on_start do
      Tep::Job.init_schema(DB_PATH)
    end

    class NoopJob < Tep::Job
      def perform(arg)
        arg
      end
    end

    job_worker DB_PATH, poll: 1

    get '/ping' do
      "pong"
    end
  RB

  def test_sigterm_exits_cleanly_with_an_idle_worker_fiber
    record = TepHarness.find_by_port(@port)
    assert_equal "pong", get("/ping").body
    status = TepHarness.terminate_status(@port, timeout: 4)
    assert status.success?, "shutdown with a job worker required a signal: #{status.inspect}"
  ensure
    FileUtils.rm_rf(record[:tmp]) if record && !TepHarness.find_by_port(@port)
  end
end
