require 'sinatra'

# A tep app built entirely on a REAL, unmodified published Ruby gem --
# maidenhead 1.0.1 (MIT), the ham-radio Maidenhead grid-locator <-> lat/lon
# converter. Vendored verbatim at vendor/maidenhead.rb (license at
# vendor/LICENSE.txt) and pulled in with require_relative, which bin/tep
# inlines into the AOT binary. Unlike the geohash example, EVERY route
# here exercises the gem and the whole public API compiles -- there is no
# unsupported-method caveat. See README.md.
require_relative 'vendor/maidenhead'

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
