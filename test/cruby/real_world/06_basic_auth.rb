# Before-filter auth: every /admin/* request must carry a token. Tests
# the halt-from-before-filter pattern.
require 'sinatra'

TOKEN = 'sekret-42'

before do
  if request.path.start_with?('/admin')
    if request.headers['x-token'] != TOKEN
      halt 401, 'forbidden'
    end
  end
end

get '/' do
  'public homepage'
end

get '/admin/dashboard' do
  'admin: ok'
end

get '/admin/users' do
  'admin: users'
end
