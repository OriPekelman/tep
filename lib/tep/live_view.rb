# Tep::LiveView -- Phoenix.LiveView-shape server-rendered stateful
# UI over WebSocket. Battery 4 in docs/BATTERIES-DESIGN.md.
#
# v1 (chunk 4.1) ships the bones: the base class apps subclass + a
# pair of cmeths (render_page / dispatch_event) for the manual
# wiring path. Auto-wiring (Tep.live "/path", CounterView), the
# handle_broadcast hook, and presence-diff bindings land in 4.2 /
# 4.3 -- they need either translator changes or the Scheduled
# server to be reliable upstream (matz/spinel#641).
#
# Usage (chunk 4.1):
#
#   class CounterView < Tep::LiveView
#     def initialize
#       super
#       @count = 0
#     end
#
#     def render
#       "<div id='tep-live-root'>Count: " + @count.to_s + "</div>"
#     end
#
#     def handle_event(event, payload, req)
#       if event == "inc"
#         @count += 1
#       end
#       0
#     end
#   end
#
#   # Initial HTML: GET serves the rendered view wrapped in a
#   # bootstrap shell that opens a WS to /counter_live + applies
#   # incoming HTML to the #tep-live-root element.
#   get "/counter" do
#     v = CounterView.new
#     v.mount(req)
#     Tep::LiveView.render_page(v.render, "/counter_live")
#   end
#
#   # WS handler -- per-connection view instance, event dispatch,
#   # re-render + send on every event.
#   websocket "/counter_live" do |ws|
#     v = CounterView.new
#     on_open do |evt|
#       v.mount_via_ws
#       ws.text(v.render)
#     end
#     on_message do |evt|
#       Tep::LiveView.dispatch_event(v, evt.data, req)
#       ws.text(v.render)
#     end
#   end
#
# Why the manual wiring shape: tep's bin/tep translator lowers the
# `websocket` DSL into a generated route + per-event handler
# subclasses, and the user-supplied block bodies are subject to
# spinel's closure-capture limits. Wrapping the LiveView in the
# block is the spinel-friendly path; auto-wire helpers can lean on
# the translator in 4.2.
module Tep
  class LiveView
    def initialize
      0
    end

    # Called when the view boots -- once on the initial HTTP GET,
    # once on WS open. Subclasses override to seed @ivars from
    # req.params / req.identity / etc.
    def mount(req)
      0
    end

    # Render the view's current state to HTML. Subclasses override.
    # Wrap your real content in an element with `id="tep-live-root"`
    # so the client-side bootstrap can swap the innerHTML cleanly.
    def render
      "<div id='tep-live-root'></div>"
    end

    # Receive an event from the client. `event` and `payload` are
    # strings (the client-side JS sends them as JSON). Subclasses
    # mutate @ivars based on the event; the caller re-renders +
    # sends the new HTML.
    def handle_event(event, payload, req)
      0
    end

    # Imeth bridge from the WS-side JSON wire format to the
    # subclass's `handle_event`. Apps call this from their
    # on_message block:
    #
    #   on_message do |evt|
    #     v.dispatch_event_json(evt.data, req)
    #     ws.text(v.render)
    #   end
    #
    # Why an imeth and not a cmeth: spinel widens cmeth params
    # to poly (sp_RbVal) when the cmeth has callers across
    # multiple LiveView subclasses, but doesn't auto-box concrete
    # subclass pointers into the poly slot at the call site. An
    # imeth on the base class dispatches through the typed slot
    # of the subclass instance and avoids the box.
    def dispatch_event_json(json_msg, req)
      event   = Tep::Json.get_str(json_msg, "event")
      payload = Tep::Json.get_str(json_msg, "payload")
      handle_event(event, payload, req)
      0
    end

    # ---- helpers (cmeths so apps reach for them without a view
    #      instance in scope) ----

    # Wrap `content_html` in a full HTML page with the client-side
    # bootstrap. The JS:
    #
    #   1. Opens a WS to `ws_path`.
    #   2. On each incoming text frame: parses as HTML and assigns
    #      to #tep-live-root's innerHTML.
    #   3. Intercepts clicks on anything with [data-event] and
    #      sends `{"event": <name>, "payload": <data-payload or "">}`
    #      over the WS.
    #
    # That's all the client-side surface for v1. No morphdom, no
    # form-data shipping, no key bindings -- "click + re-render"
    # is enough to demonstrate the pattern. Future chunks can swap
    # in morphdom for diff-on-client.
    def self.render_page(content_html, ws_path)
      "<!doctype html>\n<html><head><meta charset='utf-8'></head><body>\n" +
        content_html + "\n" +
        "<script>(function(){\n" +
        "var ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'" + ws_path + "');\n" +
        "ws.onmessage=function(e){var r=document.getElementById('tep-live-root');if(r){r.outerHTML=e.data;}};\n" +
        "document.addEventListener('click',function(e){\n" +
        "  var t=e.target;while(t&&!t.dataset.event){t=t.parentElement;}\n" +
        "  if(!t)return;\n" +
        "  e.preventDefault();\n" +
        "  ws.send(JSON.stringify({event:t.dataset.event,payload:t.dataset.payload||''}));\n" +
        "});\n" +
        "})();</script>\n" +
        "</body></html>\n"
    end

  end
end
