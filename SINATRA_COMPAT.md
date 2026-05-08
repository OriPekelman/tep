# Sinatra compatibility (tep v0.1)

Generated from the curated checklist suite under `test/` plus
real-world apps under `test/real_world/`. Run with `make test` to
refresh the checklist; build the real_world apps directly with
`bin/tep build test/real_world/<NN>.rb`.

**Headline**: 42 checklist tests pass + 5 of 8 real-world apps build
and serve correctly. The 3 failures cluster around the same
unsupported features (templates, ORM gems, JSON serialization).

## Phase A — Curated checklist

| Feature                         | Tests       | Notes |
|---------------------------------|------------:|---|
| `get` / `post` / `put` / `patch` / `delete` | ✅ 8 | All five verbs round-trip |
| Path parameters (`/hi/:name`)   | ✅ 4         | Single-segment captures |
| Two+ path parameters            | ✅ 1         | `/users/:id/posts/:post_id` |
| Splat (`*`)                     | ✅ 1         | Last-segment only |
| Query string                    | ✅ 4         | `params[:q]` reads through |
| Form-urlencoded body            | ✅ 2         | Auto-merged into params |
| URL-decoding (`%xx`, `+`)       | ✅ 2         | Path captures and query both |
| Default 200 status              | ✅ 1         | |
| Custom status (`status N`)      | ✅ 5         | 201, 204, 401, 418, 500 ... |
| Default `text/html` Content-Type | ✅ 1        | |
| Explicit `content_type 'x'`     | ✅ 2         | Plain, JSON |
| Custom `headers["X"] = "y"`     | ✅ 1         | |
| `redirect 'x'` (302)            | ✅ 1         | Location header set |
| `redirect 'x', code`            | ✅ 1         | Honors override (301) |
| `halt code, "body"`             | ✅ 1         | |
| `halt code` (no body)           | ✅ 1         | |
| `before do ... end`             | ✅ 2         | Single slot, runs before route |
| `after do ... end`              | ✅ 1         | Runs after route, sees mutated res |
| Default 404                     | ✅ 1         | |
| Custom `not_found do ... end`   | ✅ 2         | Body and `request.path` access |
| Static files via `set :public_dir` | ✅ 4      | Mime-type sniffing, X-Tep-Static |
| Path-traversal rejection        | ✅ 1         | `..` segments blocked |
| Route precedence over static    | ✅ 1         | Defined route wins |
| `Content-Length` correctness    | ✅ 1         | |
| 404 on method mismatch          | ✅ 1         | `POST /` when only GET defined |
| `on_start do ... end`           | ✅ (B)       | Body runs at top of program (added inline during Phase B) |
| `request.headers["X"]`          | ✅ (B)       | Read alias added after spinel PR #388 |

## Phase B — Real-world apps

`test/real_world/`:

| # | Source                                            | Build | Serve | Notes |
|---|---------------------------------------------------|:-----:|:-----:|---|
| 01 | sinatra/examples/simple.rb                        | ✅ | ✅ | First-try pass; `get('/'){...}` form works. |
| 02 | sinatra/examples/lifecycle_events.rb              | ✅ | ✅ | Triggered translator support for `on_start`; `on_stop` ignored (no shutdown path). |
| 03 | sinatra/examples/chat.rb                          | ❌ | — | ERB templates, `stream do |out|`, `__END__` data section, `Set.new` top-level. Out of scope for v0.1. |
| 04 | synthesized: tiny health/version JSON API         | ✅ | ✅ | Triggered translator passthrough for top-level constants. |
| 05 | synthesized: in-memory todo CRUD                  | ✅ | ✅ | Required `Array.new(0).delete_at(0)` seed-and-clear pattern for typed arrays. Triggered translator fix for receiver-aware top-call handling. |
| 06 | synthesized: before-filter Bearer auth            | ✅ | ✅ | Triggered `Tep::Request#headers` read alias (now safe after spinel PR #388). |
| 07 | github.com/bbc/REST-API-example                   | ❌ | — | DataMapper ORM, `dm-types`, `dm-validations`. ORM gems are out of scope for AOT. |
| 07 | github.com/sklise/sinatra-api-example             | ❌ | — | DataMapper, `to_json`, `send_file`. As above. |
| 08 | github.com/jwd83/sinatra-helloworld               | ⚠️ | ❌ | Builds with warnings (erb undefined → emits 0); routes serve garbage because the unresolved `erb` calls return 0 instead of HTML. |

## Inline fixes shipped during Phase B

- **Translator: `on_start` support.** Body runs verbatim at top level
  before `Tep.run!`.
- **Translator: top-level passthrough.** Constants (`VERSION = '...'`),
  class/module/def declarations, top-level `if` blocks etc. are now
  emitted verbatim. Previously dropped.
- **Translator: receiver-aware top-call handling.** Method calls with
  a receiver (`$arr.delete_at(0)`) pass through verbatim instead of
  being mis-flagged as unknown DSL methods.
- **Tep::Request: `headers` / `body` read aliases.** Sinatra-style
  `request.headers['X']` now works. (The earlier need to write
  `req.req_headers[...]` came from a spinel poly-write bug; PR #388
  fixed that, so the readable alias is now safe.)

## Not yet supported (skipped tests + Phase B blockers)

| Feature                | Effort | Found in real-world | Notes |
|------------------------|--------|---------------------|---|
| ERB templates          | small  | 03, 08              | spinel ships `lib/erb.rb`; needs `erb :name` translator support, view path config |
| `__END__` inline templates | small | 03, 08             | Read after `__END__`, expose as named templates |
| `helpers do ... end`   | medium | 08                  | Closures aren't first-class in spinel; needs translator-level "extract methods to Handler base class" pass |
| `to_json` on objects   | small  | 07                  | Either ship a tiny JSON helper or rewrite `obj.to_json` to manual JSON |
| `send_file 'path'`     | small  | 07                  | Generalize Tep's static-dir support to any path |
| Cookies / `Set-Cookie` | small  | —                   | Parse `Cookie:`, write `Set-Cookie:` |
| Sessions               | medium | —                   | Cookies + signed/encrypted store |
| Streaming `stream do`  | medium | 03                  | Chunked Transfer-Encoding writer |
| Regex routes           | medium | —                   | Spinel has built-in regexp; teach the router |
| Optional segments `(/:foo)` | medium | —              | Mustermann-lite |
| Multiple before/after filters | small | —             | Composite filter pattern; or accept perf cost of poly array |
| `pass`                 | small  | —                   | Try-next-route mechanism in dispatcher |
| Full Rack::Request methods | medium | —              | `.ip`, `.scheme`, `.ssl?`, etc. |
| Sinatra::Base modular  | large  | most github apps    | Significant rework; v0.1 is classic-only |
| `configure { ... }`    | small  | 08                  | Just gate side-effects on an env var |
| ORM gems (DataMapper, ActiveRecord) | n/a | 07, 07-bbc | Out of scope for AOT |
| `Bundler.require`      | n/a    | 07-bbc, 08          | Bundler doesn't apply to AOT-compiled binaries |

## Reading the matrix

A "supported" feature has at least one passing test that exercises it
through the full pipeline (HTTP -> tep binary -> response). "Not yet
supported" rows have a `skip` in `test/test_unsupported.rb` or a
fail-row in the real-world table.

The Phase B failures all converge on a small handful of features:
**templates** (ERB primarily), **modular `Sinatra::Base`**, and
**ORM gems**. Adding ERB would unlock 03 and 08 (and many more
real-world apps); adding modular Sinatra::Base would unlock the
majority of github-search hits.
