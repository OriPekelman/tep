# experiments -- the MCP battery demo

A mock training-run manager driven by an MCP client. The full
agent-as-driver loop in ~200 lines of Ruby:

- 4 `mcp_tool`s (start / step / list / cancel)
- 2 `mcp_resource`s (all / active)
- Capability gating on the mutating tools (`:run_experiments`)
- Auto-published catalog at `/llms.txt`, `/openapi.json`, `/mcp`

The training is **simulated** -- no actual ML. State lives in
module-level arrays. A real runner would persist to SQLite via
the same tool/resource API; nothing in the agent-facing surface
would change.

## Run

```sh
bin/tep build examples/experiments/app.rb -o /tmp/experiments
/tmp/experiments -p 4567
```

Open `http://127.0.0.1:4567/` in a browser for the landing
page (lists the tool + resource catalog with quick-start curl
recipes).

## Drive it from Claude Code (or any MCP client)

Point your MCP client at `http://127.0.0.1:4567/mcp`. Three
methods cover everything:

```
initialize        -> handshake
tools/list        -> discover the 4 tools
tools/call        -> run one (e.g. start_experiment + step_experiment)
resources/list    -> discover the 2 resources
resources/read    -> read a resource by URI
```

The client doesn't need to know any HTTP details beyond the
`/mcp` URL -- everything else (tool schemas, capability checks,
error reporting) flows through JSON-RPC.

## Drive it from curl

The natural agent-driver shape but works for humans too:

```sh
# Discover
curl http://127.0.0.1:4567/llms.txt
curl http://127.0.0.1:4567/openapi.json

# Start an experiment (capped -- demo accepts X-Demo-Cap-Run header
# as a stand-in for a real bearer-token-with-caps from a Tep::AuthOAuth2
# delegation flow)
curl -X POST http://127.0.0.1:4567/tools/start_experiment \
  -H "Content-Type: application/json" \
  -H "X-Demo-Cap-Run: 1" \
  -d '{"name":"baseline","learning_rate":"1e-3","epochs":3}'
# -> started experiment id=1 (baseline)

# Advance an epoch
curl -X POST http://127.0.0.1:4567/tools/step_experiment \
  -H "Content-Type: application/json" \
  -d '{"id":1}'
# -> id=1 name=baseline lr=1e-3 status=running epoch=1/3 loss=0.90

# Snapshot
curl http://127.0.0.1:4567/resources/experiments/active
```

## What this demo exercises

| Surface | What it does here |
|---|---|
| **`mcp_tool`** | All 4 tools declare typed params (`String` / `Integer`), descriptions, and (for the mutating two) a `caps: [:run_experiments]` gate. Tool bodies return `Tep::MCP.text(...)` for success and `Tep::MCP.error(...)` for the not-found path. |
| **`mcp_resource`** | 2 read-only fetches. Bodies return `Tep::MCP.resource_text(uri, body)`; mimeType defaults to `text/plain`. |
| **`/mcp` JSON-RPC** | Translator-generated dispatcher routes `initialize` / `tools/list` / `tools/call` / `resources/list` / `resources/read` / `notifications/initialized`. |
| **`/llms.txt`** | Auto-published markdown catalog. Both tools + resources sections, with the MCP endpoint URL + OpenAPI link in the header. |
| **`/openapi.json`** | Auto-published OpenAPI 3.0.3 spec for the HTTP-direct surface. Non-MCP agents and Swagger UI consume this directly. |
| **Capability gating** | `start_experiment` and `cancel_experiment` require `:run_experiments`; the read paths don't. Anonymous callers get an MCP `isError:true` response with `missing capability: run_experiments`. |

## What's NOT in this demo (intentionally)

- **Persistent state.** Module-level arrays only; counters reset
  on restart. A real version would use `Tep::SQLite`.
- **Real training.** The "loss" series is synthetic. The point is
  the agent-driver loop, not the ML.
- **Bearer-token auth.** The `X-Demo-Cap-Run` header shortcuts the
  full `Tep::AuthOAuth2` + JWT flow that a production deployment
  would use. The capability check itself (`req.identity.may?(...)`)
  is real.
- **Streaming progress.** `tools/call` returns when the body
  returns. Long-running experiments would benefit from MCP
  `notifications/progress` over an SSE channel -- deferred
  past chunk 5.4.

See `AGENTS.md` in this directory for the agent-facing surface
spec (the file convention agents look for at the repo root).
