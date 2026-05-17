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

Phase A (this version):

| Battery | Where |
|---|---|
| `Tep::Server::Scheduled` | `set :scheduler, :scheduled` -- fiber-per-connection serving |
| `Tep::Llm` | `Tep::Llm.new(BACKEND_URL).chat(history)` in `POST /api/send` |
| `Tep::Http` | (under `Tep::Llm`) the actual HTTP transport |
| `Tep::SQLite` | conversations + messages + app_config tables |
| `Tep::Json` | response payloads, manual encoding for nested arrays |
| `Tep::Password` | first-boot setup + login verify |
| `Tep::Session` | signed cookie + `authed` flag |
| `Tep::Assets` | bundled CSS / JS / markdown renderer (served at `/style.css`, `/chat.js`, `/markdown.js` — Tep::Assets paths-relative-to-assets/) |
| `Tep::Security::Headers` | HSTS + X-Content-Type-Options + X-Frame-Options |
| `Tep::Logger` | per-request trace to stderr |

Coming in later phases per [tep#10](https://github.com/OriPekelman/tep/issues/10):

| Phase | Battery |
|---|---|
| B (SSE streaming) | `Tep::Streamer` |
| C (sidebar + multi-conv) | `Tep::Job` (background title summarisation) |
| D (API token) | `Tep::Jwt`, `Tep::Security::Cors` |
| E (multi-backend compare) | `Tep::Parallel` |
| F (WS streaming) | `Tep::WebSocket` (waits for `matz/spinel#564`) |

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
