# Spike: can tep use the `qdrant-ruby` gem (0.9.10)?

**Question.** spinelgems lists `qdrant-ruby 0.9.10` as "verified". Can we
actually *use* it from tep — i.e. drive a real Qdrant from spinel-AOT'd
code — and stand it up as a "vector DB battery"?

**Short answer: not as a working battery as-is.** The gem's *read-path*
API logic is reusable in principle, but three independent walls stop a
real round-trip. A genuine Qdrant battery would be tep-native (typed
request builders + a TLS-capable client), using the gem only as an
API-shape reference — which is exactly tep's stated design philosophy
(match the canonical gem's API; reuse gem code *when it lowers*; no
novel APIs).

## What "verified" actually meant

spinelgems' check is `harness/smoke/qdrant-ruby.rb`: it loads the gem and
prints `Qdrant::VERSION`. Because the gem's top-level `qdrant.rb` uses
`autoload`, that smoke test never compiles `client.rb` (Faraday) or any
resource class. So "verified" = *the version constant loads*, nothing
more. This spike is the first attempt to exercise the actual API.

## What worked (probed on spinel `96b21e6`, matched toolchain)

- Gem loads; `Qdrant::VERSION` etc. (the smoke baseline).
- **Keyword arguments** — required defaults, optional `nil` defaults,
  call-site overrides — all lower correctly. The gem's entire resource
  API is kwargs-based, so this matters a lot.
- **Blocks yielding a mutable request object** (`conn.post(p){|req| ... }`)
  — the pattern every resource method uses — lowers.
- Building **heterogeneous / nested hashes** (`h["v"]=[floats]; h["n"]=5;
  h["cfg"]={...}`) compiles *when no two value types force a homogeneous
  hash* (see wall #2).
- The gem's resource files (`base.rb`, `collections.rb`, `points.rb`,
  `service.rb`) are vendored here **byte-for-byte** from 0.9.10 — they're
  thin: build a request, call `client.connection.<verb>`, return
  `response.body`. All Faraday coupling lives in `client.rb` (not used).

## Wall #1 — tep has no TLS; Qdrant Cloud is HTTPS-only

`Tep::Http.send_req` rejects any non-`http` scheme ("HTTPS / unknown
scheme -- not in v1"); `sphttp_connect` is a plain TCP connect; spinel's
"crypto" is HMAC/SHA only (explicitly *not* OpenSSL/libsodium). The
Qdrant Cloud endpoint is `https://…qdrant.io` (TLS-only). So tep cannot
reach it directly — you'd need a local TLS terminator (socat/stunnel/a
proxy) or a plaintext local Qdrant. Infra-level, not a gem problem.

## Wall #2 — heterogeneous JSON bodies can't be serialized

The gem builds request bodies as native Ruby Hashes mixing arrays of
floats, ints, bools, and nested hashes (e.g. `Points#upsert`,
`Collections#create`, `Points#search`), and relies on Faraday's `:json`
middleware to serialize *an arbitrary structure*. Under spinel:

- `Tep::Json` is a **typed, surgical** library — `encode_pair_str/int`,
  `from_str_hash`, typed getters. No generic `JSON.generate(arbitrary)`.
- stdlib `JSON.generate(poly_hash)` returns garbage (`0`), and
  `.to_json` returns empty — generic encoding of a heterogeneous
  structure does not work.
- A hash that mixes a `String` value and an `Int` value is inferred as a
  homogeneous `StrStrHash`, so the int assignment fails to compile:

  ```
  sp_StrStrHash_set(lv_cfg, "size", 4LL)   // const char* expected, got int
  ```
  (from `cfg["size"]=4; cfg["distance"]="Cosine"` — see `compile-errors.txt`)

So the *write* half of the API — the whole point of a vector DB — can't
be driven by handing native nested structures through the shim. tep's
model is to hand-build typed JSON instead.

## Wall #3 — name-based cross-class type pollution

`Tep::Http` transitively requires `Tep::Scheduler` → `Tep::APP` → the
whole framework; there is no minimal HTTP-only subset. With the gem's
classes added to that program, spinel's whole-program, **name-based**
type inference leaks `Qdrant::Client` into unrelated tep code:

```
static mrb_int sp_Tep_WebSocket_Driver_cls_send_frame(sp_Qdrant_Client * lv_fd, ...)
static inline mrb_int sp_Tep_WebSocket_Driver_set_fd(..., sp_Qdrant_Client * lv_new_fd)
```

i.e. `Tep::WebSocket::Driver`'s `fd` got typed as `Qdrant::Client`. This
is the known spinel widening/dispatch fragility (same-named
methods/vars across unrelated classes collapse types). It makes dropping
arbitrary gem classes into a large tep program brittle.

## Reproduction

```
# in the dev container (host ruby lacks prism):
cc -O2 -c lib/tep/sphttp.c -o lib/tep/sphttp.o
./bin/tep build spike/qdrant/spike.rb -o /tmp/spike_bin   # fails; see compile-errors.txt
```

Files: `vendor/qdrant/*` (gem 0.9.10, verbatim), `qdrant_shim.rb`
(Faraday-shaped transport over `Tep::Http`; read path wired, body verbs
raise to mark the boundary), `spike.rb` (driver), `compile-errors.txt`.

## Recommendation

A "Qdrant battery" is worth having given tep's scope, but **build it
tep-native**, not by compiling this gem:

1. Add **TLS to `Tep::Http`** (or a `Tep::Https`) — a prerequisite for
   *any* cloud/SaaS battery, not just Qdrant. This is the highest-leverage
   piece.
2. Typed request builders for the handful of endpoints we want
   (create/upsert/search/query), emitting JSON via `Tep::Json` the way
   `Tep::PG` / the OpenAI server already do — using `qdrant-ruby`'s
   resource files as the **API-shape reference** (paths, params, body
   keys), which is precisely tep's "match the canonical gem" philosophy.
3. Keep resource classes in their own namespace but watch for the wall-#3
   name collisions; prefer distinctive internal names.

**Meta-finding for spinelgems:** "verified" via a VERSION-only smoke test
overstates usability for gems that (a) gate real code behind `autoload`
and (b) depend on Faraday/TLS or heterogeneous JSON. Worth a tag like
`loads-only` vs `exercised`.
