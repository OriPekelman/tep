# Common Sinatra-app gems vs spinel

A snapshot of "what Sinatra apps actually pull in" mapped against
spinel's compile model. Each row classifies one of:

  - **as-is**: gem source compiles through spinel without changes.
    Rare. Almost any non-trivial gem uses metaprogramming
    (`define_method`, `class_eval`, `method_missing`,
    `attr_accessor` with custom callbacks) which spinel can't lower.
  - **patch**: gem mostly works, a small fork would smooth the
    metaprogramming-heavy bits.
  - **C-shim**: the value is in a C library; wrap libfoo with a
    thin C surface and a Ruby class (same pattern as sphttp.c /
    tep_sqlite.c).
  - **reimpl**: write a small subset in pure tep-friendly Ruby.
    Document the surface like we did for the Mustache subset.

The list is a working priority queue, not a closed set. Add as we
find concrete user demand.

## Top 20-ish gems by Sinatra deployment frequency

### JSON / serialization

| Gem            | Verdict | Notes |
|----------------|---------|---|
| `json` (stdlib)| reimpl  | The fast path is `JSON::Ext` (a C extension); spinel can't load it. The pure-Ruby `JSON::Pure` uses StringScanner + many regex / `define_method` shapes. ~200 lines of straight-line Ruby covers parse + generate for the common cases (objects, arrays, strings, numbers, true/false/null). **Highest-ROI next target.** |
| `oj`           | no      | All-C. Use `Tep::Json` instead. |
| `multi_json`   | no      | Abstraction over backends; just call our `Tep::Json` directly. |
| `yajl-ruby`    | C-shim  | libyajl is small + stable; could wrap if performance matters more than tep's pure-Ruby version. Defer until profiling says we need it. |
| `msgpack`      | C-shim  | libmsgpack-c exists. Niche for Sinatra; defer. |

### Authentication / sessions

| Gem            | Verdict | Notes |
|----------------|---------|---|
| `bcrypt`       | C-shim  | bcrypt is a 200-line C reference impl + a very stable interface. tep already does HMAC-SHA256 in sphttp.c; bcrypt would slot next to it cleanly. |
| `jwt`          | reimpl  | Header + payload + HMAC-signed-base64. tep already has the HMAC C helper; the encoder is ~80 lines, decoder + verify is ~100. |
| `omniauth`     | no      | Built around runtime strategy registration via `class_eval`. Out of scope; users would re-implement the OAuth dance per provider in handlers. |
| `devise`       | no      | Rails-only; not a real Sinatra contender. |
| `sinatra-flash`| reimpl  | "store a string in session, read+clear on next render." 30 lines on top of the existing session store. |
| `warden`       | no      | Heavy middleware abstraction, runtime strategy registration. |

### HTTP client

| Gem            | Verdict | Notes |
|----------------|---------|---|
| `net/http`     | C-shim  | Pure Ruby but uses TCP sockets, SSL via OpenSSL, `Thread`, and a deep class hierarchy with metaprogrammed accessors. Reimpl is much more work than a thin libcurl wrapper. **Recommended target if tep apps need outbound HTTP.** |
| `faraday`      | no      | Middleware stack with runtime adapter registration. |
| `httparty`     | no      | `define_method` heavy. |
| `typhoeus`     | C-shim  | libcurl-based; if we already have the libcurl shim from net/http, this gem's surface is sugar. |
| `excon`        | no      | Pure Ruby + many backends. |

### Database / persistence (beyond SQLite)

| Gem            | Verdict | Notes |
|----------------|---------|---|
| `sqlite3`      | done    | We already ship `Tep::SQLite` via `tep_sqlite.c`. |
| `pg`           | C-shim  | libpq has a stable C API. Pattern parallels tep_sqlite.c. Probably ~250 lines. |
| `mysql2`       | C-shim  | libmysqlclient. Same shape. |
| `sequel`       | no      | Pure Ruby but heavily metaprogrammed; the value IS the metaprogramming. Use raw `Tep::SQLite` or the future pg/mysql shims. |
| `activerecord` | no      | Out of scope. |
| `redis`        | C-shim  | Hiredis is the clean low-level surface. |

### Templating (already covered)

| Gem            | Verdict | Notes |
|----------------|---------|---|
| `erb` (stdlib) | done    | Tep ships its own AOT erb compiler; matches the surface tep apps actually use. |
| `mustache`     | done    | Documented subset shipped. Sections / partials / lambdas raise at build time. |
| `haml`         | no      | Whitespace-significant + heavy compilation; would need a build-time compiler the size of erb's plus the Haml syntax surface. Not impossible but not high ROI. |
| `liquid`       | no      | Runtime tag/filter registration; the value is the metaprogramming. |
| `slim`         | no      | Same shape as Haml. |

### Validators

| Gem                | Verdict | Notes |
|--------------------|---------|---|
| `dry-validation`   | no      | Built on `define_method` for predicate composition. |
| `hanami-validations` | no    | Same shape. |
| **(reimpl: tep-side)** | reimpl | A small "schema as a hash of name => predicate Procs" wouldn't be Proc-friendly under spinel; the practical alternative is per-handler explicit checks (which is what hand-written Sinatra does anyway). |

### Middleware

| Gem               | Verdict | Notes |
|-------------------|---------|---|
| `rack-protection` | reimpl  | The header / CSRF defaults are easy: cors-allowed-origins, X-Frame-Options, X-Content-Type-Options, strict-transport-security. ~30 lines. CSRF token threading is more work but a clean tep-side feature. |
| `rack-cors`       | reimpl  | CORS is "respond with the right Access-Control-Allow-* headers given a config." ~40 lines. |
| `rack-flash`      | reimpl  | See `sinatra-flash` row. |

### Logging / observability

| Gem            | Verdict | Notes |
|----------------|---------|---|
| `logger` (stdlib) | reimpl  | The stdlib Logger is metaprogrammed. tep can ship a `Tep::Logger` with `info` / `warn` / `error` levels writing to stderr / a file. ~50 lines. |
| `lograge`      | no      | Rails-targeted. |
| `sentry-ruby`  | no      | Heavy; defer. |

### Background jobs

| Gem          | Verdict | Notes |
|--------------|---------|---|
| `sidekiq`    | no      | Built on Redis client + threads; the threading model alone is out of scope. |
| `sucker_punch` | no    | Threads. |
| `resque`     | no      | Same shape. |

These really need a different runtime model. If "fire-and-forget
work" matters for tep apps, the Tep-shaped answer is `fork()` to
a child process running a separate handler, since spinel exposes
`sphttp_fork` already.

### Misc

| Gem                | Verdict | Notes |
|--------------------|---------|---|
| `nokogiri`         | C-shim  | libxml2 / libxslt; 100 lines for a basic XML parse, more for XPath. |
| `dotenv`           | reimpl  | Read `.env`, set ENV. ~20 lines. |
| `pry` / `irb`      | no      | Out of scope (eval-based). |
| `rack`             | n/a     | tep replaces rack; we are the server. |

## Priority order (recommendation)

If we want a "batteries-included Sinatra-on-spinel" feel, in order
of bang-for-buck:

1. **`Tep::Json`** -- parse + generate. Highest-ROI single
   addition (every API needs it).
2. **`Tep::Logger`** -- structured stderr/file logging. Cheap,
   nearly every app wants it.
3. **`Tep::Auth::BCrypt`** + **`Tep::Auth::Jwt`** -- C-shim
   bcrypt + pure-Ruby jwt sitting on top of the existing HMAC
   helper. Unlocks "real auth" without a SaaS dependency.
4. **`Tep::Http`** (libcurl C-shim) -- outbound HTTP. Necessary
   for any app that talks to other services. Gives `Tep::Http.get`
   / `.post` / etc. with simple kwargs.
5. **`Tep::Cors`** + **`Tep::SecureHeaders`** -- common middleware
   patterns reimplemented as before-filters.

The bcrypt + jwt + cors + secure_headers tier is what turns "tep
hello world" into "tep production API."
