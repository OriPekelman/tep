# Batteries design: Auth · Broadcast · Presence · LiveView

Roadmap for the next four batteries on tep. Designed in one session on
2026-05-21; implementation gated on matz/spinel#641 (per-fiber GC root
fix in `sp_runtime.h` that's required for `Tep::Server::Scheduled` to
survive sustained burst load).

Vision framing: **"web framework for a live agentic age"** — every
battery treats AI agents as first-class participants on equal footing
with humans. Sandbox and agent-loop primitives are explicitly **not**
built by tep; tep is the harness, external runners (gvisor, firecracker,
hosted services) do the actual sandboxing.

## Dependency graph

```
Auth   ────────────────┐
                       ├─→  LiveView
Broadcast ─→ Presence ─┘
```

Auth is independent and ships value immediately. Broadcast is the
lowest level transport. Presence builds on Broadcast plus PG for
cross-worker state. LiveView assumes both Presence and a Broadcast-
shaped event bus. Sandbox / agent-loop come later as a thin orchestration
layer over an external runner.

## Cross-battery primitives

These types flow through every battery; they're the spine.

```ruby
class Tep::Identity
  attr_reader :principal_id            # "user:42" — the human
  attr_reader :acting_via              # nil, or AgentDelegation
  attr_reader :capabilities            # Set of capability symbols
  def human?       ; acting_via.nil?           end
  def agent?       ; !human?                   end
  def may?(cap)    ; capabilities.include?(cap) end
  def subject
    return "user:#{principal_id}" if human?
    "agent:#{acting_via.agent_id}/#{principal_id}"
  end
end

class Tep::AgentDelegation
  attr_reader :agent_id, :issued_at, :expires_at, :origin
  # origin ∈ {:token, :oauth_grant, :session_handoff, ...}
end
```

`Tep::Auth` sets `req.identity`. Consumed by Broadcast (authz on publish/
subscribe), Presence (entry `kind` + delegation), LiveView (event
attribution and rendering).

### Capability vocabulary — hybrid (closed core + extension hook)

tep ships a fixed core set, apps register their own domain caps:

```ruby
# Core, always available:
Tep::Auth::CAPABILITIES = %i[read write authn authz]

# Apps extend:
Tep::Auth.register_capability(:post_to_room)
Tep::Auth.register_capability(:moderate_room)
```

Agent grants carry a subset of the principal's capabilities, never a
superset. The `Identity#may?(cap)` check is the universal authz primitive.

## Battery 1: Auth

### Provider chain

```ruby
Tep::Auth.providers.add(Tep::Auth::BearerToken.new(secret: ENV["JWT_SECRET"]))
Tep::Auth.providers.add(Tep::Auth::SessionCookie.new)
Tep::Auth.providers.add(Tep::Auth::OAuth2.new(google: { ... }))

# Installed before-filter:
before do
  req.identity = Tep::Auth.identify(req) || Tep::Identity.anonymous
end
```

### Provider interface

```ruby
class Tep::Auth::BearerToken
  def sniff(req)
    req.headers["authorization"]&.start_with?("Bearer ")
  end

  def verify(req)
    token = req.headers["authorization"][7..]
    payload = JWT.verify(token, @secret)
    Tep::Identity.from_jwt(payload)
  rescue JWT::Error
    nil
  end
end
```

First sniffer to match wins; verification failure short-circuits to 401.
Apps can compose providers — e.g. accept Bearer for API endpoints,
SessionCookie for the rest.

### JWT shape

Same payload for human sessions and agent grants. The presence or
absence of `acting_via` is the only difference:

```json
{
  "sub": "user:42",
  "acting_via": { "agent_id": "summarizer-bot", "expires_at": 1716396000 },
  "caps": ["read", "post_summary"],
  "iat": 1716392400,
  "exp": 1716396000
}
```

For a human web session via SessionCookie, `acting_via` is absent and
`caps` is the principal's full grant. For an agent token,
`acting_via.expires_at` typically tracks `exp` (short-lived).

### OAuth agentic seam

The grant endpoint accepts `?intent=agent&agent_id=X&caps=read,post_summary`
query params. Consent screen renders:

> **summarizer-bot** wants to act on your behalf with these permissions:
> - Read your messages
> - Post summaries on your behalf

Instead of the standard "App wants to access your data." The resulting
token has `acting_via` populated. Outside the consent UI, the OAuth flow
is standard.

## Battery 2: Broadcast

Pub-sub primitive. Cross-process by default (single-process is useless
under prefork). Backend is pluggable.

### Public API

```ruby
Tep::Broadcast.publish(topic, payload, from: req.identity)
Tep::Broadcast.subscribe(topic, identity: req.identity) do |msg|
  # msg = Tep::Broadcast::Message
  #   .topic, .payload, .from (Identity), .published_at
end
```

### Backend interface

```ruby
class Tep::Broadcast::Backend
  def publish(topic, payload, from_subject) ; raise NotImplementedError end
  def subscribe(topic, callback)            ; raise NotImplementedError end  # → subscription_id
  def unsubscribe(subscription_id)          ; raise NotImplementedError end
end
```

Two backends shipped together (per "pluggable from day 1" decision):

- **`Tep::Broadcast::InProc`** — single-process, in-memory fan-out.
  Useful for development with `prefork=1` and for tests. No external
  dependencies.
- **`Tep::Broadcast::Postgres`** — PG `LISTEN/NOTIFY` for cross-worker
  pub-sub. Single per-worker fiber holds the LISTEN connection and
  fans out to local subscribers. 8KB payload limit on the wire; for
  larger payloads, `publish(topic, payload, durable: true)` writes to
  a `broadcast_outbox` table and the wire-side notify carries
  `{ id: outbox_id }` — subscribers fetch on receipt.

Backend selection:

```ruby
Tep::Broadcast.backend = Tep::Broadcast::Postgres.new(pool: Tep::PG::POOL)
```

### Authz

Two layers. The `:read` (subscribe) / `:write` (publish) caps gate the
basic operation. An app-defined callback narrows further:

```ruby
Tep::Broadcast.authorize do |topic, identity, mode|
  case mode
  when :subscribe then identity.may?(:read)  && room_allows?(topic, identity)
  when :publish   then identity.may?(:write) && room_allows?(topic, identity)
  end
end
```

### Wire format on PG

```
NOTIFY tep_bcast, '<topic>|<from_subject>|<json_payload>'
```

For `durable: true`:

```
NOTIFY tep_bcast, '<topic>|<from_subject>|@<outbox_id>'
```

Outbox table:

```sql
CREATE TABLE broadcast_outbox (
  id BIGSERIAL PRIMARY KEY,
  topic TEXT NOT NULL,
  from_subject TEXT NOT NULL,
  payload JSONB NOT NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON broadcast_outbox (published_at);
```

Background reaper prunes entries older than N hours.

### WS bridge

The seam every other battery uses. Inside a WS handler:

```ruby
ws.subscribe("room:lobby")
ws.on(:broadcast) do |topic, msg|
  ws.send(msg.to_wire)
end
```

A per-worker dispatcher fiber holds the LISTEN connection and fans out
to subscribed WS fibers — no per-subscriber DB connection.

## Battery 3: Presence

Built on Broadcast for diff fan-out, on PG for cross-worker storage.

### Public API

```ruby
# In a WS handler, after auth:
Tep::Presence.track(ws, topic: "room:lobby", meta: { typing: false })

# List:
Tep::Presence.list("room:lobby")
# →
# { "user:42" => [
#     { kind: :human,      session_id: "abc",
#       status: { state: :available, note: nil, until: nil },
#       meta: { typing: false }, since: ... },
#     { kind: :agent_for,  agent_id: "summarizer-bot", session_id: "def",
#       status: { state: :busy, note: "summarizing", until: nil },
#       meta: {}, since: ... }
#   ],
#   "user:99" => [ { kind: :human, ... } ] }

# Update meta during the session:
Tep::Presence.update(ws, meta: { typing: true })

# Set structured status:
Tep::Presence.set_status(ws, state: :busy, note: "summarizing thread #1234")
Tep::Presence.set_status(ws, state: :blocked, note: "Claude API throttled",
                              until: Time.now + 600)
Tep::Presence.clear_status(ws)

# Subscribe to diffs:
Tep::Presence.subscribe("room:lobby") do |diff|
  # diff = { joins: { "user:42" => [...] }, leaves: { ... }, updates: { ... } }
end

# Filter:
Tep::Presence.list("room:lobby", kind: :human)
Tep::Presence.count_humans("room:lobby")
Tep::Presence.count_agents("room:lobby")
```

### Structured status — KISS spec

```ruby
class Tep::Presence::Status
  attr_reader :state   # :available | :busy | :blocked
  attr_reader :note    # String — free text, ~140 char soft hint
  attr_reader :until   # Time | nil — auto-expires back to :available
end
```

- `:available` — ready to handle work. UI: green dot.
- `:busy` — working on something, will respond eventually. UI: yellow dot.
- `:blocked` — waiting on something external, won't respond until
  unblocked. UI: red dot.

The three-state vocabulary is the minimum that lets a collaborating bot
decide whether to pick up work. Anything finer (away vs extended-away,
dnd vs offline) is a UI concern that the `note` field carries.

`status` is separate from `meta` because `meta` is app-arbitrary (typing
indicator, current view URL) while `status` is the cross-app
collaboration primitive every battery and every app understands.

Auto-expiry: a background fiber walks entries whose `status.until <= now`
and emits an update diff resetting them to `:available`.

### Storage

Per-topic in-memory hash on each worker (fast list/diff path) backed by
a PG table for cross-worker visibility:

```sql
CREATE TABLE presence_entries (
  topic         TEXT NOT NULL,
  principal_id  TEXT NOT NULL,
  session_id    TEXT NOT NULL,
  kind          TEXT NOT NULL,   -- 'human' | 'agent_for'
  agent_id      TEXT,            -- nullable; populated when kind = 'agent_for'
  status_state  TEXT NOT NULL DEFAULT 'available',
  status_note   TEXT,
  status_until  TIMESTAMPTZ,
  meta          JSONB NOT NULL DEFAULT '{}',
  expires_at    TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (topic, principal_id, session_id)
);
CREATE INDEX ON presence_entries (expires_at);
```

### Lifecycle

- `track` upserts a row, sets `expires_at = now() + 60s`, publishes a
  `:join` diff via Broadcast.
- Per-WS heartbeat fiber refreshes `expires_at` every 25s.
- On WS close (`ws.on(:close)`), delete the row + publish `:leave` diff.
- Background reaper fiber prunes rows where `expires_at < now()` and
  publishes `:leave` diffs for them (covers worker-crash recovery).
- Status expiry: separate background pass for rows where
  `status_until < now()` — set state back to `:available`, publish
  `:update` diff.

Worker-crash diffs emit late (within ~25-50s); acceptable for v1.
Tighter eviction needs worker liveness signaling.

## Battery 4: LiveView

Stateful server-rendered UI over WS.

### Public API

```ruby
class CounterView < Tep::LiveView
  topic "counter:#{params[:id]}"     # binds this view to a Broadcast topic

  def mount(req)
    @count    = 0
    @viewers  = Tep::Presence.list(topic)
  end

  def render
    ERB.new(VIEW_ERB).result(binding)
  end

  def handle_event("inc", _payload, req)
    raise Tep::LiveView::Unauthorized unless req.identity.may?(:write)
    @count += 1
    Tep::Broadcast.publish(topic, { kind: :inc, by: req.identity.subject })
  end

  def handle_broadcast(msg)
    # Triggered when this view's bound topic broadcasts something;
    # re-render fires automatically after this returns.
  end

  def handle_presence_diff(diff)
    @viewers = Tep::Presence.list(topic)
  end
end
```

### Lifecycle

1. **Initial GET** renders the full HTML with a small `<script>` that
   opens a WS to the live-view endpoint.
2. **WS upgrade** → `mount` runs, server stores state in the WS fiber's
   instance variables, sends the rendered HTML over WS as the initial
   payload.
3. **Client event** (`data-event="inc"` on a button click, form submit,
   keystroke, etc.) → `handle_event` on the server → state mutation →
   re-render → diff (or full HTML) sent over WS.
4. **Bound broadcast arrives** → `handle_broadcast` fires → re-render +
   diff.
5. **Presence diff on bound topic** → `handle_presence_diff` fires →
   re-render + diff.
6. **Close** → on WS close, instance is GC'd; no checkpointing in v1.

### Diff strategy

- **v1**: full innerHTML replacement of a wrapped
  `<div data-tep-live id="...">`. Trades wire bytes for implementation
  simplicity.
- **v2**: morphdom on the client side (bundled in `assets/`). Server
  still ships full HTML; client computes minimal DOM ops.

Server-side diff'ing is not in scope for either version.

### Agentic interaction

An agent's WS connection running this LiveView dispatches the same
`data-event` events as a human (capabilities check fires the same way).
The principal sees the resulting `Broadcast.publish` on their own
LiveView in real time. **No agent-specific LiveView API needed** — the
agent just behaves like an authenticated client with `acting_via` set.

### State-size constraint

Per-fiber heap state of a long-running LiveView grows. v1 documents the
constraint; v2 adds an optional `checkpoint` / `restore` pair that
serializes state to PG every N events for crash recovery.

## Sandbox / agent-loop — tep's role

Tep does **not** implement either. What tep provides is the harness:

```ruby
# Spawn an agent via an external runner. tep issues the token, tracks
# the agent, and authorizes its WS callback.
Tep::Agent.spawn(
  image: "summarizer:latest",
  principal: req.identity,
  capabilities: [:read, :post_summary],
  runner: :modal,                    # :modal, :firecracker, :gvisor, :local, ...
  on_message: ->(msg) { ... }
)
# → agent_id

# List running agents on behalf of the principal:
Tep::Agent.list_for(principal)

# Revoke (blacklist the token):
Tep::Agent.revoke(agent_id)
```

The runner adapter knows how to talk to its backing service. Tep tracks
all running agents in a `running_agents` table for visibility and revocation:

```sql
CREATE TABLE running_agents (
  agent_id      TEXT PRIMARY KEY,
  principal_id  TEXT NOT NULL,
  capabilities  TEXT[] NOT NULL,
  runner        TEXT NOT NULL,
  spawned_at    TIMESTAMPTZ NOT NULL,
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked_at    TIMESTAMPTZ,
  last_seen_at  TIMESTAMPTZ
);
```

Token revocation: the JWT verifier checks `running_agents.revoked_at`
on every request. If non-null, 401.

## End-to-end scenario

User is logged into a chat app, invites `summarizer-bot` to `#lobby`.

1. User clicks "Add summarizer." App `POST /agents` →
   `Tep::Agent.spawn(image: "summarizer:latest", principal: req.identity,
   capabilities: [:read, :post_summary], runner: :modal)`. Tep issues a
   JWT with `acting_via: { agent_id: "summarizer-bot" }`.
2. External runner starts the bot with the token. Bot opens a WS to tep
   with `Authorization: Bearer <token>`. Tep's Auth identifies it.
3. Bot calls `ws.subscribe("room:lobby")` and
   `Tep::Presence.track(ws, "room:lobby")`. Sets initial status:
   `Tep::Presence.set_status(ws, state: :busy, note: "summarizing")`.
4. Presence emits a join diff via Broadcast. User's LiveView for
   `#lobby` receives it in `handle_presence_diff`, re-renders.
   User sees "🤖 summarizer (busy: summarizing) joined."
5. User sends a message → user's WS handler `Broadcast.publish`es →
   bot's subscribed WS receives → bot processes via LLM call → bot
   `Broadcast.publish`es `{kind: :summary, text: "..."}`. The bot's
   `:post_summary` cap passes Broadcast's authorize callback.
6. User's LiveView's `handle_broadcast` fires, re-renders with the
   summary in line.
7. Bot hits the Claude API rate limit. Bot
   `Tep::Presence.set_status(ws, state: :blocked,
   note: "Claude API throttled", until: Time.now + 600)`. Presence
   emits an update diff. User's LiveView re-renders, shows
   "🤖 summarizer (blocked: Claude API throttled until 14:34)."
8. User closes the bot in the agent manager →
   `Tep::Agent.revoke(agent_id)`. Bot's next WS frame triggers 401 on
   any cap-checked operation; WS closes; Presence emits leave diff.

Every cross-battery seam is exercised: Auth issues the token, Broadcast
carries messages, Presence tracks join/status/leave, LiveView re-renders
on every event. The bot used zero special-cased "agent" APIs — same WS
surface a human client would, with `acting_via` riding along.

## Implementation order

Forced by the dependency graph:

1. **Identity + Auth core** (no upstream deps).
   `Tep::Identity`, `Tep::AgentDelegation`, capability core+extension,
   provider chain, Bearer + SessionCookie providers. OAuth in a
   follow-up (consent UI has its own design).
2. **Broadcast — backend interface + 2 backends**.
   `Tep::Broadcast::Backend`, `InProc`, `Postgres`, public API,
   authz callback.
3. **Presence**. Diffs via Broadcast (2), cross-worker storage via PG,
   entry kinds via Identity (1). Includes structured-status field +
   expiry reaper.
4. **LiveView**. WS (existing) + Broadcast (2) for topic binding;
   Presence (3) as a render helper (not a hard dep).

(3) and (4) can go in parallel once (2) is done.

## Hard scope notes

- **Scheduled server is the runtime for all four** (WS connections +
  fiber-park on I/O everywhere). Without `Tep::Server::Scheduled`
  working reliably under load, the batteries don't ship. **Blocked on
  matz/spinel#641** — the per-fiber GC root regression bisected,
  patched, and filed on 2026-05-21. Until #641 merges, all four
  batteries are paper-only.
- **~15 new classes** across the four. Expect spinel `cls_id` and
  poly-dispatch friction (see memory `spinel_widening_dispatch`).
  Likely to surface a few more spinel filings during implementation.
- **PG dependency hardens.** Presence and Broadcast's Postgres backend
  both lean on PG. tep currently treats PG as optional; this
  effectively makes it required for any app using the batteries above
  v1's in-process broadcast. Document this in the README.
