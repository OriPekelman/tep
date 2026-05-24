# MCP battery design: Tep::MCP

Battery 5. Designed 2026-05-24; implementation rolling out in
small chunks (5.1 first, see "Chunking" at the bottom).

Vision framing: tep already treats agents as first-class **users**
(via `Tep::Identity` / `Tep::AgentDelegation`). The MCP battery
makes tep apps first-class **tools** that agents drive — the
agent-as-driver role that closes the loop on tep's
"web-framework for a live agentic age" positioning.

## Goal

One DSL declaration, two transports:

```ruby
require 'sinatra'
require 'tep/mcp'

mcp_tool 'start_experiment', "Kick off a training run" do
  param :learning_rate, Float,   "1e-5 .. 1e-2 typical"
  param :optimizer,     String,  "optimizer name", enum: %w[adamw lion sgd]
  param :epochs,        Integer, "epochs", default: 10

  on_call do |learning_rate:, optimizer:, epochs:|
    id = Tep::Job.enqueue(TrainExperiment, ...)
    Tep::MCP.text("Started experiment " + id)
  end
end
```

generates:

- A JSON-RPC 2.0 endpoint at `POST /mcp` that Claude Code / OpenCode
  / Gravity CLI / any MCP client speaks to natively.
- A plain HTTP endpoint at `POST /tools/start_experiment` that any
  curl / non-MCP agent / human can hit.
- A discovery surface at `GET /llms.txt` + (chunk 5.4) an
  `openapi.json` so non-MCP agents and human readers see the same
  catalog.

`req.identity` flows through tool bodies unchanged. The agent's
capabilities (`req.identity.may?(:start_experiment)`) gate tool
execution the same way they gate normal route handlers.

## Why MCP

Three protocols on the table for the agent-as-driver role:

| Protocol | Verdict |
|---|---|
| **MCP** (Anthropic, multi-vendor) | Primary surface. Claude Code / OpenCode / Gravity speak it natively. |
| **OpenAPI + llms.txt** | Secondary. Generated from the same metadata; covers non-MCP agents + humans for free. |
| **A2A** (Google peer-agent) | Not relevant — different problem (agent ↔ agent coordination, not agent ↔ tool). |

JSON-RPC stdio is uglier than REST, but the lock-in is shallow:
the handler is the same Ruby function; only the wire transport
changes. tep's hot path is HTTP, so the HTTP transport of MCP
("Streamable HTTP", post-spec 2025-03) is the natural fit.

## Surface

### Tool declaration

```ruby
mcp_tool 'name', "human-readable description" do
  param :foo, String,  "what foo is for"
  param :bar, Integer, "what bar is for", default: 0
  param :baz, Float,   "what baz is for", enum: [0.1, 0.3, 1.0]

  on_call do |foo:, bar:, baz:|
    # body runs with req.identity in scope (capability gating)
    if !req.identity.may?(:do_thing)
      return error("not allowed")
    end
    text("did the thing with " + foo)
  end
end
```

Translator rules:
- `mcp_tool` is a top-level DSL call (no receiver), recognized
  alongside `get` / `post` / `websocket` / `Tep.live` in `bin/tep`.
- Each tool generates two `Tep::Handler` subclasses: one for the
  HTTP form (`POST /tools/<name>`), one for the JSON-RPC dispatch
  inside `/mcp` (called via a shared registry; see below).
- The block body is rewritten the same way route bodies are: `req`
  / `res` available, `params[k]` rewrites, etc.

### Response shape

Inside `on_call do ... end`, the body returns a `Tep::MCP::Result`
built via one of:

```ruby
Tep::MCP.text("plain text")
Tep::MCP.json(obj)              # serializes via Tep::Json
Tep::MCP.error("message")       # marks the tool result as isError
Tep::MCP.stream do |out|
  out.write("chunk\n")
end                              # SSE-shaped streaming response (chunk 5.3)
```

The explicit `Tep::MCP.` prefix is intentional — bare `text(...)`
helpers would need either a translator rewrite or sibling-cmeth
bridges, both of which trip spinel's parameter-type inference in
the common case where one helper is unused per tool. Keeping the
calls explicit avoids the widening and reads cleanly.

For chunk 5.1, only `text` and `error` ship. `json` and `stream`
follow.

### Resource declaration (chunk 5.3)

```ruby
mcp_resource 'server/status', "Current server status" do
  on_read do
    Tep::MCP.resource_text("server/status", "uptime: " + uptime.to_s)
  end
end
```

generates:

- `GET /resources/server/status` — HTTP-direct read returning the
  text body with the resource's mimeType as Content-Type.
- A `resources/list` arm in `/mcp` that returns the catalog
  (uri / name / description / mimeType per resource).
- A `resources/read` arm in `/mcp` that looks up by URI and
  returns the content block.

`on_read` runs with `req` in scope (same shape as tools), so
identity / caps gating works the same way (`caps:` keyword
support for resources is a 5.4 follow-up if needed).

URI templating (`'experiment/{id}/metrics'` with extracted
captures) and streaming (`stream do |out| ... end` over SSE)
defer beyond 5.3.

### Prompt declaration (chunk 5.4, maybe)

Tep apps that bundle Claude prompts as part of their surface
(rare for the experiment-driver case) can declare them. Deferred
until we have a clear use case.

## Wire

### JSON-RPC dispatch

`POST /mcp` accepts a JSON-RPC 2.0 request envelope:

```json
{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
```

Methods supported in chunk 5.1:

- `initialize` — handshake. Returns server name + version +
  capabilities (which methods are implemented).
- `tools/list` — enumerate every `mcp_tool` declaration. Returns
  `{tools: [{name, description, inputSchema}]}` where
  `inputSchema` is a JSON Schema fragment generated from the
  `param` declarations.
- `tools/call` — invoke a tool by name with arguments.
  Returns `{content: [{type: "text", text: "..."}], isError: false}`.

Additional methods in later chunks: `resources/list`,
`resources/read`, `notifications/initialized`, `ping`.

### HTTP-direct fallback

`POST /tools/<name>` accepts the tool's args as a JSON body OR as
form-urlencoded params (so `curl -d "foo=x"` works). Returns the
tool's content as plain text (for `text`) or JSON (for `json`).

This isn't part of the MCP spec — it's a convenience for humans
and non-MCP agents. The same handler body runs.

### Auth

The MCP endpoint sits behind the same `Tep::Auth` filter chain as
every other route. An MCP client identifies via:

- `Authorization: Bearer <jwt>` (uses `Tep::AuthBearerToken`).
- `Cookie: tep.session=...` (uses `Tep::AuthSessionCookie`).

For the agent-driver case, the natural shape is bearer-token: the
human user logs in, mints a delegation JWT via
`Tep::AuthOAuth2.exchange_code`, hands the token to their Claude
Code session, and Claude includes it on every `/mcp` POST. The
tool body sees `req.identity` populated with `acting_via` set,
`agent_id` matching the client, and the human's `principal_id` —
exactly the principal+delegate shape `Tep::Identity` already
supports.

## Discovery

`GET /llms.txt` returns a flat markdown index that any
LLM-friendly client can fetch:

```
# This server

Server-name: experiment-runner
MCP-endpoint: /mcp
OpenAPI: /openapi.json (TBD)

## Tools

- start_experiment — Kick off a training run
- stop_experiment  — Stop a running experiment
- list_experiments — Enumerate active + completed runs
...
```

Chunk 5.4 adds the OpenAPI generator + an `AGENTS.md` convention
(the file lives in the app's repo, not generated — tep docs it).

## Identity & capabilities

Tools that mutate state should check `req.identity.may?(...)`
inside the `on_call` body — same pattern as routes. There's no
special "MCP authorization" layer; the existing capability model
is enough.

The DSL accepts a `caps:` keyword (chunk 5.2):

```ruby
mcp_tool 'start_experiment', "...", caps: [:start_experiment] do
  ...
end
```

When the calling identity is missing any of `caps`, the dispatch
short-circuits with `Tep::MCP.error("missing capability: <name>")`
before the `on_call` body runs. Implementation: the translator
emits one inline `req.identity.may?(:<cap>)` check per declared
cap at the top of `call_<i>`. Loops over a symbol array aren't
used (spinel's symbol-array iteration is uneven); a flat sequence
of identical branches is the safest emit.

## Streaming (chunk 5.3)

MCP's streaming response shape carries `notifications/progress`
events from server to client while a long-running tool runs.
Maps cleanly onto tep's existing `Tep::Streamer` plus the
JSON-RPC progress notification:

```ruby
mcp_tool 'long_running', "..." do
  on_call do |...|
    stream do |out|
      out.progress(0.1, "warming up")
      # ... actual work ...
      out.progress(0.5, "halfway")
      # ... more work ...
      text("done")
    end
  end
end
```

For HTTP-direct callers, the stream maps to chunked
`text/event-stream` — same wire as Tep::Streamer's SSE path.

## Non-goals

- **Hosting Claude inside tep.** tep talks to LLMs via `Tep::Llm`
  (client side) and exposes tools via `Tep::MCP` (server side).
  Running Claude Code or a local model as a tep dependency is not
  on this roadmap; the agent stays out-of-process.
- **Sandboxing tool execution.** If a tool runs untrusted code,
  the app is responsible for sandboxing (gvisor / firecracker /
  whatever). tep is the dispatch harness, not the isolation
  layer.
- **Custom protocol versions.** Track the MCP spec; don't fork.

## Chunking

| Chunk | Scope | Status |
|---|---|---|
| **5.1** | Tool DSL (`mcp_tool`, `param`, `on_call`, `text`/`error`). Translator emission. JSON-RPC dispatch at `POST /mcp` with `initialize` + `tools/list` + `tools/call`. HTTP-direct `POST /tools/<name>`. `GET /llms.txt`. | Shipped (#65) |
| **5.2** | `caps:` keyword on `mcp_tool` -> inline per-cap `req.identity.may?(:...)` check at the top of `call_<i>`. `notifications/initialized` returns 204 No Content. | Shipped (#66) |
| **5.3** | `mcp_resource 'uri', "desc" do; on_read do; ...; end; end` -> `resources/list` + `resources/read` JSON-RPC + `GET /resources/<uri>` HTTP-direct. No URI templating, no streaming -- both defer. | Shipping |
| **5.4** | OpenAPI auto-generation. `AGENTS.md` convention doc. `examples/experiments` demo (training-runs scenario). URI templating + streaming for resources. | After 5.3 |

Each chunk is one PR, same cadence as Batteries 1–4. Demo
(`examples/experiments`) is the gate for considering the battery
"shipped" beyond the framework code itself.

## Spinel-related risks

The MCP battery is mostly **runtime** Ruby — no translator
gymnastics beyond the `mcp_tool` recognition (which mirrors the
`websocket` and `Tep.live` patterns we already have). Specific
concerns:

- **JSON-RPC dispatch table.** Tools register at boot into a
  `Hash[String, Tep::MCP::Tool]`-shape registry. Tep apps with
  many tools should not trip the cross-class same-name widening
  shape (matz/spinel#684) — each tool gets its own Handler
  subclass, but the `on_call` body shapes overlap. Watch for
  poly cascades in early test builds.
- **JSON Schema generation.** `inputSchema` is a nested Hash with
  mixed value types (strings, integers, arrays of literals).
  spinel doesn't track heterogeneous-value hashes well; we'll
  serialize the schema as a pre-built string via
  `Tep::Json.encode_*` helpers rather than building a Ruby Hash
  at runtime.
- **Identity flow.** Already proven via the WS req-bridge
  (matz/spinel#54 → tep PR #56). Same pattern in MCP.

## Open questions

- **Tool naming.** Snake_case mandatory? MCP spec allows any
  identifier; tep apps may want CamelCase or kebab-case for
  consistency. Probably enforce snake_case in the DSL + relax
  later if anyone asks.
- **Versioning.** When a tool's signature changes, does the MCP
  client invalidate cached descriptors? Spec says tool list is
  refreshed each connection. Tep doesn't need a version field for
  v1.
- **Multi-tenant deployments.** A single tep process serving many
  users' MCP sessions needs per-session tool registries (a user
  may have caps for some tools, not others). Tools are global at
  registration but capability-filtered per request via the
  existing `req.identity.may?` check, so single-process works.
  Cross-process state goes through the same PG-backend pattern
  Broadcast + Presence already use.
