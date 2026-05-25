# OpenAI server battery design: Tep::Llm::OpenAI::Server

Battery 7 — design draft. Tep apps serve OpenAI-compatible HTTP
responses from local compute (not a proxy — there's no upstream).
The route + streaming + auth + caps + events shell is tep; the
actual inference computation is a pluggable backend that some
other project (toy, llama.cpp wrap, ...) implements.

> Status: **design draft, no code yet**. Revised 2026-05-25
> integrating sibling-project feedback (token-level backend
> shape, toy/v1 event envelope, chunk-7.1 scope). The backend
> interface is settled; the implementation chunks are settled;
> a couple of toy-side enables (chat templating, checkpoint
> writing, embedding API) are tracked separately and don't
> block chunk 7.1.
>
> Sister doc: [`PROXY-BATTERY.md`](PROXY-BATTERY.md) covers the
> distinct **proxy** case (tep sits in front of a real upstream
> OpenAI-compatible server). The two batteries are independent.

## Why two batteries

| Question | `Tep::Proxy` (Battery 6) | `Tep::Llm::OpenAI::Server` (Battery 7) |
|---|---|---|
| Where does the response come from? | A real upstream HTTP server | Local compute |
| Knows the OpenAI wire format? | No (generic HTTP) | Yes (parses + emits OpenAI shape) |
| Dependencies | Just tep | Tep + a backend implementation |
| Run-dir checkpoint serving | ❌ no upstream to forward to | ✅ direct fit |
| `events.jsonl` emission | Possible as a proxy filter | Built-in hook |
| "Proxy a remote OpenAI through my own auth" | ✅ | (use Battery 6 instead) |

The origin-compute case is genuinely different from the proxy
case — different inside, different dependencies, different scope.
Two batteries, one shared HTTP shape.

## Goal

```ruby
require 'sinatra'
require 'tep/llm/openai/server'

# Apps wire a concrete backend at boot. The backend implements
# Tep::Llm::OpenAI::Backend (interface defined below). Backends
# accept device hints + the artifact source at construction.
backend = ToyBackend.new(
  model_path: ENV.fetch("MODEL_PATH"),   # or use run_dir: ENV["TAO_RUN_DIR"]
  device:     ENV.fetch("DEVICE", "cpu"),
)
Tep::Llm::OpenAI::Server.use(backend)

# One DSL call mounts the standard OpenAI routes + events
# emission (when an emit path is configured) + capability gating.
Tep::Llm::OpenAI::Server.serve!(
  events_jsonl: ENV["EVENTS_JSONL"],   # optional; chunk 7.1 -- see "Events" below
  cap:          :infer,                # optional; gates all routes
)
```

The `serve!` call registers:

- `GET /v1/models` — backend's catalog.
- `POST /v1/completions` — token-level completions (always mounted; the universal shape).
- `POST /v1/chat/completions` — message-level completions, **only mounted when the backend implements `generate_from_messages`** (otherwise returns 501 if requested explicitly).
- `GET /v1/embeddings` — mounted only when `backend.supports_embeddings?` returns true (chunk 7.3 scope).
- A `before` filter gating on `req.identity.may?(:infer)` when `cap:` is set.
- An events.jsonl emitter (toy/v1 envelope — see below) when `events_jsonl:` is set.

## Backend interface

```ruby
module Tep
  module Llm
    module OpenAI
      class Backend
        # Enumerate available model names. /v1/models returns
        # whatever this returns wrapped in the OpenAI envelope.
        def list_models
          # returns Array[String]
        end

        # PRIMARY shape: token-level generation. Every backend
        # implements this. Maps to /v1/completions.
        #
        # token_ids: Array[Integer] -- the encoded prompt.
        # sampling: { temperature:, max_tokens:, top_p:, ... }
        # block yields per generated token_id (Integer);
        #   tep handles decoding to text for the SSE envelope.
        # returns final usage hash {prompt_tokens:, completion_tokens:}.
        def generate_from_tokens(model_name, token_ids, sampling, &on_token_id)
          # ...
        end

        # OPTIONAL shape: message-level (chat) generation. Backends
        # implement this when they own the per-model chat template
        # (Llama 3 / Qwen 2 / SmolLM2 / Gemma 2 all differ; tep
        # deliberately doesn't ship chat templates -- that's an
        # ML-side concern). Maps to /v1/chat/completions.
        #
        # When a backend doesn't implement this, tep returns 501
        # from /v1/chat/completions and the route is effectively
        # not mounted.
        def generate_from_messages(model_name, messages, sampling, &on_token)
          # default base implementation: raises NotImplemented.
          # Backends override when they own the chat template.
        end

        # Optional: backend's chosen device. Read by tep at server
        # boot to populate the run_start event's backend.kind.
        # Defaults to "cpu" if not overridden.
        def device_kind
          "cpu"
        end

        # Optional: backends that can do embedding lookup.
        # Returning false (the base) leaves /v1/embeddings unmounted.
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

**Why two `generate_*` methods.** Toy (the expected first concrete
backend) speaks token IDs natively; chat templating is per-model
and lives further down toy's roadmap. Splitting the shape lets
each backend implement honestly: toy ships `generate_from_tokens`
on day one and `/v1/completions` works end-to-end; `/v1/chat/completions`
returns 501 until toy adds chat templating. Other backends
(llama.cpp-wrap, remote-passthrough) that own a chat templater
can implement both immediately.

**Tep does NOT ship a default chat templater.** This was
considered; rejected because per-model templates are an ML-side
concern that violates the "tep is HTTP, not ML" boundary.
Backends that need chat-shape ownership ship the template
themselves.

## HTTP surface

### `GET /v1/models`

Standard OpenAI envelope. Backed by `backend.list_models`.

```json
{
  "object": "list",
  "data": [{"id": "smollm2-135m", "object": "model", "owned_by": "tep"}]
}
```

### `POST /v1/completions`

Token-level OpenAI shape. The **primary** completion route.

```json
{
  "model": "smollm2-135m",
  "prompt": [464, 6193, 318, ...],
  "temperature": 0.7,
  "max_tokens": 256,
  "stream": false
}
```

Tep calls `backend.generate_from_tokens(model, prompt, sampling)`,
accumulates yielded token IDs, decodes via the backend, returns
OpenAI-shape:

```json
{
  "id": "cmpl-abc",
  "object": "text_completion",
  "created": 1716615000,
  "model": "smollm2-135m",
  "choices": [{"index": 0, "text": "...", "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20}
}
```

### `POST /v1/chat/completions`

Message-level shape. Mounted **only when the backend implements
`generate_from_messages`**. Standard OpenAI request:

```json
{
  "model": "smollm2-135m",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": false
}
```

When the backend doesn't implement it, tep returns:

```json
{"error": {"message": "chat-shape not supported by this backend; use /v1/completions with pre-templated token_ids", "code": "not_implemented"}}
```

with HTTP 501.

### Streaming (both `/v1/completions` and `/v1/chat/completions`, `stream: true`)

SSE response. Each yielded backend token becomes a chunk in the
appropriate OpenAI streaming envelope (`text_completion.chunk`
for `/v1/completions`, `chat.completion.chunk` for
`/v1/chat/completions`). Terminator is `data: [DONE]`.

### `GET /v1/embeddings`

Mounted only when `backend.supports_embeddings?`. Standard OpenAI
shape. **Chunk 7.3 scope**: requires a toy-side `embed_api` enable
that hasn't shipped yet (tracked separately on toy's side).

## Events emission

Adopts **toy/v1's event-stream envelope** (`docs/events-schema.md`
in toy). The serving stream is structurally indistinguishable
from a training stream — same envelope, same provenance fields,
same downstream consumers.

### `run_start` (one per server boot, before any request)

```json
{
  "kind": "run_start",
  "t": 0,
  "host": "gx10",
  "backend": {"kind": "cpu"},
  "git": {"sha": "abc123...", "dirty": false},
  "model": {"name": "smollm2-135m", "path": "/srv/runs/.../weights/100.gguf"},
  "config": {"server": "tep-llm-openai", "cap": "infer", "events_jsonl": "..."}
}
```

Emitted once at `Tep::Llm::OpenAI::Server.serve!` invocation.
`backend.kind` reads from `backend.device_kind` so `DEVICE=cuda`
at boot propagates into the stream cleanly.

### `eval` (one per request)

Serving telemetry rides on toy/v1's existing `eval` event with a
new `phase: "serve"` value:

```json
{
  "kind": "eval",
  "phase": "serve",
  "t": 87.42,
  "name": "request",
  "extra": {
    "model": "smollm2-135m",
    "prompt_tokens": 12,
    "completion_tokens": 8,
    "latency_us": 87000,
    "sampling": {"temperature": 0.7, "max_tokens": 256},
    "request_id": "cmpl-abc",
    "principal_id": "user:42"
  }
}
```

Per-request fields go in `extra` (the open-bag pattern toy/v1
uses). Tep doesn't add new top-level fields beyond `kind / phase
/ t / name / extra` — keeps the envelope stable.

### `step` (optional, per-token during streaming)

When a backend yields logprob/top-k metadata alongside each token
(opt-in; default backends don't), tep emits one `step` event per
token in the streaming response:

```json
{ "kind": "step", "phase": "decode", "t": 0.084, "step": 5,
  "token_id": 12345, "logprob": -2.314, "wall_us": 84210 }
```

For backends that don't surface logprobs (toy today), the step
event is not emitted — the `eval` event at request end is the
only per-request record. Wiring logprobs into the decode loop is
a separate toy-side issue; defer until a real consumer (e.g., a
research-lab spec) needs it.

### `run_end` (one per server shutdown)

```json
{ "kind": "run_end", "t": 28845.12, "reason": "ok",
  "stats": {"requests": 4823, "errors": 2, "tokens_out": 1284013} }
```

`reason` semantics (consistent with toy/v1):

- `"ok"` — clean shutdown (SIGTERM, SIGINT, graceful drain).
- `"errored"` — actual uncaught exception / crash. **Reserved.
  Quality verdicts on the run go in a separate field**, not
  here. (A serving run with zero requests, or sustained 500s,
  is still `"ok"` from the server's perspective; downstream
  consumers decide what's a "good" run.)

### When emission is unset

`events_jsonl: nil` (the default) makes the entire emission
hookless — no disk I/O, no allocations. Apps opt in by setting
the path.

Emission failures (disk full, permission denied) get logged but
don't fail the request — serving correctness wins over telemetry
correctness.

## Checkpoint loading

Backend-side concern, not tep's. Common patterns:

```sh
# Fixed model path (works today with toy's existing demo).
MODEL_PATH=/srv/models/smollm2-135m.gguf ./serve -p 4567

# Run directory + `latest` symlink (works once backends can
# scan dirs + projects emit checkpoints to a known shape).
TAO_RUN_DIR=/srv/runs/abc-2026-05-25 ./serve -p 4567
```

The backend reads whichever env var(s) it cares about at boot,
populates `list_models`, loads on demand from `generate_*`. Tep
itself doesn't know about either env var.

A future `Tep::Llm::OpenAI::Server.reload!` admin route can
trigger a re-scan without restart — opt-in, lives in a 7.4+
chunk if real demand surfaces.

## Identity and capabilities

Same shape as `Tep::MCP`. The `serve!` call accepts a `cap:`
keyword; all routes gate on `req.identity.may?(:<cap>)`. Auth
chain works as elsewhere in tep — bearer JWT, session cookie,
OAuth2 delegation.

OpenAI clients passing API keys as bearer tokens slot in
cleanly via `Tep::AuthBearerToken`.

## What's deliberately NOT in this battery

- **The compute substrate.** No KV cache, no batching, no
  sampling, no tokenizer, no chat templates. All backend
  concerns. The backend project ships whichever subset it
  wants; tep doesn't care.
- **Cross-version OpenAI spec coverage.** v1 targets `completions`
  + `chat/completions` + `models` + `embeddings`. The Responses
  API, Threads, Assistants, Realtime — all distinct surfaces;
  each gets its own future battery sub-namespace when an actual
  use case files.
- **Anthropic / Cohere / Bedrock / Gemini wire formats.** Each
  gets a sibling sub-namespace (`Tep::Llm::Anthropic::Server`,
  etc.) when demand surfaces. The `Tep::Llm::OpenAI::*` naming
  is deliberate: OpenAI is one wire format among several, not
  "the" LLM format.
- **A model registry.** Backends serve whatever's in their
  configured directory.

## How sibling projects fit

| Sibling | Role here |
|---|---|
| **toy** (Ruby ML framework) | Implements the first concrete `Tep::Llm::OpenAI::Backend`. Owns FFI to ggml, sampling, KV cache, batching, eventually chat templates. The backend lives in toy, not tep. Battery 7 unlocks a consolidation in toy: the existing per-model `tep_demo/openai_api_*.rb` files (one per model size) collapse into one Backend implementation that reads the model path from boot. |
| **research-lab orchestrator** | Filed the original asks against this battery. Drives serving after training: spawns a `Tep::Llm::OpenAI::Server` process pointing at a run directory, runs benchmark suites (lm-eval-harness, etc.), ingests the events.jsonl that drops alongside. The toy/v1 envelope means one ingest pipeline consumes both training + serving streams of the same model. |
| **Future remote-backend** | A `Tep::Llm::OpenAI::Backend` that proxies to a remote OpenAI-compatible server (degenerate "tep-as-shape-validator"). Implements the backend interface using `Tep::Proxy` internally. The proxy battery exists exactly for this composition. |

## Chunking

| Chunk | Scope |
|---|---|
| **7.1** | Backend interface (both `generate_*` methods; only `_from_tokens` is required). `Tep::Llm::OpenAI::Server.use` + `.serve!` DSL. `GET /v1/models` + non-streaming `POST /v1/completions`. `POST /v1/chat/completions` mounted only when backend implements `generate_from_messages`. **Events emission included** (toy/v1 envelope: `run_start` at boot + `eval` per request + `run_end` at shutdown). A reference backend that delegates to `Tep::Llm` (the existing client) for end-to-end exercise without an ML dependency. |
| **7.2** | Streaming `POST /v1/completions` + `POST /v1/chat/completions` (SSE) via `Tep::Streamer` + per-token block yielded by `backend.generate_*`. Optional per-token `step` events when the backend surfaces logprobs (no-op when it doesn't). |
| **7.3** | `GET /v1/embeddings` (gated on `backend.supports_embeddings?`). **Blocked on a toy-side enable** — flagged in scope so dependency is visible. |
| **7.4+** | Hot reload (`POST /admin/reload`), finer-grained caps, function-calling / tool-use shape, the OpenAI Responses API (likely its own sub-namespace). |

## Resolved questions (was "open for revision")

The original open questions are answered:

1. **Backend interface fit.** Two-method shape (`generate_from_tokens` primary, `generate_from_messages` optional). Resolved per toy review §Q1 recommendation (a).
2. **Events schema.** Adopt toy/v1's envelope (`kind / phase / t / name / extra`). Resolved per toy review §Q2.
3. **Checkpoint discovery convention.** Backend-side concern, not tep's. Fixed path (`MODEL_PATH`) works today; run-dir convention works once backends can scan dirs + projects emit checkpoints (separately tracked).
4. **Streaming semantics.** Per-token, matching toy's KV decode primitive.
5. **Capability set.** `:infer` as single cap for v1; finer-grained caps deferred.
6. **Hot reload.** Defer; backends self-manage until a real route is needed.

## Remaining cross-project notes

- **Chat templates ship in the backend project, not tep.** Toy adds them when they're needed; until then `/v1/chat/completions` returns 501 cleanly. The HTTP route is correct from day one; only the body that backs it grows over time.
- **Embedding endpoint blocked on backend-side enable** (`toy#embed-api` or equivalent). Chunk 7.3 doesn't ship until that lands.
- **Per-token logprob streaming blocked on backend-side enable.** Chunk 7.2's `step` event is opt-in and no-ops when the backend doesn't surface logprobs.
- **`run_end.reason` semantics.** Reserved for actual server-side failure (uncaught exception). Quality verdicts on the run (zero traffic, sustained 500s, etc.) are downstream consumer decisions — not encoded in `reason`. Matches toy/v1.

## Non-goals (firm)

- **Multi-tenant model isolation per request.** Single tep process, single backend. Different models served from the same backend is fine; different backends in the same process means multiple tep processes.
- **Replacing OpenAI's hosted service.** No chat history, no thread management, no fine-tuning API, no playground. Apps building those surfaces compose them on top.
- **Compute scheduling.** Backends decide how to batch / pipeline / parallelize.
