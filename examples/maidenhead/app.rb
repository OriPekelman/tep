require 'sinatra'

# A tep app built entirely on a REAL published Ruby gem -- maidenhead
# 1.0.1 (MIT), the ham-radio grid-locator <-> lat/lon converter --
# declared in a Gemfile and resolved the proper way: `spinel-compat
# vendor` (bundler-spinel, from ../spinelgems) reads Gemfile.lock and
# places the gem under vendor/spinel/ with a generated deps.rb. We pull
# it in with the ONE require below; bin/tep inlines the require_relative
# chain into the AOT binary. Nothing here is hand-vendored. Run
# `make vendor` (or see README.md) before building. Unlike the geohash
# example, EVERY route exercises the gem and the whole public API
# compiles -- no unsupported-method caveat.
require_relative 'vendor/spinel/deps'

# GET /valid?loc=FN31pr  -> "true" / "false"
get '/valid' do
  if Maidenhead.valid_maidenhead?(params["loc"])
    "true"
  else
    "false"
  end
end

# GET /to_latlon?loc=FN31pr  -> "41.731076,-72.704514"
get '/to_latlon' do
  r = Maidenhead.to_latlon(params["loc"])
  r[0].to_s + "," + r[1].to_s
end

# GET /to_grid?lat=40.7128&lon=-74.0060&precision=3  -> "FN20xr"
get '/to_grid' do
  lat  = params["lat"].to_f
  lon  = params["lon"].to_f
  prec = params["precision"].to_i
  if prec <= 0
    prec = 5
  end
  Maidenhead.to_maidenhead(lat, lon, prec)
end

get '/' do
  "tep + maidenhead 1.0.1 (a real, unmodified published gem)\n" +
  "try: /valid?loc=FN31pr\n" +
  "     /to_latlon?loc=FN31pr\n" +
  "     /to_grid?lat=40.7128&lon=-74.0060&precision=3\n"
end
