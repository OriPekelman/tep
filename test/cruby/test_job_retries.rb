require_relative "helper"

# Tep::Job retries, delay, stale reclaim, schema migration and the
# atomic claim (#230). Runs with 4 prefork workers so concurrent
# claims really do come from separate processes on one SQLite file.
class TestJobRetries < TepTest
  DB = "/tmp/tep_job_retries_test_#{Process.pid}.db"
  LEGACY_DB = "/tmp/tep_job_legacy_test_#{Process.pid}.db"
  [DB, LEGACY_DB].each { |f| File.delete(f) if File.exist?(f) }
  Minitest.after_run { [DB, LEGACY_DB].each { |f| File.delete(f) if File.exist?(f) } }

  workers 4

  app_source <<~RB
    require 'sinatra'

    DB_PATH = "#{DB}"
    LEGACY_PATH = "#{LEGACY_DB}"

    on_start do
      Tep::Job.init_schema(DB_PATH)
    end

    get '/enqueue/:arg/:delay/:retries' do
      id = Tep::Job.enqueue_opts("J", params[:arg], DB_PATH, params[:delay].to_i, params[:retries].to_i)
      id.to_s
    end

    get '/enqueue_in/:arg/:delay' do
      Tep::Job.enqueue_in(params[:delay].to_i, "J", params[:arg], DB_PATH).to_s
    end

    get '/claim' do
      claim = Tep::Job.fetch_next(DB_PATH)
      if claim.length == 0
        "none"
      else
        claim
      end
    end

    get '/fail/:id/:msg' do
      Tep::Job.retry_or_fail(DB_PATH, params[:id].to_i, params[:msg]).to_s
    end

    get '/done/:id' do
      Tep::Job.mark_done(DB_PATH, params[:id].to_i, "ok").to_s
    end

    get '/stale/:secs' do
      Tep::Job.requeue_stale(DB_PATH, params[:secs].to_i).to_s
    end

    # Test-only: make a backed-off job claimable again.
    get '/due/:id' do
      db = Tep::SQLite.new
      db.open(DB_PATH)
      db.prepare("UPDATE tep_jobs SET run_at = 0 WHERE id = ?")
      db.bind_int(1, params[:id].to_i)
      db.step
      db.finalize
      db.close
      "ok"
    end

    # status|attempts|error|seconds-until-run_at
    get '/row/:id' do
      db = Tep::SQLite.new
      db.open(DB_PATH)
      db.prepare("SELECT status, attempts, error, run_at FROM tep_jobs WHERE id = ?")
      db.bind_int(1, params[:id].to_i)
      out = "missing"
      if db.step == 1
        out = db.col_str(0) + "|" + db.col_int(1).to_s + "|" + db.col_str(2) + "|" + (db.col_int(3) - Time.now.to_i).to_s
      end
      db.finalize
      db.close
      out
    end

    # A table as an older tep created it, holding one queued row,
    # then migrated in place by init_schema.
    get '/legacy' do
      Tep::Shell.run("rm -f " + LEGACY_PATH)
      db = Tep::SQLite.new
      db.open(LEGACY_PATH)
      db.exec("CREATE TABLE tep_jobs (id INTEGER PRIMARY KEY, job_name TEXT, arg TEXT, status TEXT, created_at INTEGER, finished_at INTEGER, result TEXT)")
      db.exec("INSERT INTO tep_jobs (job_name, arg, status, created_at) VALUES ('Old', 'payload', 'queued', 1)")
      db.close
      Tep::Job.init_schema(LEGACY_PATH)
      Tep::Job.init_schema(LEGACY_PATH)
      db2 = Tep::SQLite.new
      db2.open(LEGACY_PATH)
      cols = db2.first_int("SELECT COUNT(*) FROM pragma_table_info('tep_jobs')", "")
      db2.close
      old = Tep::Job.fetch_next(LEGACY_PATH)
      nid = Tep::Job.enqueue("New", "x", LEGACY_PATH)
      cols.to_s + ";" + old + ";" + nid.to_s
    end
  RB

  # Every test drains whatever earlier tests left claimable.
  def setup
    super
    200.times { break if get("/claim").body == "none" }
  end

  def row(id) = get("/row/#{id}").body.split("|", -1)

  def test_retry_requeues_with_backoff_then_fails_when_exhausted
    id = get("/enqueue/a/0/1").body
    assert_equal "#{id}|J|a", get("/claim").body
    assert_equal "1", get("/fail/#{id}/boom").body, "one retry allowed: requeued"
    status, attempts, error, wait = row(id)
    assert_equal ["queued", "1", "boom"], [status, attempts, error]
    assert_includes 14..16, wait.to_i, "sidekiq backoff: 1**4 + 15 seconds"
    assert_equal "none", get("/claim").body, "not claimable during backoff"

    get("/due/#{id}")
    assert_equal "#{id}|J|a", get("/claim").body
    assert_equal "0", get("/fail/#{id}/boom2").body, "retries exhausted: terminal"
    assert_equal ["failed", "2", "boom2"], row(id)[0, 3]
    assert_equal "none", get("/claim").body
  end

  def test_no_retries_by_default
    id = get("/enqueue/b/0/0").body
    get("/claim")
    assert_equal "0", get("/fail/#{id}/nope").body
    assert_equal ["failed", "1", "nope"], row(id)[0, 3]
  end

  def test_delayed_job_is_not_claimable_until_due
    id = get("/enqueue_in/c/3600").body
    assert_equal "none", get("/claim").body
    assert_includes 3598..3600, row(id)[3].to_i
    get("/due/#{id}")
    assert_equal "#{id}|J|c", get("/claim").body
    get("/done/#{id}")
    assert_equal "done", row(id)[0]
  end

  def test_requeue_stale_reclaims_running_rows
    retried  = get("/enqueue/d/0/1").body
    one_shot = get("/enqueue/e/0/0").body
    get("/claim"); get("/claim")
    get("/stale/3600")
    assert_equal "running", row(retried)[0], "a fresh claim is not stale"
    get("/stale/0")
    assert_equal ["queued", "1", "worker lost"], row(retried)[0, 3]
    assert_equal ["failed", "1", "worker lost"], row(one_shot)[0, 3]
  end

  def test_init_schema_migrates_a_legacy_table_in_place
    cols, old, new_id = get("/legacy").body.split(";")
    assert_equal "13", cols, "7 legacy columns + 6 added, added once"
    assert_equal "1|Old|payload", old, "a pre-migration row is still claimable"
    assert_equal "2", new_id
  end

  def test_concurrent_workers_never_claim_the_same_job
    ids = 40.times.map { |i| get("/enqueue/n#{i}/0/0").body }
    claims = Queue.new
    8.times.map {
      Thread.new do
        30.times do
          body = get("/claim").body
          claims << body.split("|").first unless body == "none"
        end
      end
    }.each(&:join)
    got = []
    got << claims.pop until claims.empty?
    assert_equal got.uniq.size, got.size, "a job was claimed twice"
    assert_equal ids.sort, got.sort, "every job claimed exactly once"
  end
end
