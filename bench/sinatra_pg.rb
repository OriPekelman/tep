require 'sinatra'
require 'pg'
require 'json'

set :bind,    '127.0.0.1'
set :port,    4570
set :logging, false
set :show_exceptions, false
disable :protection

PG_URL = ENV.fetch("PG_URL", "postgresql:///postgres")

def db
  Thread.current[:db] ||= PG::Connection.new(PG_URL)
end

# Idempotent schema + 1000-row seed. Mirrors bench/pg_bench.rb.
def seed_db!
  c = PG::Connection.new(PG_URL)
  c.exec("CREATE TABLE IF NOT EXISTS users (" \
         "id INTEGER PRIMARY KEY, name TEXT, email TEXT, active INTEGER)")
  n = c.exec("SELECT count(*) FROM users").getvalue(0, 0).to_i
  if n == 0
    c.exec("BEGIN")
    1000.times do |i|
      c.exec_params(
        "INSERT INTO users (id, name, email, active) VALUES ($1, $2, $3, $4)",
        [i + 1, "User #{i + 1}", "u#{i + 1}@example.com", (i + 1) % 2])
    end
    c.exec("COMMIT")
  end
  c.close
end

seed_db!

get '/users/:id' do
  content_type 'application/json'
  id = params[:id].to_i
  if id < 1 || id > 1000
    halt 404, '{"error":"not found"}'
  end
  r = db.exec_params("SELECT id, name, email, active FROM users WHERE id = $1", [id])
  if r.ntuples == 0
    halt 404, '{"error":"not found"}'
  end
  row = r.first
  { id: row["id"].to_i,
    name: row["name"],
    email: row["email"],
    active: row["active"].to_i }.to_json
end
