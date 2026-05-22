# agentic chat -- the four-battery demo

A small chat room exercising every battery in tep's agentic
story: identity, broadcast, presence, server-rendered HTML.

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

Page auto-refreshes every 3 seconds (HTTP `<meta refresh>`) so
new messages + presence changes from other tabs appear. Click
**+ summarizer** to invite a synthetic agent into the room —
it appears in the presence sidebar with `kind=agent_for`,
shares the inviter's `principal_id`, and posts an arrival
message.

## What's wired

| Battery | What it does here |
|---|---|
| `Tep::Auth` (`Tep::AuthSessionCookie`) | Every visitor's first request auto-creates an `identity` cookie. Subsequent requests land with `req.identity` populated; `req.identity.subject` is rendered in the header + drives presence rows. |
| `Tep::AuthOAuth2`-style delegation | The `+ summarizer` route constructs a `Tep::AgentDelegation` + `Tep::Identity` with `kind=:agent_for, origin=:oauth_grant` — same shape an external bot would receive over the real OAuth flow. |
| `Tep::Broadcast` | Every `POST /chat/send` and `POST /agent/add` calls `Tep::Broadcast.publish(CHAT_TOPIC, …)`. v1 polling means subscribers aren't WS clients (yet); the publish wire is in place for the WS upgrade when spinel's WS-handler widening is resolved. |
| `Tep::Presence` | Humans tracked on every `GET /chat` (one row per principal_id). Agents tracked on `+ summarizer` with `status_state=:busy, status_note="summarizing the room"`. Sidebar renders both groups with the agentic kind + status. |
| `Tep::LiveView` | The rendered `#messages` block is the live-view content target. The full live-WS path is held — see "wire shape" below — but the `render_page` helper + `ChatRoom#render` pattern is what an upgraded LiveView would use unchanged. |

## Wire shape

v1 uses HTTP polling via `<meta http-equiv="refresh" content="3">`.
The natural shape — WS-driven server pushes — is held up on two
spinel-side surfaces I hit while building this:

1. **`Tep::Json.get_str` widens when called from inside an
   `on_message do |evt| ... end` block.** The translator
   generates a `Tep::WebSocket::Handler` subclass per event;
   reading `evt.data` and slicing it inside the body causes
   spinel to widen `evt.data` (declared as `String`) to poly,
   which cascades through every downstream `String` slot the
   message touches. Adding a `sig/tep/websocket.rbs` with
   `Event#data: String` + enabling `--rbs` doesn't fix it
   today; `spinel_rbs_extract` only loads if it's built (`make
   rbs_extract`), and tep's overall RBS coverage is too stale
   for `--rbs` to be defaulted on without a multi-PR cleanup.

2. **The `websocket "/path" do |ws|` DSL doesn't bridge the
   per-request `req` into `on_open` / `on_message` handler
   bodies.** Each handler becomes a separate `Handler`
   subclass with `@ws` storage but no `req` — so capturing the
   session-cookie identity at upgrade time + attaching it to
   the WS connection needs an out-of-band shape (e.g. the
   client sends a "hello|<subject>" first frame, server caches
   keyed by fd).

Both are tep-side issues, separate from this PR.

When those resolve, the polling layer drops out and the route
becomes a real WS-driven LiveView with sub-second updates +
`handle_presence_diff` running server-side. The CSS, HTML,
ChatRoom class, presence-rendering helpers all stay; only the
transport changes.

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
  alongside the humans — the framework surface is identical.
- **Sub-second updates.** Polling at 3s; WS at <100ms once
  spinel unblocks the surfaces above.
