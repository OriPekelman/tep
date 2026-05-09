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

40k+ requests per second on a laptop, 200k+ on a small server, with
~20 µs median latency. The hot path is C from end to end (kqueue/epoll
scheduling, request parsing, dispatch table, response writer); the
Ruby you wrote is compiled, not interpreted. HTTP/1.1 keep-alive and
prefork-with-`SO_REUSEPORT` are the usual perf wins applied.

| Server                              | Req/sec | p50    | p99    |
|-------------------------------------|--------:|-------:|-------:|
| **tep, 8 workers (Linux/aarch64)**  | 227,186 |  32 µs | 145 µs |
| **tep, 1 worker  (Linux/aarch64)**  |  49,037 |  18 µs |  73 µs |
| Sinatra + Puma + CRuby (8w × 4t)    |  34,108 | 1.2 ms | 152 ms |
| **tep, 1 worker  (macOS/aarch64)**  |  42,457 |  20 µs |  77 µs |

`wrk -t8 -c256 -d10s` against a hello-world handler. macOS doesn't
load-balance `SO_REUSEPORT` the same way Linux does, so prefork on
macOS doesn't scale beyond a single worker — the headline numbers
come from Linux.

## What works (today)

**Routing**: `get` / `post` / `put` / `patch` / `delete`; path
captures (`:name`), splats (`*`), regex (`get %r{^/posts/(\d+)$}`,
captures bind to `params["1"]..["9"]`), query string,
form-urlencoded bodies.

**Response**: `status N`, `redirect 'x'`, `halt N, "msg"`,
`content_type 'x'`, `headers["X"] = "y"`.

**State**: cookies (`cookies[k]` to read, `set_cookie "k", "v"` to
write), sessions (`session[k] = v` — HMAC-SHA256-signed cookie
store; tampered cookies are rejected; set
`Tep.session_secret = "..."` to enable).

**Templates**: ERB at build time. Each `views/<name>.erb` becomes a
top-level method; `erb :name, locals: { x: ... }` calls it.
`<%= %>`, `<% %>`, and `<%# %>` all work.

**Streaming**: chunked Transfer-Encoding via subclass of
`Tep::Streamer`, dispatched as `stream MyStreamer.new`.

**Composition**: `Sinatra::Base` modular apps (the translator
unwraps them; routes from multiple classes coexist). `before` /
`after` filters, custom `not_found`, static-file serving via
`set :public_dir, '...'`, `set :views, '...'`. `on_start do`.

**Request inside handlers**: `request.params`, `request.headers`,
`request.path`, `request.verb`, `request.body`, `request.cookies`,
`session`, plus the `params` / `cookies` / `session` shorthands.

68 documented Sinatra behaviours pass `make test` (9 still skip).
5 of 8 small real-world Sinatra apps (Sinatra's own `examples/`
plus a few fetched-from-GitHub) build and serve correctly through
`tep build`. Full breakdown in [SINATRA_COMPAT.md](SINATRA_COMPAT.md).

## What doesn't (yet)

`helpers do ... end` (closures aren't first-class in Spinel).
`send_file 'path'` from inside a handler. Optional path segments
(`get '/say(/:greeting)'` — Mustermann syntax). Multiple chained
`before` / `after` filters. `pass`. Full `Rack::Request` methods
(`.ip`, `.scheme`, `.ssl?`). `configure { ... }`. Sinatra's
bare-`@ivar` ERB locals (use `locals: {...}` instead).
`__END__` inline templates. Haml / Slim / etc. ORM gems.

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

The translator (`bin/tep`) is plain CRuby (Ruby >= 3.4 — Prism
ships with it). The compiled binaries themselves have no Ruby
dependency; `tep build` is the only step that needs CRuby.

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
