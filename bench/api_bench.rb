# API benchmark for tep -- exercises more of the stack than hello:
# SQLite SELECT-by-id + JSON encode. Same shape as a typical
# "fetch a user by id" route in a real app.
#
# DB is seeded once at startup (deterministic 1000 rows) via the
# `on_start do ... end` block; each prefork worker shares the same
# file but opens its own per-process handle (the C side caps at 16
# concurrent handles, so we don't want to open-per-request under
# heavy concurrent load). Requests pick rows via /users/:id.
#
# Run:
#   tep build bench/api_bench.rb -o bench/api_bench
#   ./bench/api_bench -p 4567 --workers 8
#   wrk -t8 -c256 -d10s 'http://127.0.0.1:4567/users/42'
require 'sinatra'

DB_PATH = ENV.fetch("TEP_BENCH_DB", "/tmp/tep_api_bench.db")

# Per-worker DB handle. Tep's prefork model gives each worker its
# own process, so a single Tep::SQLite instance is naturally
# isolated. Opened in on_start (which runs in each worker before
# the accept loop).
DB = Tep::SQLite.new

on_start do
  if DB.open(DB_PATH)
    DB.exec("PRAGMA journal_mode=WAL")
    DB.exec("PRAGMA synchronous=NORMAL")
    DB.exec("CREATE TABLE IF NOT EXISTS users (" +
            "id INTEGER PRIMARY KEY, name TEXT, email TEXT, active INTEGER)")
    n = DB.first_int("SELECT count(*) FROM users", "")
    if n == 0
      DB.exec("BEGIN")
      i = 1
      while i <= 1000
        DB.prepare("INSERT INTO users (id, name, email, active) VALUES (?, ?, ?, ?)")
        DB.bind_int(1, i)
        DB.bind_str(2, "User " + i.to_s)
        DB.bind_str(3, "u" + i.to_s + "_at_example.com")
        DB.bind_int(4, i % 2)
        DB.step
        DB.finalize
        i += 1
      end
      DB.exec("COMMIT")
    end
  end
end

get '/users/:id' do
  id = params[:id].to_i
  if id < 1 || id > 1000
    res.set_status(404)
    res.headers["Content-Type"] = "application/json"
    return "{\"error\":\"not found\"}"
  end

  DB.prepare("SELECT id, name, email, active FROM users WHERE id = ?")
  DB.bind_int(1, id)

  body = ""
  if DB.step == 1
    uid    = DB.col_int(0)
    name   = DB.col_str(1)
    email  = DB.col_str(2)
    active = DB.col_int(3)
    body = "{" +
      Tep::Json.encode_pair_int("id", uid)     + "," +
      Tep::Json.encode_pair_str("name", name)  + "," +
      Tep::Json.encode_pair_str("email", email) + "," +
      Tep::Json.encode_pair_int("active", active) +
    "}"
  else
    body = "{\"error\":\"not found\"}"
  end
  DB.finalize

  res.headers["Content-Type"] = "application/json"
  body
end
