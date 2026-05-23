# Counter -- minimal Tep::LiveView demo using Tep.live auto-wiring.
#
# A single shared integer counter. Every open browser is subscribed
# to the same topic; clicking + / - / reset mutates the shared
# state and broadcasts the re-rendered HTML to every subscriber.
# All connections see the new value in <100ms with no polling and
# no full-page reload.
#
# Run:
#   bin/tep build examples/counter/app.rb -o /tmp/counter
#   /tmp/counter -p 4567
# Open http://127.0.0.1:4567/counter in two browsers and click +.
require 'sinatra'

set :scheduler, :scheduled

# Single-element typed array as a shared int slot. (Spinel doesn't
# track module-level `@@cvar` writes reliably across method calls;
# an Array[Integer] gives us a typed shared slot that survives
# request boundaries.)
COUNTER = [0]

class CounterView < Tep::LiveView
  # Topic binds every connected viewer to the same broadcast stream.
  # On every event, broadcast_render fans the updated HTML out to
  # all subscribers (each WS on this topic).
  def topic
    "counter:shared"
  end

  def render
    "<div id='tep-live-root' class='counter'>" +
      "<h1>shared counter</h1>" +
      "<p class='value'>" + COUNTER[0].to_s + "</p>" +
      "<div class='controls'>" +
        "<button data-event='dec'>&minus;</button>" +
        "<button data-event='inc'>+</button>" +
      "</div>" +
      "<button class='reset' data-event='reset'>reset</button>" +
      "<p class='hint'>open this page in another tab to see live updates.</p>" +
    "</div>" +
    "<style>" + counter_css + "</style>"
  end

  def handle_event(event, payload, req)
    if event == "inc"
      COUNTER[0] = COUNTER[0] + 1
      broadcast_render
    elsif event == "dec"
      COUNTER[0] = COUNTER[0] - 1
      broadcast_render
    elsif event == "reset"
      COUNTER[0] = 0
      broadcast_render
    end
    0
  end
end

def counter_css
  "body{margin:0;font:14px/1.4 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;" +
    "background:#f6f7f9;color:#1a1a1a;" +
    "display:flex;justify-content:center;align-items:center;min-height:100vh}" +
  ".counter{background:#fff;padding:2rem 3rem;border-radius:8px;" +
    "box-shadow:0 1px 4px rgba(0,0,0,.06);text-align:center;min-width:300px}" +
  ".counter h1{margin:0 0 1rem;font-size:.85rem;text-transform:uppercase;" +
    "letter-spacing:.1em;color:#666;font-weight:600}" +
  ".counter .value{margin:0 0 1.5rem;font-size:4rem;font-weight:700;" +
    "font-variant-numeric:tabular-nums;color:#1a1a1a}" +
  ".counter .controls{display:flex;gap:.5rem;justify-content:center;margin-bottom:1rem}" +
  ".counter button{padding:.6rem 1.4rem;border:1px solid #d0d3d8;background:#fafbfc;" +
    "color:#1a1a1a;border-radius:4px;font:inherit;font-size:1.2rem;cursor:pointer}" +
  ".counter button:hover{background:#1a1a1a;color:#fff;border-color:#1a1a1a}" +
  ".counter button.reset{font-size:.8rem;padding:.3rem .8rem;color:#888;background:transparent}" +
  ".counter button.reset:hover{background:#f0f1f3;color:#1a1a1a;border-color:#d0d3d8}" +
  ".counter .hint{margin:1rem 0 0;font-size:.75rem;color:#888;font-style:italic}"
end

Tep.live "/counter", CounterView

get '/' do
  res.set_status(302)
  res.headers["Location"] = "/counter"
  ""
end
