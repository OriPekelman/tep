# examples/chatbot — minimalistic OpenWebUI-style client

A single-user, single-conversation chat UI that talks to any
OpenAI-compatible chat completions backend. Demonstrates the full
[Tep](https://github.com/OriPekelman/tep) battery surface against a
real workload.

Distinct from [examples/chat/](../chat/) — that's a multi-user
people-talking-to-people chat with SSE; this one is user-to-LLM.

## Quick start

```sh
# Build once
bin/tep build examples/chatbot/app.rb -o /tmp/chatbot

# Run (defaults to Ollama on localhost:11434, model "llama3")
/tmp/chatbot -p 4567

# Browse to http://localhost:4567/
# First boot: set a password. Subsequent visits: log in.
```

The first time you hit `/`, you'll be redirected to `/setup` to pick
a password. After that, login at `/login`.

## Backend selection

Three backends interchangeable via env var:

```sh
# Ollama (default)
CHAT_BACKEND=http://localhost:11434 CHAT_MODEL=llama3 /tmp/chatbot

# toy/tep_demo/openai_api (sibling project's GPT-2 / DistilGPT2 server)
CHAT_BACKEND=http://localhost:8080 CHAT_MODEL=gpt-2 /tmp/chatbot

# OpenAI proper
CHAT_BACKEND=https://api.openai.com CHAT_MODEL=gpt-4 \
  CHAT_API_KEY=sk-... /tmp/chatbot
```

All three speak the same `/v1/chat/completions` shape; the chatbot
talks to all three identically via `Tep::Llm`.

## All env vars

| Var | Default | What |
|---|---|---|
| `CHAT_BACKEND` | `http://localhost:11434` | Base URL of the LLM backend |
| `CHAT_MODEL` | `llama3` | Model name passed to the backend |
| `CHAT_API_KEY` | `""` | Bearer token (only needed for OpenAI / similar) |
| `CHAT_SYSTEM_PROMPT` | `""` | Prepended to every conversation if set |
| `CHAT_DB` | `/tmp/tep_chatbot.db` | SQLite path for password + history |
| `CHAT_SESSION_SECRET` | `dev-secret-change-me` | HMAC key for the session cookie. Change for any non-localhost deployment. |
| `CHAT_HSTS` | `0` | HSTS max-age in seconds. Set non-zero ONLY when fronted by HTTPS. |

## Tep batteries this exercises

Phases A–E are shipped (per [tep#10](https://github.com/OriPekelman/tep/issues/10),
closed):

| Battery | Where |
|---|---|
| `Tep::Server::Scheduled` | `set :scheduler, :scheduled` -- fiber-per-connection serving |
| `Tep::Llm` | `Tep::Llm.new(BACKEND_URL).chat(history)` + `.chat_stream(history)` |
| `Tep::Http` | (under `Tep::Llm`) the actual HTTP transport |
| `Tep::SQLite` | conversations + messages + app_config tables |
| `Tep::Json` | response payloads, manual encoding for nested arrays |
| `Tep::Password` | first-boot setup + login verify |
| `Tep::Session` | signed cookie + `authed` flag |
| `Tep::Assets` | bundled CSS / JS / markdown renderer (served at `/style.css`, `/chat.js`, `/markdown.js` — Tep::Assets paths-relative-to-assets/) |
| `Tep::Security::Headers` | HSTS + X-Content-Type-Options + X-Frame-Options |
| `Tep::Security::Cors` | API surface CORS preflight (`/api/v1/...`) |
| `Tep::Jwt` | API bearer-token auth on `/api/v1/chat/completions` |
| `Tep::Streamer` | SSE streaming of LLM chunks (the `/api/c/:id/stream` fallback route) |
| `Tep::WebSocket` | live chat over WS (the default `/api/c/ws` route); `Driver#write` is a Streamer-shape alias so `Tep::Llm.chat_stream` drives the socket directly |
| `Tep::Job` | background conversation-title summarisation |
| `Tep::Parallel` | multi-backend compare endpoint (sequential dispatch today; the genuine fork fan-out is blocked on [matz/spinel#575](https://github.com/matz/spinel/issues/575)) |
| `Tep::Logger` | per-request trace to stderr |

Phase F is done (closes [tep#11](https://github.com/OriPekelman/tep/issues/11)):
the JS client opens one WebSocket to `/api/c/ws` and sends
`{"conv_id":N,"content":"..."}` per turn; the server emits SSE-
shaped chunks (`data: {...}\n\n`) per LLM delta as TEXT frames.
The SSE-shaped wire keeps the parsing loop on both sides — the
JS code that turned an SSE chunk into a markdown update now
runs against WS-framed input unchanged. The HTTP SSE route
(`POST /api/c/:id/stream`) stays as a fallback for older
browsers / curl debugging.

## Source layout

```
examples/chatbot/
├── app.rb                   ~280 LOC -- routes + DB + auth
├── views/
│   ├── index.erb            chat UI shell
│   ├── login.erb            login form
│   └── setup.erb            first-boot password form
├── assets/
│   ├── style.css            ~150 lines, no framework
│   ├── chat.js              ~120 lines, vanilla, sends + renders
│   └── markdown.js          ~60 lines, hand-rolled subset
├── schema.sql               DDL (also inlined in app.rb)
└── README.md                this file
```

Total: ~280 LOC Ruby + ~330 lines of HTML/CSS/JS + the schema. Builds
to a single ~1.5 MiB native binary; the bundled assets + views are
compiled in (per `Tep::Assets`'s build-time bundling).
