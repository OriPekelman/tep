# tep chat -- live multi-user chat with presence + Server-Sent
# Events streaming. A second flagship demo (alongside examples/blog/)
# that pushes tep into less-trodden corners:
#
#   - Tep::Streamer        long-running SSE pump per client
#   - polling SSE          while-loop with sleep + sphttp_write_chunk
#   - SQLite as a fanout   each streamer polls a `messages` table for
#                          rows newer than its last seen id; the
#                          single-cursor-per-process rule means each
#                          worker process holds one streamer + one
#                          DB cursor at a time, but the prefork model
#                          (-w N) gives N concurrent listeners
#   - Presence             heartbeat table refreshed via POST every
#                          few seconds; `who` query lists rows touched
#                          in the last 30 s
#   - Tep::Json            wire format for the SSE event payloads
#                          and the /who endpoint
#   - SpinelKit::Log          per-connection trace
#   - Tep::Security        CORS + secure-headers
#   - ERB + @ivar locals   the chat UI page
#
# Build + run:
#
#     bin/tep build examples/chat/app.rb -o /tmp/chat
#     /tmp/chat -p 4567 -w 4
#
# Open http://localhost:4567/ in two browser windows; watch
# messages from one show up in the other within ~1 s. The `-w 4`
# matters: each open SSE connection occupies a worker.

require 'sinatra'

# Concurrency model
# -----------------
# tep handlers are blocking inside their worker; a long-running
# stream pins that worker until it returns. macOS's SO_REUSEPORT
# does not load-balance new connections across listening
# processes (only Linux 3.9+ does), so on macOS even with
# `-w 4` a single SSE connection effectively blocks every other
# request. Linux behaves correctly.
#
# To make this demo work across platforms we ship the polling
# variant by default (each browser hits `GET /chat/recent` once
# per second). The SSE streamer survives in the codebase as
# `ChatStreamer` + `GET /chat/stream`; on Linux you can set
# TEP_CHAT_USE_SSE=1 in the page's JS layer (see views/index.erb)
# to switch back to the streaming path with sub-second latency.
set :workers, 4

DB_PATH      = ENV.fetch("TEP_CHAT_DB", "/tmp/tep_chat.db")
PRESENCE_TTL = 30   # seconds; users not seen in this window drop
                    # out of /who
STREAM_MAX   = 30   # seconds; streamers self-close after this and
                    # the client reconnects (so we don't pile up
                    # connection-state forever in any one worker)

LOGGER = SpinelKit::Log.new
LOGGER.set_level("info")

CORS = Tep::Security::Cors.new
CORS.set_origin("*")
CORS.set_allowed_verbs("GET,POST,OPTIONS")
CORS.set_allowed_headers("Content-Type")
Tep.before CORS

HEADERS = Tep::Security::Headers.new
Tep.after HEADERS

set :views, File.expand_path("views", __dir__)

# -------------------------------------------------------------------
# Schema
# -------------------------------------------------------------------

on_start do
  db = Tep::SQLite.new
  if db.open(DB_PATH)
    db.exec("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, room TEXT, author TEXT, body TEXT, created_at INTEGER)")
    db.exec("CREATE TABLE IF NOT EXISTS presence (user TEXT PRIMARY KEY, last_seen INTEGER)")
    LOGGER.info("chat ready, db at " + DB_PATH)
    db.close
  end
end

before do
  LOGGER.info(req.verb + " " + req.path)
end

# -------------------------------------------------------------------
# Web UI
# -------------------------------------------------------------------

get '/' do
  @last_id = current_max_id
  erb :index
end

# Helper: read max(messages.id) so the page joins mid-stream.
def current_max_id
  db = Tep::SQLite.new
  db.open(DB_PATH)
  n = db.first_int("SELECT IFNULL(MAX(id), 0) FROM messages", "")
  db.close
  n
end

# -------------------------------------------------------------------
# Send / heartbeat / who -- the JSON corners
# -------------------------------------------------------------------

post '/chat/send' do
  res.headers["Content-Type"] = "application/json"
  author = params[:author]
  body   = params[:body]
  room   = "main"
  if author.length == 0 || body.length == 0
    res.set_status(400)
    return "{\"error\":\"author and body required\"}"
  end

  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("INSERT INTO messages (room, author, body, created_at) VALUES (?, ?, ?, ?)")
  db.bind_str(1, room)
  db.bind_str(2, author)
  db.bind_str(3, body)
  db.bind_int(4, Time.now.to_i)
  db.step
  db.finalize
  id = db.last_rowid

  # Fold the send into the sender's presence too.
  db.prepare("INSERT OR REPLACE INTO presence (user, last_seen) VALUES (?, ?)")
  db.bind_str(1, author)
  db.bind_int(2, Time.now.to_i)
  db.step
  db.finalize
  db.close

  LOGGER.info("send id=" + id.to_s + " by " + author + ": " + body)
  "{" + Tep::Json.encode_pair_int("id", id) + "}"
end

post '/chat/heartbeat' do
  res.headers["Content-Type"] = "application/json"
  user = params[:user]
  if user.length == 0
    res.set_status(400)
    return "{\"error\":\"user required\"}"
  end
  db = Tep::SQLite.new
  db.open(DB_PATH)
  db.prepare("INSERT OR REPLACE INTO presence (user, last_seen) VALUES (?, ?)")
  db.bind_str(1, user)
  db.bind_int(2, Time.now.to_i)
  db.step
  db.finalize
  db.close
  "{\"ok\":1}"
end

get '/chat/who' do
  res.headers["Content-Type"] = "application/json"
  cutoff = Time.now.to_i - PRESENCE_TTL

  db = Tep::SQLite.new
  db.open(DB_PATH)
  out = "["
  first = true
  db.prepare("SELECT user, last_seen FROM presence WHERE last_seen >= ? ORDER BY last_seen DESC")
  db.bind_int(1, cutoff)
  while db.step == 1
    if !first
      out = out + ","
    end
    first = false
    out = out + "{" +
      Tep::Json.encode_pair_str("user", db.col_str(0)) + "," +
      Tep::Json.encode_pair_int("last_seen", db.col_int(1)) + "}"
  end
  db.finalize
  db.close
  out + "]"
end

# Non-streaming fallback for clients that don't grok SSE.
get '/chat/recent' do
  res.headers["Content-Type"] = "application/json"
  since = (params[:since].length > 0 ? params[:since] : "0").to_i

  db = Tep::SQLite.new
  db.open(DB_PATH)
  out = "["
  first = true
  db.prepare("SELECT id, author, body FROM messages WHERE id > ? ORDER BY id LIMIT 200")
  db.bind_int(1, since)
  while db.step == 1
    if !first
      out = out + ","
    end
    first = false
    out = out + "{" +
      Tep::Json.encode_pair_int("id", db.col_int(0)) + "," +
      Tep::Json.encode_pair_str("author", db.col_str(1)) + "," +
      Tep::Json.encode_pair_str("body",   db.col_str(2)) + "}"
  end
  db.finalize
  db.close
  out + "]"
end

# -------------------------------------------------------------------
# SSE stream
# -------------------------------------------------------------------
#
# Polls the messages table once per second, emits any rows with id
# greater than the last one we sent, plus an SSE comment keepalive
# on every tick so an idle connection still proves it's alive.
# After STREAM_MAX seconds the pump returns; the client reconnects
# (?since=<last_id>) to keep going.
#
# Single-cursor-per-process: each pump tick opens its own SQLite
# handle, runs the SELECT to completion, and closes the handle
# before sleeping. That keeps the cursor lifetime short and lets a
# concurrent /chat/send on the same worker (none, since workers are
# single-threaded) or a different worker run uncontested.

class ChatStreamer < Tep::Streamer
  attr_accessor :since_id

  def initialize
    @since_id = 0
  end

  def pump(out)
    last_id = @since_id
    ticks = 0
    while ticks < STREAM_MAX
      db = Tep::SQLite.new
      db.open(DB_PATH)
      db.prepare("SELECT id, author, body FROM messages WHERE id > ? ORDER BY id LIMIT 50")
      db.bind_int(1, last_id)
      while db.step == 1
        id     = db.col_int(0)
        author = db.col_str(1)
        body   = db.col_str(2)
        line = "data: {" +
          Tep::Json.encode_pair_int("id", id) + "," +
          Tep::Json.encode_pair_str("author", author) + "," +
          Tep::Json.encode_pair_str("body",   body) + "}\n\n"
        out.write(line)
        if id > last_id
          last_id = id
        end
      end
      db.finalize
      db.close

      # SSE comment keepalive -- the browser EventSource ignores it
      # but the byte arriving on the socket is what we use to detect
      # a half-closed peer (writes start failing once the kernel
      # learns the other side is gone).
      out.write(": tick\n\n")

      sleep 1
      ticks += 1
    end
    0
  end
end

get '/chat/stream' do
  res.headers["Content-Type"] = "text/event-stream"
  res.headers["Cache-Control"] = "no-cache"
  s = ChatStreamer.new
  s.since_id = (params[:since].length > 0 ? params[:since] : "0").to_i
  stream s
end
