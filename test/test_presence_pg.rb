require_relative "helper"

# Tep::Presence PG mirror: cross-worker visibility. Gated on
# PG_TEST_URL like test_pg / test_broadcast_pg.
#
#   PG_TEST_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres \
#     ruby test/test_presence_pg.rb
#
# Test strategy: enable the mirror on the tep app under test,
# track + set_status + untrack through the tep API, verify the
# rows landed in the PG table via list_global. Cross-worker
# behavior is simulated by inserting rows with a different
# worker_id from outside the tep app (via raw exec_params on
# the tep app's own conn -- not perfect isolation but exercises
# the SELECT-across-workers shape).
class TestPresencePg < TepTest
  PG_URL = ENV["PG_TEST_URL"]

  def setup
    if PG_URL.nil? || PG_URL.empty?
      skip "PG_TEST_URL not set (e.g. PG_TEST_URL=postgresql:///postgres). " \
           "See test/test_pg.rb header for the docker recipe."
    end
    super
    # Hard reset between cases: drop all rows so test order doesn't matter.
    get("/reset_pg_table")
    get("/reset")
  end

  app_source <<~RB
    require 'sinatra'

    PG_URL = "#{PG_URL}"

    on_start do
      Tep::Presence.enable_pg_mirror(PG_URL)
    end

    before do
      res.headers["Content-Type"] = "text/plain"
      who = params[:as]
      caps = [:read, :write]
      if who == "agent"
        deleg = Tep::AgentDelegation.new(
          "summarizer-bot", 1000, 9999999999, :token)
        req.identity = Tep::Identity.new("user:42", deleg, caps)
      elsif who.length > 0
        req.identity = Tep::Identity.new(who, nil, caps)
      end
    end

    get '/reset' do
      Tep::Presence.clear.to_s
    end

    get '/reset_pg_table' do
      # Wipe the whole tep_presence table; reused between tests.
      c = Tep::APP.presence_pg_conn
      r = c.exec("DELETE FROM tep_presence")
      n = r.cmd_tuples
      r.clear
      n.to_s
    end

    get '/track' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Presence.track(req, topic, fd).to_s
    end

    get '/untrack' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Presence.untrack(topic, fd).to_s
    end

    get '/set_status' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      state = params[:state].to_sym
      note  = params[:note]
      ut    = params[:until_ts].to_i
      Tep::Presence.set_status(topic, fd, state, note, ut).to_s
    end

    get '/count_global' do
      Tep::Presence.count_global(params[:topic]).to_s
    end

    get '/list_global_summary' do
      # Same compact format as test_presence.rb's list_summary;
      # uses list_global instead of list. principal|kind|agent_id|fd
      # SEMICOLON-separated.
      topic = params[:topic]
      entries = Tep::Presence.list_global(topic)
      out = ""
      i = 0
      while i < entries.length
        e = entries[i]
        if out.length > 0
          out = out + ";"
        end
        out = out + e.principal_id + "|" + e.kind.to_s + "|" + e.agent_id + "|" + e.fd.to_s
        i += 1
      end
      out
    end

    get '/global_status_summary' do
      # Returns the status fields for an entry matching (topic, principal).
      topic = params[:topic]
      principal = params[:principal]
      entries = Tep::Presence.list_global(topic)
      i = 0
      while i < entries.length
        e = entries[i]
        if e.principal_id == principal
          return e.status_state.to_s + "|" + e.status_note + "|" + e.status_until.to_s
        end
        i += 1
      end
      ""
    end

    # Heartbeat + prune-stale-workers helpers (chunk per #47).
    get '/heartbeat' do
      Tep::Presence.heartbeat.to_s
    end

    get '/prune_stale_workers' do
      ttl = params[:ttl].to_i
      Tep::Presence.prune_stale_workers(ttl).to_s
    end

    # Inject a heartbeat row at an arbitrary past timestamp so
    # the prune test can simulate a stale-then-pruned worker.
    get '/inject_worker_heartbeat' do
      worker = params[:worker]
      ts     = params[:ts].to_i
      c = Tep::APP.presence_pg_conn
      r = c.exec_params(
        "INSERT INTO tep_presence_worker (worker_id, last_seen_ts) " +
        "VALUES ($1, $2) " +
        "ON CONFLICT (worker_id) DO UPDATE SET last_seen_ts = EXCLUDED.last_seen_ts",
        [worker, ts.to_s])
      ok = r.ok? ? "1" : "0"
      r.clear
      ok
    end

    get '/worker_count' do
      c = Tep::APP.presence_pg_conn
      r = c.exec("SELECT count(*) FROM tep_presence_worker")
      n = "0"
      if r.ok? && r.ntuples > 0
        n = r.values[0][0]
      end
      r.clear
      n
    end

    get '/reset_worker_table' do
      c = Tep::APP.presence_pg_conn
      r = c.exec("DELETE FROM tep_presence_worker")
      n = r.cmd_tuples
      r.clear
      n.to_s
    end

    # Simulate a row written by ANOTHER worker (different worker_id)
    # so list_global has cross-worker data to aggregate.
    get '/inject_other_worker_row' do
      topic = params[:topic]
      principal = params[:principal]
      fd = params[:fd].to_i
      worker = params[:worker]
      c = Tep::APP.presence_pg_conn
      r = c.exec_params(
        "INSERT INTO tep_presence (worker_id, topic, fd, principal_id, kind, agent_id, " +
        " since_ts, status_state, status_note, status_until) " +
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        [worker, topic, fd.to_s, principal, "human", "",
         "1000", "available", "", "0"])
      ok = r.ok? ? "1" : "0"
      r.clear
      ok
    end
  RB

  # ---- track mirrors to PG ----

  def test_track_mirrors_to_pg
    get("/track?topic=room:lobby&fd=10&as=user:42")
    assert_equal "1", get("/count_global?topic=room:lobby").body
    assert_equal "user:42|human||10",
      get("/list_global_summary?topic=room:lobby").body
  end

  def test_track_agent_mirrors_with_delegation
    get("/track?topic=room:lobby&fd=11&as=agent")
    assert_equal "user:42|agent_for|summarizer-bot|11",
      get("/list_global_summary?topic=room:lobby").body
  end

  # ---- untrack mirrors removal ----

  def test_untrack_removes_pg_row
    get("/track?topic=room:lobby&fd=10&as=user:42")
    assert_equal "1", get("/count_global?topic=room:lobby").body
    get("/untrack?topic=room:lobby&fd=10")
    assert_equal "0", get("/count_global?topic=room:lobby").body
  end

  # ---- set_status mirrors ----

  def test_set_status_mirrors_to_pg
    get("/track?topic=room:lobby&fd=10&as=user:42")
    get("/set_status?topic=room:lobby&fd=10&state=busy&note=working&until_ts=2026200000")
    res = get("/global_status_summary?topic=room:lobby&principal=user:42")
    assert_equal "busy|working|2026200000", res.body
  end

  # ---- cross-worker aggregation ----

  def test_list_global_includes_other_worker_rows
    # Track one entry from THIS worker.
    get("/track?topic=room:lobby&fd=10&as=user:42")
    # Simulate two other workers' entries.
    get("/inject_other_worker_row?topic=room:lobby&principal=user:99&fd=5&worker=worker-B")
    get("/inject_other_worker_row?topic=room:lobby&principal=user:100&fd=7&worker=worker-C")
    assert_equal "3", get("/count_global?topic=room:lobby").body
  end

  def test_list_global_segregates_by_topic
    get("/inject_other_worker_row?topic=room:lobby&principal=user:99&fd=5&worker=worker-B")
    get("/inject_other_worker_row?topic=room:other&principal=user:100&fd=6&worker=worker-B")
    assert_equal "1", get("/count_global?topic=room:lobby").body
    assert_equal "1", get("/count_global?topic=room:other").body
  end

  # ---- heartbeat + prune_stale_workers (#47) ----

  def test_enable_pg_mirror_registers_heartbeat
    # enable_pg_mirror already ran in on_start; its heartbeat
    # row should be present.
    n = get("/worker_count").body.to_i
    assert n >= 1, "expected at least one heartbeat row, got #{n}"
  end

  def test_heartbeat_is_idempotent
    # Calling heartbeat multiple times shouldn't multiply rows;
    # the upsert keeps it at one per worker_id.
    n_before = get("/worker_count").body.to_i
    3.times { get("/heartbeat") }
    n_after = get("/worker_count").body.to_i
    assert_equal n_before, n_after
  end

  def test_prune_drops_stale_worker_and_its_presence_rows
    get("/reset_worker_table")
    # Inject one fresh + one stale worker, each with their own
    # presence row.
    fresh_ts = Time.now.to_i
    stale_ts = fresh_ts - 3600
    get("/inject_worker_heartbeat?worker=worker-fresh&ts=#{fresh_ts}")
    get("/inject_worker_heartbeat?worker=worker-stale&ts=#{stale_ts}")
    get("/inject_other_worker_row?topic=room:prune&principal=user:1&fd=1&worker=worker-fresh")
    get("/inject_other_worker_row?topic=room:prune&principal=user:2&fd=2&worker=worker-stale")
    assert_equal "2", get("/count_global?topic=room:prune").body

    # Prune with a 60s TTL: stale (3600s old) gets dropped; fresh
    # (just now) stays. count_global drops to 1.
    pruned = get("/prune_stale_workers?ttl=60").body.to_i
    assert pruned >= 1, "expected at least one tep_presence row deleted, got #{pruned}"
    assert_equal "1", get("/count_global?topic=room:prune").body
  end

  def test_prune_preserves_live_worker_rows
    get("/reset_worker_table")
    # Single fresh worker -- prune should leave it alone.
    fresh_ts = Time.now.to_i
    get("/inject_worker_heartbeat?worker=worker-live&ts=#{fresh_ts}")
    get("/inject_other_worker_row?topic=room:keep&principal=user:9&fd=99&worker=worker-live")
    assert_equal "1", get("/count_global?topic=room:keep").body
    pruned = get("/prune_stale_workers?ttl=60").body.to_i
    assert_equal 0, pruned, "expected no rows deleted for live worker, got #{pruned}"
    assert_equal "1", get("/count_global?topic=room:keep").body
  end
end
