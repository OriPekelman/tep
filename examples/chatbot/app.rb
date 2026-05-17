# examples/chatbot -- minimalistic OpenWebUI-style client for any
# OpenAI-compatible chat backend.
#
# Talks to Ollama / OpenAI / [toy](https://github.com/OriPekelman/toy)'s
# tep_demo/openai_api.rb via a uniform wire protocol. Single-user,
# first-boot password setup, conversation persistence in SQLite.
#
# Distinct from examples/chat/ -- that one is a multi-user SSE chat
# (people talking to people). This one is a user-to-LLM chatbot.
#
# Phase A scope (this file, ~250 LOC + ~300 LOC across views/assets)
# ----------------------------------------------------------------
# * First-boot password setup; subsequent login via the same flow.
# * Single conversation (the first row of `conversations`). The
#   sidebar UI + multi-conversation UX is Phase C.
# * Synchronous chat: POST a message, await the full assistant reply,
#   render. Streaming is Phase B (SSE) and Phase F (WS).
# * Markdown rendering on assistant turns (vanilla JS, no deps).
#
# Backend selection
# -----------------
# `CHAT_BACKEND` env var sets the LLM base_url. Defaults to Ollama
# on localhost:11434. Other values:
#   - http://localhost:8080  (toy/tep_demo/openai_api)
#   - https://api.openai.com (real OpenAI; needs CHAT_API_KEY)
#
# `CHAT_MODEL` picks the model. Default is "llama3" for Ollama.
require "sinatra"

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
DB_PATH        = ENV.fetch("CHAT_DB",            "/tmp/tep_chatbot.db")
SESSION_SECRET = ENV.fetch("CHAT_SESSION_SECRET","dev-secret-change-me")
BACKEND_URL    = ENV.fetch("CHAT_BACKEND",       "http://localhost:11434")
MODEL          = ENV.fetch("CHAT_MODEL",         "llama3")
API_KEY        = ENV.fetch("CHAT_API_KEY",       "")
SYSTEM_PROMPT  = ENV.fetch("CHAT_SYSTEM_PROMPT", "")
HSTS_SECONDS   = ENV.fetch("CHAT_HSTS",          "0").to_i

set :views, File.expand_path("views", __dir__)
set :scheduler, :scheduled

Tep.session_secret = SESSION_SECRET

# Standard security headers on every response. HSTS opt-in for
# https-fronted deployments only (sending it bare-http locks
# browsers out of the http variant).
HEADERS = Tep::Security::Headers.new
HEADERS.set_hsts(HSTS_SECONDS)
Tep.after HEADERS

LOGGER = Tep::Logger.new
LOGGER.set_level("info")
LOGGER.to_stderr

# -------------------------------------------------------------------
# DB helpers. Each call opens + closes a fresh handle; tep_sqlite's
# single-cursor-per-instance contract means the per-call shape is
# safer than a long-lived handle when multiple fibers compete.
# -------------------------------------------------------------------
def db_open
  db = Tep::SQLite.new
  db.open(DB_PATH)
  # Schema is multi-statement; exec each line individually so
  # tep_sqlite_exec (single-statement) sees one at a time.
  db.exec("CREATE TABLE IF NOT EXISTS app_config (k TEXT PRIMARY KEY, v TEXT)")
  db.exec("CREATE TABLE IF NOT EXISTS conversations (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, created_at INTEGER)")
  db.exec("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id INTEGER NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL)")
  db.exec("CREATE INDEX IF NOT EXISTS messages_by_conv ON messages (conversation_id, id)")
  db
end

def config_get(key)
  db = db_open
  out = db.first_str("SELECT v FROM app_config WHERE k = ?", key)
  db.close
  out
end

def config_set(key, value)
  db = db_open
  db.prepare("INSERT INTO app_config (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v")
  db.bind_str(1, key)
  db.bind_str(2, value)
  db.step
  db.finalize
  db.close
  0
end

def password_set?
  config_get("password_hash").length > 0
end

# Ensure conversation row #1 exists. Returns its id.
def ensure_default_conversation
  db = db_open
  existing = db.first_int("SELECT id FROM conversations LIMIT 1", "")
  if existing == 0
    db.prepare("INSERT INTO conversations (title, created_at) VALUES (?, ?)")
    db.bind_str(1, "Chat")
    db.bind_int(2, Time.now.to_i)
    db.step
    db.finalize
  end
  out = db.first_int("SELECT id FROM conversations LIMIT 1", "")
  db.close
  out
end

def append_message(conv_id, role, content)
  db = db_open
  db.prepare("INSERT INTO messages (conversation_id, role, content, created_at) VALUES (?, ?, ?, ?)")
  db.bind_int(1, conv_id)
  db.bind_str(2, role)
  db.bind_str(3, content)
  db.bind_int(4, Time.now.to_i)
  db.step
  db.finalize
  db.close
  0
end

# Build a JSON envelope for the messages list. Hand-rolled because
# Tep::Json's flat encoders don't cover nested arrays-of-hashes
# (same shape Tep::Llm uses internally).
def messages_as_json(conv_id)
  db = db_open
  db.prepare("SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id ASC")
  db.bind_int(1, conv_id)
  out = '{"messages":['
  first = true
  while db.step == 1
    role    = db.col_str(0)
    content = db.col_str(1)
    if !first
      out = out + ","
    end
    out = out + "{\"role\":" + Tep::Json.quote(role) +
                ",\"content\":" + Tep::Json.quote(content) + "}"
    first = false
  end
  db.finalize
  db.close
  out + "]}"
end

# Build the messages array Tep::Llm.chat() consumes.
def conversation_history(conv_id)
  db = db_open
  db.prepare("SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id ASC")
  db.bind_int(1, conv_id)
  msgs = [Tep::Llm::Message.new("", "")]
  msgs.delete_at(0)
  while db.step == 1
    msgs.push(Tep::Llm::Message.new(db.col_str(0), db.col_str(1)))
  end
  db.finalize
  db.close
  msgs
end

# -------------------------------------------------------------------
# Auth: redirect unauthed traffic to /setup (first boot) or /login.
# Bypasses for /setup / /login / /logout / /healthz / /assets/*.
# -------------------------------------------------------------------
class AuthFilter < Tep::Filter
  def before(req, res)
    p = req.path
    if p == "/setup" || p == "/login" || p == "/logout" || p == "/healthz"
      return 0
    end
    # Bundled assets (Tep::Assets) sit at the root, not under /assets/
    # -- e.g. assets/style.css is served at /style.css. Bypass auth
    # so the login/setup pages can load their CSS without a redirect.
    if p == "/style.css" || p == "/chat.js" || p == "/markdown.js"
      return 0
    end
    if !password_set?
      res.set_status(302)
      res.headers["Location"] = "/setup"
      res.halted = true
      return 0
    end
    if req.session.get("authed") != "1"
      res.set_status(302)
      res.headers["Location"] = "/login"
      res.halted = true
      return 0
    end
    0
  end
end

Tep.before AuthFilter.new

# -------------------------------------------------------------------
# Routes
# -------------------------------------------------------------------

get '/healthz' do
  "ok"
end

# First-boot password setup. Once configured the route 404s so an
# attacker can't reset auth from an unauthed request.
get '/setup' do
  if password_set?
    halt 404, "not found"
  end
  erb :setup
end

post '/setup' do
  if password_set?
    halt 404, "not found"
  end
  pwd = params["password"].to_s
  if pwd.length < 6
    @error = "Password must be at least 6 characters."
    erb :setup
  else
    config_set("password_hash", Tep::Password.hash(pwd))
    req.session.set("authed", "1")
    req.session.dirty = true
    redirect "/"
  end
end

get '/login' do
  if !password_set?
    redirect "/setup"
  end
  erb :login
end

post '/login' do
  if !password_set?
    redirect "/setup"
  end
  if Tep::Password.verify(params["password"].to_s, config_get("password_hash"))
    req.session.set("authed", "1")
    req.session.dirty = true
    redirect "/"
  else
    @error = "Wrong password."
    erb :login
  end
end

post '/logout' do
  req.session.clear
  redirect "/login"
end

# Main UI. Embeds the conversation history inline so the page renders
# usefully on first load without a JS round-trip.
get '/' do
  conv_id = ensure_default_conversation
  @messages_json = messages_as_json(conv_id)
  @model = MODEL
  @backend = BACKEND_URL
  erb :index
end

# JSON: list of messages in the current conversation.
get '/api/messages' do
  conv_id = ensure_default_conversation
  res.headers["Content-Type"] = "application/json"
  messages_as_json(conv_id)
end

# JSON: append user message, call backend, append assistant reply,
# return the assistant reply. Synchronous -- streaming is Phase B.
post '/api/send' do
  conv_id = ensure_default_conversation
  content = params["content"].to_s
  if content.length == 0
    res.set_status(400)
    res.headers["Content-Type"] = "application/json"
    return '{"error":"empty content"}'
  end

  # Persist the user turn before the network round-trip so an LLM
  # failure leaves the conversation in a consistent state.
  append_message(conv_id, "user", content)

  client = Tep::Llm.new(BACKEND_URL)
  client.set_model(MODEL)
  if API_KEY.length > 0
    client.set_api_key(API_KEY)
  end
  if SYSTEM_PROMPT.length > 0
    client.set_system_prompt(SYSTEM_PROMPT)
  end

  reply = client.chat(conversation_history(conv_id))

  if reply.content.length > 0
    append_message(conv_id, "assistant", reply.content)
  end

  res.headers["Content-Type"] = "application/json"
  '{"role":"assistant","content":' + Tep::Json.quote(reply.content) +
    ',"stop_reason":' + Tep::Json.quote(reply.stop_reason) + '}'
end
