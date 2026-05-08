require 'sinatra'

set :bind, '127.0.0.1'
set :port, 4570
set :logging, false
set :show_exceptions, false
disable :protection

get '/' do
  content_type 'text/plain'
  "hello, world\n"
end
