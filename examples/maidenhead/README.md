# maidenhead — a tep app that *fully* runs on an external gem

This app is built entirely on a real, unmodified published Ruby gem:
[`maidenhead` 1.0.1](https://rubygems.org/gems/maidenhead) (MIT), the
ham-radio [Maidenhead Locator System](https://en.wikipedia.org/wiki/Maidenhead_Locator_System)
converter. The source is vendored verbatim at
[`vendor/maidenhead.rb`](vendor/maidenhead.rb) (license at
[`vendor/LICENSE.txt`](vendor/LICENSE.txt)) and pulled in with
`require_relative`, which `bin/tep build` inlines into the AOT binary.

**Every route exercises the gem, and the entire public API compiles** —
there is no unsupported-method caveat (contrast the sibling `geohash`
example, where the gem's hot path works but two helpers need spinel
features that aren't there yet).

```ruby
require_relative 'vendor/maidenhead'

get '/valid'     { Maidenhead.valid_maidenhead?(params["loc"]) ... }
get '/to_latlon' { Maidenhead.to_latlon(params["loc"]) ... }
get '/to_grid'   { Maidenhead.to_maidenhead(lat, lon, precision) }
```

## Run it

```sh
bin/tep build examples/maidenhead/app.rb -o /tmp/maidenhead
/tmp/maidenhead -p 4981 &

curl 'http://127.0.0.1:4981/valid?loc=FN31pr'                          # => true
curl 'http://127.0.0.1:4981/to_latlon?loc=FN31pr'                      # => 41.731076,-72.704514
curl 'http://127.0.0.1:4981/to_grid?lat=40.7128&lon=-74.0060&precision=3'  # => FN20xr
```

Each result is identical to CRuby's `Maidenhead.*`.
`test/test_maidenhead_example.rb` builds this app and checks every route
against CRuby's output.

## How a tep app uses a gem

tep apps are ahead-of-time compiled by spinel — there is no runtime gem
loader. `bin/tep build` inlines app-local `require_relative` targets into
the generated program, so the gem becomes native compiled code. A plain
`require "gem_name"` is dropped (spinel has no gem search path), so the
pattern is: vendor the gem source, `require_relative` it.
