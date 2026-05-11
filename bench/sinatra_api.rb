require 'sinatra'
require 'sqlite3'
require 'json'

set :bind,    '127.0.0.1'
set :port,    4570
set :logging, false
set :show_exceptions, false
disable :protection

DB_PATH = ENV.fetch('TEP_BENCH_DB', '/tmp/tep_api_bench.db')

def db
  Thread.current[:db] ||= SQLite3::Database.new(DB_PATH).tap do |d|
    d.execute("PRAGMA journal_mode=WAL")
    d.execute("PRAGMA synchronous=NORMAL")
  end
end

# Seed (idempotent). Same shape as the tep app's seed.
def seed_db!
  d = SQLite3::Database.new(DB_PATH)
  d.execute("CREATE TABLE IF NOT EXISTS users (" \
            "id INTEGER PRIMARY KEY, name TEXT, email TEXT, active INTEGER)")
  n = d.execute("SELECT count(*) FROM users").first[0]
  if n == 0
    d.execute("BEGIN")
    1000.times do |i|
      d.execute("INSERT INTO users (id, name, email, active) VALUES (?, ?, ?, ?)",
                [i + 1, "User #{i + 1}", "u#{i + 1}@example.com", (i + 1) % 2])
    end
    d.execute("COMMIT")
  end
  d.close
end

seed_db!

get '/users/:id' do
  content_type 'application/json'
  id = params[:id].to_i
  if id < 1 || id > 1000
    halt 404, '{"error":"not found"}'
  end
  row = db.execute("SELECT id, name, email, active FROM users WHERE id = ?", [id]).first
  if row.nil?
    halt 404, '{"error":"not found"}'
  end
  { id: row[0], name: row[1], email: row[2], active: row[3] }.to_json
end
