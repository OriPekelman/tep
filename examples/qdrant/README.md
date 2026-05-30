# qdrant — the rejected end of the spectrum (a spinelgems gate experiment)

This directory has **no app** — on purpose. It's the counterpart to the
`geohash` and `maidenhead` examples: a real, useful gem
([`qdrant-ruby`](https://rubygems.org/gems/qdrant-ruby)) that **cannot** be
used from a tep app today, declared in a [`Gemfile`](Gemfile) precisely so
the spinelgems compatibility **gate** can tell us *why*. Running gems
through spinelgems is the point; a clean "no" with reasons is a useful
result.

## The gate verdict

```sh
bundle lock
SPINEL_DIR=/spinel ruby -I $SPINELGEMS/lib $SPINELGEMS/exe/spinel-compat check Gemfile.lock
```

```
✗ faraday           2.14.2   rejected  — hard:Mutex.new
✗ faraday-net_http  3.4.3    rejected  — no-entrypoint
✗ json              2.19.7   rejected  — c-extension
✗ logger            1.7.0    rejected  — unresolved:instance_method, …
✗ net-http          0.9.1    rejected  — no-entrypoint
✓ qdrant-ruby       0.9.10   clean
✗ uri               1.1.1    rejected  — unresolved:…
```

The gem's *own* source is `clean` — but it's unusable, because its entire
transitive transport stack is rejected:

- **faraday** uses `Mutex.new`, which spinel doesn't support (`hard:`).
- **json** is a C-extension gem (spinel provides its own `JSON`, but the
  gem's native build can't be compiled in).
- **net-http / faraday-net_http** have no spinel entrypoint.
- **uri / logger** lean on dozens of unresolved stdlib methods.

So unlike `geohash` (gem reuse is per-*method*), qdrant fails at the
*dependency* level: there's no subset of entry points that avoids Faraday.

## What we proved separately

Even bypassing the gem (raw `Tep::Http` + `JSON.generate`), the Qdrant
*write* path is blocked by a spinel codegen gap: request bodies are built
as incrementally-mutated **heterogeneous** hashes (`h["a"]=1; h["b"]="x"`),
which spinel types homogeneously and fails to compile. A tep-native client
that builds bodies as *literals* does round-trip against Qdrant Cloud over
TLS — but that's not "using the gem". See the project memory notes.

## Why this is here

A gem catalog is only trustworthy if the "no"s are as legible as the
"yes"es. `geohash` + `maidenhead` show what works; `qdrant` shows the gate
catching what doesn't, with actionable reasons. All three go through the
same Gemfile + `spinel-compat` path.
