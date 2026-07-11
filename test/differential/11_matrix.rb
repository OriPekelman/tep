# Differential fixture: broader Phase A matrix coverage. Valid under
# BOTH real sinatra and tep (docs/mirrors/sinatra.md condition 2).
# Divergent read-APIs (splat value, regex captures, cookies DSL) are
# deliberately NOT read here -- routes only exercise surface both
# dialects share; the known divergences are pinned by the runner's
# ledgered-divergence assertions instead.
require 'sinatra'

put '/verb' do
  'put-ok'
end

patch '/verb' do
  'patch-ok'
end

# Splat: single-segment matches in both dialects. The VALUE is not
# read (sinatra: params['splat'] array; tep: no exposed value) and
# multi-segment matching diverges -- see runner ledger L5.
get '/files/*' do
  'file-route'
end

# Regex route, no capture reads (sinatra: params['captures']; tep:
# params["1"] -- runner ledger L6). Unanchored on purpose: sinatra's
# mustermann raises at boot on ^/$ anchors (it anchors implicitly),
# while tep accepts them -- anchored regex routes are tep-only (L6).
get %r{/rx/\d+} do
  'rx-route'
end

# after-filter mutating a response header; both dialects claim it.
after do
  headers['x-after'] = 'ran'
end

get '/afterhdr' do
  'body'
end

# Query-string URL decoding: %xx and `+` as space.
get '/dec' do
  v = params[:v]
  v = '' if v.nil?
  'v=[' + v + ']'
end

# Multipart/form-data: text fields merge into params in both dialects
# (file parts are tep-ledgered as skipped; not exercised here).
post '/mp' do
  f = params[:field]
  f = '' if f.nil?
  'field=[' + f + ']'
end

# Bare halt (status only, empty body).
get '/gone' do
  halt 410
end

not_found do
  'nf: ' + request.path
end
