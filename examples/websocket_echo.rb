# Tep WebSocket echo demo.
#
# Walks the Sinatra-shaped DSL hook the bin/tep translator lowers
# into a generated upgrade route + per-event Tep::WebSocket::Handler
# subclasses. WS support requires the scheduled server (the recv
# loop parks on Tep::Scheduler.io_wait), so we opt in via
# `set :scheduler, :scheduled`.
#
# Try it:
#   ./examples/websocket_echo -p 4567
#   # then from a separate terminal:
#   websocat ws://127.0.0.1:4567/echo
#   > hello
#   < echo: hello
require_relative "../lib/tep"

set :scheduler, :scheduled

get "/" do
  "<!doctype html><html><body>" +
    "<p>WebSocket echo server. Connect to <code>ws://host:port/echo</code>.</p>" +
    "</body></html>"
end

websocket "/echo" do |ws|
  on_open do |evt|
    ws.text("welcome")
  end

  on_message do |evt|
    ws.text("echo: " + evt.data)
  end

  on_close do |evt|
    # No-op; placeholder for the user's cleanup path.
  end
end
