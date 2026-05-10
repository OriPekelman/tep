<p align="center">
  <img src="logo/tep.png" alt="Tep — Spinal Tap of web frameworks" width="240">
</p>

# tep

A Sinatra-flavoured web framework that compiles to a native binary
via [Spinel][spinel].

> **Pre-alpha.** tep exists primarily to exercise Spinel against
> real-world Ruby code. The framework happens to be useful too —
> it's a fast, single-binary HTTP server with the Sinatra DSL most
> Rubyists already know — but the *point* of the project is to
> shake bugs out of Spinel's codegen, file PRs upstream, and grow
> Spinel's coverage of idiomatic Ruby. If something doesn't work
> here, the bug is usually in Spinel, and that's interesting.

## What it looks like

```ruby
require 'sinatra'

set :public_dir, './public'
set :views,      './views'
Tep.session_secret = ENV.fetch("TEP_SESSION_SECRET")

get '/' do
  erb :index, locals: { name: cookies["who"] }
end

get '/hi/:name' do
  set_cookie "who", params[:name]
  session["last_seen"] = params[:name]
  "<p>hi, " + params[:name] + "!</p>"
end

# Regex routes work too:
get %r{^/posts/(\d+)$} do
  "post id=" + params["1"]
end

before do
  puts "[" + request.verb + "] " + request.path
end

not_found do
  "<h1>oops -- " + request.path + " not here</h1>"
end
```

```sh
tep build app.rb     # translate + AOT-compile to ./app
./app -p 4567        # serve
```

The compiled binary is ~80 KB. No Ruby runtime ships with it;
Spinel emits standalone C and a system C compiler turns it into a
native executable that links against the platform's libc.

## Why is this fast?

200k+ requests per second on a small Linux server, ~20 µs median
latency. The hot path is C from end to end (epoll scheduling, request
parsing, dispatch table, response writer); the Ruby you wrote is
compiled, not interpreted. HTTP/1.1 keep-alive and prefork-with-
`SO_REUSEPORT` are the usual perf wins applied.

| Server                              | Req/sec | p50    | p99    |
|-------------------------------------|--------:|-------:|-------:|
| **tep, 8 workers (Linux/aarch64)**  | 227,186 |  32 µs | 145 µs |
| **tep, 1 worker  (Linux/aarch64)**  |  49,037 |  18 µs |  73 µs |
| Sinatra + Puma + CRuby (8w × 4t)    |  34,108 | 1.2 ms | 152 ms |

`wrk -t8 -c256 -d10s` against a hello-world handler on Linux 6.x /
aarch64.

> **macOS note.** Linux is tep's primary deployment target. Builds and
> runs on macOS for development too, but Darwin's `SO_REUSEPORT`
> doesn't load-balance new connections across prefork workers — a
> single long-running response (SSE, long-poll) on the busy worker
> blocks every other request on the same listener. On Linux 3.9+
> the kernel distributes accepts correctly, so prefork scales as
> the table above.

## What works (today)

**Routing**: `get` / `post` / `put` / `patch` / `delete`; path
captures (`:name`), splats (`*`), regex (`get %r{^/posts/(\d+)$}`,
captures bind to `params["1"]..["9"]`), optional segments
(`get '/say(/:greeting)'`), `pass` / `pass if cond`,
query string, form-urlencoded bodies.

**Response**: `status N`, `redirect 'x'`, `halt N, "msg"`,
`content_type 'x'`, `headers["X"] = "y"`, `send_file 'path'`.

**State**: cookies (`cookies[k]` to read, `set_cookie "k", "v"` to
write), sessions (`session[k] = v` — HMAC-SHA256-signed cookie
store; tampered cookies are rejected; set
`Tep.session_secret = "..."` to enable).

**Templates**: ERB at build time with Sinatra-style `@ivar` locals
(`@x = "alice"` in the handler, `<%= @x %>` in the template) and
explicit `locals: {...}` hashes. `__END__` inline templates work.
A documented Mustache subset ships alongside (`mustache :name`,
parallel DSL) for projects that prefer logic-less templates.

**Streaming**: chunked Transfer-Encoding via subclass of
`Tep::Streamer`, dispatched as `stream MyStreamer.new`.

**Composition**: `Sinatra::Base` modular apps (the translator
unwraps them; routes from multiple classes coexist). Multiple
chained `before` / `after` filters. Custom `not_found`. Static-file
serving via `set :public_dir, '...'`, `set :views, '...'`,
`set :workers, N`. `on_start do`. `configure { ... }` /
`configure :env { ... }`. Compile-time asset bundling: anything
under `<app>/assets/` is baked into the binary at build time and
served straight from memory.

**Request inside handlers**: `request.params`, `request.headers`,
`request.path`, `request.verb`, `request.body`, `request.cookies`,
`request.host`, `request.user_agent`, `request.referer`,
`request.accept`, `request.content_type`, `request.scheme` /
`.ssl?` (via `X-Forwarded-Proto`). Plus the `params` / `cookies` /
`session` shorthands.

**Batteries** (under `Tep::*`):

| Module           | What it covers |
|------------------|---|
| `Tep::SQLite`    | libsqlite3 wrapper via a small C shim — exec / prepare / bind / step / col / first_str / first_int. |
| `Tep::Json`      | encode primitives + flat-key decoder for JSON-over-HTTP. |
| `Tep::Logger`    | levelled logger (debug/info/warn/error), stderr by default, `to_file(path)` for append. |
| `Tep::Jwt`       | HS256 JWT encode / verify / decode; interop-tested against the canonical `jwt` gem. |
| `Tep::Password`  | PBKDF2-SHA256 password hashing, 200k iters, self-describing storage format. |
| `Tep::Security`  | `Cors` (before-filter) + `Headers` (after-filter; HSTS, nosniff, frame-options, ...). |
| `Tep::Assets`    | compile-time bundling for `<app>/assets/*` (CSS, SVG, JS, ...). |
| `Tep::Scheduler` | cooperative fiber scheduler — spawn / tick / run_until_empty / sleep. Time-driven; I/O-readiness peers planned. |

~160 tests across the test suite pass `make test`. 4 documented
skips. 6 real-world examples build and serve end-to-end (smoke-
tested through `Net::HTTP`). Full breakdown in
[SINATRA_COMPAT.md](SINATRA_COMPAT.md); ecosystem survey in
[GEM_SURVEY.md](GEM_SURVEY.md).

## What doesn't (yet)

`helpers do ... end` (closures aren't first-class in Spinel).
`request.ip` / `request.remote_ip` (needs an `sphttp_accept`
variant that returns the peer address). Haml / Slim and other
metaprogramming-heavy templating gems.

Each gap that bites a real-world app gets logged as a backlog
entry and either fixed in tep or, where the underlying constraint
is in Spinel itself, filed as a Spinel issue / PR.

## Install (from source)

```sh
git clone https://github.com/matz/spinel
cd spinel && make all
export PATH="$PWD:$PATH"   # so `spinel` is on PATH

git clone https://github.com/OriPekelman/tep
cd tep && make             # builds the C helper + the demo binaries
./examples/hello -p 4567   # try it
```

The translator (`bin/tep`) is plain CRuby and needs Ruby >= 3.4
(Prism ships with the standard library from 3.4 onward; on older
rubies install it explicitly: `gem install prism` — but you'll need
`ruby-dev` / `libruby-dev` for the C extension to build).
Compiled binaries themselves have no Ruby dependency; `tep build`
is the only step that needs CRuby.

Linux build deps: `build-essential` (or just `gcc` + `make`),
`libsqlite3-dev` (for the SQLite-backed examples). macOS:
Xcode command-line tools cover both.

## Two flavours of source

Sinatra-style (recommended; the translator handles it):

```ruby
require 'sinatra'
get('/') { 'hi' }
```

Spinel-direct (no translator; less ergonomic, more transparent):

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

`tep build` accepts both.

## How it works under the hood

```
your-app.rb                          ┐
   │  bin/tep build                  │  build-time
   │   (Prism parser + textual       │  (CRuby)
   │    rewrites, inlines tep        │
   │    framework into one file)    │
   ▼                                 │
spinel-compatible .rb                │
   │  spinel                         │
   │   (parse + whole-program type   │
   │    inference + C codegen)       │
   ▼                                 │
.c                                   │
   │  cc -O2                        │
   ▼                                 │
native binary  ◄─────────────────────┘
```

At runtime the binary is a pre-fork HTTP server (with optional
`SO_REUSEPORT` workers) and its own request parser, router,
chunked-encoding writer, signed-cookie store, and ERB renderer —
all written in tep's Ruby and compiled to C. A small C helper
(`lib/tep/sphttp.c`) wraps POSIX sockets and provides SHA-256 /
HMAC primitives for the session store, all reached via Spinel's
FFI surface. There's no Rack in the picture.

## Reporting bugs

If you hit something that "should work" — a Sinatra idiom that
doesn't translate, a Spinel-emitted miscompile, a runtime hang,
anything — please file an issue with a minimal reproduction. tep is
explicitly trying to find Spinel's edges, so "your app doesn't
build" is a useful data point.

## License

MIT, see [LICENSE](LICENSE).

[spinel]: https://github.com/matz/spinel
