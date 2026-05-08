# Sinatra-classic style. Compile with `bin/tep build sinatra_style.rb`.
# This file is NOT meant to be passed to spinel directly -- the translator
# rewrites the do/end blocks into Tep::Handler subclasses first.
require 'sinatra'   # ignored by translator; documentation-only

set :public_dir, '../public'

get '/' do
  "<h1>hello, world</h1>" +
  "<p>This is real Sinatra-style source compiled by spinel via tep.</p>"
end

get '/hi/:name' do
  "<p>hi, " + params[:name] + "!</p>"
end

get '/about' do
  content_type 'text/plain'
  "served as plain text\n"
end

get '/old' do
  redirect '/'
end

before do
  puts "[" + request.verb + "] " + request.path
end

not_found do
  "<h1>oops -- " + request.path + " not here</h1>"
end
