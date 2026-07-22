# In-memory todo list. Exercises GET / POST / DELETE, path params,
# top-level mutable state, and JSON responses.
require 'sinatra'

# Two parallel arrays as the store. Spinel won't let us push procs
# into a hash, but plain typed arrays are first-class. Seed-and-clear
# so spinel infers the element type (`[]` defaults to int_array).
$todos_id   = [0]
$todos_id.delete_at(0)
$todos_text = [""]
$todos_text.delete_at(0)
$next_id    = 1

before do
  content_type 'application/json'
end

get '/todos' do
  out = '['
  i = 0
  while i < $todos_id.length
    out += '{"id":' + $todos_id[i].to_s + ',"text":"' + $todos_text[i] + '"}'
    out += ',' if i + 1 < $todos_id.length
    i += 1
  end
  out + ']'
end

post '/todos' do
  text = params[:text]
  $todos_id.push($next_id)
  $todos_text.push(text)
  $next_id += 1
  '{"id":' + ($next_id - 1).to_s + ',"text":"' + text + '"}'
end

delete '/todos/:id' do
  target = params[:id].to_i
  i = 0
  found = false
  while i < $todos_id.length
    if $todos_id[i] == target
      $todos_id.delete_at(i)
      $todos_text.delete_at(i)
      found = true
      i = $todos_id.length
    else
      i += 1
    end
  end
  if found
    '{"deleted":' + target.to_s + '}'
  else
    status 404
    '{"error":"not found"}'
  end
end
