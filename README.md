<p align="center">
  <img src="logo/tep.png" alt="Tep — Spinal Tap of web frameworks" width="240">
</p>

# Tep

A Sinatra-flavoured web framework that compiles to a native binary
via [Spinel][spinel].

> **Pre-alpha.** Tep exists primarily to exercise Spinel against
> real-world Ruby code. The framework happens to be useful too —
> it's a fast, single-binary HTTP server with the Sinatra DSL most
> Rubyists already know — but the *point* of the project is to
> shake bugs out of Spinel's codegen, file PRs upstream, and grow
> Spinel's coverage of idiomatic Ruby. If something doesn't work
> here, the bug is usually in Spinel, and that's interesting.

## Quick start

```sh
# 1. install Spinel
git clone https://github.com/matz/spinel
cd spinel && make all
export PATH="$PWD:$PATH"

# 2. install Tep
git clone https://github.com/OriPekelman/tep
cd tep && make
./examples/hello -p 4567
```

Your own app:

```ruby
# hello.rb
require 'sinatra'

get '/' do
  "hello from Tep"
end

get '/hi/:name' do
  "hi, " + params[:name] + "!"
end
```

```sh
tep build hello.rb       # -> ./hello (~80 KB binary, no Ruby runtime)
./hello -p 4567
```

The translator (`bin/tep`) needs CRuby >= 3.4 — Prism ships with
the stdlib from 3.4 onward. Recommended Ruby manager:
[`rv`](https://github.com/spinel-coop/rv) — fast version+gem
manager from the Spinel Cooperative (separate project from the
matz/spinel AOT compiler Tep compiles through; same Ruby
neighbourhood). `.ruby-version` in this repo pins 3.4.0; `rv
shell` makes `rv run rake test` just work. Build deps on Linux:
`build-essential`, `libsqlite3-dev`. macOS: Xcode CLI tools.

For a full walkthrough — auth, persistence, deploy — see the
[Getting started](https://github.com/OriPekelman/tep/wiki/Getting-Started)
wiki page.

## Is it fast?

Yes. 200k+ req/s on a small Linux server, ~20 µs median latency.
The hot path is C from end to end (epoll, request parsing, dispatch,
response writer); the Ruby you wrote is compiled, not interpreted.
HTTP/1.1 keep-alive and prefork with `SO_REUSEPORT` are the usual
wins applied.

| Server                              | Req/sec | p50    | p99    |
|-------------------------------------|--------:|-------:|-------:|
| **Tep, 8 workers (Linux/aarch64)**  | 227,186 |  32 µs | 145 µs |
| **Tep, 1 worker  (Linux/aarch64)**  |  49,037 |  18 µs |  73 µs |
| Sinatra + Puma + CRuby (8w × 4t)    |  34,108 | 1.2 ms | 152 ms |

`wrk -t8 -c256 -d10s` against a hello-world handler on Linux 6.x /
aarch64.

> **macOS note.** Linux is Tep's primary deployment target. Builds
> and runs on macOS too, but Darwin's `SO_REUSEPORT` doesn't load-
> balance new connections across prefork workers — a single long-
> running response on the busy worker blocks every other request on
> the same listener. On Linux 3.9+ the kernel distributes accepts
> correctly, so prefork scales as the table above.

## What's in the box

Sinatra-shaped routing, filters, responses, templates, sessions,
plus a collection of "batteries" — pure-Tep modules that cover the
gem ecosystem's most common needs in a way that lowers cleanly
through Spinel.

| Battery          | What it covers |
|------------------|---|
| `Tep::SQLite`    | libsqlite3 wrapper via a small C shim — exec / prepare / bind / step / col / first_str / first_int. |
| `Tep::Json`      | encode primitives + flat-key decoder for JSON-over-HTTP. |
| `Tep::Logger`    | levelled logger (debug/info/warn/error), stderr or file. |
| `Tep::Jwt`       | HS256 JWT encode / verify / decode. |
| `Tep::Password`  | PBKDF2-SHA256, 200k iters, self-describing storage. |
| `Tep::Security`  | `Cors` (before-filter) + `Headers` (HSTS, nosniff, ...). |
| `Tep::Assets`    | compile-time bundling for `<app>/assets/*`. |
| `Tep::Scheduler` | cooperative fiber scheduler with timer + I/O parking. |
| `Tep::Shell`     | popen-based shell-out + small-file reader (`/proc`, `/sys`, `/etc`). |
| `Tep::Http`      | Faraday-shaped outbound HTTP/1.0 client. |
| `Tep::Parallel`  | grosser/parallel-shaped fork fan-out. |
| `Tep::Job`       | sidekiq-shaped queue over SQLite. |

Per-battery API docs and cookbooks live on the
[wiki](https://github.com/OriPekelman/tep/wiki). The full
Sinatra-compatibility matrix is in
[SINATRA_COMPAT.md](SINATRA_COMPAT.md); the ecosystem survey
(which gems lower today, which don't) in
[GEM_SURVEY.md](GEM_SURVEY.md).

~180 tests pass `make test`. 9 real-world test apps build and serve
end-to-end (smoke-tested through `Net::HTTP`), and the bundled
[`examples/gx10_dashboard/`](examples/gx10_dashboard/app.rb) — an
operator dashboard for an NVIDIA GB10 server — exercises every
public Tep feature in ~640 lines.

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
