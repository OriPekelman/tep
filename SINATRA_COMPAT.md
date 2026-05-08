# Sinatra compatibility (tep)

Generated from the curated checklist suite under `test/` plus
real-world apps under `test/real_world/`. Run `make test` to refresh.

**Headline (v0.2)**: 68 checklist tests pass + 5 of 8 real-world apps
build and serve correctly. 9 skips remain. Cookies, sessions,
streaming, regex routes, modular `Sinatra::Base`, and ERB templates
all landed in v0.2.

## Phase A — Curated checklist

| Feature                              | Tests   | Notes |
|--------------------------------------|--------:|---|
| `get`/`post`/`put`/`patch`/`delete`  | ✅ 8    | All five verbs round-trip |
| Path parameters (`/hi/:name`)        | ✅ 4    | Single-segment captures |
| Two+ path parameters                 | ✅ 1    | `/users/:id/posts/:post_id` |
| Splat (`*`)                          | ✅ 1    | Last-segment only |
| Query string                         | ✅ 4    | `params[:q]` reads through |
| Form-urlencoded body                 | ✅ 2    | Auto-merged into params |
| URL-decoding (`%xx`, `+`)            | ✅ 2    | Path captures and query both |
| Custom status (`status N`)           | ✅ 5    | 201, 204, 401, 418, 500, ... |
| Default `text/html` Content-Type     | ✅ 1    | |
| Explicit `content_type 'x'`          | ✅ 2    | Plain, JSON |
| Custom `headers["X"] = "y"`          | ✅ 1    | |
| `redirect 'x'` (302)                 | ✅ 1    | Location header set |
| `redirect 'x', code`                 | ✅ 1    | Honors override (301) |
| `halt code, "body"`                  | ✅ 1    | |
| `halt code` (no body)                | ✅ 1    | |
| `before do ... end`                  | ✅ 2    | Single slot, runs before route |
| `after do ... end`                   | ✅ 1    | Runs after route, sees mutated res |
| Default 404                          | ✅ 1    | |
| Custom `not_found do ... end`        | ✅ 2    | Body and `request.path` access |
| Static files (`set :public_dir`)     | ✅ 4    | Mime-type sniffing, X-Tep-Static |
| Path-traversal rejection             | ✅ 1    | `..` segments blocked |
| Route precedence over static         | ✅ 1    | Defined route wins |
| `Content-Length` correctness         | ✅ 1    | |
| 404 on method mismatch               | ✅ 1    | `POST /` when only GET defined |
| `on_start do ... end`                | ✅ 1    | Body runs at top of program |
| `request.headers["X"]`               | ✅ 1    | Read alias |
| **Cookies**: `cookies["x"]` (read)   | ✅ 4    | Parsed from Cookie: header |
| **Cookies**: `set_cookie "k", "v"`   | ✅ 2    | Set-Cookie line written |
| **Sessions**: signed cookie store    | ✅ 4    | HMAC-SHA256, tampered cookies rejected |
| **Streaming**: `stream X.new`        | ✅ 4    | Chunked Transfer-Encoding via Streamer subclass |
| **Regex routes**: `get %r{...}`      | ✅ 5    | Up to 9 captures bound to params["1"]..params["9"] |
| **Modular**: `class A < Sinatra::Base` | ✅ 3 | Routes fold into the global app; multiple modular classes coexist |
| **ERB**: `erb :name` + `locals: {}`  | ✅ 4    | Build-time compiled; `<%= %>`, `<% %>`, `<%# %>` |

## Phase B — Real-world apps

`test/real_world/`:

| # | Source                                            | Build | Serve | Notes |
|---|---------------------------------------------------|:-----:|:-----:|---|
| 01 | sinatra/examples/simple.rb                        | ✅ | ✅ | First-try pass |
| 02 | sinatra/examples/lifecycle_events.rb              | ✅ | ✅ | Triggered translator support for `on_start`; `on_stop` ignored |
| 03 | sinatra/examples/chat.rb                          | ⚠️ | — | ERB now works, but `stream do |out|` block syntax + `Set.new` top-level + `__END__` data section still don't translate |
| 04 | synthesized: tiny health/version JSON API         | ✅ | ✅ | |
| 05 | synthesized: in-memory todo CRUD                  | ✅ | ✅ | Required `[0].delete_at(0)` seed for typed arrays |
| 06 | synthesized: before-filter Bearer auth            | ✅ | ✅ | |
| 07-bbc | github.com/bbc/REST-API-example              | ❌ | — | DataMapper ORM, dm-types, dm-validations |
| 07-sklise | github.com/sklise/sinatra-api-example     | ❌ | — | DataMapper, `to_json`, `send_file` |
| 08 | github.com/jwd83/sinatra-helloworld               | ⚠️ | ⚠️ | Uses `__END__` inline templates; ERB itself works for view-files now |

## Inline fixes shipped

- **Translator**: `on_start`, top-level passthrough (constants, classes, defs), receiver-aware top-call, `Sinatra::Base` modular unwrapping.
- **Translator**: rewrites for `cookies[]`, `set_cookie`, `session[]=` / `session[]` (via `.set` / `.get`), `stream X`, `erb :name`, `set :views`, `set :public_dir`.
- **Tep::Request**: `headers` / `body` read aliases.
- **Tep::Response**: `set_cookie`, `start_stream`.
- **Tep::Session**: HMAC-SHA256-signed cookie store; tampered cookies rejected via timing-safe compare.
- **Tep::Streamer**: subclass-style streaming with chunked frames written via `Stream#write`.
- **C helper**: `sphttp_hmac_sha256_hex`, `sphttp_write_chunk`, `sphttp_write_chunk_end`.

## Not yet supported (skipped tests)

| Feature                | Effort | Notes |
|------------------------|--------|---|
| Haml / Slim / etc.     | n/a    | Out of scope -- those are CRuby gems |
| `helpers do ... end`   | medium | Closures not first-class in spinel; would need translator-level "extract methods to Handler base" pass |
| `send_file 'path'`     | small  | Generalize Tep's static-dir support to any path |
| Optional path segments `(/:foo)` | medium | Mustermann subset; or use a regex route as a workaround |
| Multiple before/after filters chained | small | Composite filter pattern; or accept perf cost of poly array |
| `pass`                 | small  | Try-next-route mechanism in dispatcher |
| Full Rack::Request methods | medium | `.ip`, `.scheme`, `.ssl?`, etc. |
| `configure { ... }`    | small  | Environment switching not implemented |
| ERB locals via `@ivar` | medium | v0.2 ERB only supports `locals: {...}` hash form, not Sinatra's bare-ivar style |
| `__END__` inline templates | small | One-shot scan + emit them as `tep_view_<name>` methods alongside file-based views |

## Reading the matrix

A "supported" feature has at least one passing test through the
full pipeline (HTTP -> tep binary -> response). "Not yet supported"
rows have a `skip` in `test/test_unsupported.rb` or a fail-row in
the real-world table.
