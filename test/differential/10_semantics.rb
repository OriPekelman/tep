# Differential fixture: core routing/response semantics that both real
# sinatra and tep claim. This file must stay valid under BOTH dialects
# (docs/mirrors/sinatra.md condition 2) -- no tep extensions
# (request.headers, cookies[], set_cookie) and no sinatra-contrib.
require 'sinatra'

get '/hi/:name' do
  'hi ' + params[:name]
end

get '/two/:a/:b' do
  params[:a] + '-' + params[:b]
end

get '/q' do
  q = params[:q]
  q = '' if q.nil?
  'q=' + q
end

post '/form' do
  t = params[:text]
  t = '' if t.nil?
  'text=' + t
end

get '/redir' do
  redirect '/hi/there'
end

get '/redir301' do
  redirect '/hi/there', 301
end

get '/teapot' do
  status 418
  'short and stout'
end

get '/halted' do
  halt 401, 'no entry'
end

get '/hdr' do
  headers['x-custom'] = 'yes'
  'ok'
end

get '/ct' do
  content_type 'text/plain'
  'plain body'
end

not_found do
  'nope: ' + request.path
end
