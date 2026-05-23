# counter -- the smallest Tep::LiveView demo

A single shared integer counter, server-side. Open in two browsers,
click `+` in one, watch the other update.

```
┌──────────────────────────────┐
│       SHARED COUNTER         │
│                              │
│              7               │
│                              │
│         [ - ]  [ + ]         │
│           reset              │
│                              │
│  open this page in another   │
│  tab to see live updates.    │
└──────────────────────────────┘
```

## Run

```sh
bin/tep build examples/counter/app.rb -o /tmp/counter
/tmp/counter -p 4567
# open http://127.0.0.1:4567/counter in two browsers
```

## What it shows

This is the smallest possible app that exercises three pieces of
the LiveView surface at once:

| Piece | What it does here |
|---|---|
| `Tep.live "/counter", CounterView` | One DSL call lowers to GET `/counter` (initial render + bootstrap JS) **and** WS `/counter/ws` (event dispatch + re-render). No manual `websocket` block. |
| `CounterView#topic` | Returns a stable string. Every WS connection that opens against this view subscribes to that topic automatically; `broadcast_render` fans out to all of them. |
| `broadcast_render` | After mutating the shared `COUNTER`, every subscriber sees the new HTML in <100ms via a single WS TEXT frame. The bootstrap JS in `Tep::LiveView.render_page` does `outerHTML = e.data` on `#tep-live-root`. |

## Code

~30 lines of Ruby for the view + handler; ~20 lines of inline CSS.
No JS to write -- click + re-render comes from the bootstrap
shell that `Tep.live` wires automatically. Clicks on any element
with `data-event="..."` send `{"event": <name>, "payload": ""}`
over the WS; the server's `handle_event` mutates state + calls
`broadcast_render`; every subscriber re-renders.

## Shared state

The counter lives in a module-level `COUNTER = [0]` array
(single-element typed slot, because spinel doesn't track module-
level `@@cvar` writes reliably across method calls). Per-worker
scope: a multi-worker deployment would need
`Tep::Broadcast.enable_pg_backend` to route NOTIFYs through PG so
all workers see the same mutations. Left out here for demo
simplicity.

## What this demo does NOT show

- **Per-user state.** Every browser sees the same number. For
  per-user LiveView state, give the view per-instance ivars +
  seed them in `mount(req)` from `req.identity` or `req.params`.
- **Authentication.** No `Tep.session_secret` / `Tep::Auth.install!`
  here. The presence-aware four-battery surface lives in
  [`examples/agentic_chat`](../agentic_chat).
- **History / persistence.** The counter resets to 0 on every
  server restart. For persistent state, mutate a `Tep::SQLite`
  table from `handle_event`.
