# maidenhead — a tep app that *fully* runs on an external gem (via a Gemfile)

This app is built entirely on a real published Ruby gem:
[`maidenhead` 1.0.1](https://rubygems.org/gems/maidenhead) (MIT), the
ham-radio [Maidenhead Locator System](https://en.wikipedia.org/wiki/Maidenhead_Locator_System)
converter. It is **declared in a `Gemfile`** and resolved the proper way —
not hand-vendored.

**Every route exercises the gem, and the entire public API compiles** —
there is no unsupported-method caveat (contrast the sibling `geohash`
example, where the gem's hot path works but two helpers need spinel
features that aren't there yet).

## How a tep app uses a gem (the spinelgems convention)

tep apps are ahead-of-time compiled by spinel — there is no runtime gem
loader, and spinel has no gem load path. The
[`bundler-spinel`](https://github.com/OriPekelman/spinelgems) plugin
(`spinel-compat`) bridges that: it reads a `Gemfile.lock`, places each
gem's source under `vendor/spinel/<name>/`, and generates
`vendor/spinel/deps.rb` (a `require_relative` per gem, in lock order). The
app pulls everything in with one line:

```ruby
require_relative 'vendor/spinel/deps'
```

`bin/tep build` inlines that `require_relative` **recursively** (deps.rb
chains to each gem), so the gems become native compiled code in the
binary. The `Gemfile` + `Gemfile.lock` are the source of truth and are
committed; `vendor/spinel/` is generated and gitignored.

## Build + run

```sh
make vendor-examples           # spinel-compat vendor -> vendor/spinel/ (needs ../spinelgems)
bin/tep build examples/maidenhead/app.rb -o /tmp/maidenhead
/tmp/maidenhead -p 4981 &

curl 'http://127.0.0.1:4981/valid?loc=FN31pr'                              # => true
curl 'http://127.0.0.1:4981/to_latlon?loc=FN31pr'                          # => 41.731076,-72.704514
curl 'http://127.0.0.1:4981/to_grid?lat=40.7128&lon=-74.0060&precision=3'  # => FN20xr
```

Each result is identical to CRuby's `Maidenhead.*`.
`test/test_maidenhead_example.rb` runs the vendor step, builds this app,
and checks every route against CRuby's output.
