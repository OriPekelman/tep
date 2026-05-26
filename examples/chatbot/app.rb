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
JWT_SECRET     = ENV.fetch("CHAT_JWT_SECRET",    SESSION_SECRET)
BACKEND_URL    = ENV.fetch("CHAT_BACKEND",       "http://localhost:11434")
MODEL          = ENV.fetch("CHAT_MODEL",         "llama3")
API_KEY        = ENV.fetch("CHAT_API_KEY",       "")
SYSTEM_PROMPT  = ENV.fetch("CHAT_SYSTEM_PROMPT", "")
HSTS_SECONDS   = ENV.fetch("CHAT_HSTS",          "0").to_i
CORS_ORIGIN    = ENV.fetch("CHAT_CORS_ORIGIN",   "*")

# Phase E: extra backends to fan out the same prompt against, in
# parallel. Format: `url|model|key;url|model|key;...` (`;` separator
# between backends, `|` between fields). Empty string -> compare-mode
# falls back to the primary backend only (degenerate one-pane result).
COMPARE_BACKENDS_RAW = ENV.fetch("CHAT_COMPARE_BACKENDS", "")

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

# Tep::Job's queue table init -- once per worker at module load,
# avoids the "called every request" segfault we saw under
# Tep::Server::Scheduled. (Probably an interaction between
# Tep::Job's open/close cycle and the cooperative scheduler;
# noted as a debug TODO in the Phase C commit.)
Tep::Job.init_schema(ENV.fetch("CHAT_DB", "/tmp/tep_chatbot.db"))

# -------------------------------------------------------------------
# Phase E: compare-backends parsing + worker
# -------------------------------------------------------------------
# Parse `url|model|key;url|model|key;...` into an Array<String> where
# each element is one `url|model|key` triple (same shape so the
# CompareWorker just splits on `|`). If the env var is empty, fall
# back to the primary backend.
def parse_compare_backends(raw)
  out = [""]
  out.delete_at(0)
  if raw.length == 0
    out.push(BACKEND_URL + "|" + MODEL + "|" + API_KEY)
    return out
  end
  pos = 0
  while pos < raw.length
    semi = Tep.str_find(raw, ";", pos)
    if semi < 0
      out.push(raw[pos, raw.length - pos])
      pos = raw.length
    else
      out.push(raw[pos, semi - pos])
      pos = semi + 1
    end
  end
  out
end

# CompareWorker takes one `url|model|key` item per fork, runs the
# user's prompt through Tep::Llm.chat() against that backend, returns
# the reply content. The prompt is carried via @prompt (set once on
# the worker before map_processes; the fork inherits the ivar). Each
# child returns a small wire-shape: `<seconds_taken>|<reply_content>`
# so the parent can render the took-time alongside the response
# without a second JSON parse.
# See matz/spinel#575: under combined tep binaries the @worker.run
# dispatch in Tep::Parallel still pulls in Tep::Server.run /
# Tep::Server::Scheduled.run (same name, different arity), widening
# the result to sp_RbVal and breaking the downstream File.write.
# Even after pulling spinel master past today's commits the divergence
# from matz's local synthetic persists -- working on a minimal repro
# for the issue. Until #575 lands, CompareWorker stays free-standing
# (no ParallelWorker inheritance) and the route loops sequentially.
class CompareWorker
  attr_accessor :prompt

  def initialize
    @prompt = ""
  end

  # Returns `<seconds_taken>|<reply_content>`. Same wire shape as
  # the parallel version would have used.
  def run(item)
    pipe1 = Tep.str_find(item, "|", 0)
    pipe2 = Tep.str_find(item, "|", pipe1 + 1)
    if pipe1 < 0 || pipe2 < 0
      return "0|malformed item"
    end
    backend = item[0, pipe1]
    model   = item[pipe1 + 1, pipe2 - pipe1 - 1]
    key     = item[pipe2 + 1, item.length - pipe2 - 1]

    client = Tep::Llm.new(backend)
    client.set_model(model)
    if key.length > 0
      client.set_api_key(key)
    end

    msgs = [Tep::Llm::Message.new("user", @prompt)]
    t0 = Time.now.to_i
    reply = client.chat(msgs)
    took = Time.now.to_i - t0

    took.to_s + "|" + reply.content
  end
end

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

# Conversation lifecycle. Phase C ships multi-conversation: a new
# row per "New chat" click, sidebar listing newest-first, per-id
# stream route. The schema is unchanged from Phase A.
def create_conversation
  db = db_open
  db.prepare("INSERT INTO conversations (title, created_at) VALUES (?, ?)")
  db.bind_str(1, "")   # title filled later by TitleJob
  db.bind_int(2, Time.now.to_i)
  db.step
  db.finalize
  id = db.last_rowid
  db.close
  id
end

# Newest conversation id, or 0 if none exist.
def newest_conversation_id
  db = db_open
  id = db.first_int("SELECT id FROM conversations ORDER BY id DESC LIMIT 1", "")
  db.close
  id
end

# Returns an existing conversation id, or creates a new one if the
# db is empty. The chatbot defaults to "show me the newest" on /.
def ensure_default_conversation
  id = newest_conversation_id
  if id == 0
    id = create_conversation
  end
  id
end

# JSON list of {id, title, created_at} for the sidebar.
def conversations_as_json
  db = db_open
  db.prepare("SELECT id, title, created_at FROM conversations ORDER BY id DESC")
  out = '{"conversations":['
  first = true
  while db.step == 1
    id = db.col_int(0)
    title = db.col_str(1)
    created = db.col_int(2)
    if !first
      out = out + ","
    end
    out = out + "{\"id\":" + id.to_s +
                ",\"title\":" + Tep::Json.quote(title) +
                ",\"created_at\":" + created.to_s + "}"
    first = false
  end
  db.finalize
  db.close
  out + "]}"
end

# Set the title for a conversation. Used by TitleJob.
def set_conversation_title(conv_id, title)
  db = db_open
  db.prepare("UPDATE conversations SET title = ? WHERE id = ?")
  db.bind_str(1, title)
  db.bind_int(2, conv_id)
  db.step
  db.finalize
  db.close
  0
end

# Count the assistant turns in a conversation. Used to decide
# whether to enqueue TitleJob (only after the first one).
def assistant_msg_count(conv_id)
  db = db_open
  db.prepare("SELECT COUNT(*) FROM messages WHERE conversation_id = ? AND role = 'assistant'")
  db.bind_int(1, conv_id)
  n = 0
  if db.step == 1
    n = db.col_int(0)
  end
  db.finalize
  db.close
  n
end

# Does this conversation lack a title?
def needs_title?(conv_id)
  db = db_open
  db.prepare("SELECT title FROM conversations WHERE id = ?")
  db.bind_int(1, conv_id)
  t = ""
  if db.step == 1
    t = db.col_str(0)
  end
  db.finalize
  db.close
  t.length == 0
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
# Bypasses for /setup / /login / /logout / /healthz / bundled assets /
# /api/v1/* (those routes use JwtAuthFilter, not cookie auth).
# -------------------------------------------------------------------
def jwt_path?(p)
  p.length >= 8 && p[0, 8] == "/api/v1/"
end

# CORS instance for the /api/v1/* surface. Configured once; the
# combined filter delegates to it.
CORS = Tep::Security::Cors.new
CORS.set_origin(CORS_ORIGIN)
CORS.set_allowed_verbs("GET,POST,OPTIONS")
CORS.set_allowed_headers("Content-Type,Authorization")
CORS.set_max_age(3600)

# Single combined before-filter. `Tep::App#set_before` is a single
# slot (the LAST Tep.before call wins), so all per-request gating
# for the chatbot lives here. Routes are partitioned into:
#   - bypass (assets, healthz, setup/login/logout)
#   - JWT-authed (`/api/v1/*`)        -- CORS + Bearer
#   - cookie-authed (everything else) -- session redirect to /setup or /login
class ChatbotFilter < Tep::Filter
  def before(req, res)
    p = req.path
    # Bypass: routes that need no auth at all.
    if p == "/setup" || p == "/login" || p == "/logout" || p == "/healthz"
      return 0
    end
    if p == "/style.css" || p == "/chat.js" || p == "/markdown.js" || p == "/compare.js"
      return 0
    end

    # JWT routes: CORS + Bearer-token check.
    if jwt_path?(p)
      CORS.before(req, res)
      if res.halted
        # CORS handled OPTIONS preflight; emit the CORS headers and
        # stop without further auth.
        return 0
      end
      ChatbotFilter.require_bearer(req, res)
      return 0
    end

    # Cookie-authed routes.
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

  def self.require_bearer(req, res)
    auth = req.headers["authorization"]
    if auth.length < 8 || auth[0, 7] != "Bearer "
      ChatbotFilter.deny(res, "missing or malformed Authorization header")
      return 0
    end
    token = auth[7, auth.length - 7]
    payload = Tep::Jwt.verify_and_decode(token, JWT_SECRET)
    if payload.length == 0
      ChatbotFilter.deny(res, "invalid token")
      return 0
    end
    0
  end

  def self.deny(res, why)
    res.set_status(401)
    res.headers["Content-Type"] = "application/json"
    res.body = '{"error":"unauthorized","reason":' + Tep::Json.quote(why) + '}'
    res.halted = true
    0
  end
end

Tep.before ChatbotFilter.new

# -------------------------------------------------------------------
# Background worker -- TitleJob via Tep::Job
# -------------------------------------------------------------------
# Tep::Job persists pending work in SQLite (queue table init'd via
# Tep::Job.init_schema). The chatbot enqueues TitleJob each time a
# conversation gets its first assistant reply; a background fiber
# (one per prefork worker) polls every 5 s, dispatches to
# TitleJob.perform, and marks done.
#
# perform(arg) gets the conversation_id (as a String -- Tep::Job's
# arg surface). The body reads the first user+assistant turns,
# asks the LLM for a ~5-word title, and writes it back to
# conversations.title. The sidebar polls /api/conversations every
# few seconds to pick up the change.

class TitleJob < Tep::Job
  def perform(arg)
    conv_id = arg.to_i

    db = db_open
    db.prepare("SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id ASC LIMIT 2")
    db.bind_int(1, conv_id)
    user_msg = ""
    asst_msg = ""
    while db.step == 1
      r = db.col_str(0)
      c = db.col_str(1)
      if r == "user" && user_msg.length == 0
        user_msg = c
      elsif r == "assistant" && asst_msg.length == 0
        asst_msg = c
      end
    end
    db.finalize
    db.close

    if user_msg.length == 0
      return ""
    end

    client = Tep::Llm.new(BACKEND_URL)
    client.set_model(MODEL)
    if API_KEY.length > 0
      client.set_api_key(API_KEY)
    end
    client.set_system_prompt(
      "You produce 4-6 word titles summarising a chat conversation. " +
      "Reply with the title only, no quotes or punctuation."
    )

    prompt = "User: " + user_msg + "\n\nAssistant: " + asst_msg +
             "\n\nWrite a 4-6 word title for this conversation."
    msgs = [Tep::Llm::Message.new("user", prompt)]
    reply = client.chat(msgs)

    title = reply.content
    if title.length > 80
      title = title[0, 80]
    end
    if title.length == 0
      title = "New chat"
    end
    set_conversation_title(conv_id, title)
    ""
  end
end

# Job dispatcher. Phase C ships INLINE dispatch (called from
# LlmStreamer.pump right after the stream completes) rather than a
# background-fiber poller. A naive `Fiber.new { poll_loop }` spawned
# from a before-filter segfaulted under Tep::Server::Scheduled --
# needs its own debug session (probably an interaction between the
# scheduler tick + Tep::SQLite's single-cursor-per-process contract).
# Inline dispatch keeps the Tep::Job queue table as an audit trail
# without cross-fiber races. Phase E ("Tep::Parallel multi-backend
# compare") is the better showcase for fork-based background work.
class JobWorker
  def self.process_one
    json = Tep::Job.fetch_next(DB_PATH)
    if json.length == 0
      return 0
    end
    job_id = Tep::Json.get_int(json, "id")
    name   = Tep::Json.get_str(json, "job_name")
    arg    = Tep::Json.get_str(json, "arg")
    if name == "TitleJob"
      TitleJob.new.perform(arg)
      Tep::Job.mark_done(DB_PATH, job_id, "")
    else
      Tep::Job.mark_failed(DB_PATH, job_id)
    end
    0
  end
end

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

# Issue a JWT API token bound to the logged-in session. Caller uses
# it for /api/v1/* routes (e.g. from a curl / Python client / another
# tep app). No expiry in v1; rotate JWT_SECRET to invalidate all
# outstanding tokens.
post '/api/token' do
  payload_json = '{"sub":"user","iat":' + Time.now.to_i.to_s + '}'
  token = Tep::Jwt.encode_hs256(payload_json, JWT_SECRET)
  res.headers["Content-Type"] = "application/json"
  '{"token":' + Tep::Json.quote(token) + '}'
end

# -------------------------------------------------------------------
# OpenAI-compat /v1/chat/completions passthrough.
#
# Accepts the standard OpenAI request shape:
#   {"model":"...","messages":[{"role":"...","content":"..."}...],
#    "stream":true|false}
#
# Non-streaming: returns a chat.completion object:
#   {"id":"...","object":"chat.completion","model":"...",
#    "choices":[{"index":0,"message":{"role":"assistant","content":"..."},
#                "finish_reason":"..."}]}
#
# Streaming: emits the SSE event stream OpenAI clients expect:
#   data: {"id":"...","choices":[{"index":0,"delta":{"content":"<chunk>"},
#                                  "finish_reason":null}]}\n\n
#   ...
#   data: [DONE]\n\n
#
# Backend is whatever the chatbot was configured with (CHAT_BACKEND);
# the passthrough re-uses the same Tep::Llm client. Conversation
# persistence is bypassed -- /api/v1 is a stateless passthrough, not
# a tied-to-this-chatbot transcript.
# -------------------------------------------------------------------

# Parse the OpenAI request body into a Tep::Llm::Message array.
# Hand-rolled because Tep::Json's flat decoder doesn't dive into
# the messages-array shape. Walks `"messages":[{"role":"...","content":"..."},...]`
# and pulls each role/content pair.
def parse_openai_messages(body)
  msgs = [Tep::Llm::Message.new("", "")]
  msgs.delete_at(0)
  m_at = Tep.str_find(body, "\"messages\"", 0)
  if m_at < 0
    return msgs
  end
  # Walk objects between m_at and the matching closing bracket.
  # Each object starts at `{` and ends at `}`. Use the same
  # extract_str_field pattern Tep::Llm already exposes.
  pos = m_at
  while true
    obj_start = Tep.str_find(body, "{", pos)
    if obj_start < 0
      return msgs
    end
    obj_end = Tep.str_find(body, "}", obj_start)
    if obj_end < 0
      return msgs
    end
    obj = body[obj_start, obj_end - obj_start + 1]
    role    = Tep::Llm.extract_str_field(obj, "role",    0)
    content = Tep::Llm.extract_str_field(obj, "content", 0)
    if role.length > 0
      msgs.push(Tep::Llm::Message.new(role, content))
    end
    pos = obj_end + 1
    # Stop at the closing ] of the messages array (heuristic:
    # the next `]` after pos comes before the next `{`).
    nxt_bracket = Tep.str_find(body, "]", pos)
    nxt_brace   = Tep.str_find(body, "{", pos)
    if nxt_bracket >= 0 && (nxt_brace < 0 || nxt_bracket < nxt_brace)
      return msgs
    end
  end
  msgs
end

# Build the OpenAI non-streaming response envelope. The unix
# timestamp + a fixed id keep the shape minimal; clients that
# care about ids generate their own.
def openai_envelope(model, content, stop_reason)
  '{"id":"chatcmpl-tep","object":"chat.completion","created":' +
    Time.now.to_i.to_s +
    ',"model":' + Tep::Json.quote(model) +
    ',"choices":[{"index":0,"message":{"role":"assistant","content":' +
    Tep::Json.quote(content) +
    '},"finish_reason":' + Tep::Json.quote(stop_reason) +
    '}]}'
end

class PassthroughStreamer < Tep::Streamer
  attr_accessor :model, :messages

  def initialize
    @model    = ""
    @messages = [Tep::Llm::Message.new("", "")]
    @messages.delete_at(0)
  end

  def pump(out)
    client = Tep::Llm.new(BACKEND_URL)
    client.set_model(@model)
    if API_KEY.length > 0
      client.set_api_key(API_KEY)
    end
    if SYSTEM_PROMPT.length > 0
      client.set_system_prompt(SYSTEM_PROMPT)
    end
    client.chat_stream(@messages, out)
    0
  end
end

post '/api/v1/chat/completions' do
  body = req.body
  if body.length == 0
    res.set_status(400)
    res.headers["Content-Type"] = "application/json"
    return '{"error":"empty body"}'
  end

  # Extract model + stream flag from the JSON body. Model
  # falls back to the chatbot's configured default.
  model = Tep::Json.get_str(body, "model")
  if model.length == 0
    model = MODEL
  end
  msgs = parse_openai_messages(body)
  # Local var renamed away from `stream`: bin/tep's Sinatra DSL
  # rewrites bare `stream X` into `res.start_stream(X)`, which
  # collides with `stream = ...` LHS assignment too. `is_streaming`
  # avoids the textual rewrite.
  is_streaming = Tep.str_find(body, "\"stream\":true",  0) >= 0 ||
                 Tep.str_find(body, "\"stream\": true", 0) >= 0

  if is_streaming
    res.headers["Content-Type"]  = "text/event-stream"
    res.headers["Cache-Control"] = "no-cache"
    s = PassthroughStreamer.new
    s.model    = model
    s.messages = msgs
    stream s
  else
    client = Tep::Llm.new(BACKEND_URL)
    client.set_model(model)
    if API_KEY.length > 0
      client.set_api_key(API_KEY)
    end
    if SYSTEM_PROMPT.length > 0
      client.set_system_prompt(SYSTEM_PROMPT)
    end
    reply = client.chat(msgs)
    res.headers["Content-Type"] = "application/json"
    openai_envelope(model, reply.content, reply.stop_reason)
  end
end

# Tiny health endpoint under /api/v1 so callers can probe
# without needing a real token (OPTIONS preflight only).
get '/api/v1/healthz' do
  res.headers["Content-Type"] = "application/json"
  '{"status":"ok"}'
end

# -------------------------------------------------------------------
# Phase E: /compare -- fan one prompt out to N backends in parallel,
# render side-by-side. Sidebar gets a "Compare backends" link;
# /compare is its own page (different layout from the chat panel).
# -------------------------------------------------------------------

get '/compare' do
  @backends_json = compare_backends_as_json
  @model = MODEL
  @backend = BACKEND_URL
  erb :compare
end

# Module-level constant return-type inference can mis-fire here
# (spinel pins it to Integer instead of Array<String>). Compute
# the list on demand inside each consumer instead; it's a few
# string ops and we don't call it on the hot path.
def compare_backends
  parse_compare_backends(COMPARE_BACKENDS_RAW)
end

post '/api/compare' do
  prompt = params["prompt"].to_s
  res.headers["Content-Type"] = "application/json"
  if prompt.length == 0
    res.set_status(400)
    return '{"error":"empty prompt"}'
  end

  worker = CompareWorker.new
  worker.prompt = prompt

  backends = compare_backends
  results = [""]
  results.delete_at(0)
  t_outer0 = Time.now.to_i
  i = 0
  while i < backends.length
    results.push(worker.run(backends[i]))
    i += 1
  end
  t_outer = Time.now.to_i - t_outer0

  out = "{\"total_s\":" + t_outer.to_s + ",\"results\":["
  i = 0
  while i < backends.length
    triple = backends[i]
    p1 = Tep.str_find(triple, "|", 0)
    p2 = Tep.str_find(triple, "|", p1 + 1)
    backend = triple[0, p1]
    model   = triple[p1 + 1, p2 - p1 - 1]

    reply = results[i]
    sep = Tep.str_find(reply, "|", 0)
    took = 0
    content = ""
    if sep > 0
      took = reply[0, sep].to_i
      content = reply[sep + 1, reply.length - sep - 1]
    else
      content = reply
    end

    if i > 0
      out = out + ","
    end
    out = out + "{\"backend\":" + Tep::Json.quote(backend) +
                ",\"model\":" + Tep::Json.quote(model) +
                ",\"took_s\":" + took.to_s +
                ",\"content\":" + Tep::Json.quote(content) + "}"
    i += 1
  end
  out + "]}"
end

# Compact JSON of the compare backends for the view's boot data.
def compare_backends_as_json
  backends = compare_backends
  out = "["
  i = 0
  while i < backends.length
    triple = backends[i]
    p1 = Tep.str_find(triple, "|", 0)
    p2 = Tep.str_find(triple, "|", p1 + 1)
    backend = triple[0, p1]
    model   = triple[p1 + 1, p2 - p1 - 1]
    if i > 0
      out = out + ","
    end
    out = out + "{\"backend\":" + Tep::Json.quote(backend) +
                ",\"model\":" + Tep::Json.quote(model) + "}"
    i += 1
  end
  out + "]"
end

# Main UI: list of conversations + the most-recent conversation
# pre-loaded into the chat panel. The sidebar JS polls
# /api/conversations every few seconds to pick up titles set by
# TitleJob, and rerenders the list.
get '/' do
  conv_id = ensure_default_conversation
  @conv_id = conv_id
  @messages_json = messages_as_json(conv_id)
  @conversations_json = conversations_as_json
  @model = MODEL
  @backend = BACKEND_URL
  erb :index
end

# Same UI, scoped to a specific conversation. /c/:id is the
# bookmarkable URL the sidebar links to.
get '/c/:id' do
  conv_id = params["id"].to_i
  if conv_id == 0
    redirect "/"
  end
  @conv_id = conv_id
  @messages_json = messages_as_json(conv_id)
  @conversations_json = conversations_as_json
  @model = MODEL
  @backend = BACKEND_URL
  erb :index
end

# JSON: list of conversations for the sidebar.
get '/api/conversations' do
  res.headers["Content-Type"] = "application/json"
  conversations_as_json
end

# Create a new conversation. Returns the new id as JSON.
post '/api/conversations' do
  res.headers["Content-Type"] = "application/json"
  id = create_conversation
  '{"id":' + id.to_s + '}'
end

# JSON: messages for a specific conversation.
get '/api/c/:id/messages' do
  conv_id = params["id"].to_i
  res.headers["Content-Type"] = "application/json"
  messages_as_json(conv_id)
end

# SSE: append user message, stream the assistant reply from the
# backend incrementally to the browser, persist the full reply
# on completion. Phase B.
class LlmStreamer < Tep::Streamer
  attr_accessor :conv_id, :messages

  def initialize
    @conv_id  = 0
    @messages = [Tep::Llm::Message.new("", "")]
    @messages.delete_at(0)
  end

  def pump(out)
    client = Tep::Llm.new(BACKEND_URL)
    client.set_model(MODEL)
    if API_KEY.length > 0
      client.set_api_key(API_KEY)
    end
    if SYSTEM_PROMPT.length > 0
      client.set_system_prompt(SYSTEM_PROMPT)
    end
    full_reply = client.chat_stream(@messages, out)
    if full_reply.length > 0
      append_message(@conv_id, "assistant", full_reply)
      # If this was the conversation's first assistant turn AND the
      # conversation still lacks a title, enqueue a TitleJob and
      # process one pending job inline. Phase C ships INLINE
      # dispatch (vs. a background-poller fiber) until the
      # Scheduled+JobWorker+SQLite segfault is debugged.
      if needs_title?(@conv_id) && assistant_msg_count(@conv_id) == 1
        Tep::Job.enqueue("TitleJob", @conv_id.to_s, DB_PATH)
        JobWorker.process_one
      end
    end
    0
  end
end

post '/api/c/:id/stream' do
  conv_id = params["id"].to_i
  if conv_id == 0
    res.set_status(400)
    res.headers["Content-Type"] = "application/json"
    return '{"error":"bad conversation id"}'
  end
  content = params["content"].to_s
  if content.length == 0
    res.set_status(400)
    res.headers["Content-Type"] = "application/json"
    return '{"error":"empty content"}'
  end
  append_message(conv_id, "user", content)

  res.headers["Content-Type"]  = "text/event-stream"
  res.headers["Cache-Control"] = "no-cache"
  s = LlmStreamer.new
  s.conv_id  = conv_id
  s.messages = conversation_history(conv_id)
  stream s
end

# WebSocket variant of the streaming endpoint (Phase F). Client
# opens one WS, sends one TEXT frame per user turn:
#
#     {"conv_id": 42, "content": "hello"}
#
# Server persists the user message, calls Tep::Llm.chat_stream
# directly against the driver (Driver#write is a Streamer-shape
# alias for #text), then persists the assistant reply once
# chat_stream returns. One frame per delta — same wire shape as
# the SSE route, just framed as WS TEXT chunks the JS receives
# via onmessage. Multiple turns on the same socket; client just
# keeps sending message frames.
websocket "/api/c/ws" do |ws|
  on_message do |evt|
    conv_id = Tep::Json.get_int(evt.data, "conv_id")
    content = Tep::Json.get_str(evt.data, "content")
    if conv_id > 0 && content.length > 0
      append_message(conv_id, "user", content)
      msgs = conversation_history(conv_id)
      client = Tep::Llm.new(BACKEND_URL)
      client.set_model(MODEL)
      if API_KEY.length > 0
        client.set_api_key(API_KEY)
      end
      if SYSTEM_PROMPT.length > 0
        client.set_system_prompt(SYSTEM_PROMPT)
      end
      full_reply = client.chat_stream(msgs, ws)
      if full_reply.length > 0
        append_message(conv_id, "assistant", full_reply)
        if needs_title?(conv_id) && assistant_msg_count(conv_id) == 1
          Tep::Job.enqueue("TitleJob", conv_id.to_s, DB_PATH)
          JobWorker.process_one
        end
      end
    end
  end
end

# JSON: append user message, call backend, append assistant reply,
# return the assistant reply. Synchronous; kept as a fallback /
# debugging endpoint. Phase B's default for the JS client is the
# streaming /api/stream route above.
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
