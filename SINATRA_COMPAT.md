# Sinatra compatibility (tep)

Generated from the curated checklist suite under `test/` plus
real-world apps under `test/real_world/`. Run `make test` to refresh.

**Headline**: 71 checklist tests pass + 5 of 8 real-world apps
build and serve correctly. 9 skips remain. v0.2 added cookies,
sessions, streaming, regex routes, modular `Sinatra::Base`, ERB.
Three more landed since: `send_file 'path'` from inside a handler,
`configure { ... }` (and `configure :env { ... }`), and Sinatra's
`__END__` inline templates.

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
| **ERB ivar locals (`@name`)**        | ✅ 3    | Sinatra-style: `@x = v` in handler / `before` filter, `<%= @x %>` in template. Translator stores on a per-request `req.ivars` String=>String bag; templates take `(locals, ivars)`. Values are `(...).to_s`-coerced on write. |
| **Mustache (subset)**                | ✅ 3    | Build-time compiled; `mustache :name` DSL parallel to `erb :name`. See "Mustache subset" below. |
| **send_file `'path'`**               | ✅ 1    | Reuses Tep::Response#send_file streaming path |
| **configure { ... }** / **:env**     | ✅ 1    | Body runs at module load; env-keyed form gates on `ENV["TEP_ENV"]` (default "development") |
| **`__END__` inline templates**       | ✅ 1    | `@@ name` blocks compile through the same ERB pipeline as files; file-based views still win when both exist |
| **`pass`** / **`pass if cond`**       | ✅ 3    | `req.passed` flag; dispatcher walks to next matching route or 404s |
| **Multiple `before` / `after`**       | ✅ 2    | Translator merges N blocks into one composite Filter subclass |
| **Optional path segments `(/:foo)`**  | ✅ 5    | Translator expands to the Cartesian product of include/skip; up to N optionals |
| **Rack::Request-style methods**       | ✅ 6    | `.host`, `.user_agent`, `.referer`/`.referrer`, `.accept`, `.content_type`, `.scheme`/`.ssl?` (via `X-Forwarded-Proto`) |

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
| `request.ip` / `request.remote_ip` | medium | Needs an sphttp_accept variant that returns the peer addr from the kernel; the rest of Rack::Request lands without C changes |

## Mustache subset

Tep ships a build-time Mustache compiler with a deliberately
narrow surface. The DSL mirrors ERB:

```ruby
get '/' do
  mustache :hello, locals: { name: "alice", snippet: "<b>BOLD</b>" }
end
```

Supported tags:

| Tag             | Compiles to                          | Notes |
|-----------------|--------------------------------------|---|
| `{{name}}`      | `out += Tep.h(locals["name"])`       | Default. HTML-escaped. |
| `{{{name}}}`    | `out += locals["name"]`              | Raw / unescaped. |
| `{{& name}}`    | `out += locals["name"]`              | Spec alias for the triple-stache form. |
| `{{@name}}`     | `out += Tep.h(ivars["name"])`        | Reads from the per-request ivars bag (same `@x = v` pattern as ERB). Escaped. |
| `{{{@name}}}`   | `out += ivars["name"]`               | Raw ivar form. |
| `{{! comment}}` | dropped at compile                   | |

Out of scope (compiler raises with a `mustache ... unsupported`
message if reached, so build fails fast instead of silently
mis-rendering):

  - `{{#section}}...{{/section}}` and inverted `{{^section}}` --
    sections need iterable locals; tep's view args are
    `String=>String` hashes.
  - `{{>partial}}` -- call `mustache :partial` from the handler
    instead, or compose at the handler level.
  - `{{=<% %>=}}` delimiter swaps -- niche, no plan.
  - Lambdas / Proc-valued locals -- spinel has no Proc.

File resolution mirrors ERB: `views/<name>.mustache` first, then
the inline `__END__ \n @@ name` block. Tep's compiler emits a
distinct `tep_mustache_<name>(locals, ivars)` function, so a
project can mix ERB and Mustache views without name collisions.

## Reading the matrix

A "supported" feature has at least one passing test through the
full pipeline (HTTP -> tep binary -> response). "Not yet supported"
rows have a `skip` in `test/test_unsupported.rb` or a fail-row in
the real-world table.
