# PG benchmark for tep -- mirrors bench/api_bench.rb (SQLite version)
# but exercises the PG battery against a real PostgreSQL.
#
# Same "fetch a user by id" shape; the diff from api_bench is the
# storage backend. Useful as the apples-to-apples comparison point
# for roundhouse's Rails-shape benches: same workload, three rails
# in the workload-complexity continuum (microbench / Tep-Sinatra /
# Rails-roundhouse).
#
# Seeds 1000 rows once at startup; each prefork worker opens its
# own PG::Connection in on_start. Requests pick rows via /users/:id.
#
# Run:
#   tep build bench/pg_bench.rb -o bench/pg_bench
#   PG_URL='postgresql://postgres:postgres@host/postgres' \
#     ./bench/pg_bench -p 4567 -w 8
#   wrk -t8 -c256 -d10s 'http://127.0.0.1:4567/users/42'
require 'sinatra'

PG_URL = ENV["PG_URL"] != nil && ENV["PG_URL"].length > 0 ? ENV["PG_URL"] : "postgresql:///postgres"

# Per-worker PG handle. Tep's prefork model gives each worker its
# own process, so each Connection is naturally isolated. Opened in
# on_start (runs in every worker before the accept loop).
DB = PG::Connection.new(PG_URL)

on_start do
  # idempotent schema + 1000-row seed
  r = DB.exec("CREATE TABLE IF NOT EXISTS users (" +
              "id INTEGER PRIMARY KEY, name TEXT, email TEXT, active INTEGER)")
  r.clear
  r = DB.exec("SELECT count(*) FROM users")
  n = r.getvalue(0, 0).to_i
  r.clear
  if n == 0
    r = DB.exec("BEGIN"); r.clear
    i = 1
    while i <= 1000
      r = DB.exec_params(
        "INSERT INTO users (id, name, email, active) VALUES ($1, $2, $3, $4)",
        [i, "User " + i.to_s, "u" + i.to_s + "_at_example.com", i % 2])
      r.clear
      i += 1
    end
    r = DB.exec("COMMIT"); r.clear
  end
end

get '/users/:id' do
  id = params[:id].to_i
  if id < 1 || id > 1000
    res.set_status(404)
    res.headers["Content-Type"] = "application/json"
    return "{\"error\":\"not found\"}"
  end

  r = DB.exec_params(
    "SELECT id, name, email, active FROM users WHERE id = $1",
    [id])

  body = ""
  if r.ntuples > 0
    uid    = r.getvalue(0, 0).to_i
    name   = r.getvalue(0, 1)
    email  = r.getvalue(0, 2)
    active = r.getvalue(0, 3).to_i
    body = "{" +
      Tep::Json.encode_pair_int("id", uid)     + "," +
      Tep::Json.encode_pair_str("name", name)  + "," +
      Tep::Json.encode_pair_str("email", email) + "," +
      Tep::Json.encode_pair_int("active", active) +
    "}"
  else
    body = "{\"error\":\"not found\"}"
  end
  r.clear

  res.headers["Content-Type"] = "application/json"
  body
end
