# AGENTS.md

This file documents the agent-facing surface of this app for any
LLM / agent reading it. The convention: every tep app exposing
MCP ships an `AGENTS.md` at its repo root so a Claude Code (or
OpenCode / Gravity / etc.) session can read it once and know
how to drive the app safely.

## What this app does

A mock training-run manager. Agents start named experiments with
hyperparameters, advance them one epoch at a time, list current
state, and cancel runs.

The training is simulated for demo purposes; the agent-facing
surface is the production shape.

## How to discover

| URL | Purpose |
|---|---|
| `/mcp` (POST, JSON-RPC 2.0) | Primary surface. Speak MCP here. |
| `/llms.txt` (GET) | Plain-text catalog of tools + resources. |
| `/openapi.json` (GET) | OpenAPI 3.0.3 of the HTTP-direct surface. |

Inside `/mcp`: `initialize` returns server info + capabilities;
`tools/list` enumerates tools; `resources/list` enumerates
resources; `tools/call` and `resources/read` invoke them.

## Tool catalog

| Tool | Caps required | Effect |
|---|---|---|
| `start_experiment(name, learning_rate, epochs)` | `:run_experiments` | Enqueue + auto-start a run. Returns the new id. |
| `step_experiment(id)` | (none) | Advance one epoch. Idempotent on `done` / `cancelled`. |
| `list_experiments()` | (none) | Snapshot of every experiment as `id=N name=... status=... epoch=K/N loss=L1,L2,...`. |
| `cancel_experiment(id)` | `:run_experiments` | Mark a run as `cancelled`. Reversible: re-call `start_experiment` to start a new run with the same name. |

## Resource catalog

| Resource URI | mimeType | Effect |
|---|---|---|
| `experiments/all` | `text/plain` | Snapshot of every experiment. Same format as `list_experiments`. |
| `experiments/active` | `text/plain` | Only runs with `status=running`. |

Resources are read-only fetches. Use them for periodic state
polling between tool calls.

## Invariants the app maintains

- Experiment ids are monotonically increasing (1, 2, 3, ...).
- Status transitions: `queued -> running -> {done | cancelled}`.
  Never goes backward.
- `step_experiment` on `done` or `cancelled` is a no-op.
- `cancel_experiment` on `done` is allowed but flips status back
  to `cancelled` -- avoid if you want to preserve "completed" runs.
- Loss series is append-only; no in-place edits.

## How to drive efficiently

- **Start a batch**, then `step` each run round-robin until all
  complete. Listing in a loop polls cheaply (`list_experiments`
  is O(n)).
- **Compare runs** by reading `experiments/all` and parsing the
  loss arrays per id. The format is stable; agents can string-
  split safely.
- **Cancel early** when an experiment's loss curve is clearly
  worse than alternatives. Don't wait for it to finish.

## Authorization

For the demo this app accepts an `X-Demo-Cap-Run: 1` header as a
stand-in for the capability. A real deployment uses
`Tep::AuthOAuth2` to mint a JWT delegating the agent
`run_experiments` capability on behalf of a human user; the
agent passes that JWT as `Authorization: Bearer <token>` on
every `/mcp` POST. The tool body sees `req.identity` with
`acting_via` set to the delegation, exactly as the framework
documents.

## Things you should NOT do

- **Don't restart runs to force a different seed.** This
  particular app is deterministic; cancel + start is the same as
  step + step.
- **Don't start more than ~10 concurrent runs.** State is in-
  memory; the app has no backpressure or queuing.
- **Don't assume `loss` values are real ML output.** They're
  synthetic for the demo. Use the shape of the API to drive
  reasoning about agent loops; don't extrapolate to actual
  hyperparameter search conclusions.
