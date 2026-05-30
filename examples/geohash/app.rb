require 'sinatra'

# Use a REAL published Ruby gem -- pr_geohash 1.0.0 (MIT) -- from a tep
# app, declared in a Gemfile and resolved by `spinel-compat vendor`
# (bundler-spinel, ../spinelgems) into vendor/spinel/. The one require
# below pulls in the generated deps.rb chain; bin/tep inlines it into the
# AOT binary. Run `make vendor` (or see README.md) before building.
require_relative 'vendor/spinel/deps'

# GET /geohash?lat=..&lon=..&precision=..
# Encodes a latitude/longitude into a geohash using GeoHash.encode from
# the gem. Query params (not path segments) so the '-' and '.' in real
# coordinates don't need escaping.
get '/geohash' do
  lat  = params["lat"].to_f
  lon  = params["lon"].to_f
  prec = params["precision"].to_i
  if prec <= 0
    prec = 12
  end
  GeoHash.encode(lat, lon, prec)
end

# NOTE: GeoHash.neighbors / GeoHash.decode are intentionally NOT exposed.
# They lean on Array#flatten / Array#transpose, which spinel doesn't
# compile yet (encode uses only map/join/bit-ops and works fine). A good
# illustration that gem reuse is per-method: the hot path compiles, a
# couple of helpers don't -- see README.md.

get '/' do
  "tep + pr_geohash 1.0.0 (a real, unmodified published gem)\n" +
  "try: /geohash?lat=48.8584&lon=2.2945&precision=8\n"
end
