# PG-with-pool benchmark for tep -- same workload as
# bench/pg_bench.rb (SELECT-by-id + JSON encode against a seeded
# 1000-row `users` table) but uses PG::Pool to hold multiple
# connections per worker instead of one.
#
# Per-worker pool size N: each worker can serve N concurrent PG
# queries (e.g. 4 workers x 8 pool = 32 in-flight, matching Puma's
# default 4-threads-per-worker shape).
#
# Run:
#   tep build bench/pg_pool_bench.rb -o bench/pg_pool_bench
#   PG_URL='...' POOL_SIZE=8 ./bench/pg_pool_bench -p 4567 -w 4
#   wrk -t8 -c256 -d10s 'http://127.0.0.1:4567/users/42'
require 'sinatra'

# Note: this bench currently boots under the default prefork
# server. Pool-under-Scheduled is its own follow-up: the
# checkout-on-empty path needs a proper waiter queue (an
# io_wait-style park-and-wake) rather than the spin-via-pause
# v1 ships. Tracked in docs/PG-BATTERY.md's "Pool" section.
# Until then, prefork with one PG conn per worker (the existing
# bench/pg_bench.rb) is the apples-to-apples comparison; this
# pool bench measures the per-worker multi-conn cost which is
# the wrong axis for the SO_REUSEPORT-distributed workload.

PG_URL = ENV["PG_URL"] != nil && ENV["PG_URL"].length > 0 ? ENV["PG_URL"] : "postgresql:///postgres"
POOL_SIZE = ENV["POOL_SIZE"] != nil && ENV["POOL_SIZE"].length > 0 ? ENV["POOL_SIZE"].to_i : 8

# Per-worker pool. Tep's prefork model gives each worker its own
# process, so each Pool is naturally isolated. Opened in on_start
# (runs in every worker before the accept loop).
POOL = PG::Pool.new(PG_URL, POOL_SIZE)

on_start do
  # Seed once at boot through any pool conn (the schema is shared
  # across all conns in the pool; one connect-time CREATE TABLE
  # suffices).
  c = POOL.checkout
  r = c.exec("CREATE TABLE IF NOT EXISTS users (" +
             "id INTEGER PRIMARY KEY, name TEXT, email TEXT, active INTEGER)")
  r.clear
  r = c.exec("SELECT count(*) FROM users")
  n = r.getvalue(0, 0).to_i
  r.clear
  if n == 0
    r = c.exec("BEGIN"); r.clear
    i = 1
    while i <= 1000
      r = c.exec_params(
        "INSERT INTO users (id, name, email, active) VALUES ($1, $2, $3, $4)",
        [i, "User " + i.to_s, "u" + i.to_s + "_at_example.com", i % 2])
      r.clear
      i += 1
    end
    r = c.exec("COMMIT"); r.clear
  end
  POOL.checkin(c)
end

get '/users/:id' do
  id = params[:id].to_i
  if id < 1 || id > 1000
    res.set_status(404)
    res.headers["Content-Type"] = "application/json"
    return "{\"error\":\"not found\"}"
  end

  c = POOL.checkout
  r = c.exec_params(
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
  POOL.checkin(c)

  res.headers["Content-Type"] = "application/json"
  body
end
