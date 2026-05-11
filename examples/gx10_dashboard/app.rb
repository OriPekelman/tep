# gx10 dashboard -- the flagship demo. A small Sinatra-style tep
# app that surfaces "is the box happy" for the home GB10 server:
#
#   - GPU temp + utilization                  (nvidia-smi)
#   - inference backends                      (~/gx10_config/bin/inference)
#   - load + memory                           (/proc/loadavg, /proc/meminfo)
#   - active tmux sessions                    (tmux ls)
#   - running docker projects                 (docker ps)
#   - sites in ~/sites and their last commit  (git log)
#   - a tiny todo list for the operator       (SQLite)
#
# Every public tep feature gets a turn here:
#
#   routes (GET/POST/DELETE) + Sinatra-classic `do ... end`
#   ERB + Mustache views with @ivar locals
#   before / after filters + custom not_found
#   `send_file 'path'`                      (the system-state snapshot)
#   `__END__` inline templates              (the footer partial)
#   `configure { ... }`                     (env-keyed dev/prod knobs)
#   Sessions (signed cookies)               (web login)
#   Tep::Streamer + SSE                     (live status pump)
#   Tep::SQLite                             (todos)
#   Tep::Json (object + array + hash)       (JSON wire format)
#   Tep::Logger                             (per-request trace, file-backed)
#   Tep::Jwt (HS256)                        (POST /api/token + Bearer auth)
#   Tep::Password (PBKDF2)                  (login + token issue)
#   Tep::Security::Cors                     (open CORS on /api/*)
#   Tep::Security::Headers                  (HSTS + nosniff + frame-options)
#   Tep::Assets                             (bundled CSS + logo SVG)
#   Tep::Scheduler                          (SSE pump via cooperative sleep)
#   Tep::Shell                              (popen + /proc reads, everywhere)
#
# Build + run:
#
#     bin/tep build examples/gx10_dashboard/app.rb -o /tmp/gx10dash
#     TEP_DASH_PASSWORD=letmein /tmp/gx10dash -p 4500
#
# Open http://gx10:4500/ in a browser. Default user is "operator";
# password comes from TEP_DASH_PASSWORD (the app refuses to start
# without it set, so there's never a hardcoded credential).

require 'sinatra'

# Config -- everything env-driven so the same binary works in dev
# (loose CORS, console logs) and prod (HSTS, file logs).
DASH_USER       = ENV.fetch("TEP_DASH_USER",     "operator")
DASH_PASSWORD   = ENV.fetch("TEP_DASH_PASSWORD", "")
DB_PATH         = ENV.fetch("TEP_DASH_DB",       "/tmp/tep_dash.db")
LOG_PATH        = ENV.fetch("TEP_DASH_LOG",      "")
JWT_SECRET      = ENV.fetch("TEP_JWT_SECRET",    "dev-jwt-secret-change-me")
SESSION_SECRET  = ENV.fetch("TEP_SESSION_SECRET","dev-session-secret-change-me")
SITES_ROOT      = ENV.fetch("TEP_DASH_SITES",    "/home/oripekelman/sites")
SNAPSHOT_PATH   = ENV.fetch("TEP_DASH_SNAPSHOT", "/home/oripekelman/gx10_config/docs/system-state.md")
STREAM_MAX      = 30   # seconds; SSE pump self-closes after this and
                       # the client reconnects (so we don't pin a
                       # worker forever).
TICK_SECONDS    = 3    # SSE update cadence

# Prefork so a long-running SSE subscriber on /api/events doesn't pin
# the only worker against every other request. Two is plenty for a
# single-operator dashboard; bump via `-w N` on the CLI if you wire
# multiple clients into the live feed.
set :workers, 2

Tep.session_secret = SESSION_SECRET

LOGGER = Tep::Logger.new
LOGGER.set_level("info")

configure :production do
  if LOG_PATH.length > 0
    LOGGER.to_file(LOG_PATH)
  end
end

configure :development do
  LOGGER.to_stderr
end

# CORS is open on /api/* only; the web routes set their own cookies
# and don't want a permissive Origin. The dashboard server itself
# decides whether a request is /api/ inside the before-filter.
CORS = Tep::Security::Cors.new
CORS.set_origin("*")
CORS.set_allowed_verbs("GET,POST,DELETE,OPTIONS")
CORS.set_allowed_headers("Content-Type,Authorization")

# Security headers go on every response. HSTS is opt-in (we only
# emit the header when configured to a positive number; setting it
# without HTTPS in front would lock browsers out of the http://
# variant).
HEADERS = Tep::Security::Headers.new
HEADERS.set_hsts(ENV.fetch("TEP_DASH_HSTS", "0").to_i)
Tep.after HEADERS

set :views, File.expand_path("views", __dir__)

# -------------------------------------------------------------------
# Schema -- a single `todos` table. The operator scribbles a wish list
# into the dashboard; nothing here syncs with anything else.
# -------------------------------------------------------------------

on_start do
  if DASH_PASSWORD.length == 0
    puts "tep dashboard: refusing to start without TEP_DASH_PASSWORD set"
    exit(1)
  end
  db = Tep::SQLite.new
  if db.open(DB_PATH)
    db.exec("CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY, body TEXT, done INTEGER, created_at INTEGER)")
    db.exec("CREATE TABLE IF NOT EXISTS config (k TEXT PRIMARY KEY, v TEXT)")
    # Refresh the stored password hash every boot. Lets the operator
    # change TEP_DASH_PASSWORD in env, restart, and have the new
    # credential take effect without touching the DB by hand. Pinning
    # the hash to a constant at the Ruby module level confuses spinel's
    # type inference (the cmeth return widens to int), so SQLite is the
    # cheap workaround.
    hash = Tep::Password.hash(DASH_PASSWORD)
    db.prepare("INSERT OR REPLACE INTO config (k, v) VALUES (?, ?)")
    db.bind_str(1, "pwd_hash")
    db.bind_str(2, hash)
    db.step
    db.finalize
    LOGGER.info("gx10 dashboard ready, db=" + DB_PATH + " sites=" + SITES_ROOT)
    db.close
  end
end

# Look up the stored password hash. ~one SELECT per login attempt;
# Tep::Password.verify pays the PBKDF2 cost.
def stored_pwd_hash
  db = Tep::SQLite.new
  db.open(DB_PATH)
  h = db.first_str("SELECT v FROM config WHERE k = ?", "pwd_hash")
  db.close
  h
end

# -------------------------------------------------------------------
# Filters -- request log + CORS (api only) + auth gate
# -------------------------------------------------------------------

before do
  LOGGER.info(req.verb + " " + req.path)
  # CORS preflight short-circuits via the Cors filter itself; we
  # invoke it manually so the web routes don't pick up
  # Access-Control-Allow-Origin headers they don't want.
  if req.path.length >= 5 && req.path[0, 5] == "/api/"
    CORS.before(req, res)
  end
  # Public paths: login, healthz, anything under /assets/* (which
  # Tep::Assets serves before route dispatch anyway), and the api/
  # subtree (those have their own JWT-or-401 gate).
  if needs_auth?(req.path) && !logged_in?(req)
    if req.verb == "GET"
      redirect "/login"
    else
      res.set_status(401)
      res.set_body_if_empty("login required\n")
    end
  end
end

# Routes that require a session cookie. /api/* uses Bearer JWTs
# (gated per-handler), bundled assets (served at the root by
# Tep::Assets) are open, and /login / /healthz are open.
def needs_auth?(path)
  return false if path == "/login"
  return false if path == "/healthz"
  return false if path == "/favicon.ico"
  return false if path.length >= 5 && path[0, 5] == "/api/"
  return false if Tep::Assets.has?(path)
  true
end

def logged_in?(req)
  req.session.get("user").length > 0
end

# -------------------------------------------------------------------
# Login + logout (session-backed)
# -------------------------------------------------------------------

get '/login' do
  @flash = req.session.get("flash")
  req.session.set("flash", "")
  mustache :login
end

post '/login' do
  user = params[:user]
  pwd  = params[:password]
  stored = stored_pwd_hash
  if user == DASH_USER && Tep::Password.verify(pwd, stored)
    req.session.set("user", user)
    LOGGER.info("login ok: " + user)
    redirect "/"
  else
    LOGGER.warn("login failed for user=" + user)
    req.session.set("flash", "wrong username or password")
    redirect "/login"
  end
end

post '/logout' do
  user = req.session.get("user")
  req.session.set("user", "")
  LOGGER.info("logout: " + user)
  redirect "/login"
end

get '/healthz' do
  res.headers["Content-Type"] = "application/json"
  "{\"ok\":1}"
end

# -------------------------------------------------------------------
# Probes -- each returns a small struct of qualitative facts. Heavy
# users (the dashboard render, SSE pump, /api/status) call them all;
# light users (a future widget) can pick and choose.
# -------------------------------------------------------------------

# Hostname + uptime + load + memory; one helper per concern.

def probe_hostname
  Tep::Shell.read("/etc/hostname").strip
end

def probe_uptime_seconds
  raw = Tep::Shell.read("/proc/uptime")
  # /proc/uptime: "<seconds> <idle>"
  i = raw.index(" ")
  if i < 0
    return 0
  end
  raw[0, i].to_i
end

def probe_loadavg
  raw = Tep::Shell.read("/proc/loadavg").strip
  # "<1m> <5m> <15m> <runnable/total> <last_pid>" -- keep the first three
  parts = raw.split(" ")
  if parts.length < 3
    return "?"
  end
  parts[0] + " / " + parts[1] + " / " + parts[2]
end

def probe_meminfo
  raw = Tep::Shell.read("/proc/meminfo")
  total = kb_field(raw, "MemTotal:")
  avail = kb_field(raw, "MemAvailable:")
  used = total - avail
  out = Tep.str_hash
  out["total_gb"]      = gib(total)
  out["used_gb"]       = gib(used)
  out["available_gb"]  = gib(avail)
  out
end

def kb_field(blob, label)
  i = blob.index(label)
  if i < 0
    return 0
  end
  j = i + label.length
  # skip spaces, read digits
  while j < blob.length && blob[j] == " "
    j += 1
  end
  k = j
  while k < blob.length && blob[k] >= "0" && blob[k] <= "9"
    k += 1
  end
  blob[j, k - j].to_i
end

def gib(kb)
  # round-down to GiB
  (kb / 1024 / 1024).to_s + "G"
end

def probe_gpu
  # `--query-gpu=...,--format=csv,noheader` keeps output one row per
  # GPU; we display the first row only since gx10 has one card. If
  # nvidia-smi isn't on PATH the helper returns "" and we synthesize
  # a "no GPU detected" line.
  raw = Tep::Shell.run("nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null").strip
  if raw.length == 0
    return "no GPU detected"
  end
  raw
end

def probe_inference
  # `inference status` is the canonical aggregator script on the
  # box. If it's missing we fall back to inspecting docker ps for
  # the well-known container names.
  raw = Tep::Shell.run(ENV.fetch("HOME", "/root") + "/gx10_config/bin/inference status 2>/dev/null")
  if raw.length > 0
    return raw
  end
  Tep::Shell.run("docker ps --filter name=vllm --filter name=ollama --format '{{.Names}}\t{{.Status}}' 2>/dev/null")
end

def probe_tmux
  raw = Tep::Shell.run("tmux ls 2>/dev/null")
  if raw.length == 0
    return "no sessions"
  end
  raw
end

def probe_docker
  Tep::Shell.run("docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null")
end

# List directory children whose name doesn't start with ".". One
# entry per line. The build-time AOT pipeline lowers `Dir.glob` /
# `Dir.entries` unevenly; shelling out is simpler.
def probe_sites
  raw = Tep::Shell.run("ls -1 " + SITES_ROOT + " 2>/dev/null")
  out = "" # newline-separated "name\tcommit\tsubject"
  raw.split("\n").each do |name|
    if name.length == 0 || name[0] == "."
      next
    end
    line = Tep::Shell.run_limited("cd " + SITES_ROOT + "/" + name + " 2>/dev/null && git log -1 --pretty='format:%h %ar %s' 2>/dev/null", 256).strip
    if out.length > 0
      out = out + "\n"
    end
    if line.length == 0
      out = out + name + "\t(no commit history)"
    else
      out = out + name + "\t" + line
    end
  end
  out
end

# -------------------------------------------------------------------
# Dashboard page (web)
# -------------------------------------------------------------------

get '/' do
  @user      = req.session.get("user")
  @host      = probe_hostname
  @uptime    = format_uptime(probe_uptime_seconds)
  @load      = probe_loadavg
  meminfo    = probe_meminfo
  @mem_used  = meminfo["used_gb"]
  @mem_tot   = meminfo["total_gb"]
  @mem_avail = meminfo["available_gb"]
  @gpu       = probe_gpu
  @inference = probe_inference
  @tmux      = probe_tmux
  @docker    = probe_docker
  @sites     = probe_sites
  @todos     = list_todos
  @version   = Tep::VERSION
  # Render the __END__ inline `@@ footer` partial first; index.erb
  # interpolates @footer below the main content.
  @footer    = erb :footer
  erb :index
end

def format_uptime(seconds)
  d = seconds / 86400
  h = (seconds % 86400) / 3600
  m = (seconds % 3600) / 60
  if d > 0
    return d.to_s + "d " + h.to_s + "h"
  end
  if h > 0
    return h.to_s + "h " + m.to_s + "m"
  end
  m.to_s + "m"
end

# -------------------------------------------------------------------
# Todos -- CRUD over a tiny SQLite table. Web + JSON share handlers
# where the wire shape lines up; the web flow redirects to '/' to
# stay no-JS, while the JSON flow returns the row.
# -------------------------------------------------------------------

def list_todos
  out = "" # newline-separated "id\tdone\tbody"
  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("SELECT id, done, body FROM todos ORDER BY done ASC, id DESC")
  while db.step == 1
    if out.length > 0
      out = out + "\n"
    end
    out = out + db.col_int(0).to_s + "\t" + db.col_int(1).to_s + "\t" + db.col_str(2)
  end
  db.finalize
  db.close
  out
end

def insert_todo(body)
  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("INSERT INTO todos (body, done, created_at) VALUES (?, ?, ?)")
  db.bind_str(1, body)
  db.bind_int(2, 0)
  db.bind_int(3, Time.now.to_i)
  db.step
  db.finalize
  id = db.last_rowid
  db.close
  id
end

def toggle_todo(id)
  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("UPDATE todos SET done = 1 - done WHERE id = ?")
  db.bind_int(1, id)
  db.step
  db.finalize
  db.close
  0
end

def delete_todo(id)
  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("DELETE FROM todos WHERE id = ?")
  db.bind_int(1, id)
  db.step
  db.finalize
  db.close
  0
end

post '/todos' do
  body = params[:body]
  if body.length > 0
    insert_todo(body)
  end
  redirect "/"
end

post '/todos/:id/toggle' do
  id = params[:id].to_i
  if id > 0
    toggle_todo(id)
  end
  redirect "/"
end

post '/todos/:id/delete' do
  id = params[:id].to_i
  if id > 0
    delete_todo(id)
  end
  redirect "/"
end

# -------------------------------------------------------------------
# JSON API (bearer-token authed). POST /api/token issues a JWT against
# the same credentials as the web login; every other /api/* requires
# `Authorization: Bearer <jwt>`.
# -------------------------------------------------------------------

def bearer_payload(req)
  # Tep stores header names lowercase (see lib/tep/parser.rb).
  auth = req.req_headers["authorization"]
  if auth.length < 8 || auth[0, 7] != "Bearer "
    return ""
  end
  token = auth[7, auth.length - 7]
  Tep::Jwt.verify_and_decode(token, JWT_SECRET)
end

post '/api/token' do
  res.headers["Content-Type"] = "application/json"
  user = params[:user]
  pwd  = params[:password]
  stored = stored_pwd_hash
  if user != DASH_USER || !Tep::Password.verify(pwd, stored)
    res.set_status(401)
    return "{\"error\":\"invalid credentials\"}"
  end
  # JWT payload: just the user + an issued-at. No expiry in this demo;
  # production code should add one and verify it in bearer_payload.
  payload = "{" +
    Tep::Json.encode_pair_str("sub", user) + "," +
    Tep::Json.encode_pair_int("iat", Time.now.to_i) +
  "}"
  token = Tep::Jwt.encode_hs256(payload, JWT_SECRET)
  "{" + Tep::Json.encode_pair_str("token", token) + "}"
end

get '/api/status' do
  res.headers["Content-Type"] = "application/json"
  if bearer_payload(req).length == 0
    res.set_status(401)
    return "{\"error\":\"bearer token required\"}"
  end
  status_json
end

# A single JSON snapshot of every probe. Shared between /api/status
# (one-shot) and the SSE pump (every TICK_SECONDS).
def status_json
  meminfo = probe_meminfo
  facts = Tep.str_hash
  facts["host"]        = probe_hostname
  facts["load"]        = probe_loadavg
  facts["mem_used_gb"] = meminfo["used_gb"]
  facts["mem_total_gb"] = meminfo["total_gb"]
  facts["gpu"]         = probe_gpu.split("\n")[0] || ""
  facts["uptime"]      = format_uptime(probe_uptime_seconds)
  Tep::Json.from_str_hash(facts)
end

get '/api/todos' do
  res.headers["Content-Type"] = "application/json"
  if bearer_payload(req).length == 0
    res.set_status(401)
    return "{\"error\":\"bearer token required\"}"
  end
  out = "["
  first = true
  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("SELECT id, done, body FROM todos ORDER BY id DESC")
  while db.step == 1
    if !first
      out = out + ","
    end
    first = false
    out = out + "{" +
      Tep::Json.encode_pair_int("id", db.col_int(0)) + "," +
      Tep::Json.encode_pair_int("done", db.col_int(1)) + "," +
      Tep::Json.encode_pair_str("body", db.col_str(2)) +
    "}"
  end
  db.finalize
  db.close
  out + "]"
end

# -------------------------------------------------------------------
# SSE live status (anyone with session OR bearer can subscribe). Each
# tick emits one `data:` event with the current status snapshot.
# Driven by Tep::Scheduler.pause so any future fiber needs (parallel
# probes, etc.) plug in cleanly.
# -------------------------------------------------------------------

class StatusStreamer < Tep::Streamer
  attr_accessor :ticks
  def initialize
    @ticks = 0
  end
  # The streamer can't reach the App's top-level probe_* helpers
  # (different class context), so it calls Tep::Shell directly. This
  # keeps the SSE payload tight: host, load, GPU one-liner, uptime --
  # the operator can hit /api/status for the full snapshot.
  def pump(out)
    while @ticks < STREAM_MAX
      facts = Tep.str_hash
      facts["host"]   = Tep::Shell.read("/etc/hostname").strip
      facts["load"]   = Tep::Shell.read("/proc/loadavg").strip
      facts["gpu"]    = Tep::Shell.run("nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu --format=csv,noheader 2>/dev/null").strip
      facts["ts"]     = Time.now.to_i.to_s
      out.write("data: " + Tep::Json.from_str_hash(facts) + "\n\n")
      out.write(": tick\n\n")  # SSE keepalive comment
      # Tep::Scheduler.pause does the right thing in both contexts:
      # yields back to the scheduler when called from a fiber,
      # falls back to plain sleep when called from a normal
      # handler. The streamer runs in a request handler so we hit
      # the fallback here.
      Tep::Scheduler.pause(TICK_SECONDS)
      @ticks += 1
    end
    0
  end
end

get '/api/events' do
  if !logged_in?(req) && bearer_payload(req).length == 0
    res.set_status(401)
    return "login or bearer token required\n"
  end
  res.headers["Content-Type"]  = "text/event-stream"
  res.headers["Cache-Control"] = "no-cache"
  stream StatusStreamer.new
end

# -------------------------------------------------------------------
# Snapshot download (uses send_file). Lets the operator pull
# ~/gx10_config/docs/system-state.md without ssh'ing in.
# -------------------------------------------------------------------

get '/snapshot.md' do
  res.headers["Content-Type"] = "text/markdown; charset=utf-8"
  # send_file's translator macro only matches a literal-string arg;
  # pass the configured path directly to res.send_file.
  res.send_file(SNAPSHOT_PATH)
  ""
end

# -------------------------------------------------------------------
# Custom 404 (uses the not_found DSL).
# -------------------------------------------------------------------

not_found do
  res.headers["Content-Type"] = "text/html; charset=utf-8"
  "<!doctype html><html><body style=\"font-family:system-ui;padding:2rem\">" +
  "<h1>404</h1><p>no such page on this gx10.</p>" +
  "<p><a href=\"/\">dashboard</a></p></body></html>"
end

__END__

@@ footer
<!-- inline partial loaded via the __END__ pipeline -->
<footer class="footer">
  tep <%= Tep::VERSION %> · <%= @host %> · uptime <%= @uptime %>
</footer>
