# geohash — using a real published gem from a tep app (via a Gemfile)

This example demonstrates something tep couldn't do before: **compile and
run an app that depends on a published Ruby gem, declared in a `Gemfile`.**

The gem is [`pr_geohash` 1.0.0](https://rubygems.org/gems/pr_geohash) (MIT),
a pure-Ruby geohash encoder. It's declared in [`Gemfile`](Gemfile) and
resolved by [`bundler-spinel`](https://github.com/OriPekelman/spinelgems)
(`spinel-compat vendor`) — not hand-vendored.

```ruby
require_relative 'vendor/spinel/deps'   # generated from Gemfile.lock
# ...
get '/geohash' do
  GeoHash.encode(params["lat"].to_f, params["lon"].to_f, 12)
end
```

## How it works (the spinelgems convention)

tep apps are AOT-compiled by spinel — no runtime gem loader, no gem load
path. `spinel-compat vendor` reads `Gemfile.lock`, places each gem under
`vendor/spinel/<name>/`, and writes `vendor/spinel/deps.rb` (a
`require_relative` per gem). The app pulls them in with one
`require_relative "vendor/spinel/deps"`, and `bin/tep build` inlines that
chain recursively into the binary. `Gemfile`/`Gemfile.lock` are committed;
`vendor/spinel/` is generated (gitignored).

## Build + run

```sh
make vendor-examples           # spinel-compat vendor -> vendor/spinel/ (needs ../spinelgems)
bin/tep build examples/geohash/app.rb -o /tmp/geohash
/tmp/geohash -p 4979 &
curl 'http://127.0.0.1:4979/geohash?lat=48.8584&lon=2.2945&precision=8'
# => u09tunqu   (identical to CRuby's GeoHash.encode)
```

`test/test_geohash_example.rb` vendors, builds this app, and checks the
output matches CRuby byte-for-byte.

## What works, what doesn't (gem reuse is per-method)

`GeoHash.encode` compiles and runs cleanly — it uses only `map`, `join`,
integer bit-ops and Float comparisons, all of which spinel supports.

`GeoHash.neighbors` and `GeoHash.decode` are deliberately **not** exposed:
they rely on `Array#flatten` (on a string-element array) / `Array#transpose`,
which spinel doesn't compile yet — tracked upstream as
[matz/spinel#1078](https://github.com/matz/spinel/issues/1078) (flatten is
specialized for int-element arrays only) and
[matz/spinel#1079](https://github.com/matz/spinel/issues/1079) (transpose
missing). That's the honest shape of gem reuse under tep today: the hot
path of a well-behaved pure-Ruby gem drops straight in, while methods that
reach for unsupported stdlib corners don't.

For an example where the gem's **entire** API compiles — no caveats — see
[`examples/maidenhead`](../maidenhead/README.md).
