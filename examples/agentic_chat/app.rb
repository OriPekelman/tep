# Agentic chat -- the four-battery demo.
#
# A small chat-room view exercising every battery in tep's
# agentic story: Tep::Auth (session-cookie identity),
# Tep::Broadcast (in-process publish path), Tep::Presence
# (who's here, agent-aware, with structured status),
# Tep::LiveView (the render_page bootstrap helper).
#
# This v1 uses **HTTP polling** instead of a live WS-driven
# feed. The reason: tep's `websocket "/path" do |ws|` DSL
# doesn't bridge the per-request `req` into on_X handler
# bodies, and a spinel inference quirk widens `evt.data` to
# poly when it flows into custom helpers from inside on_message.
# A real-time WS chat is the natural shape -- filed as a tep
# follow-up; this demo gets you the agentic surface across
# all four batteries today.
#
# Run:
#   bin/tep build examples/agentic_chat/app.rb -o /tmp/agentic_chat
#   /tmp/agentic_chat -p 4567
# Open http://127.0.0.1:4567/ in two browsers.
require 'sinatra'

Tep.session_secret = "demo-only-do-not-use-in-prod-XXXXXXXXXX"
Tep::Auth.install!

CHAT_TOPIC = "agentic_chat:room"

# ---- shared chat state ----
#
# Parallel string arrays for the message log + simple `add`
# entry point. Plain class (no Tep::LiveView subclass) to
# sidestep the virtual-dispatch widening tep's translator
# currently emits across LiveView base + subclass.

class ChatRoom
  def initialize
    @msg_subjects = [""]
    @msg_subjects.delete_at(0)
    @msg_bodies = [""]
    @msg_bodies.delete_at(0)
    @msg_kinds = [""]
    @msg_kinds.delete_at(0)
  end

  def add(subject, body, kind)
    @msg_subjects.push(subject)
    @msg_bodies.push(body)
    @msg_kinds.push(kind)
    while @msg_subjects.length > 50
      @msg_subjects.delete_at(0)
      @msg_bodies.delete_at(0)
      @msg_kinds.delete_at(0)
    end
    0
  end

  def render
    out = "<div id='messages'>"
    if @msg_subjects.length == 0
      out = out + "<div class='msg empty'>" +
        "<em>no messages yet. say hi using the form below.</em></div>"
    end
    i = 0
    while i < @msg_subjects.length
      out = out + "<div class='msg " + @msg_kinds[i] + "'>" +
        "<span class='who'>" + Tep.h(@msg_subjects[i]) + "</span>" +
        "<span class='body'>" + Tep.h(@msg_bodies[i]) + "</span>" +
        "</div>"
      i += 1
    end
    out + "</div>"
  end
end

CHAT = ChatRoom.new

# ---- synthetic agent state ----

AGENT_FD_COUNTER = [-9000]

def next_agent_fd
  AGENT_FD_COUNTER[0] = AGENT_FD_COUNTER[0] - 1
  AGENT_FD_COUNTER[0]
end

def spawn_agent(principal_id)
  fd = next_agent_fd
  agent_req = Tep::Request.new
  delegation = Tep::AgentDelegation.new(
    "summarizer-bot", Time.now.to_i,
    Time.now.to_i + 3600, :oauth_grant)
  agent_req.identity = Tep::Identity.new(
    principal_id, delegation, [:read, :post_summary])
  Tep::Presence.track(agent_req, CHAT_TOPIC, fd)
  Tep::Presence.set_status(
    CHAT_TOPIC, fd, :busy, "summarizing the room",
    Time.now.to_i + 60)
  CHAT.add(
    "agent:summarizer-bot/" + principal_id,
    "i'm here -- watching for things to summarize.", "agent")
  Tep::Broadcast.publish(CHAT_TOPIC, "agent-spawned")
  fd
end

# ---- presence sidebar ----

def render_presence
  entries = Tep::Presence.list(CHAT_TOPIC)
  humans = ""
  agents = ""
  hcount = 0
  acount = 0
  i = 0
  while i < entries.length
    e = entries[i]
    row = "<div class='pres-row " + e.kind.to_s + " " +
      e.status_state.to_s + "'>" +
      "<span class='dot'></span>" +
      "<span class='who'>" + Tep.h(e.principal_id) + "</span>"
    if e.kind == :agent_for
      row = row + "<span class='agent-of'>via " +
        Tep.h(e.agent_id) + "</span>"
    end
    if e.status_state != :available
      row = row + "<div class='note'>" + e.status_state.to_s +
        ": " + Tep.h(e.status_note) + "</div>"
    end
    row = row + "</div>"
    if e.kind == :human
      humans = humans + row
      hcount += 1
    else
      agents = agents + row
      acount += 1
    end
    i += 1
  end
  "<aside id='presence'>" +
    "<h3>humans (" + hcount.to_s + ")</h3>" +
    "<div class='group humans'>" + humans + "</div>" +
    "<h3>agents (" + acount.to_s + ")</h3>" +
    "<div class='group agents'>" + agents + "</div>" +
  "</aside>"
end

# ---- routes ----

before do
  # principal_id is opaque -- Identity#subject prepends "user:"
  # for humans, so the principal stored on the session should NOT
  # already carry it.
  #
  # We also set req.identity directly: Tep::AuthFilter runs
  # BEFORE this before-filter, so it already populated
  # req.identity from session (= anonymous on first visit).
  # AuthSessionCookie.set writes to req.session but
  # req.identity stays whatever the auth filter put there.
  # Direct assignment plugs the gap for the same-request render.
  if req.session.get("identity_sub").length == 0
    pid = Crypto.sp_crypto_random_b64url(4)
    ident = Tep::Identity.new(pid, nil, [:read, :write])
    Tep::AuthSessionCookie.set(req, ident, 0)
    req.identity = ident
  end
end

get '/' do
  res.set_status(302)
  res.headers["Location"] = "/chat"
  ""
end

get '/chat' do
  res.headers["Content-Type"] = "text/html; charset=utf-8"
  # Track the human's session in presence. Synthetic fd derived
  # from the principal_id so reloads reuse the same row.
  pid = req.identity.principal_id
  fd = pid.bytes[5]   # cheap deterministic-per-user fd; collisions
                      # tolerable for the demo
  Tep::Presence.track(req, CHAT_TOPIC, fd)
  user_subject = req.identity.subject
  "<!doctype html><html><head>" +
    "<meta charset='utf-8'>" +
    "<title>agentic chat (tep)</title>" +
    "<meta http-equiv='refresh' content='3'>" +
    "<link rel='stylesheet' href='/agentic_chat/style.css'>" +
    "</head><body>" +
    "<header>" +
      "<span class='title'>agentic chat</span>" +
      "<span class='user'>you are <code>" +
        Tep.h(user_subject) + "</code></span>" +
    "</header>" +
    "<main>" +
      "<section id='room'>" +
        CHAT.render +
        "<form id='compose' action='/chat/send' method='POST'>" +
          "<input name='body' placeholder='message…' autocomplete='off' autofocus>" +
          "<button type='submit'>send</button>" +
        "</form>" +
        "<form id='agent-form' action='/agent/add' method='POST'>" +
          "<button type='submit'>+ summarizer</button>" +
        "</form>" +
      "</section>" +
      render_presence +
    "</main>" +
    "</body></html>"
end

post '/chat/send' do
  body = req.params["body"]
  if body.length > 0
    CHAT.add(req.identity.subject, body, "human")
    Tep::Broadcast.publish(CHAT_TOPIC, "message-added")
  end
  res.set_status(302)
  res.headers["Location"] = "/chat"
  ""
end

post '/agent/add' do
  pid = req.identity.principal_id + ""
  spawn_agent(pid)
  res.set_status(302)
  res.headers["Location"] = "/chat"
  ""
end

get '/agentic_chat/style.css' do
  res.headers["Content-Type"] = "text/css"
  agentic_chat_css
end

# ---- inline assets ----

def agentic_chat_css
  "*{box-sizing:border-box}" +
  "body{margin:0;font:14px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;" +
    "background:#f6f7f9;color:#1a1a1a}" +
  "header{display:flex;justify-content:space-between;align-items:center;" +
    "padding:.6rem 1rem;background:#1a1a1a;color:#f6f7f9}" +
  "header .title{font-weight:600}" +
  "header .user code{background:#2a2a2a;padding:.15em .4em;border-radius:3px;" +
    "font-size:.85em;color:#cde}" +
  "main{display:grid;grid-template-columns:1fr 260px;height:calc(100vh - 44px)}" +
  "#room{display:flex;flex-direction:column;background:#fff}" +
  "#messages{flex:1;overflow-y:auto;padding:1rem;display:flex;" +
    "flex-direction:column;gap:.4rem}" +
  ".msg{display:flex;gap:.6rem;padding:.3rem .5rem;border-radius:4px}" +
  ".msg.empty{justify-content:center;color:#888}" +
  ".msg .who{color:#666;font-size:.85em;min-width:11rem;text-align:right;" +
    "flex-shrink:0;font-family:ui-monospace,monospace}" +
  ".msg .body{flex:1}" +
  ".msg.agent{background:#fef8eb}" +
  ".msg.agent .who{color:#a07412}" +
  "#compose{display:flex;gap:.5rem;padding:.7rem;border-top:1px solid #e8e9eb;" +
    "background:#fafbfc}" +
  "#compose input{flex:1;padding:.5rem .7rem;border:1px solid #d0d3d8;" +
    "border-radius:4px;font:inherit;background:#fff}" +
  "#compose input:focus{outline:none;border-color:#3b82f6}" +
  "#compose button{padding:.5rem .9rem;border:1px solid #d0d3d8;background:#1a1a1a;" +
    "color:#fff;border-color:#1a1a1a;border-radius:4px;font:inherit;cursor:pointer}" +
  "#compose button:hover{background:#000}" +
  "#agent-form{padding:.5rem .7rem;background:#fafbfc;border-top:1px solid #e8e9eb}" +
  "#agent-form button{padding:.4rem .8rem;border:1px solid #d0d3d8;background:#fff;" +
    "border-radius:4px;font:inherit;cursor:pointer}" +
  "#agent-form button:hover{background:#f0f1f3}" +
  "#presence{background:#fafbfc;border-left:1px solid #e8e9eb;padding:1rem;" +
    "overflow-y:auto}" +
  "#presence h3{margin:0 0 .5rem;font-size:.7em;text-transform:uppercase;" +
    "letter-spacing:.08em;color:#888;font-weight:600}" +
  "#presence .group{margin-bottom:1.5rem;display:flex;flex-direction:column;gap:.4rem}" +
  ".pres-row{display:flex;align-items:center;gap:.5rem;font-size:.9em;flex-wrap:wrap}" +
  ".pres-row .dot{width:.6rem;height:.6rem;border-radius:50%;background:#22c55e;" +
    "flex-shrink:0}" +
  ".pres-row.busy .dot{background:#eab308}" +
  ".pres-row.blocked .dot{background:#ef4444}" +
  ".pres-row .who{font-family:ui-monospace,monospace;font-size:.85em;color:#1a1a1a}" +
  ".pres-row.agent_for .who{color:#a07412}" +
  ".pres-row .agent-of{font-size:.75em;color:#888;font-family:ui-monospace,monospace}" +
  ".pres-row .note{width:100%;padding-left:1.1rem;font-size:.8em;color:#888;" +
    "font-style:italic}"
end

# bin/tep auto-injects Tep.run! at the bottom of the translated
# source AFTER the generated route registrations, so don't add
# our own here -- if we did, the server would start before the
# routes existed and every request would 404.
