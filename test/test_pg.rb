require_relative "helper"

# Tep::PG end-to-end against a real PostgreSQL instance.
#
# Gated on PG_TEST_URL -- set to a libpq conninfo string when running:
#
#   PG_TEST_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres \
#     ruby test/test_pg.rb
#
# `make test-pg` (Makefile target) spins up a postgres:16 docker
# container, sets the env var, runs this file, tears down on exit.
#
# Without PG_TEST_URL set, every test in this class skips cleanly --
# `make test` on a contributor's machine that doesn't have PG running
# still passes its other test classes.
#
# Each test uses a per-class temp table whose name carries the PID so
# parallel test files don't collide. Test order is randomised via
# minitest seed; the on_start hook seeds the table and individual
# tests are written to be order-independent (each one re-asserts the
# count it expects).
class TestPg < TepTest
  PG_URL = ENV["PG_TEST_URL"]

  # Skip the whole class cleanly when PG isn't available. Override
  # setup BEFORE TepTest's setup runs `boot!` (which tries to compile
  # the inline app_source). With PG_TEST_URL unset, every test method
  # short-circuits to a single skip.
  def setup
    if PG_URL.nil? || PG_URL.empty?
      skip "PG_TEST_URL not set (e.g. PG_TEST_URL=postgresql:///postgres). " \
           "See test/test_pg.rb header for the docker recipe."
    end
    super
  end

  TBL = "tep_test_pg_#{$$}"

  # Build the app source with the PG_URL + table name interpolated in
  # at class load time. The heredoc body is a regular Ruby string in
  # the harness; the inline-quoted constants land as string literals
  # in the compiled binary.
  app_source <<~RB
    require 'sinatra'
    require "tep/pg"          # opt-in PG backend (#216)

    # The PG test app runs under the default prefork server. We
    # exercise the async surface explicitly via /async_exec and
    # /async_params routes (which call Connection#async_exec
    # directly); io_wait falls back to single-shot poll(2)
    # outside scheduled context so async correctness is
    # measurable here regardless of server choice. The
    # multi-fiber concurrency win that scheduled gives is
    # measured in bench/pg_pool_bench.rb (which DOES boot under
    # Scheduled).

    PG_URL = "#{PG_URL}"
    TBL    = "#{TBL}"

    on_start do
      c = PG.connect(PG_URL)
      if c.connected?
        # Drop on every boot so re-running tests is idempotent.
        r = c.exec("DROP TABLE IF EXISTS " + TBL)
        r.clear
        r = c.exec("CREATE TABLE " + TBL +
                   " (id SERIAL PRIMARY KEY, body TEXT NOT NULL, n INTEGER, opt TEXT)")
        r.clear
        # Seed three rows so reads-without-prior-writes have something.
        r = c.exec_params("INSERT INTO " + TBL + " (body, n, opt) VALUES ($1, $2, $3)",
                          ["alpha", 1, "first"])
        r.clear
        r = c.exec_params("INSERT INTO " + TBL + " (body, n, opt) VALUES ($1, $2, $3)",
                          ["beta",  2, nil])
        r.clear
        r = c.exec_params("INSERT INTO " + TBL + " (body, n, opt) VALUES ($1, $2, $3)",
                          ["gamma's",  3, "third"])
        r.clear
        c.close
      end
    end

    # GET /version -- banner-style libpq + server version.
    get '/version' do
      c = PG.connect(PG_URL)
      out = "libpq=" + PG.libpq_version + " server=" + c.server_version.to_s
      c.close
      out
    end

    # GET /connect_ok -- did the connect succeed?
    get '/connect_ok' do
      c = PG.connect(PG_URL)
      out = c.connected? ? "ok" : ("fail:" + c.last_error_message)
      c.close
      out
    end

    # GET /select_const -- one-row, two-col round-trip.
    get '/select_const' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT 1 AS one, 'hello' AS greeting")
      out = "rows=" + r.ntuples.to_s + " cols=" + r.nfields.to_s +
            " row0=[" + r.getvalue(0, 0) + "," + r.getvalue(0, 1) + "]"
      r.clear
      c.close
      out
    end

    # GET /seed_count -- number of seeded rows (>= 3).
    get '/seed_count' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT count(*) FROM " + TBL)
      n = r.getvalue(0, 0)
      r.clear
      c.close
      "count=" + n
    end

    # GET /iter -- indexed iteration via getvalue. PG::Result#each_row
    # and #each are blocked on matz/spinel#628 (yield-of-typed-container
    # loses type at the block-local binding); both return wrong values
    # silently today. The methods stay defined in pg.rb so they light
    # up automatically when #628 lands; for now the v1 iteration story
    # is the explicit while loop below.
    get '/iter' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT body FROM " + TBL + " ORDER BY id")
      out = ""
      i = 0
      n = r.ntuples
      while i < n
        out = out + r.getvalue(i, 0) + ","
        i += 1
      end
      r.clear
      c.close
      "bodies=" + out
    end

    # GET /fields_and_fnumber -- shape of fields + fnumber lookup.
    get '/fields_and_fnumber' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT id, body, n, opt FROM " + TBL + " LIMIT 1")
      out = "fields=" + r.fields.join(",") +
            " fnumber_body=" + r.fnumber("body").to_s +
            " fnumber_missing=" + r.fnumber("nope").to_s
      r.clear
      c.close
      out
    end

    # GET /values -- the full values() shape.
    get '/values' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT body FROM " + TBL + " WHERE body IN ('alpha','beta') ORDER BY body")
      v = r.values
      out = "type=array(" + v.length.to_s + "x" + v[0].length.to_s + ") " +
            "row0_col0=" + v[0][0] + " row1_col0=" + v[1][0]
      r.clear
      c.close
      out
    end

    # GET /column_values -- single-column slice.
    get '/column_values' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT body FROM " + TBL + " ORDER BY id")
      cv = r.column_values(0)
      out = "len=" + cv.length.to_s + " first=" + cv[0] + " last=" + cv[cv.length - 1]
      r.clear
      c.close
      out
    end

    # GET /null -- find the seeded row with opt IS NULL via
    # getisnull. The seeded "beta" row (id <= 3 by construction)
    # is the canonical NULL holder; other tests may insert more
    # NULL-opt rows so we filter by id to keep this deterministic.
    get '/null' do
      c = PG.connect(PG_URL)
      r = c.exec("SELECT body, opt FROM " + TBL + " WHERE id <= 3 ORDER BY id")
      found = "none"
      n = r.ntuples
      i = 0
      while i < n
        if r.getisnull(i, 1)
          found = r.getvalue(i, 0)
        end
        i += 1
      end
      r.clear
      c.close
      "null_opt_for=" + found
    end

    # POST /insert -- exec_params with positional binds, RETURNING id.
    post '/insert' do
      c = PG.connect(PG_URL)
      r = c.exec_params(
        "INSERT INTO " + TBL + " (body, n) VALUES ($1, $2) RETURNING id",
        [params[:body], params[:n].to_i])
      id = r.getvalue(0, 0)
      r.clear
      c.close
      "inserted_id=" + id
    end

    # GET /by_id/:id -- read-back the inserted row.
    get '/by_id/:id' do
      c = PG.connect(PG_URL)
      r = c.exec_params("SELECT body, n FROM " + TBL + " WHERE id = $1",
                        [params[:id]])
      if r.ntuples == 0
        out = "not_found"
      else
        out = "body=" + r.getvalue(0, 0) + " n=" + r.getvalue(0, 1)
      end
      r.clear
      c.close
      out
    end

    # GET /int_round_trip -- exec_params with an Integer; libpq's
    # text format means the returned getvalue is the string "42".
    get '/int_round_trip' do
      c = PG.connect(PG_URL)
      r = c.exec_params("SELECT $1::int + 0", [42])
      out = r.getvalue(0, 0)
      r.clear
      c.close
      "val=" + out
    end

    # GET /quote_string -- params containing single quotes don't
    # break the SQL (proves binds aren't string-interpolated).
    get '/quote_string' do
      c = PG.connect(PG_URL)
      r = c.exec_params("SELECT $1::text", ["O'Brien"])
      out = r.getvalue(0, 0)
      r.clear
      c.close
      "val=" + out
    end

    # GET /escape_literal -- in case anyone DOES need to interpolate.
    get '/escape_literal' do
      c = PG.connect(PG_URL)
      out = c.escape_literal("O'Brien")
      c.close
      "lit=" + out
    end

    # GET /escape_identifier -- table/column names.
    get '/escape_identifier' do
      c = PG.connect(PG_URL)
      out = c.escape_identifier("users")
      c.close
      "ident=" + out
    end

    # GET /missing_table -- error path; exec raises PG::UndefinedTable.
    get '/missing_table' do
      c = PG.connect(PG_URL)
      out = ""
      begin
        r = c.exec("SELECT * FROM tep_no_such_table_anywhere")
        r.clear
        out = "raised=no"
      rescue PG::UndefinedTable => e
        out = "raised=UndefinedTable" +
              " sqlstate=" + c.last_sqlstate +
              " match42P01=" + (c.last_sqlstate == "42P01" ? "yes" : "no") +
              " is_pg_error=" + (e.is_a?(PG::Error) ? "yes" : "no")
      end
      c.close
      out
    end

    # GET /unique_violation -- duplicate PK INSERT raises
    # PG::UniqueViolation (SQLSTATE 23505).
    get '/unique_violation' do
      c = PG.connect(PG_URL)
      # Clear any leftover row from a prior crashed run so the first
      # INSERT below reliably succeeds.
      rd = c.exec_params("DELETE FROM " + TBL + " WHERE id = $1", ["99001"])
      rd.clear
      r1 = c.exec_params("INSERT INTO " + TBL + " (id, body) VALUES ($1, $2)",
                         ["99001", "duplicate"])
      r1.clear
      out = ""
      begin
        r2 = c.exec_params("INSERT INTO " + TBL + " (id, body) VALUES ($1, $2)",
                          ["99001", "duplicate"])
        r2.clear
        out = "first_ok=yes second_raised=no"
      rescue PG::UniqueViolation => e
        out = "first_ok=yes second_raised=UniqueViolation" +
              " sqlstate=" + c.last_sqlstate +
              " is_pg_error=" + (e.is_a?(PG::Error) ? "yes" : "no")
      end
      r3 = c.exec_params("DELETE FROM " + TBL + " WHERE id = $1", ["99001"])
      r3.clear
      c.close
      out
    end

    # GET /tx_commit -- transaction with COMMIT writes survive.
    get '/tx_commit' do
      c = PG.connect(PG_URL)
      r = c.exec("BEGIN"); r.clear
      r = c.exec_params("INSERT INTO " + TBL + " (body) VALUES ($1) RETURNING id",
                        ["tx-commit-row"])
      id = r.getvalue(0, 0)
      r.clear
      r = c.exec("COMMIT"); r.clear
      # Read back in a fresh statement (already inside same conn, fine).
      r = c.exec_params("SELECT body FROM " + TBL + " WHERE id = $1", [id])
      out = "id=" + id + " body=" + r.getvalue(0, 0)
      r.clear
      r = c.exec_params("DELETE FROM " + TBL + " WHERE id = $1", [id])
      r.clear
      c.close
      out
    end

    # GET /tx_rollback -- transaction with ROLLBACK doesn't persist.
    get '/tx_rollback' do
      c = PG.connect(PG_URL)
      r = c.exec("BEGIN"); r.clear
      r = c.exec_params("INSERT INTO " + TBL + " (body) VALUES ($1) RETURNING id",
                        ["tx-rollback-row"])
      id = r.getvalue(0, 0)
      r.clear
      r = c.exec("ROLLBACK"); r.clear
      # Should NOT be in the table now.
      r = c.exec_params("SELECT count(*) FROM " + TBL + " WHERE id = $1", [id])
      n = r.getvalue(0, 0)
      r.clear
      c.close
      "after_rollback_count=" + n
    end

    # GET /cmd_status -- COMMAND-style result reports the libpq
    # cmd_status string for an UPDATE.
    get '/cmd_status' do
      c = PG.connect(PG_URL)
      r = c.exec_params("UPDATE " + TBL + " SET n = n WHERE body = $1", ["alpha"])
      out = "status=[" + r.cmd_status + "] tuples=" + r.cmd_tuples.to_s
      r.clear
      c.close
      out
    end

    # GET /many_results -- open many concurrent results to verify
    # the slot table doesn't fall over under load.
    get '/many_results' do
      c = PG.connect(PG_URL)
      held = [0]
      held.delete_at(0)
      i = 0
      while i < 20
        r = c.exec("SELECT " + i.to_s)
        held.push(r.rh)
        i += 1
      end
      # Now read each held result + free.
      sum = 0
      j = 0
      while j < held.length
        r = PG::Result.new(held[j])
        sum += r.getvalue(0, 0).to_i
        r.clear
        j += 1
      end
      c.close
      "sum=" + sum.to_s
    end

    # -------- PG::Pool routes --------
    POOL = PG::Pool.new(PG_URL, 4)

    # GET /pool_size -- pool was constructed with 4 conns; all
    # should be open + healthy.
    get '/pool_size' do
      "size=" + POOL.size.to_s +
        " available=" + POOL.available.to_s +
        " healthy=" + (POOL.healthy? ? "yes" : "no")
    end

    # GET /pool_query -- checkout, run a query, checkin. Verifies
    # the pool conns are usable.
    get '/pool_query' do
      c = POOL.checkout
      r = c.exec("SELECT 1 AS one, 'pool' AS src")
      out = r.getvalue(0, 0) + "/" + r.getvalue(0, 1)
      r.clear
      POOL.checkin(c)
      "val=" + out
    end

    # GET /pool_drain_refill -- checkout 2, observe drained
    # count, checkin both, observe refilled count.
    get '/pool_drain_refill' do
      n = POOL.size
      c1 = POOL.checkout
      c2 = POOL.checkout
      drained_avail = POOL.available
      POOL.checkin(c2)
      POOL.checkin(c1)
      refilled_avail = POOL.available
      "size=" + n.to_s +
        " drained=" + drained_avail.to_s +
        " refilled=" + refilled_avail.to_s
    end

    # GET /async_exec -- explicit async path. Under Scheduled
    # this exercises PQsendQuery + io_wait; under prefork it's
    # still correct (io_wait falls back to a single-shot poll).
    get '/async_exec' do
      c = POOL.checkout
      r = c.async_exec("SELECT 'async-hello'")
      out = r.getvalue(0, 0)
      r.clear
      POOL.checkin(c)
      "val=" + out
    end

    # GET /async_params -- async with $1 bind.
    get '/async_params/:n' do
      c = POOL.checkout
      r = c.async_exec_params("SELECT $1::int * 7", [params[:n]])
      out = r.getvalue(0, 0)
      r.clear
      POOL.checkin(c)
      "val=" + out
    end

    # GET /pool_reusable -- a conn returned to the pool is
    # actually usable again. checkout, exec, checkin, checkout,
    # exec -- verify the second exec works.
    get '/pool_reusable' do
      c1 = POOL.checkout
      r1 = c1.exec("SELECT 1")
      v1 = r1.getvalue(0, 0)
      r1.clear
      POOL.checkin(c1)
      c2 = POOL.checkout
      r2 = c2.exec("SELECT 2")
      v2 = r2.getvalue(0, 0)
      r2.clear
      POOL.checkin(c2)
      "first=" + v1 + " second=" + v2
    end

    # GET /pool_exhaust -- drain every connection, then a further
    # checkout past the (lowered) timeout raises PG::PoolExhausted.
    # Verifies the raise is rescuable both as the exact class and via
    # the PG::Error parent. Restores the pool + timeout before
    # returning so the route is idempotent across test runs.
    get '/pool_exhaust' do
      POOL.set_checkout_timeout_ms(1)
      held = []
      n = POOL.size
      i = 0
      while i < n
        held.push(POOL.checkout)
        i += 1
      end
      exact = "no"
      parent = "no"
      begin
        POOL.checkout
      rescue PG::PoolExhausted => e
        exact = "yes"
      end
      begin
        POOL.checkout
      rescue PG::Error => e
        parent = "yes"
      end
      while held.length > 0
        POOL.checkin(held.delete_at(0))
      end
      POOL.set_checkout_timeout_ms(5000)
      "exact=" + exact + " parent=" + parent
    end
  RB

  def test_connect_succeeds
    res = get("/connect_ok")
    assert_equal "200", res.code
    assert_equal "ok", res.body
  end

  def test_libpq_and_server_version_render
    res = get("/version")
    assert_equal "200", res.code
    # libpq= matches major.minor.patch; server is an integer >= 100000.
    assert_match(/\Alibpq=\d+\.\d+\.\d+ server=\d{5,}\z/, res.body)
  end

  def test_select_const_round_trips
    res = get("/select_const")
    assert_equal "200", res.code
    assert_equal "rows=1 cols=2 row0=[1,hello]", res.body
  end

  def test_seed_rows_present
    res = get("/seed_count")
    assert_equal "200", res.code
    n = res.body.split("=").last.to_i
    assert n >= 3, "expected >= 3 seeded rows, got #{n} (body=#{res.body})"
  end

  def test_indexed_iteration_via_getvalue
    res = get("/iter")
    assert_match(/^bodies=/, res.body)
    bodies = res.body.split("=", 2).last
    assert_includes bodies, "alpha"
    assert_includes bodies, "beta"
    assert_includes bodies, "gamma's"
  end

  # test_each_row_yields_array / test_each_yields_hash -- deferred.
  # Both block on matz/spinel#628 (yield of typed Array / Hash loses
  # type at the block-local binding). The methods stay in pg.rb;
  # tests light up automatically when #628 lands.

  def test_fields_and_fnumber
    res = get("/fields_and_fnumber")
    assert_match(/fields=id,body,n,opt /, res.body)
    assert_includes res.body, "fnumber_body=1"
    assert_includes res.body, "fnumber_missing=-1"
  end

  def test_values_shape
    res = get("/values")
    assert_match(/\Atype=array\(2x1\)/, res.body)
    assert_includes res.body, "row0_col0=alpha"
    assert_includes res.body, "row1_col0=beta"
  end

  def test_column_values_returns_array
    res = get("/column_values")
    body = res.body
    assert_match(/^len=\d+ /, body)
    assert_includes body, "first=alpha"
  end

  def test_null_detected_via_getisnull
    res = get("/null")
    # Seeded "beta" row has opt=NULL.
    assert_equal "null_opt_for=beta", res.body
  end

  def test_exec_params_quoted_string_round_trip
    res = get("/quote_string")
    assert_equal "val=O'Brien", res.body
  end

  def test_exec_params_int_round_trip
    res = get("/int_round_trip")
    # libpq text format: the int comes back as the string "42".
    assert_equal "val=42", res.body
  end

  def test_insert_and_read_back
    res = post("/insert", "body=insert-test&n=99")
    assert_equal "200", res.code
    id = res.body.split("=").last
    assert id.to_i >= 1, "expected positive id, got #{id}"

    res2 = get("/by_id/#{id}")
    assert_match(/body=insert-test/, res2.body)
    assert_match(/n=99/, res2.body)
  end

  def test_missing_table_error_path
    res = get("/missing_table")
    # exec now RAISES PG::UndefinedTable (rescued in the route).
    assert_match(/raised=UndefinedTable/, res.body)
    assert_match(/sqlstate=42P01/, res.body)
    assert_match(/match42P01=yes/, res.body)
    # the leaf is a PG::Error (base rescue + is_a? walk the hierarchy).
    assert_match(/is_pg_error=yes/, res.body)
  end

  def test_unique_violation_reports_23505
    res = get("/unique_violation")
    # the duplicate INSERT raises PG::UniqueViolation; first succeeds.
    assert_match(/first_ok=yes/, res.body)
    assert_match(/second_raised=UniqueViolation/, res.body)
    assert_match(/sqlstate=23505/, res.body)
    assert_match(/is_pg_error=yes/, res.body)
  end

  def test_escape_literal_quotes_apostrophe
    res = get("/escape_literal")
    # libpq emits PostgreSQL's E'...' or '...' form; either should
    # contain a doubled-up '' for the embedded apostrophe.
    assert_match(/lit=.*'O''Brien'/, res.body)
  end

  def test_escape_identifier_quotes_name
    res = get("/escape_identifier")
    assert_equal "ident=\"users\"", res.body
  end

  def test_transaction_commit_persists
    res = get("/tx_commit")
    assert_match(/^id=\d+ body=tx-commit-row\z/, res.body)
  end

  def test_transaction_rollback_does_not_persist
    res = get("/tx_rollback")
    assert_equal "after_rollback_count=0", res.body
  end

  def test_cmd_status_for_update
    res = get("/cmd_status")
    # libpq cmd_status format: "UPDATE <rows_affected>".
    assert_match(/^status=\[UPDATE \d+\] tuples=\d+\z/, res.body)
  end

  def test_many_results_concurrent
    res = get("/many_results")
    # 20 rows numbered 0..19; sum is 190.
    assert_equal "sum=190", res.body
  end

  # -------- PG::Pool tests --------

  def test_pool_starts_healthy_with_full_free_list
    res = get("/pool_size")
    assert_equal "size=4 available=4 healthy=yes", res.body
  end

  def test_pool_checkout_returns_usable_connection
    res = get("/pool_query")
    assert_equal "val=1/pool", res.body
  end

  def test_pool_drains_and_refills
    res = get("/pool_drain_refill")
    # 2 checkouts -> drained=2; 2 checkins -> refilled=4 (back to size).
    assert_equal "size=4 drained=2 refilled=4", res.body
  end

  def test_pool_returned_connection_is_reusable
    res = get("/pool_reusable")
    assert_equal "first=1 second=2", res.body
  end

  def test_pool_exhaustion_raises_pool_exhausted
    res = get("/pool_exhaust")
    assert_equal "200", res.code
    # checkout past the timeout raises PG::PoolExhausted, caught both
    # as the exact class and via the PG::Error parent (matz/spinel#1041).
    assert_equal "exact=yes parent=yes", res.body
  end

  # --- async exec ---

  def test_async_exec_returns_same_result_as_sync
    res = get("/async_exec")
    assert_equal "val=async-hello", res.body
  end

  def test_async_exec_params_round_trip
    res = get("/async_params/6")
    assert_equal "val=42", res.body
  end
end
