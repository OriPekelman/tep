# Sinatra compatibility (tep)

Generated from the curated checklist suite under `test/` plus
real-world apps under `test/real_world/`. Run `make test` to refresh.

**Headline**: ~160 checklist tests pass + 6 real-world apps build
and serve correctly (smoke-tested through `Net::HTTP`).
4 documented skips remain. v0.2 brought cookies, sessions,
streaming, regex routes, modular `Sinatra::Base`, ERB. v0.3 added
`send_file 'path'`, `configure { ... }` (incl. `:env`), `__END__`
inline templates, `pass`, multiple chained `before`/`after`,
optional path segments, full Rack::Request method surface, ERB
ivar locals, a Mustache subset, Tep::SQLite, Tep::Json,
Tep::Logger, Tep::Jwt, Tep::Password, Tep::Security
(CORS + secure headers), Tep::Assets (compile-time asset
bundling), and Tep::Scheduler (cooperative fiber scheduler with
poll(2)-backed `io_wait`).

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
| **SQLite (libsqlite3 wrapper)**      | ✅ 5    | `Tep::SQLite` class wrapping libsqlite3 via a thin C shim (tep_sqlite.c). Same FFI pattern as sphttp.c -- spinel can't load gem-style native extensions, so we link a static .o instead. See "SQLite" below. |
| **JSON (subset)**                    | ✅ 13   | Pure-Ruby `Tep::Json`: encode primitives + flat-key decoder. See "JSON subset" below. |
| **Logger**                           | ✅ 3    | `Tep::Logger` with debug/info/warn/error levels. stderr by default; `to_file(path)` appends. Format: `[<unix_seconds>] [<level>] <msg>`. |
| **JWT (HS256)**                      | ✅ 10   | `Tep::Jwt` -- encode/verify/decode. HS256 only (asymmetric algs would need OpenSSL); `none` deliberately not supported (RFC 8725 §3.1). Tokens verify cleanly against the canonical `jwt` Ruby gem (interop test included). New base64url helpers (`sphttp_b64url_encode/decode`, `sphttp_hmac_sha256_b64url`) ride on top of the existing HMAC-SHA256 used by the session store. |
| **Password hashing (PBKDF2)**        | ✅ 9    | `Tep::Password.hash` / `verify`. PBKDF2-SHA256, 200k iters by default, 16-byte CSPRNG salt. Self-describing storage format (`pbkdf2-sha256$<iters>$<salt>$<derived>`) so iter rotation can land later without breaking old hashes. New `sphttp_pbkdf2_sha256_b64url` + `sphttp_random_b64url` C helpers. (`Klass.hash(plain)` factory shape resolved via spinel #407.) |
| **CORS + secure headers**            | ✅ 4    | `Tep::Security::Cors` (before-filter; configurable origin / verbs / headers / max-age; OPTIONS preflight short-circuits with 204) and `Tep::Security::Headers` (after-filter; `nosniff`, `SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-XSS-Protection: 0`, optional HSTS via `set_hsts(seconds)`). |
| **Cooperative scheduler**            | ✅ 4    | `Tep::Scheduler` -- spawn fibers, drain via tick / `run_until_empty` / `run_for(seconds)`, cooperative `sleep(seconds)` and `io_wait(fd, mode, timeout)` that yield back to the scheduler root. Each `tick` runs a poll(2) round (`sphttp_poll_*` C helpers) to mark socket-ready fibers, then resumes whichever wake_at (time- or I/O-) is soonest-due. Spinel ships Fiber natively (ucontext-based, GC-aware); the scheduler is the layer above. |
| **Compile-time asset bundling**      | ✅ 1    | `<app>/assets/**` auto-discovered by `bin/tep`, emitted as `Tep::Assets._add` registrations. Body bytes ride in the binary as Ruby string literals. `Tep::Assets.serve(path, res)` runs in `App#dispatch` before route matching; `Cache-Control: public, max-age=3600` on every response. |
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

## Showcases

Two flagship examples that put the framework through its paces.

### `examples/blog/`

Posts + users persisted in SQLite, web login via sessions +
`Tep::Password`, JSON API with `Tep::Json`, JWT-authed writes via
`Tep::Jwt`, ERB views with Sinatra-style `@ivar` locals, request
logging via `Tep::Logger`, CORS + secure headers via
`Tep::Security`. First boot seeds `alice / hunter2` and an intro
post explaining what tep is.

  bin/tep build examples/blog/app.rb -o /tmp/blog
  /tmp/blog -p 4567

### `examples/chat/`

Live multi-user chat with **presence** and **bundled assets**.
The view ships an SVG logo + a polished CSS file from
`examples/chat/assets/`; both are baked into the binary by
`bin/tep` (see "Compile-time asset bundling" below) and served
directly from memory.

By default the JS client polls `GET /chat/recent?since=N` once
per second. The Server-Sent Events transport (the
`ChatStreamer` + `GET /chat/stream`) is also wired -- flip
`window.USE_SSE = true` in the page to switch. SSE works fine on
Linux (prefork distributes accepts across workers); on macOS dev
machines `SO_REUSEPORT` doesn't load-balance the same way, so a
held SSE connection on the only-accepting worker blocks every
other request on the same listener until the stream self-closes
(`STREAM_MAX`, 30 s). Polling-by-default keeps the dev experience
identical across the two.

`set :workers, 4` is wired in the app source so prefork is the
default.

  bin/tep build examples/chat/app.rb -o /tmp/chat
  /tmp/chat -p 4567

Open in two browsers; messages from one show up in the other
within a second.

## Compile-time asset bundling

Anything under `<app_dir>/assets/` is auto-discovered by
`bin/tep` and emitted as `Tep::Assets._add` registrations in the
generated source. The body bytes ride in the binary as Ruby
string literals (which spinel passes through to the C compile as
`const char *`); MIME is inferred from extension at build time.

```
examples/chat/
  app.rb
  assets/
    style.css   ->  GET /style.css     (text/css)
    logo.svg    ->  GET /logo.svg      (image/svg+xml)
```

The `Tep::Assets.serve(path, res)` check runs in `App#dispatch`
before route matching, so a route at `/foo` and an asset at
`/foo` -- the asset wins. Each response gets
`Cache-Control: public, max-age=3600`.

Limitations:

  - Files containing NUL bytes are skipped (warned at build time).
    Spinel's `:str` type doesn't track length alongside the
    pointer, so a NUL truncates the served body. For binary
    assets that need exact byte round-trip (PNG, fonts, ...),
    use `Tep.public_dir` to serve from disk at runtime instead.
  - No content-hash etag yet; the bytes are immutable for the
    life of the binary, so a fingerprint-in-filename strategy
    would be a clean follow-up.

### Smoke-tested end-to-end

`test/test_real_world.rb` builds each "claimed working" example
and the two showcases on a fresh port, drives Net::HTTP requests
through them, and asserts on the response shape (incl. raw
TCP-socket reads on the SSE pipe to verify backlog + keepalive
chunks land before `Net::HTTP` would have stopped reading). A
build-passes-but-doesn't-actually-serve regression fails CI now,
not "later, when someone curls it by hand."

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

## SQLite

`Tep::SQLite` exposes libsqlite3 through a thin C shim (`lib/tep/tep_sqlite.c`).
Spinel can't load CRuby's native-extension gems (the `sqlite3` gem
ships an `.so`/`.bundle` against MRI's ABI), so the binding shape
is "static link to a small C wrapper" rather than "load a gem at
runtime". The Makefile builds `tep_sqlite.o` and `bin/tep`
substitutes its absolute path into `sqlite.rb`'s `ffi_cflags`.
`-lsqlite3` is added via `ffi_lib`.

```ruby
db = Tep::SQLite.new
db.open("./app.db")
db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT)")

# Parameterised insert.
db.prepare("INSERT INTO notes (body) VALUES (?)")
db.bind_str(1, "hello")
db.step
db.finalize
id = db.last_rowid

# Single-row read with one bound param. The convenience first_str /
# first_int wrap prepare + bind + step + col + finalize.
body = db.first_str("SELECT body FROM notes WHERE id = ?", id.to_s)

# Multi-row iteration.
db.prepare("SELECT id, body FROM notes ORDER BY id")
while db.step == 1
  puts db.col_int(0).to_s + ": " + db.col_str(1)
end
db.finalize
```

API surface:

| Method                | Returns | Notes |
|-----------------------|---------|---|
| `open(path)`          | bool    | `path` may be `:memory:` for an anonymous in-memory db. |
| `close`               | int     | |
| `exec(sql)`           | bool    | DDL / non-bound writes / `BEGIN`+`COMMIT`. |
| `prepare(sql)`        | bool    | Opens the cursor; `?` markers bind 1-indexed. |
| `bind_str(idx, v)`    | int     | |
| `bind_int(idx, v)`    | int     | |
| `step`                | int     | 1 -> row, 0 -> done, -1 -> error. |
| `col_str(idx)`        | str     | NULL columns return `""`. |
| `col_int(idx)`        | int     | |
| `col_count`           | int     | |
| `reset`               | int     | Re-step the same prepared statement (e.g. inside a binding loop). |
| `finalize`            | int     | |
| `last_rowid`          | int     | |
| `first_str(sql, p1)`  | str     | Convenience for "single-row, single-column read with one param." Pass `""` for "no param". |
| `first_int(sql, p1)`  | int     | Same. |

Constraints:

  - **One in-flight cursor per process.** `prepare` / `step` /
    `finalize` share a single `sqlite3_stmt *`. Tep runs handlers
    serially per worker so this is fine for "one DB call per
    request"; nested queries (open one cursor, run another query
    inside its `while step == 1` loop) would clobber the parent
    cursor.
  - **Up to 16 open DB handles per process** (a static slot table).
    Increase `TEP_SQLITE_MAX_HANDLES` in `tep_sqlite.c` if needed.
  - **String / int columns only.** Floats and blobs aren't first-
    class. NULL is indistinguishable from empty-string.
  - **64 KiB cap on a single col_str result.** Bump
    `TEP_SQLITE_COL_BUFSIZE` for larger row fields.

## JSON subset

`Tep::Json` is a pure-Ruby JSON shim covering the encode + decode
shapes that JSON-over-HTTP APIs use in practice. It deliberately
trades full library breadth for spinel-friendly code paths.

### Encode

```ruby
# Primitives.
Tep::Json.escape(s)              # body of a JSON string literal (no quotes)
Tep::Json.quote(s)               # "<escaped s>"

# Object building blocks (fixed-arity; compose by concatenation).
Tep::Json.encode_pair_str("k", v_string)   # "k":"v"
Tep::Json.encode_pair_int("k", v_int)      # "k":N

# Build a full object literal:
"{" + Tep::Json.encode_pair_str("name", name) + "," +
      Tep::Json.encode_pair_int("age", age) + "}"

# Arrays.
Tep::Json.from_str_array(["a", "b"])       # ["a","b"]
Tep::Json.from_int_array([1, 2, 3])        # [1,2,3]
```

There's intentionally **no** `from_str_hash(h)` / `from_int_hash(h)`
"give me a hash" convenience right now. Spinel #408 (commit
9ca01d7) fixed the body-walker harvest for the top-level shape, so
a method that `each`-iterates a Hash and concatenates `k`/`v` into
the output works fine. But once the body calls a sibling cmeth
inside the loop (`Json.escape(k)`), the narrowed `k:str` doesn't
propagate into `escape`'s param-type inference -- it widens to int
and the C compile fails. Filed as a #408 follow-up. Until that
lands, the fixed-arity `encode_pair_*` building blocks side-step
the issue and keep the call shape type-clean.

### Decode (flat-key, top-level only)

```ruby
Tep::Json.get_str(body, "name")  # value of top-level "name", or "" if absent / non-string
Tep::Json.get_int(body, "age")   # 0 if absent / non-numeric
Tep::Json.has_key?(body, "x")    # boolean
```

The hand-rolled state-machine parser walks one `{ "k": <value>, ... }`
pair at a time and skips over values it doesn't need (including
nested objects / arrays / strings with `"` and `{` / `}` inside
them). Returns 0 / "" on parse failure rather than raising --
suits API code that wants "no key" and "wrong type" to behave
the same way.

### Out of scope (deliberately)

  - **Floats.** Numbers parse / emit as int (`.to_s`). For
    fractional values, transport as strings.
  - **Path traversal** in the decoder (`payload.user.email`-style).
    Use a flatter API contract or do the nested decode manually.
  - **`\uXXXX` decoding past 00XX.** ASCII round-trips; non-ASCII
    bytes pass through verbatim in encode and on parse-time
    \u escapes in input we keep the low byte only.
  - **Streaming** parsers. Loads the whole string.

## Reading the matrix

A "supported" feature has at least one passing test through the
full pipeline (HTTP -> tep binary -> response). "Not yet supported"
rows have a `skip` in `test/test_unsupported.rb` or a fail-row in
the real-world table.
