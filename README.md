<p align="center">
  <img src="logo/tep.png" alt="Tep — Spinal Tap of web frameworks" width="240">
</p>

# Tep

A Sinatra-flavoured web framework that compiles to a **native binary**
via [Spinel][spinel]. You write a Sinatra-style `app.rb`:

```ruby
require 'sinatra'

get '/hi/:name' do
  "hi, " + params[:name] + "!"
end
```

…and get `./app` — a single static executable, ~80 KB, **no Ruby
runtime**, doing ~150k req/s. Beyond routing / sessions / templates, the
[batteries ↓](#whats-in-the-box) cover auth (bearer / cookie / OAuth2),
SQLite, opt-in PostgreSQL, WebSockets, Broadcast + Presence + LiveView,
an MCP tool catalog, TLS, a pooled HTTP client, and an OpenAI-compatible
LLM client + server.

> **Current release:** [v0.11.7](https://github.com/OriPekelman/tep/releases/tag/v0.11.7)
> on [RubyGems](https://rubygems.org/gems/tep) — `gem install tep`.
> Pre-alpha; API still in motion.

<details>
<summary><b>Why Tep exists</b> — it's a deliberate Spinel torture test + toy's serving layer</summary>

Tep is the largest pure-Ruby application Spinel compiles end-to-end:
every Sinatra idiom and battery doubles as a torture test for the AOT
compiler's codegen + analyzer, and bugs found here get reduced to
minimal repros and land upstream as
[matz/spinel](https://github.com/matz/spinel) PRs. It's also the
HTTP / MCP / serving layer for its sibling [toy][toy] — a pure-Ruby ML
framework Spinel compiles — so every battery is shaped by what toy
needs to ship. Tep is a genuinely useful general web framework too, but
the design choices are made through those two lenses.
</details>

[toy]: https://github.com/OriPekelman/toy

## Quick start

**A new project (the simple path).** The Spinel toolbelt
([bundler-spinel](https://github.com/OriPekelman/spinelgems)) scaffolds a
project and provisions the Spinel compiler for you:

```sh
gem install bundler-spinel
spinel-compat init my_app && cd my_app
./bin/build            # ensures tep, vendors deps, provisions Spinel, compiles → ./app
./app -p 4567
```

`spinel-compat init` writes a `Gemfile` (`gem "tep"`), an `app.rb`, and a
`bin/build`. The build step provisions a pinned Spinel compiler (cached under
`~/.cache/spinel`), vendors dependencies where Spinel can follow them, and
compiles `app.rb` to a native binary — no Ruby runtime in the result.

Your `app.rb` is plain Sinatra-flavoured Ruby:

```ruby
require 'sinatra'

get '/' do
  "hello from Tep"
end

get '/hi/:name' do
  "hi, " + params[:name] + "!"
end
```

**Already have a Sinatra app?** Scaffold a project and use your source as its
`app.rb` — the build reports any Spinel-incompatible patterns:

```sh
gem install bundler-spinel
spinel-compat init my_app && cd my_app
cp /path/to/your_app.rb app.rb
./bin/build                      # → ./app  (or a clear report of what won't translate)
```

The `tep` translator is also on RubyGems on its own (`gem install tep`) for use
in your own build scripts, once a Spinel engine is on `$SPINEL` / PATH.

<details>
<summary><b>From source</b> (hacking on tep itself, or no bundler)</summary>

```sh
# 1. Spinel (the AOT compiler)
git clone https://github.com/matz/spinel && cd spinel && make all
export PATH="$PWD:$PATH"

# 2. tep
git clone https://github.com/OriPekelman/tep && cd tep && make all
./examples/hello -p 4567

# your own app
tep build hello.rb       # → ./hello (~80 KB binary, no Ruby runtime)
```
</details>

The translator (`bin/tep`) needs CRuby >= 3.2 with the `prism` gem
installed (a development-only dependency — `bundle install` brings it
in). Prism ships with the stdlib from 3.4 onward; on 3.2/3.3 it's a
gem install. Recommended Ruby manager:
[`rv`](https://github.com/spinel-coop/rv) — fast version+gem
manager from the Spinel Cooperative (separate project from the
matz/spinel AOT compiler Tep compiles through; same Ruby
neighbourhood). `.ruby-version` in this repo pins 4.0.0; `rv
shell` makes `rv run rake test` just work. Build deps on Linux:
`build-essential`, `libsqlite3-dev`. macOS: Xcode CLI tools.

For a full walkthrough — auth, persistence, deploy — see the
[Getting started](https://github.com/OriPekelman/tep/wiki/Getting-Started)
wiki page.

## Is it fast?

Yes. ~150k req/s on a small Linux server with the request path doing
actual work (SQLite SELECT + JSON), microsecond median latency. The
hot path is C from end to end (epoll, request parsing, dispatch,
response writer); the Ruby you wrote is compiled, not interpreted.
HTTP/1.1 keep-alive and prefork with `SO_REUSEPORT` are the usual
wins applied.

Two scenarios, both `wrk -t8 -c256 -d10s` on Linux 6.x / aarch64,
8 workers a side (Sinatra: 8 workers × 4 threads):

| Scenario                | Server         | Req/sec | p50    | p99    |
|-------------------------|----------------|--------:|-------:|-------:|
| **hello** (raw plumbing)| Tep            | 167,150 |  40 µs | <1 ms  |
| hello                   | Sinatra + Puma |  31,184 |  40 ms | 171 ms |
| **api** (SQLite + JSON) | Tep            | 145,290 |  43 µs | 243 µs |
| api                     | Sinatra + Puma |  24,926 | 1.8 ms | 171 ms |

Numbers are conservative floors; a clean re-run on a quiet host is
expected to come in higher. Reproduce with `bench/run_all.sh`.

> **macOS note.** Linux is Tep's primary deployment target. Builds
> and runs on macOS too, but Darwin's `SO_REUSEPORT` doesn't load-
> balance new connections across prefork workers — a single long-
> running response on the busy worker blocks every other request on
> the same listener. On Linux 3.9+ the kernel distributes accepts
> correctly, so prefork scales as the table above. The path forward
> for tep apps that need real concurrency on macOS is
> `Tep::Server::Scheduled` (one worker, fibers per connection) + a
> cooperative `Tep::Http` — design + phases in
> [`docs/MACOS-CONCURRENCY.md`](docs/MACOS-CONCURRENCY.md).

## What's in the box

Sinatra-shaped routing, filters, responses, templates, sessions,
plus a collection of "batteries" — pure-Tep modules that cover the
gem ecosystem's most common needs in a way that lowers cleanly
through Spinel.

| Battery          | What it covers |
|------------------|---|
| `Tep::SQLite`    | libsqlite3 wrapper via a small C shim — exec / prepare / bind / step / col / first_str / first_int. |
| `SpinelKit::Json`      | encode primitives + flat-key decoder for JSON-over-HTTP. |
| `SpinelKit::Log`    | levelled logger (debug/info/warn/error), stderr or file. |
| `Tep::Jwt`       | HS256 JWT encode / verify / decode. |
| `Tep::Password`  | PBKDF2-SHA256, 200k iters, self-describing storage. |
| `Tep::Security`  | `Cors` (before-filter) + `Headers` (HSTS, nosniff, ...). |
| `Tep::Assets`    | compile-time bundling for `<app>/assets/*`. |
| `Tep::Scheduler` | cooperative fiber scheduler with timer + I/O parking. |
| `Tep::Shell`     | popen-based shell-out + small-file reader (`/proc`, `/sys`, `/etc`). |
| `Tep::Http`      | Faraday-shaped outbound HTTP/1.0 client. |
| `Tep::Llm`       | ruby-openai-shaped chat-completions client; backends interchangeable via base_url (Ollama / OpenAI / [toy](https://github.com/OriPekelman/toy)). Sync `chat()` + SSE `chat_stream()`. |
| `Tep::Llm::OpenAI::Server` | The other side of the OpenAI fence — serve OpenAI-compatible HTTP from local compute. Subclass `Tep::Llm::OpenAI::Backend`, wire `Server.use(MyBackend.new)` + `Server.serve!(events_jsonl)`, get `/v1/models` + `/v1/completions` (non-streaming + SSE with `"stream": true`) + toy/v1 events out of the box. `/v1/embeddings` lives app-side (the lib stays float-free); see [`docs/OPENAI-SERVER-BATTERY.md`](docs/OPENAI-SERVER-BATTERY.md). |
| `Tep::Proxy`     | Sinatra-flavored reverse proxy. Subclass `Tep::Proxy`, override `rewrite_path` / `before_forward` / `after_forward` (non-streaming), or `stream_request?` / `on_stream_chunk` / `on_stream_end` (SSE / chunked pass-through). Block-form DSL — `proxy.before_forward do \|req, res, ureq\| ... end` — lowers to a synthesized subclass; see [`docs/PROXY-BATTERY.md`](docs/PROXY-BATTERY.md). |
| `Tep::Events`    | toy/v1 JSONL emitter (`run_start` / `inference` / `run_end`). Float-free by design — caller hands in integer `wall_us`, schema-side floats live in caller-built `extra_json`. The OpenAI-server battery wires it automatically; standalone for any per-request telemetry stream. |
| `Tep::WebSocket` | RFC 6455 server-side WebSocket. `websocket '/chat' do \|ws\| ... end` DSL lowers to Frame + Handshake + Driver + Connection. Requires `set :scheduler, :scheduled`. |
| `Tep::Parallel`  | grosser/parallel-shaped fork fan-out. |
| `Tep::Job`       | sidekiq-shaped queue over SQLite. |
| `PG`             | **Opt-in** ruby-pg-shape libpq client — `require "tep/pg"` (so non-PG apps don't link libpq). `PG::Connection`, `PG::Result`, `PG::Error`; surface mirrors the `pg` gem (`exec` / `exec_params` / `escape_*` / `fields` / `values` / `getvalue` / `sql_state`). Designed so an eventual ActiveRecord-on-spinel port reuses the existing AR adapter with minimal divergence — see `docs/PG-BATTERY.md`. |
| `Tep::Auth`      | Principal+delegate identity (`Tep::Identity` / `Tep::AgentDelegation`) + provider chain. Three providers shipped: `Tep::AuthBearerToken` (JWT-HS256), `Tep::AuthSessionCookie` (signed cookie), `Tep::AuthOAuth2` (authorization-code grant issuance for bots/agents). Same `req.identity` surface regardless of provider; agents are first-class (`identity.agent?`, `identity.acting_via.agent_id`, capability subsetting). |
| `Tep::Broadcast` | In-process pub-sub + cross-worker via PG LISTEN/NOTIFY. Subscribe an fd to a topic (`subscribe` raw, `subscribe_ws` WS-frame-wrapped); publish writes to every matching subscriber. The seam Presence and LiveView build on. |
| `Tep::Presence`  | Topic-keyed who's-here registry, agent-aware. `Tep::Presence.track(req, topic, fd)` records a (principal, session, topic) tuple with a 3-state structured status (`:available | :busy | :blocked` + free-text note + expiry). Diffs broadcast on join/leave/status; PG-mirror for cross-worker `list_global` snapshots. |
| `Tep::LiveView`  | Phoenix.LiveView-shape server-rendered stateful UI over WebSocket. Subclass `Tep::LiveView`, override `render` + `handle_event` + (optionally) `handle_presence_diff`; `broadcast_render` fans the new HTML out to every subscribed viewer. Bootstrap client (~10 lines of inline JS) ships in `Tep::LiveView.render_page`. |
| `Tep::MCP`       | Tool catalog for the agent-as-driver role. `mcp_tool 'name', "desc" do; param :foo, Type, "..."; on_call do; ...; end; end` registers a tool both at `POST /tools/<name>` (HTTP-direct) and through a JSON-RPC 2.0 dispatcher at `POST /mcp` (MCP-native — Claude Code / OpenCode / Gravity CLI). `GET /llms.txt` auto-publishes the catalog. See [`docs/MCP-BATTERY.md`](docs/MCP-BATTERY.md). Chunk 5.1; `mcp_resource` + streaming + OpenAPI in 5.2–5.4. |

Per-battery API docs and cookbooks live on the
[wiki](https://github.com/OriPekelman/tep/wiki). The full
Sinatra-compatibility matrix is in
[SINATRA_COMPAT.md](SINATRA_COMPAT.md).

The last four batteries (`Tep::Auth`, `Tep::Broadcast`,
`Tep::Presence`, `Tep::LiveView`) ship a small framework for
"web apps in a live agentic age" — `req.identity` is always a
principal+delegate pair so agents acting on behalf of humans
are first-class through every battery. The end-to-end design
+ a realistic chat-room scenario walked through every seam
lives in [`docs/BATTERIES-DESIGN.md`](docs/BATTERIES-DESIGN.md).

430 tests pass `make test` (serial, ~13 min on the gx10) or `make test-parallel` (subprocess fan-out, ~4 min — see [`test/run_parallel.rb`](test/run_parallel.rb)). End-to-end demos that build and run:

- **[`examples/counter/`](examples/counter/app.rb)** — the
  smallest `Tep.live` demo. Shared integer counter; click in one
  tab, every other tab updates in <100ms. ~80 lines of Ruby + CSS,
  no JS to write (the bootstrap shell wires `data-event` clicks
  through the WS).
- **[`examples/experiments/`](examples/experiments/app.rb)** —
  the `Tep::MCP` battery demo. Mock training-run manager driven
  by an MCP client (Claude Code / OpenCode / Gravity): 4 tools,
  2 resources, capability gating, auto-published `/llms.txt` +
  `/openapi.json` + `/mcp` JSON-RPC. ~200 lines of Ruby plus an
  `AGENTS.md` worked example.
- **[`examples/agentic_chat/`](examples/agentic_chat/app.rb)** —
  the four-battery agentic demo. Sub-second WS push, multi-user
  chat, agent-spawn with OAuth2-style delegation. ~270 lines.
- **[`examples/chatbot/`](examples/chatbot/app.rb)** — minimalistic
  OpenWebUI-style client backed by any OpenAI-compatible endpoint
  (Ollama / OpenAI / [toy](https://github.com/OriPekelman/toy)'s `toy serve`)
  exercising the full pre-agentic battery surface
  (`Tep::Server::Scheduled` + `Tep::Llm` + `Tep::SQLite` +
  `Tep::Streamer` + `Tep::Session` + `Tep::Password` + `Tep::Jwt` +
  `Tep::Security::{Cors,Headers}` + `Tep::Assets` + `SpinelKit::Json` +
  `Tep::Job` + `SpinelKit::Log`) in ~1500 lines of Ruby + HTML + CSS + JS.
- **[`examples/llm_gateway/`](examples/llm_gateway/app.rb)** — the
  `Tep::Proxy` streaming demo. Block-form DSL gateway in front of an
  OpenAI-compatible upstream; pumps SSE token deltas straight through
  to the client and emits one `Tep::Events` `inference` event per
  completed stream.
- **[`examples/api_gateway/`](examples/api_gateway/app.rb)** — the
  buffered-proxy demo. Capability-gated forwarding with `before_forward`
  + `after_forward` observability hooks; same DSL, non-streaming.
- **[`examples/websocket_echo.rb`](examples/websocket_echo.rb)** —
  `Tep::WebSocket` in isolation; `test/test_websocket_echo.rb`
  performs a real RFC 6455 handshake over a raw socket and
  round-trips a masked TEXT frame.

### Type signatures (RBS)

`sig/` ships [RBS](https://github.com/ruby/rbs) signatures for tep's
public surface, mirroring `lib/tep/`. They're for IDE tooling today
(Solargraph, RubyMine) and for forward compatibility with
spinel-side RBS consumption (discussion at [#6](https://github.com/OriPekelman/tep/issues/6)) —
the goal is to let library authors carry the type-correctness burden
in `.rbs` files so app developers can write idiomatic Ruby without
the inference-warming seed dance that currently lives at the top
of `lib/tep.rb`. `rake rbs:validate` syntax-checks the tree.

## Spinel-direct

`tep build` accepts either the Sinatra DSL or a lower-level
Tep-class style without the translator:

```ruby
require_relative '../lib/tep'

class Hi < Tep::Handler
  def handle(req, res)
    "<p>hi, " + req.params["name"] + "!</p>"
  end
end

Tep.get "/hi/:name", Hi.new
Tep.run!(4567, 1, false)
```

Useful for tracing where the translator's textual rewrites go.

## Reporting bugs

Tep deliberately exists to find Spinel's edges. If you hit a
Sinatra idiom that doesn't translate, a Spinel-emitted miscompile,
a runtime hang — please file an issue with a minimal reproduction.
"Your app doesn't build" is a useful data point.

## License

MIT, see [LICENSE](LICENSE).

[spinel]: https://github.com/matz/spinel
