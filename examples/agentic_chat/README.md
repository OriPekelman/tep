# agentic chat -- the four-battery demo

A small chat room exercising every battery in tep's agentic
story: identity, broadcast, presence, server-rendered HTML
pushed over WebSocket.

```
┌───────────────────────────────────────────────────────────┐
│  agentic chat                      you are user:uXsC2g    │
├──────────────────────────────────────┬────────────────────┤
│  user:42  hi                         │  HUMANS (2)        │
│  user:99  hello                      │  • user:42         │
│  agent:summarizer-bot/user:42        │  • user:99         │
│           i'm here -- watching for   │                    │
│           things to summarize.       │  AGENTS (1)        │
│                                      │  • user:42         │
│  [ type message      ]        [send] │      via summari…  │
│                                      │      busy:         │
│  [+ summarizer]                      │      summarizing   │
└──────────────────────────────────────┴────────────────────┘
```

## Run

```sh
bin/tep build examples/agentic_chat/app.rb -o /tmp/agentic_chat
/tmp/agentic_chat -p 4567
# open http://127.0.0.1:4567/ in two browsers
```

Every chat message + agent spawn arrives in the other tab in
<100ms via a WebSocket push. No polling, no full-page reload --
the server re-renders the `#messages` + `#presence` regions on
every change and broadcasts both to all subscribed sockets.
Click **+ summarizer** to invite a synthetic agent into the
room -- it appears in the presence sidebar with `kind=agent_for`,
shares the inviter's `principal_id`, and posts an arrival
message.

## What's wired

| Battery | What it does here |
|---|---|
| `Tep::Auth` (`Tep::AuthSessionCookie`) | Every visitor's first request auto-creates an `identity` cookie. Subsequent requests land with `req.identity` populated; `req.identity.subject` is rendered in the header + drives presence rows. |
| `Tep::AuthOAuth2`-style delegation | The `+ summarizer` route constructs a `Tep::AgentDelegation` + `Tep::Identity` with `kind=:agent_for, origin=:oauth_grant` -- same shape an external bot would receive over the real OAuth flow. |
| `Tep::Broadcast` | Every `POST /chat/send` and `POST /agent/add` calls `publish_room`, which builds the updated `#messages` + `#presence` HTML once and publishes a single TEXT frame to every WS subscriber via `Tep::Broadcast.publish`. |
| `Tep::Presence` | Humans tracked on every `GET /chat` (one row per principal_id). Agents tracked on `+ summarizer` with `status_state=:busy, status_note="summarizing the room"`. Sidebar renders both groups with the agentic kind + status. |
| `Tep::LiveView` | `CHAT.render` + `render_presence` are the live-view content targets. The WS push delivers the new HTML; client-side JS does `outerHTML = ...` on both regions in place. The same render functions run for the initial page load and for every push -- no special template-vs-push divergence. |

## Wire shape

```
client                          server
   |  GET  /chat                   |
   |<------------------------------|  full page (HTML + JS)
   |                               |
   |  GET  /chat/ws (Upgrade)      |
   |------------------------------>|  websocket "/chat/ws" do |ws|
   |<------------------------------|    on_open -> subscribe_ws
   |     101 Switching             |
   |                               |
   |  POST /chat/send {body:"hi"}  |
   |------------------------------>|  CHAT.add + publish_room
   |<------------------------------|  204 No Content
   |                               |
   |<------------------------------|  WS TEXT frame:
   |   "<<TEP>><div id='messages'> |   "<<TEP>>{messages}
   |     ...<<TEP>><aside id='     |    <<TEP>>{presence}"
   |     presence'>..."            |
   |                               |
   |   JS: e.data.split('<<TEP>>') |
   |       -> swap each outerHTML  |
```

`<<TEP>>` is a sentinel separator (ASCII, unlikely to appear in
user text). The server packs both regions into one frame so
subscribers see them update atomically.

## Code size

| File | LOC |
|---|---|
| `app.rb` | ~270 (incl. CSS + JS inline) |
| `README.md` | this file |

No CSS framework, no JS bundler, no DB.

## What this demo does NOT show

- **Cross-worker presence/broadcast.** Single worker. Both
  `Tep::Broadcast.enable_pg_backend` and
  `Tep::Presence.enable_pg_mirror` would make this multi-
  worker; left out for demo simplicity.
- **Real bot in a separate process.** The "+ summarizer"
  button adds a synthetic presence row + posts one message
  in the same process. A real bot would open its own WS with
  the JWT minted by `Tep::AuthOAuth2.exchange_code` and chat
  alongside the humans -- the framework surface is identical.
- **Per-subscriber rendering.** Every WS subscriber gets the
  same HTML payload. Personalized views (e.g. mention
  highlights for the current user) would need either per-fd
  render filters or a client-side template that consumes a
  structured payload instead of HTML.
