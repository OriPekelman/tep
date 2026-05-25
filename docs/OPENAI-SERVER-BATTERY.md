# OpenAI server battery design: Tep::Llm::OpenAI::Server

Battery 7 — early design draft. **Open with sibling project
authors to finalize.** Tep apps serve OpenAI-compatible HTTP
responses from local compute (not a proxy — there's no upstream).
The route + streaming + auth + caps shell is tep; the actual
inference computation is a pluggable backend that some other
project (toy, llama.cpp wrap, ...) implements.

> Status: **early draft, no code yet, open for revision**.
> Drafted to address two concrete asks from a sibling project
> (run-dir checkpoint serving + events.jsonl emission). The
> backend interface + chunking plan freezes once those needs
> are confirmed against this sketch.
>
> Sister doc: [`PROXY-BATTERY.md`](PROXY-BATTERY.md) covers the
> distinct **proxy** case (tep sits in front of a real upstream
> OpenAI-compatible server). The two batteries are independent;
> the proxy battery can be composed with this one if needed
> (e.g., a router that selects "local vs remote" per request).

## Why two batteries

| Question | `Tep::Proxy` (Battery 6) | `Tep::Llm::OpenAI::Server` (Battery 7) |
|---|---|---|
| Where does the response come from? | A real upstream HTTP server | Local compute |
| Knows the OpenAI wire format? | No (generic HTTP) | Yes (parses + emits OpenAI shape) |
| Dependencies | Just tep | Tep + a backend implementation |
| Tao's `serve-from-tao-run-dir` | ❌ no upstream to forward to | ✅ direct fit |
| Tao's `openai-eval-emit` | Possible as a proxy filter | Built-in hook |
| "Proxy a remote OpenAI through my own auth" | ✅ | (use Battery 6 instead) |

This battery exists because the origin-compute case is genuinely
different from the proxy case — different inside, different
dependencies, different scope. Trying to merge them either makes
the proxy battery carry inference concerns or makes the server
battery a degenerate proxy. Two batteries, one shared HTTP
shape.

## Goal

```ruby
require 'sinatra'
require 'tep/llm/openai/server'

# Apps wire a concrete backend at boot. The backend implements
# Tep::Llm::OpenAI::Backend (interface defined below).
backend = ToyBackend.new(model_dir: ENV.fetch("TAO_RUN_DIR"))
Tep::Llm::OpenAI::Server.use(backend)

# One DSL call mounts the standard OpenAI routes + events
# emission (when an emit path is configured) + capability gating.
Tep::Llm::OpenAI::Server.serve!(
  events_jsonl: ENV["EVENTS_JSONL"],   # optional
  cap:          :infer,                # optional; gates all routes
)
```

The `serve!` call registers:

- `GET /v1/models` — backend's catalog.
- `POST /v1/chat/completions` — streaming + non-streaming.
- `GET /v1/embeddings` — if the backend supports embeddings.
- A `before` filter that gates all three on `req.identity.may?(:infer)` when `cap:` is set.
- An events.jsonl emitter that appends one event per inference when `events_jsonl:` is set.

## Backend interface

The contract tep apps implement (in toy, llama.cpp wrap, or
elsewhere). Kept narrow so multiple backend projects can target
it without coordination.

```ruby
module Tep
  module Llm
    module OpenAI
      class Backend
        # Enumerate available model names. The catalog is what
        # /v1/models returns. Backends typically read this from
        # the configured artifact directory (one model per
        # subdirectory, or whatever the project's convention is).
        def list_models
          # returns Array[String]
        end

        # Generate a completion for the given messages against
        # the named model. sampling carries temperature /
        # max_tokens / top_p / etc. The block yields per token
        # (or per delta-chunk); tep wraps each yielded value
        # into the OpenAI streaming chunk envelope.
        def generate(model_name, messages, sampling, &on_token)
          # yield String per token; return final usage hash
          # {prompt_tokens: N, completion_tokens: N}
        end

        # Optional. When backend supports embeddings,
        # implement this; tep mounts /v1/embeddings only if so.
        # Returning false from the base class is the opt-out.
        def supports_embeddings?
          false
        end

        # Compute an embedding for a single input string. Only
        # called when supports_embeddings? returns true.
        def embed(model_name, input)
          # returns Array[Float]
        end
      end
    end
  end
end
```

The interface is **read-only from tep's perspective** — tep
calls it, doesn't store state on it. Backends own their own
state (model handles, KV caches, batching queues, etc.). This
keeps tep oblivious to ML concerns and lets each backend
implementation make its own performance choices.

## HTTP surface

### `GET /v1/models`

Response (OpenAI-compat):

```json
{
  "object": "list",
  "data": [
    {"id": "smollm2-135m", "object": "model", "owned_by": "tep"},
    {"id": "qwen-410m",    "object": "model", "owned_by": "tep"}
  ]
}
```

Backed by `backend.list_models`.

### `POST /v1/chat/completions` (non-streaming)

Standard OpenAI request:

```json
{
  "model": "smollm2-135m",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user",   "content": "Hello"}
  ],
  "temperature": 0.7,
  "max_tokens":  256,
  "stream":      false
}
```

Tep parses the request, calls `backend.generate`, accumulates
the yielded tokens, returns:

```json
{
  "id": "chatcmpl-abc",
  "object": "chat.completion",
  "created": 1716615000,
  "model": "smollm2-135m",
  "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hi! ..."},
               "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20}
}
```

### `POST /v1/chat/completions` (streaming, `stream: true`)

SSE response. Each yielded backend token becomes a chunk:

```
data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1716615000,"model":"smollm2-135m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1716615000,"model":"smollm2-135m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

...

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1716615000,"model":"smollm2-135m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

`Tep::Streamer` handles the SSE write side; the route handler
calls `backend.generate` with a block that wraps each token in
the chunk envelope and writes it through the streamer.

### `GET /v1/embeddings`

Mounted only when `backend.supports_embeddings?` returns true.
Standard OpenAI shape; calls `backend.embed`.

## Checkpoint loading from a directory

The natural integration with training pipelines that emit
checkpoints: training writes to a directory; tep boots pointing
at the directory; the backend's `load_model` (or `list_models`)
reads from it.

```sh
TAO_RUN_DIR=/srv/runs/abc-2026-05-25 ./my_inference_app -p 4567
```

`Tep::Llm::OpenAI::Server` itself doesn't know about
`TAO_RUN_DIR` — that's a backend-side convention. The backend
reads the env var at boot, scans the directory for
checkpoints, returns the names from `list_models`, loads them
on demand from `generate`.

A `latest` symlink convention (training pipeline updates
`$TAO_RUN_DIR/latest` after each new checkpoint) lets the same
running tep process pick up new weights without restart — the
backend can re-scan on every request, on a TTL, or expose a
`reload!` admin route. None of that is tep's concern.

## Events emission

The `events_jsonl:` argument to `serve!` wires a built-in
post-completion hook that appends one JSON-encoded line per
inference to the configured path. Schema target:

```json
{"ts": 1716615000.42, "kind": "eval", "model": "smollm2-135m",
 "prompt_tokens": 12, "completion_tokens": 8, "latency_ms": 87,
 "sampling": {"temperature": 0.7, "max_tokens": 256},
 "request_id": "chatcmpl-abc",
 "principal_id": "user:42"}
```

The exact field names + types **need to be aligned with the
sibling project's training-events schema** so a single ingest
consumes both training and serving telemetry. Held open until
the sibling project publishes the v1 schema; this design will
follow that.

For apps not configuring an emit path, the hook is a no-op (no
disk I/O, no latency overhead). For apps configuring it, the
append happens after the response is sent to the client —
emission failures (disk full, etc.) get logged but don't fail
the request.

## Identity and capabilities

Same shape as `Tep::MCP` (Battery 5). The `serve!` call accepts
a `cap:` keyword:

```ruby
Tep::Llm::OpenAI::Server.serve!(cap: :infer)
```

A `before` filter on all three routes checks
`req.identity.may?(:infer)`; anonymous or under-capped callers
get a 403 with `{"error": {"message": "missing capability:
infer", "code": "permission_denied"}}` in the OpenAI error
shape.

The auth chain works as it does elsewhere in tep —
`Authorization: Bearer <jwt>` with `Tep::AuthBearerToken`,
session cookies with `Tep::AuthSessionCookie`, OAuth2 delegation
with `Tep::AuthOAuth2`. OpenAI clients passing API keys as
bearer tokens slot in cleanly.

## What's deliberately NOT in this battery

- **The compute substrate.** No KV cache, no batching, no
  sampling, no tokenizer. All backend concerns. The backend
  project ships whichever subset it wants; tep doesn't care.
- **Cross-version OpenAI spec coverage.** v1 targets the
  `chat/completions` + `models` + `embeddings` shape current
  as of late 2025. The Responses API, Threads, Assistants,
  Realtime — all distinct surfaces, each gets its own future
  battery sub-namespace (`Tep::Llm::OpenAI::Realtime`, etc.)
  when an actual use case files.
- **Anthropic / Cohere / Bedrock wire formats.** Each gets its
  own sub-namespace (`Tep::Llm::Anthropic::Server`, etc.)
  modeled after this one, when demand surfaces. The
  `Tep::Llm::OpenAI::*` naming is deliberate: OpenAI is one
  wire format among several, not "the" LLM format.
- **Pre-loaded model registry.** No "tep ships a model zoo".
  Backends serve whatever's in their configured directory.

## How sibling projects fit

| Sibling | Role here |
|---|---|
| **toy** (Ruby ML framework) | Likely implements the first concrete `Tep::Llm::OpenAI::Backend`. Owns the FFI to ggml + sampling + KV cache + batching. The backend lives in toy, not tep. |
| **(research-lab orchestrator)** | Drives the serving side after training: spawns a `Tep::Llm::OpenAI::Server` process pointing at a run directory, runs benchmark suites against it (lm-eval-harness, etc.), ingests the events.jsonl that drops alongside. Files the original `tep#serve-from-tao-run-dir` + `tep#openai-eval-emit` asks against this battery. |
| **Future remote-backend** | If someone wants a `Tep::Llm::OpenAI::Backend` that *itself* proxies to a remote OpenAI server (degenerate "tep-as-LLM-router-with-shape-validation"), they implement the backend interface with `Tep::Proxy` inside. The `Tep::Proxy` battery exists exactly for this composition. |

## Chunking (open for revision)

Initial sketch — the actual chunk shape locks in after sibling
projects confirm the backend interface fits their needs.

| Chunk | Scope |
|---|---|
| **7.1** | Backend interface (`Tep::Llm::OpenAI::Backend` base class), `Tep::Llm::OpenAI::Server.use` + `.serve!` DSL, `/v1/models` + non-streaming `/v1/chat/completions`. A reference backend that delegates to `Tep::Llm` (the existing OpenAI-compat client) so the server can be exercised end-to-end without an ML dependency — useful for tests + demos. |
| **7.2** | Streaming `/v1/chat/completions` (SSE) via `Tep::Streamer` + per-token block yielded by `backend.generate`. |
| **7.3** | Events.jsonl emission (schema aligned with sibling-project's training events). |
| **7.4** | `/v1/embeddings` (gated on `backend.supports_embeddings?`). |
| **7.5+** | Function-calling / tool-use surface (when a real use case surfaces). Possibly the OpenAI Responses API (separate surface, possibly its own sub-namespace). |

## Open questions for sibling-project conversation

1. **Backend interface fit.** Does the `list_models` / `generate(model, messages, sampling, &on_token)` shape match what toy (or whichever concrete backend) wants to implement? Are KV cache + batching internal to the backend, or do they need tep-side hooks for sharing across requests?

2. **Events schema.** What's the v1 event-stream schema training emits? The events.jsonl emitter here aligns with it; if the schema isn't frozen yet, we co-design.

3. **Checkpoint discovery convention.** Is `TAO_RUN_DIR` + `latest` symlink the right shape, or does the backend project want a different convention (e.g., per-checkpoint subdirectories with manifest files)? Tep doesn't care — the backend owns it — but documenting the convention in tep's design helps coordination.

4. **Streaming semantics.** Does the backend yield per token, per word, per N tokens, or per arbitrary chunk? OpenAI's spec is permissive (any sub-sentence delta is valid). v1 assumes per-token; if backends want bigger units for batching efficiency, this is easy to relax.

5. **Capability set.** Is `:infer` the right single cap, or does the integration need finer-grained caps (`:infer:small_model` vs `:infer:large_model`, etc.) for billing/quota reasons? Probably defer until a real use case.

6. **Hot reload.** Does the backend need a tep-mounted admin route (`POST /admin/reload`) to trigger re-scanning the run directory, or does the backend handle re-scanning autonomously (TTL, file-watch, etc.)? Tep can ship both — empty by default, opt-in.

Filing answers to these is what unblocks freezing this design + starting chunk 7.1. Until then, the doc stays at "early draft, open for revision".

## Non-goals (firm)

- **Multi-tenant model isolation per request.** v1 assumes a single tep process serves one backend instance. Different models served from the same process is fine (the backend handles it via `list_models`); different backends in the same process is not (use multiple tep processes).
- **Replacing OpenAI's own server.** This battery serves OpenAI-compat traffic from local compute. It's not a drop-in replacement for OpenAI's hosted service — there's no chat history, no thread management, no model fine-tuning API, no playground. Apps that need those surfaces build them on top.
- **Compute scheduling.** Backends decide how to batch / pipeline / parallelize. Tep is the HTTP shell.
