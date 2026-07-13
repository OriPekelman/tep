# Mirror audit: the `sinatra` claim (sphttp-backed) — tep#234

Audit of tep's sphttp-backed surfaces against matz's three normative
mirror conditions (matz/spinel#1753: a package may claim a real gem's
require string only with (1) a ledgered-divergences exclusion list,
(2) the real gem as a differential oracle, (3) loud failure outside
the contract).

Audited 2026-07-09 at tep `696527a`, pin f6d5eef, spinel master
f9a81b1d for gate behavior.

## What sphttp actually backs — one mirror claim, two non-claims

| surface | require string claimed | mirror conditions apply? |
|---|---|---|
| Sinatra DSL (translator in `bin/tep`) | **`require "sinatra"`** (swallowed; the translator *is* the implementation; `class X < Sinatra::Base` modular form too) | **YES — this is the mirror** |
| `Tep::Http` | none — Faraday-*shaped* by design, but lives in tep's namespace | No (internal ledger only, see below) |
| `Sock` / `Tep::Server` / `Tep::WebSocket` | none — internal FFI plumbing + server | No |

So "the sphttp mirror audit" reduces to auditing the **sinatra claim**.
If tep publishes to spin-index claiming `sinatra`, the three conditions
bind; publishing under `tep` only (with sinatra-compat as a documented
feature) would relax the name-claim question but matz's "match CRuby or
refuse loudly" rule still applies to the compat surface we advertise.

## Condition 1 — ledgered divergences: PARTIAL

`SINATRA_COMPAT.md` is a **positive matrix** (~170 checklist tests, 6
real-world apps) — it says what works, not what is narrowed. The
exclusion ledger below inverts it. **The contract is exactly the
Phase A matrix of SINATRA_COMPAT.md**; everything not listed there is
out of contract. Known narrowings, from the doc's skip tables + the
translator's warn-inventory + code:

| real sinatra | tep behavior today | failure mode today |
|---|---|---|
| `use <Rack middleware>` | not supported | ⚠️ warn + **ignored** (app builds, middleware silently absent) |
| `helpers do ... end` | not supported (spinel closures) | ⚠️ warn + **ignored**; calls to dropped helpers then hit the compile gate (loud at post-1356cb14 pins, silent at f6d5eef) |
| Haml / Slim / builder / markdown templates | ERB + Mustache-subset only | no translator diagnostic; `haml :x` falls through to the unresolved-call gate |
| `stream do \|out\|` block form | `stream Klass.new` Streamer-subclass form only | translate-time drop (real_world/03) |
| `on_stop` / shutdown hooks | none | ⚠️ warn + ignored |
| `request.ip` / `remote_ip` | not implemented (needs peer-addr C helper) | unresolved at compile |
| multipart file-upload parts | text fields only, files skipped | silent narrowing (documented) |
| unknown `set :key` | recognized keys only | ⚠️ warn + ignored |
| splat `*` | last-segment only (sinatra spans segments: `/files/a/b` matches `/files/*` there, 404s here); splat *value* not exposed (sinatra: `params['splat']` array) | **oracle-pinned** (runner L5 `diverge:` assertion) |
| regex routes | ≤9 captures → `params["1".."9"]` (sinatra: `params['captures']` / block args); tep also accepts `^`/`$`-anchored regexes that sinatra's mustermann *rejects at boot* — anchor-free is the portable form | narrowing + anchor asymmetry, documented (runner L6) |
| sessions | signed-cookie store only | narrowing, documented |
| `params[k]` on a missing key | `""` (test_params pins it; the translator routes DSL reads through `Tep.param`) — sinatra reads nil | deliberate divergence, documented |
| `session[k]` on a missing key | `""` (test_sessions pins it; `Session#get` guards the miss) — sinatra reads nil | deliberate divergence, documented |
| `cookies[k]` on a missing cookie | `""` (test_cookies pins it; DSL reads route through `Tep.cookie`) — sinatra-contrib reads nil | deliberate divergence, documented |
| `error do ... end` blocks, route conditions (`provides:`, `agent:`), `register`/extensions | not claimed | mostly unresolved at compile; not individually diagnosed |
| unrecognized top-level calls | — | ⚠️ warn + **ignored** |

(⚠️ = one of the translator's nine warn-and-continue paths; inventory:
`bin/tep` lines ~1209–1448.)

**Gap:** the ledger above needs to live as the normative artifact (this
file), kept in sync with SINATRA_COMPAT.md's matrix; the matrix cites
tests, the ledger cites narrowings.

## Condition 2 — real gem as oracle: PARTIAL (harness live, coverage growing)

Current verification is **hand-derived, not differential**: the ~170
checklist expectations were written from sinatra's documented behavior,
and the Phase B real-world apps (sinatra's own `examples/simple.rb`,
`lifecycle_events.rb`, three GitHub apps, three synthesized) are
smoke-tested through `Net::HTTP` against **tep only**. `test/helper.rb
spawn_app(mode: :sinatra)` means "build via the tep translator" — real
sinatra is never spawned, responses are never diffed.

Bright spot: `Tep::Jwt` already does exactly what matz asks — an interop
test verifying tokens against the canonical `jwt` gem. That's the
pattern to replicate.

**Remediation — SHIPPED (harness + CI job), coverage growing:**
`test/differential/runner.rb` boots each fixture app twice — CRuby +
the real sinatra gem vs the tep-compiled binary — replays the same
requests and diffs status / body / content-type / redirect Location /
declared headers. Unledgered divergences fail; accepted ones are
normalized away with a lettered reason recorded in the runner (L1
sinatra's `;charset=utf-8` suffix, L2 rack-protection default headers,
L3 transport furniture, L4 Location absolutization) that must also
live here. Its own Gemfile keeps sinatra out of tep's dependency
graph; CI runs it as the `differential` job. Coverage today (5 apps,
107 assertions): real_world 01/04/05 + two purpose-built fixtures —
`10_semantics.rb` (params, query, form, redirect ×2, halt, custom
status, custom header, content_type, url-decode, not_found) and
`11_matrix.rb` (PUT/PATCH, splat, regex route, after-filter header
mutation, `%xx`/`+` query decoding, multipart text fields, bare
halt). The harness also supports **executable ledger pins**: a
request marked `diverge:` asserts the two servers *disagree* as
documented (splat multi-segment, L5) — if the divergence ever heals,
the assertion flips and the ledger entry gets cleaned up. Extend
toward the full checklist over time.

**First fruits of the oracle:**
- tep omitted the default `Content-Type` on empty-body responses
  (redirects!) where sinatra/Rack emit `text/html` — **fixed** in both
  servers, with 204/304 excepted (Rack strips entity headers there).
- real_world/06 uses `request.headers["x-token"]`, which is **not
  valid sinatra** — `request.headers` is a tep extension (sinatra
  spells it `request.env["HTTP_..."]`). 06 is excluded from the oracle
  set; the extension joins the ledger: code written against it is
  tep-only, not sinatra-portable.

## Condition 3 — loud failure outside the contract: FAIL today

Two regimes:

- **Translator level: warn-and-continue** on all nine out-of-contract
  paths above — the app builds and runs *minus* the dropped semantics.
  This is precisely the "silent divergence" condition 3 forbids (a
  printed warning that doesn't stop a build is not "fails visibly" —
  nothing downstream distinguishes the degraded binary).
- **Compile level: loud since matz/spinel 1356cb14** — anything that
  survives translation as an unresolved call (haml, dropped-helper
  invocations, `request.ip`) now raises NoMethodError / fails the gate.
  This half is already mirror-grade at spin-era pins.

**Remediation — SHIPPED:** the translator is strict by default: any
would-be-dropped construct fails the build with an error naming this
document, and `tep build --lax` (or `TEP_LAX=1`) restores
warn-and-continue. All `warnings <<` sites route through one emission
point in `translate`, so the switch covers every drop path, not just
the nine cataloged ones. `test/test_unsupported.rb` asserts the
refusals (`use`, `helpers`, unknown `set`, `on_stop`) and the `--lax`
downgrade.

## Non-claims, for completeness

- **`Tep::Http`** keeps its own name; its header ledger ("HTTP/1.0,
  no chunked reads, no redirects, no streaming") is accurate except
  the *"HTTP only — no TLS"* line, which is stale — outbound https
  landed in #150 (`sphttp_connect_tls`), inbound TLS in #148/#159.
  Fixed alongside this audit.
- **`pg` / `sqlite3`** claims are audited separately (see #234; the
  consume-vs-publish question vs rubys' `spinel-pg` comes first —
  first accepted publish reserves the name).

## Verdict

| condition | state | remediation |
|---|---|---|
| 1 — exclusion ledger | PARTIAL (positive matrix exists; this file is the inverted ledger) | keep this file normative, sync with SINATRA_COMPAT.md |
| 2 — real-gem oracle | PARTIAL — differential harness + CI job live (4 fixture apps, 75 assertions); checklist coverage still growing | extend fixtures toward the full Phase A matrix |
| 3 — loud failure | **PASS** — translator strict by default (`--lax` opt-out); compile gate loud post-1356cb14 | shipped |

Publishing a `sinatra` claim to spin-index: conditions 1 and 2 are both
PARTIAL — the machinery exists and is normative, the remaining work is
coverage (more checklist surface through the oracle, ledger kept in
lockstep). Judgment call for when coverage is "enough" to publish; the
oracle already caught one real parity bug and one invalid fixture on
its first run, which is the mechanism working as designed.
