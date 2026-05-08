# Common pattern: tiny health/version JSON API. Exercises content_type,
# multiple routes, no params, no body parsing.
require 'sinatra'

VERSION = '1.4.2'

before do
  content_type 'application/json'
end

get '/healthz' do
  '{"status":"ok"}'
end

get '/version' do
  '{"version":"' + VERSION + '"}'
end

get '/' do
  '{"endpoints":["/healthz","/version"]}'
end

not_found do
  '{"error":"not found","path":"' + request.path + '"}'
end
