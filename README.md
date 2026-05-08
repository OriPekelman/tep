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

get '/' do
  "<h1>hello, world</h1>"
end

get '/hi/:name' do
  "<p>hi, " + params[:name] + "!</p>"
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

`get` / `post` / `put` / `patch` / `delete` routes; path captures
(`:name`), splats (`*`), query string, form-urlencoded bodies;
`status N`, `redirect 'x'`, `halt N, "msg"`, `content_type 'x'`,
`headers["X"] = "y"`; `before` and `after` filters; custom
`not_found`; static file serving via `set :public_dir, '...'`.

`request.params`, `request.headers`, `request.path`, `request.verb`,
`request.body` are all available inside a handler.

42 of 42 documented Sinatra behaviours covered by `make test`.
5 of 8 small real-world Sinatra apps (Sinatra's own `examples/`
plus a handful of fetched-from-GitHub apps) build and serve
correctly through `tep build`. Full breakdown in
[SINATRA_COMPAT.md](SINATRA_COMPAT.md).

## What doesn't (yet)

Templates (ERB / Haml), sessions, cookies, streaming responses,
`Sinatra::Base` modular apps, `helpers do ... end`, regex routes,
`pass`, ORM gems. See SINATRA_COMPAT.md for the full list and the
priority order. Each gap that bites a real-world app gets logged
as a backlog entry and either fixed in tep or, where the underlying
constraint is in Spinel itself, filed as a Spinel issue / PR.

## Install (from source)

```sh
git clone https://github.com/OriPekelman/spinel    # or your fork
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

At runtime the binary is a single-process pre-fork HTTP server with
its own request parser (no Rack), routing table, and response writer
all written in tep's Ruby and compiled to C. A small C helper
(`lib/tep/sphttp.c`) wraps POSIX sockets via Spinel's FFI surface.

## Reporting bugs

If you hit something that "should work" — a Sinatra idiom that
doesn't translate, a Spinel-emitted miscompile, a runtime hang,
anything — please file an issue with a minimal reproduction. tep is
explicitly trying to find Spinel's edges, so "your app doesn't
build" is a useful data point.

## License

MIT, see [LICENSE](LICENSE).

[spinel]: https://github.com/matz/spinel
