require_relative "helper"

# Tep::SQLite -- a thin libsqlite3 binding wired through spinel's
# FFI DSL. Tests cover: basic CRUD, parameterised insert + select,
# multi-row iteration, last_rowid, and a per-test temp .db file
# so test order is irrelevant.
class TestSqlite < TepTest
  TMP_DB = "/tmp/tep_test_#{$$}.db"

  app_source <<~RB
    require 'sinatra'

    on_start do
      db = Tep::SQLite.new
      if db.open("#{TMP_DB}")
        db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT)")
        db.exec("DELETE FROM notes")
        db.prepare("INSERT INTO notes (body) VALUES (?)")
        db.bind_str(1, "first note")
        db.step
        db.reset
        db.bind_str(1, "second note")
        db.step
        db.reset
        db.bind_str(1, "third note")
        db.step
        db.finalize
        db.close
      end
    end

    get '/note/:id' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      body = db.first_str("SELECT body FROM notes WHERE id = ?", params[:id])
      db.close
      "id=" + params[:id] + " body=" + body
    end

    get '/notes' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      out = ""
      db.prepare("SELECT id, body FROM notes ORDER BY id")
      while db.step == 1
        out = out + db.col_int(0).to_s + ":" + db.col_str(1) + "\\n"
      end
      db.finalize
      db.close
      out
    end

    get '/count' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      n = db.first_int("SELECT count(*) FROM notes", "")
      db.close
      "count=" + n.to_s
    end

    post '/notes' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      db.prepare("INSERT INTO notes (body) VALUES (?)")
      db.bind_str(1, params[:body])
      db.step
      db.finalize
      id = db.last_rowid
      db.close
      "inserted=" + id.to_s
    end

    # 64-bit round-trip (issue #171): bind a value > 2^31 via bind_int,
    # read it back via col_int. With the old 32-bit path this wrapped
    # negative (3427544687 -> -867422609); now it must survive intact.
    get '/bigint' do
      db = Tep::SQLite.new
      db.open("#{TMP_DB}")
      db.exec("CREATE TABLE IF NOT EXISTS bignums (n INTEGER)")
      db.exec("DELETE FROM bignums")
      db.prepare("INSERT INTO bignums (n) VALUES (?)")
      db.bind_int(1, 3427544687)
      db.step
      db.finalize
      db.prepare("SELECT n FROM bignums LIMIT 1")
      db.step
      n = db.col_int(0)
      db.finalize
      db.close
      "n=" + n.to_s
    end
  RB

  Minitest.after_run do
    File.unlink(TMP_DB) if File.exist?(TMP_DB)
  end

  def test_first_str_with_param
    res = get("/note/1")
    assert_equal "200", res.code
    assert_equal "id=1 body=first note", res.body.strip
  end

  def test_first_str_missing_row_returns_empty
    res = get("/note/9999")
    assert_equal "200", res.code
    assert_equal "id=9999 body=", res.body.strip
  end

  # Tests that mutate are written to be order-independent: minitest
  # randomises seed-shuffled order and the test app boots once per
  # class (on_start runs once), so reads-then-writes-then-reads in
  # an arbitrary order all need to make sense.

  def test_iterate_all_rows_has_seeded_bodies
    res = get("/notes")
    assert_equal "200", res.code
    body = res.body
    assert_match(/:first note$/, body)
    assert_match(/:second note$/, body)
    assert_match(/:third note$/, body)
  end

  def test_first_int_returns_at_least_seed_count
    res = get("/count")
    assert_equal "200", res.code
    n = res.body.strip.split("=").last.to_i
    assert n >= 3, "expected count >= 3, got #{n}"
  end

  def test_insert_and_last_rowid_round_trips
    res = post("/notes", "body=via-test")
    assert_equal "200", res.code
    inserted_id = res.body.strip.split("=").last.to_i
    assert inserted_id >= 1, "expected a positive rowid, got #{inserted_id}"

    res2 = get("/note/#{inserted_id}")
    assert_match(/body=via-test/, res2.body)
  end

  def test_bind_and_col_int_round_trip_64bit
    # 3,427,544,687 > 2^31-1. The old 32-bit bind/col path truncated it
    # to -867,422,609 (issue #171); 64-bit bind_int/col_int preserve it.
    res = get("/bigint")
    assert_equal "200", res.code
    assert_equal "n=3427544687", res.body
  end
end
