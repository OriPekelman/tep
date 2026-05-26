require_relative "helper"

# Tep::SQLite#prepare_cached -- cache hit / miss / reset-on-finalize
# semantics. Backs the perf-leverage win documented in issue #75.
class TestSqliteCached < TepTest
  TMP_DB = "/tmp/tep_test_cache_#{$$}.db"

  app_source <<~RB
    require 'sinatra'

    on_start do
      db = Tep::SQLite.new
      if db.open("#{TMP_DB}")
        db.exec("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT)")
        db.exec("DELETE FROM items")
        db.prepare("INSERT INTO items (name) VALUES (?)")
        db.bind_str(1, "alpha")
        db.step
        db.reset
        db.bind_str(1, "beta")
        db.step
        db.reset
        db.bind_str(1, "gamma")
        db.step
        db.finalize
        db.close
      end
    end

    # Repeated prepare_cached with the SAME sql + DIFFERENT
    # bindings -- the cache reuse path must reset+clear_bindings
    # so the second call's binding wins.
    get '/cached_rebind' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      sql = "SELECT name FROM items WHERE id = ?"
      out = ""
      i = 1
      while i <= 3
        db.prepare_cached(sql)
        db.bind_int(1, i)
        if db.step == 1
          if out.length > 0
            out = out + ","
          end
          out = out + db.col_str(0)
        end
        db.finalize
        i += 1
      end
      db.close
      out
    end

    # Mix prepare + prepare_cached + prepare -- exercises both
    # paths in alternation. Uncached prepare after a cached one
    # must release the cached cursor via reset (NOT finalize),
    # leaving the cache slot valid for the next prepare_cached.
    get '/mixed_prepare' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      cached_sql = "SELECT name FROM items WHERE id = ?"
      # First cached hit (cache miss -> populate slot)
      db.prepare_cached(cached_sql)
      db.bind_int(1, 1)
      db.step
      first = db.col_str(0)
      db.finalize
      # Uncached prepare in between
      db.prepare("SELECT name FROM items WHERE id = ?")
      db.bind_int(1, 2)
      db.step
      middle = db.col_str(0)
      db.finalize
      # Cached hit again (slot still alive)
      db.prepare_cached(cached_sql)
      db.bind_int(1, 3)
      db.step
      last = db.col_str(0)
      db.finalize
      db.close
      first + "|" + middle + "|" + last
    end

    # Cache survives across a different db (per-handle scope) --
    # the cached_sql here belongs to db1; db2 with the same SQL
    # gets a separate cache slot.
    get '/per_handle' do
      sql = "SELECT name FROM items WHERE id = ?"
      db1 = Tep::SQLite.new
      db1.open("#{TMP_DB}")
      db1.prepare_cached(sql)
      db1.bind_int(1, 1)
      db1.step
      r1 = db1.col_str(0)
      db1.finalize
      db1.close   # close while a cache slot still exists for this handle

      db2 = Tep::SQLite.new
      db2.open("#{TMP_DB}")
      db2.prepare_cached(sql)
      db2.bind_int(1, 2)
      db2.step
      r2 = db2.col_str(0)
      db2.finalize
      db2.close
      r1 + "|" + r2
    end

    # Smoke: a tight loop of cached calls works without leaks --
    # exercises the cache hit path repeatedly with the same SQL.
    get '/loop_count' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      sql = "SELECT count(*) FROM items"
      n = 0
      i = 0
      while i < 50
        db.prepare_cached(sql)
        if db.step == 1
          n = db.col_int(0)
        end
        db.finalize
        i += 1
      end
      db.close
      "loops=" + i.to_s + " count=" + n.to_s
    end
  RB

  Minitest.after_run do
    File.unlink(TMP_DB) if File.exist?(TMP_DB)
  end

  def test_cache_hit_rebinds_correctly
    # Same SQL, three different bindings, three different rows.
    # If clear_bindings didn't fire, the int param would leak
    # across calls and rows would repeat.
    res = get("/cached_rebind")
    assert_equal "200", res.code
    assert_equal "alpha,beta,gamma", res.body
  end

  def test_mixed_prepare_paths_coexist
    # The uncached prepare in the middle must not invalidate the
    # cached slot for the surrounding prepare_cached calls.
    res = get("/mixed_prepare")
    assert_equal "200", res.code
    assert_equal "alpha|beta|gamma", res.body
  end

  def test_close_finalizes_cached_stmts_for_handle
    # /per_handle opens db1, caches a stmt, closes db1, opens db2,
    # caches the same SQL (separate slot), closes db2. If close()
    # didn't finalize db1's cached stmt, sqlite3_close would
    # SQLITE_BUSY and the second open would land an invalid handle.
    res = get("/per_handle")
    assert_equal "200", res.code
    assert_equal "alpha|beta", res.body
  end

  def test_loop_of_cached_calls_no_leak
    # 50 reuses of the same cached SQL. If the cache flag handling
    # was wrong, sqlite would either leak or error out around
    # iteration 16+ (SQLITE_MAX_STATEMENT_PARAMETERS / stack
    # exhaustion).
    res = get("/loop_count")
    assert_equal "200", res.code
    assert_match(/loops=50 count=3/, res.body)
  end
end
