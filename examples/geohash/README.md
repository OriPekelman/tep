# geohash — using a real published gem from a tep app

This example demonstrates something tep couldn't do before: **compile and
run an app that depends on an unmodified, published Ruby gem.**

The gem is [`pr_geohash` 1.0.0](https://rubygems.org/gems/pr_geohash) (MIT),
a pure-Ruby geohash encoder. Its source is vendored verbatim at
[`vendor/pr_geohash.rb`](vendor/pr_geohash.rb) (original license header
intact) and pulled in the ordinary Ruby way:

```ruby
require_relative 'vendor/pr_geohash'
# ...
get '/geohash' do
  GeoHash.encode(params["lat"].to_f, params["lon"].to_f, 12)
end
```

## How it works

tep apps are ahead-of-time compiled by spinel — there is no runtime gem
loader. `bin/tep build` inlines **app-local `require_relative` targets**
straight into the generated program (the same mechanism it already used
for tep's own library), so the gem becomes native compiled code in the
binary. A plain `require "gem_name"` is still dropped — spinel has no gem
search path — so to use a gem you vendor its source and `require_relative`
it, as here.

## Run it

```sh
bin/tep build examples/geohash/app.rb -o /tmp/geohash
/tmp/geohash -p 4979 &
curl 'http://127.0.0.1:4979/geohash?lat=48.8584&lon=2.2945&precision=8'
# => u09tunqu   (identical to CRuby's GeoHash.encode)
```

`test/test_geohash_example.rb` builds this app and checks the output
matches CRuby byte-for-byte.

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
reach for unsupported stdlib corners don't. Pick the entry points that stay
inside the supported surface.

For an example where the gem's **entire** API compiles — no caveats — see
[`examples/maidenhead`](../maidenhead/README.md).
