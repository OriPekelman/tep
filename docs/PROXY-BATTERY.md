# Proxy battery design: Tep::Proxy

Battery 6 — design draft. Generic HTTP proxy with a middleware
filter chain. A primitive every tep app composes for: API
gateways, observability layers, key-swap proxies, multi-upstream
routing, mirror-to-staging, fan-out, LLM proxies. Whatever sits
between a client and a real upstream HTTP server.

> Status: **chunks 6.1 + 6.2 + block-DSL (#88) shipped**
> (`lib/tep/proxy.rb` + bin/tep). 6.1: non-streaming forward +
> `before_forward` / `after_forward`. 6.2: streaming forward (chunked
> + SSE) via `stream_request?` opt-in, `on_stream_chunk(chunk, out,
> stats)` (chunk is a `StreamChunk` — read `chunk.chunk_text`),
> `on_stream_end(req, out, stats)`, carried `StreamStats` (byte_count
> / chunk_count / errored / meta_bag). #88: the `api.before do … end`
> block DSL lowers to a generated subclass (see "Filter shape").
> Streaming requires the scheduled server. https:// upstreams are
> still draft. Sister doc:
> [`OPENAI-SERVER-BATTERY.md`](OPENAI-SERVER-BATTERY.md) covers
> the *origin-server* case (no upstream — tep is the source of
> truth). The two batteries are independent; an OpenAI gateway
> uses this one, an OpenAI server uses that one.

## Goal

One DSL declaration: ~10 lines of Ruby give you a tep route that
forwards HTTP requests to an upstream, runs filter chains in
both directions, and supports streaming bodies (SSE, chunked
transfer) end-to-end.

```ruby
require 'sinatra'
require 'tep/proxy'

api = Tep::Proxy.new(upstream: "https://api.openai.com")

api.before do |req, upstream_req|
  upstream_req.headers["Authorization"] = "Bearer " + ENV.fetch("OPENAI_KEY")
end

api.after do |upstream_res, res|
  Logger.info "upstream returned " + upstream_res.status.to_s
end

api.on_stream_chunk do |chunk, out|
  out.write(chunk)   # could rewrite, count tokens, etc.
end

Tep.post "/v1/chat/completions", api
Tep.get  "/v1/models",           api
```

## What it IS

- An **HTTP reverse proxy**: client → tep (filters) → upstream → tep (filters) → client.
- A **middleware chain** with three stages: `before` (pre-forward), `after` (post-response, non-streaming), `on_stream_chunk` (per-chunk for streaming responses).
- A **`Tep::Handler` subclass** that mounts at any `Tep.<verb> "/path"` like a normal route handler. One proxy instance can serve many paths.
- **Streaming-aware**: detects chunked / SSE responses and switches modes; client sees the same chunked stream the upstream emitted, with filter transformations applied per chunk.
- **Identity-flowing**: `req.identity` from `Tep::Auth` is in scope in every filter, so capability checks, rate-limiting-by-user, audit logging all work uniformly.

## What it ISN'T

- **Not an origin server.** If you want tep to serve responses from local compute (model inference, business logic, anything where there's no upstream URL), the proxy battery doesn't help. See [`OPENAI-SERVER-BATTERY.md`](OPENAI-SERVER-BATTERY.md) for the OpenAI-shape origin case; for general origin work, just use plain `Tep.<verb>` routes.
- **Not a service mesh.** No service discovery, no health checks, no automatic retries. One upstream URL per `Tep::Proxy` instance (composition via routing happens at a higher layer; see "Multi-upstream routing" below).
- **Not protocol-aware.** The proxy speaks HTTP; the filters can inspect bodies but the battery itself doesn't know about OpenAI, REST conventions, GraphQL, etc. Protocol-specific logic lives in user filters or in higher-level batteries that compose this one.

## Filter shape

> **Two equivalent forms now ship.** As of #88 the block DSL below
> (`api.before do … end`) works — the bin/tep translator lowers it
> into a generated `Tep::Proxy` subclass (the block bodies become
> `before_forward` / `after_forward` / `on_stream_chunk` /
> `on_stream_end` / `stream_request?` imeths, with `before`/`after`
> renamed to `*_forward` to dodge spinel's same-name dispatch
> collision with `Filter`/`Security`/`Auth`). The subclass-override
> form (below the block example) is the direct equivalent — both
> compile to the same thing; use whichever reads better.
>
> Block-DSL specifics: `chunk` in `on_stream_chunk` is a
> `StreamChunk` (read `chunk.chunk_text`); the proxy var is mounted
> via `Tep.<verb> "path", api` (the translator rewrites it to a
> generated constant — passing a Proxy subclass through a *local* into
> `Tep.<verb>` trips a spinel inference bug, a constant doesn't). Use
> the proxy var only for mounts.
>
> ```ruby
> api = Tep::Proxy.new("http://api.internal:8080")
> api.before do |req, res, ureq|
>   ureq.set_header("Authorization", "Bearer " + ENV["OPENAI_KEY"])
>   false                                  # true short-circuits
> end
> api.after { |req, ures, res| Tep::Logger.info("up " + ures.status.to_s); 0 }
> Tep.post "/v1/chat/completions", api
> ```
>
> Subclass-override equivalent:
>
> ```ruby
> class OpenAIProxy < Tep::Proxy
>   def rewrite_path(path)
>     path                      # forward verbatim (default)
>   end
>   def before_forward(req, res, ureq)
>     ureq.set_header("Authorization", "Bearer " + ENV["OPENAI_KEY"])
>     false                     # return true to short-circuit
>   end
>   def after_forward(req, ures, res)
>     Tep::Logger.info("upstream " + ures.status.to_s)
>     0
>   end
> end
>
> api = OpenAIProxy.new("http://api.internal:8080")
> Tep.post "/v1/chat/completions", api
> Tep.get  "/v1/models",           api
> ```

Four filter chains (block-DSL target form), each runs in declaration order:

```ruby
# before(req, res, upstream_req) — runs after request body is
# fully received, before forwarding. upstream_req is mutable;
# tweak its headers / path / query / body. res is the client-
# facing response; setting res.set_status + returning early
# short-circuits the chain (the proxy skips forwarding and
# sends res directly to the client).
api.before do |req, res, upstream_req|
  if !req.identity.may?(:call_upstream)
    res.set_status(403)
    res.body = "missing capability: call_upstream"
    return   # short-circuits — no upstream call happens
  end
  upstream_req.headers["X-Forwarded-For"] = req.remote_host
end

# after(req, upstream_res, res) — runs after upstream sends its
# full (non-streaming) response, before res is written to the
# client. upstream_res is read-only; res is mutable. Use to
# transform the final response, emit logs/metrics, etc.
#
# ALSO runs when a `before` filter short-circuited: in that case
# upstream_res is nil and res carries the short-circuit body. This
# is deliberate — audit logging should see rejected requests too.
api.after do |req, upstream_res, res|
  res.headers["X-Proxy-Latency-Us"] = (...).to_s
end

# on_stream_chunk(chunk, out) — runs for each chunk of a
# streaming response (chunked transfer encoding or SSE). For
# text/event-stream upstreams, each chunk is one complete SSE
# event record (`event: ...\n` + zero or more `data: ...\n`
# lines + `\n`). out is a Tep::Stream-shape writer; whatever
# you write goes to the client. Drop a chunk by not calling
# out.write. Transform by writing modified bytes. Emit
# additional chunks by calling out.write multiple times.
api.on_stream_chunk do |chunk, out|
  out.write(chunk)
end

# on_stream_end(req, out, stats) — fires exactly once when a
# streaming response finishes (last chunk seen + upstream closed).
# stats is a Hash the on_stream_chunk filters accumulated into
# (chunk count, byte count, whatever the filter chain stored on
# stats[:foo] = ...). Use this to emit one final telemetry event
# at end-of-stream -- the streaming analog of `after`.
api.on_stream_end do |req, out, stats|
  EVENTS.write(req_id: req.headers["x-request-id"],
               tokens_out: stats[:tokens],
               wall_us: stats[:wall_us])
end
```

Filters run in order; multiple `before` / `after` /
`on_stream_chunk` / `on_stream_end` declarations stack.

The `stats` Hash passed to `on_stream_end` is the same Hash
each `on_stream_chunk` invocation receives as a fourth optional
argument (`|chunk, out, _, stats|`). Filters that accumulate
across chunks (token counting, byte counting, parsing for an
end-of-stream `[DONE]` marker) write to it.

> **Shipped form (chunk 6.2): subclass + override + opt-in.** As with
> 6.1, the block DSL above is the target API; the shipped form is
> subclass-override, and streaming is opt-in per request:
>
> ```ruby
> class LlmGateway < Tep::Proxy
>   # Opt this request into streaming (default: false -> buffered
>   # before_forward/after_forward path). Request-side, not response
>   # sniffing -- the client signals intent ("stream": true), and the
>   # buffered path stays on the unchanged Tep::Http.send_req.
>   def stream_request?(req)
>     Tep::Json.get_bool(req.raw_body, "stream")
>   end
>
>   # One call per dechunked HTTP chunk / per SSE event record.
>   # `chunk` is a Tep::Proxy::StreamChunk -- read the bytes via
>   # chunk.chunk_text (an object, not a bare String, so String
>   # methods work in the override despite spinel's poly-boxing of
>   # virtual-hook params). `out` writes to the client.
>   def on_stream_chunk(chunk, out, stats)
>     out.write(chunk.chunk_text)        # transform / drop / fan out
>     0
>   end
>
>   # Fires exactly once at end-of-stream (clean EOF or error --
>   # stats.errored distinguishes). `stats` is a Tep::Proxy::StreamStats:
>   # framework-maintained byte_count / chunk_count, plus meta_bag (a
>   # String=>String bag) for your own counters. This is the seam for
>   # one per-request telemetry event.
>   def on_stream_end(req, out, stats)
>     EVENTS.write(chunks: stats.chunk_count, bytes: stats.byte_count)
>     0
>   end
> end
> ```
>
> Notes vs the block sketch: `after_forward` does NOT run for streamed
> responses (`on_stream_end` is its streaming counterpart); `stats` is
> a typed `StreamStats` object, not a `stats[:sym]` hash (spinel hashes
> are single-value-typed); and streaming requires the scheduled server
> (the pump parks on `io_wait`). Field/param names are collision-free
> on purpose (`chunk_text` not `text`, `byte_count`/`chunk_count`/
> `meta_bag` not `bytes`/`chunks`/`data`) — see lib/tep/proxy.rb for why.

### SSE caveat

For `text/event-stream` upstreams, tep dispatches each SSE event
record as one chunk to `on_stream_chunk`. An event record can
contain **multiple `data:` lines** per the SSE spec:

```
event: message
data: line one
data: line two

```

A filter that extracts data payloads must handle the multi-line
shape, not just the first `data:` line. For OpenAI-shaped
streams the events are single-line and the simple
`event[/data:\s*(.+)/, 1]` pattern works; for other producers
join the `data:` lines with `\n` per spec.

## DSL

```ruby
# Single-upstream proxy.
proxy = Tep::Proxy.new(
  upstream: "https://api.openai.com",
  timeout:  30,           # seconds; defaults to 30
  # Optional: rewrite the path-and-query that gets forwarded.
  # Default: forward as-is. If set, gets the request's
  # path+query and returns the upstream path+query.
  path_rewrite: ->(p) { p },
)

proxy.before          { |req, res, upstream_req|       ... }
proxy.after           { |req, upstream_res, res|       ... }
proxy.on_stream_chunk { |chunk, out, stats|            ... }
proxy.on_stream_end   { |req, out, stats|              ... }

# Mount as a handler at any tep route. One proxy serves many
# routes; routing decisions happen at Tep.<verb> declaration time.
Tep.get  "/v1/models",            proxy
Tep.post "/v1/chat/completions",  proxy
```

For the spinel-friendly path, filters are stored as instance
methods on translator-emitted Handler subclasses (similar to how
`mcp_tool` lowers); the `before` / `after` / `on_stream_chunk`
calls collect bodies at translate time and emit one Handler
subclass per `Tep::Proxy` instance. This avoids the
PtrArray<Block>-shape that spinel doesn't handle well.

## Streaming

Most interesting case + most subtle. Three sub-shapes:

### 1. Plain non-streaming response

Upstream sends a fixed-length body. tep reads it all, runs the
`after` chain, writes the full response. Easy.

### 2. Chunked transfer encoding

Upstream sends `Transfer-Encoding: chunked`. tep reads chunks
as they arrive, runs `on_stream_chunk` per chunk, forwards
each one (with whatever transformation the filter applied) to
the client as chunked output. `after` chain does not run for
streaming responses (it's for the full-body shape).

### 3. SSE (`text/event-stream`)

Upstream sends `Content-Type: text/event-stream` with
`event:` / `data:` / `id:` lines separated by `\n\n`. tep
recognizes the content type and switches the `on_stream_chunk`
unit to "one SSE event" rather than "one HTTP chunk" — so the
filter sees coherent event records rather than raw HTTP chunks.

```ruby
# Per-event SSE filter (recognized automatically when upstream
# Content-Type is text/event-stream):
api.on_stream_chunk do |event, out|
  # event is the full event record: "data: {...}\n\n"
  parsed_data = event[/data:\s*(.+)/, 1]
  # transform / inspect / re-encode
  out.write(event)
end
```

The transport implementation reuses tep's existing primitives:
`Tep::Llm.read_sse_response` (already used by the chatbot
example for inbound SSE) becomes the engine for SSE-aware
chunk dispatch; `Tep::Streamer` (already used for outbound SSE)
becomes the engine for writing to the client.

## Multi-upstream routing

Routing across multiple upstreams happens at the **Tep route**
layer, not inside `Tep::Proxy`. Pattern:

```ruby
openai     = Tep::Proxy.new(upstream: "https://api.openai.com")
anthropic  = Tep::Proxy.new(upstream: "https://api.anthropic.com")

# Route by model name in the request body
post "/v1/chat/completions" do
  body = req.raw_body
  model = Tep::Json.get_str(body, "model")
  if model.start_with?("claude-")
    anthropic.handle(req, res)
  else
    openai.handle(req, res)
  end
  res.body
end
```

A future helper (`Tep::Proxy::Router`) could DSL this
pattern, but v1 keeps it as plain Ruby route handlers
selecting from a dictionary of proxies. Smaller surface, more
predictable.

## Identity and capabilities

`req.identity` from `Tep::Auth` is in scope in every filter
(same as in route handlers). Common pattern:

```ruby
api.before do |req, upstream_req|
  if !req.identity.may?(:call_upstream)
    res.set_status(403)
    res.body = "missing capability"
    return
  end
end
```

The proxy can ALSO swap auth on the way out — strip the
client's credential, attach the upstream credential:

```ruby
api.before do |req, upstream_req|
  upstream_req.headers["Authorization"] =
    "Bearer " + ENV.fetch("UPSTREAM_KEY")
  # client's req.identity stays in scope for filter logic, but
  # the upstream sees only the server-side key.
end
```

## Discovery / observability

The proxy battery doesn't auto-publish anything (unlike MCP's
`/llms.txt` + `/openapi.json`). A proxy is an internal infra
component; what it forwards is the upstream's surface, and the
upstream is responsible for advertising itself. If an app wants
discovery on top of a proxy, they declare it explicitly
(e.g., proxy `GET /v1/models` from upstream and serve a static
`/openapi.json` describing the proxied subset).

## Chunking

| Chunk | Scope |
|---|---|
| **6.1** ✅ | `Tep::Proxy.new(upstream)` base; `before_forward` + `after_forward` overridable hooks; non-streaming bodies; hop-by-hop header stripping; connect-failure → 502; mount as `Tep::Handler` at any verb/path. Block-form DSL deferred to #88. |
| **6.2** ✅ | Streaming proxy — `stream_request?` opt-in, chunked + SSE-aware `on_stream_chunk(chunk, out, stats)` (chunk = `StreamChunk`, read `chunk.chunk_text`), **`on_stream_end(req, out, stats)` finalizer** + carried `StreamStats`. Requires the scheduled server. |
| **6.3** | `examples/api_gateway` (auth-attach + observability composition) + `examples/llm_gateway` (proxy a remote OpenAI with token-counting filter + per-request `inference` event emission via `on_stream_end`). |
| **6.4+** | Multi-upstream router helper, request-body buffering limits, automatic retries with exponential backoff (opt-in), upstream connection pooling. |

## Spinel-related risks

- **Outbound HTTP/1.1 keep-alive.** Tep's current outbound
  client (`Tep::Http`) is HTTP/1.0 — a connection per upstream
  request. For high-volume proxying this is wasteful. v1 ships
  on HTTP/1.0; chunk 6.4+ adds an opt-in pooled HTTP/1.1
  outbound client (probably extends `Tep::Http` rather than
  creating a new battery).
- **Streaming SSE re-encoding under fibers.** Works today —
  `Tep::Server::Scheduled` + `Tep::Streamer` already exercise
  the shape via LiveView/counter/agentic_chat. Re-using the
  inbound-SSE consumer from `Tep::Llm.read_sse_response`
  shouldn't trip spinel's recent landings, but watch for
  poly-cascade if the filter blocks store callbacks across
  multiple Proxy instances (PtrArray<Block> territory).
- **Large request bodies.** Forwarding a 100MB upload through
  filters means tep holds the body in memory. v1 caps at
  `Tep::Server`'s existing SPHTTP_BUFSIZE (64 KiB) for the
  start-line + headers; body up to `Content-Length` is
  drained. Apps that need to proxy multi-megabyte bodies
  should mount the proxy under a path that bypasses body
  filtering and stream the body through unchanged (a 6.4+
  opt-in).

## Non-goals

- **Multi-protocol.** This is an HTTP proxy. WebSocket
  proxying is a separate problem (WS upgrade handshake, bi-
  directional frames). If a demand surfaces, a sibling
  `Tep::WebSocketProxy` battery is the right shape, not
  growing this one.
- **TLS termination.** tep doesn't do TLS itself (a fronting
  nginx/Caddy does); the proxy operates on plaintext HTTP.
  Upstream TLS works if `upstream:` is `https://` because
  the outbound client uses libcurl-shape semantics, but the
  proxy isn't a TLS-aware traffic inspector.
- **Body transformation across content-type.** Filters see
  raw bytes. If you want to JSON-parse, transform, re-encode,
  you do it explicitly. The battery doesn't auto-deserialize.

## Open questions

- **Filter ordering vs short-circuit.** When a `before` filter
  short-circuits (sets `res` + returns early), later `before`
  filters do NOT run. The `after` chain DOES run — with
  `upstream_res = nil` and `res` carrying the short-circuit
  body — so audit logging sees rejected requests. (Set in this
  revision; was open in the first draft.)
- **Header allow-list / deny-list defaults.** Should hop-by-hop
  headers (`Connection`, `Keep-Alive`, `Transfer-Encoding`,
  `Upgrade`, `Proxy-Authorization`, `TE`, `Trailers`) be
  stripped automatically per RFC 7230? Yes — v1 strips them
  by default; explicit `pass_hop_headers: true` overrides.
- **WebSocket upgrade pass-through.** Out of scope for v1 (see
  Non-goals). Worth confirming there's no near-term proxy use
  case that needs it before locking the doc.
