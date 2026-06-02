# llm_gateway — an LLM API gateway on `Tep::Proxy`

Fronts a remote OpenAI-compatible upstream and adds, in ~40 lines of
Ruby, the three things a gateway exists for:

1. **Credential swap** — strips the client's `Authorization`, attaches
   the server-side key (`before`). The upstream only ever sees the
   gateway's key.
2. **Transparent streaming** — `stream: true` requests are forwarded
   over a held-open connection and the SSE events pass straight back
   to the client, unbuffered (`stream_request?` + `on_stream_chunk`).
3. **Per-request telemetry** — exactly one toy/v1 `inference` event
   per request, emitted at end-of-stream (`on_stream_end` +
   `Tep::Events`) — the right cardinality (one per request, not per
   chunk), with token counts + latency.

This is the showcase for proxy battery chunk 6.2 (streaming +
`on_stream_end`) composed with `Tep::Events`. It uses the **block-form
proxy DSL** (`gw.before do … end`), which `bin/tep` lowers to a
`Tep::Proxy` subclass.

## Run

```sh
UPSTREAM=https://api.openai.com \
OPENAI_KEY=sk-... \
EVENTS_JSONL=/tmp/gateway.events.jsonl \
  bin/tep build examples/llm_gateway/app.rb -o /tmp/gw && /tmp/gw -p 4567
```

(Points at any OpenAI-compatible server — a local `ollama`, vLLM,
llama.cpp's server, or the real OpenAI API. `EVENTS_JSONL` unset
disables emission with zero overhead.)

```sh
# streaming chat completion — SSE passthrough + one inference event
curl -s localhost:4567/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini","stream":true,
       "messages":[{"role":"user","content":"hi"}]}'

tail -1 /tmp/gateway.events.jsonl
# {"kind":"eval","phase":"serve","t":3,"name":"request","extra":{
#   "model":"gpt-4o-mini","prompt_tokens":0,"completion_tokens":42,
#   "latency_us":3000000,"request_id":"...","principal_id":"anonymous"}}
```

The events stream is the toy/v1 envelope, so a research-lab
orchestrator (or any consumer of training/serving events) ingests it
the same way it ingests a training run.

## Notes / limits

- **Streaming requires the scheduled server** (`set :scheduler,
  :scheduled`) — the pump parks on `io_wait`, same as WebSocket.
- **Token counts are approximate at the proxy:** `completion_tokens`
  is the SSE-event count (no tokenizer here); `prompt_tokens` is left
  0. A real gateway parses `delta.content` / the request `messages`.
  The origin-server battery (`Tep::Llm::OpenAI::Server`) reports exact
  counts from the backend.
- **`latency_us` is second-resolution** (the caller passes `wall_us`,
  emitted on the wire as `latency_us`; `Time.now` exposes only integer
  epoch seconds, and LLM requests are seconds-scale, so latency is still
  meaningful). Sub-second timing would need a µs-clock primitive.
- **Auth/capabilities** flow through `req.identity` like any tep
  route — gate the gateway with `req.identity.may?(:call_upstream)` in
  `before` if you want per-principal access control.

## See also

- [`docs/PROXY-BATTERY.md`](../../docs/PROXY-BATTERY.md) — the battery.
- `lib/tep/events.rb` — the toy/v1 emitter.
- `examples/api_gateway` — the non-streaming sibling (auth-attach +
  observability), 6.3's other half.
