require_relative "helper"

# Tep::LiveView base class + helpers (Battery 4 chunk 4.1).
# v1 ships the manual-wiring path: a base class apps subclass +
# the render_page / dispatch_event cmeths. Auto-wiring lands in
# 4.2; these tests cover the building blocks.
class TestLiveView < TepTest
  app_source <<~RB
    require 'sinatra'

    # A counter view: state is an integer; "inc" increments,
    # "dec" decrements, "reset" zeroes.
    class CounterView < Tep::LiveView
      attr_accessor :count
      def initialize
        super
        @count = 0
      end
      def mount(req)
        # Pull a seed value from the request's params if present;
        # otherwise leave at 0. A missing param reads as nil
        # (sinatra-parity) -- guard before String calls.
        seed = req.params["seed"]
        seed = "" if seed.nil?
        if seed.length > 0
          @count = seed.to_i
        end
        0
      end
      def render
        "<div id='tep-live-root'>Count: " + @count.to_s + "</div>"
      end
      def handle_event(event, payload, req)
        if event == "inc"
          @count += 1
        elsif event == "dec"
          @count -= 1
        elsif event == "reset"
          @count = 0
        end
        0
      end
    end

    # Per-request scratchpad: the test app boots once, but we
    # need a fresh view per request so tests don't pollute each
    # other. The handler routes below construct a view, run the
    # operation, return the result; no cross-request state.

    before do
      res.headers["Content-Type"] = "text/plain"
    end

    get '/initial_render' do
      v = CounterView.new
      v.mount(req)
      v.render
    end

    get '/render_page' do
      Tep::LiveView.render_page("<p>hi</p>", "/_live")
    end

    get '/event_inc' do
      v = CounterView.new
      v.mount(req)
      v.dispatch_event_json("{\\"event\\":\\"inc\\",\\"payload\\":\\"\\"}", req)
      v.render
    end

    get '/event_chain' do
      # Multiple events through the same view to verify state
      # carries forward.
      v = CounterView.new
      v.mount(req)
      v.dispatch_event_json("{\\"event\\":\\"inc\\",\\"payload\\":\\"\\"}", req)
      v.dispatch_event_json("{\\"event\\":\\"inc\\",\\"payload\\":\\"\\"}", req)
      v.dispatch_event_json("{\\"event\\":\\"inc\\",\\"payload\\":\\"\\"}", req)
      v.dispatch_event_json("{\\"event\\":\\"dec\\",\\"payload\\":\\"\\"}", req)
      v.render
    end

    get '/event_unknown' do
      v = CounterView.new
      v.mount(req)
      v.dispatch_event_json("{\\"event\\":\\"never\\",\\"payload\\":\\"\\"}", req)
      v.render
    end

    get '/base_class_render' do
      # The Tep::LiveView base class's default render is a noop
      # shell -- subclasses are expected to override.
      Tep::LiveView.new.render
    end

    # ---- chunk 4.2: broadcast binding ----

    # A view bound to a topic. Setting the topic via a class
    # constant rather than a per-instance ivar so the test
    # endpoint doesn't need to thread state across calls.
    class RoomView < Tep::LiveView
      def topic
        "room:lobby"
      end
      def render
        "<div id='tep-live-root'>room:lobby</div>"
      end
    end

    # Default base class topic.
    get '/base_topic' do
      Tep::LiveView.new.topic
    end

    # Subclass with overridden topic.
    get '/room_topic' do
      RoomView.new.topic
    end

    # broadcast_render on a topic-less view is a no-op (returns 0).
    get '/broadcast_noop_topicless' do
      Tep::LiveView.new.broadcast_render.to_s
    end

    # ---- Tep.live auto-wiring ----
    #
    # `Tep.live "/auto", CounterView` is lowered by the translator
    # into a GET handler at /auto (initial render + bootstrap JS)
    # and a WS handler at /auto/ws (event dispatch + re-render).
    # The blocking server returns 501 for the WS upgrade, so the
    # test exercises the GET side only.
    Tep.live "/auto", CounterView

    # ---- chunk 4.3: presence diff binding ----

    # A view that records every presence diff it receives -- the
    # subclass override of handle_presence_diff pulls a field out
    # and appends to a class-level Array so the test endpoint can
    # report it back.
    class PresenceTrackingView < Tep::LiveView
      def initialize
        super
        @last_principal = ""
        @last_kind      = ""
        @last_state     = ""
      end
      attr_reader :last_principal, :last_kind, :last_state
      def topic
        "room:lobby"
      end
      def render
        "<div id='tep-live-root'>" + @last_principal + ":" + @last_state + "</div>"
      end
      def handle_presence_diff(diff_json)
        @last_principal = SpinelKit::Json.get_str(diff_json, "principal")
        @last_kind      = SpinelKit::Json.get_str(diff_json, "kind")
        @last_state     = SpinelKit::Json.get_str(diff_json, "state")
        0
      end
    end

    get '/presence_diff_default_noop' do
      Tep::LiveView.new.handle_presence_diff("{\\"kind\\":\\"join\\"}").to_s
    end

    get '/presence_diff_apply' do
      v = PresenceTrackingView.new
      # Feed a synthetic diff JSON.
      diff = "{\\"kind\\":\\"status\\",\\"principal\\":\\"user:42\\"," +
             "\\"state\\":\\"busy\\",\\"note\\":\\"\\"}"
      v.apply_presence_diff_json(diff)
      v.last_principal + "|" + v.last_kind + "|" + v.last_state
    end

    get '/presence_diff_render_after_apply' do
      v = PresenceTrackingView.new
      diff = "{\\"kind\\":\\"join\\",\\"principal\\":\\"user:99\\"," +
             "\\"state\\":\\"available\\",\\"note\\":\\"\\"}"
      v.apply_presence_diff_json(diff)
      v.render
    end

    # broadcast_render with a topic + an existing subscriber.
    get '/broadcast_render_match_count' do
      # Subscribe a fake fd to room:lobby so broadcast_render has
      # someone to match.
      Tep::Broadcast.clear
      Tep::Broadcast.subscribe("room:lobby", -1)
      v = RoomView.new
      "topic=" + v.topic +
        "|subs=" + Tep::Broadcast.subscribers_for("room:lobby").to_s +
        "|direct_publish=" + Tep::Broadcast.publish("room:lobby", "x").to_s +
        "|broadcast_render=" + v.broadcast_render.to_s
    end
  RB

  def test_initial_render_default_count
    res = get("/initial_render")
    assert_equal "<div id='tep-live-root'>Count: 0</div>", res.body
  end

  def test_mount_picks_seed_from_params
    res = get("/initial_render?seed=42")
    assert_equal "<div id='tep-live-root'>Count: 42</div>", res.body
  end

  def test_render_page_wraps_content_and_includes_bootstrap
    res = get("/render_page").body
    assert_includes res, "<!doctype html>"
    assert_includes res, "<p>hi</p>"
    # The bootstrap script connects to the supplied WS path.
    assert_includes res, "new WebSocket"
    assert_includes res, "/_live"
    # Click->event dispatch wire shape (uses t.dataset.event on the
    # client side).
    assert_includes res, "dataset.event"
    # innerHTML/outerHTML swap on incoming frame.
    assert_includes res, "outerHTML"
  end

  def test_dispatch_event_inc
    res = get("/event_inc").body
    assert_equal "<div id='tep-live-root'>Count: 1</div>", res
  end

  def test_dispatch_event_chain_preserves_state_across_events
    # 3 inc + 1 dec = 2
    res = get("/event_chain").body
    assert_equal "<div id='tep-live-root'>Count: 2</div>", res
  end

  def test_dispatch_event_unknown_event_is_noop
    res = get("/event_unknown").body
    assert_equal "<div id='tep-live-root'>Count: 0</div>", res
  end

  def test_base_class_render_is_empty_shell
    res = get("/base_class_render").body
    assert_equal "<div id='tep-live-root'></div>", res
  end

  # ---- chunk 4.2: broadcast binding ----

  def test_base_class_topic_is_empty
    assert_equal "", get("/base_topic").body
  end

  def test_subclass_topic_override
    assert_equal "room:lobby", get("/room_topic").body
  end

  def test_broadcast_render_noop_when_topicless
    # broadcast_render on a view with no topic is a no-op
    # (subscribers can't bind to "" topics).
    assert_equal "0", get("/broadcast_noop_topicless").body
  end

  def test_broadcast_render_publishes_to_topic
    # Pre-subscribe a fake fd to room:lobby. broadcast_render
    # should publish + match the subscriber.
    res = get("/broadcast_render_match_count").body
    # res shape:
    #   topic=room:lobby|subs=1|direct_publish=1|broadcast_render=1
    assert_match(/topic=room:lobby/, res)
    assert_match(/subs=1/, res)
    assert_match(/direct_publish=1/, res)
    assert_match(/broadcast_render=1/, res)
  end

  # ---- chunk 4.3: presence diff binding ----

  def test_base_class_handle_presence_diff_is_noop
    # Default returns 0 and doesn't crash on arbitrary JSON.
    assert_equal "0", get("/presence_diff_default_noop").body
  end

  def test_subclass_handle_presence_diff_receives_diff_fields
    # The subclass override pulls principal/kind/state out of the
    # diff JSON and updates ivars. apply_presence_diff_json is
    # the imeth that bridges JSON to handle_presence_diff.
    assert_equal "user:42|status|busy", get("/presence_diff_apply").body
  end

  def test_handle_presence_diff_can_drive_render
    # After applying a join diff, render reflects the new state.
    res = get("/presence_diff_render_after_apply").body
    assert_equal "<div id='tep-live-root'>user:99:available</div>", res
  end

  # ---- Tep.live auto-wiring ----

  def test_tep_live_get_returns_initial_render_wrapped_in_page
    # GET /auto runs the translator-emitted route: instantiate
    # CounterView, mount(req), render, wrap in render_page targeted
    # at /auto/ws.
    res = get("/auto")
    assert_equal "200", res.code
    body = res.body
    # Initial render comes from CounterView#render with @count = 0.
    assert_includes body, "<div id='tep-live-root'>Count: 0</div>"
    # render_page bootstrap JS targets the auto-generated WS path.
    assert_includes body, "/auto/ws"
    # render_page wraps in a full HTML doc with the bootstrap shell.
    assert_includes body, "<!doctype html>"
    assert_includes body, "var ws=new WebSocket("
  end

  def test_tep_live_get_honors_view_mount
    # CounterView#mount reads ?seed= from req.params and seeds @count.
    res = get("/auto?seed=42")
    assert_includes res.body, "<div id='tep-live-root'>Count: 42</div>"
  end

  def test_tep_live_ws_path_returns_501_under_blocking_server
    # The auto-wired WS path requires the scheduled server. The
    # blocking server returns 501 for WS upgrade attempts (same
    # behavior as a hand-written `websocket` block).
    res = req(:get, "/auto/ws", nil, {
      "Upgrade"               => "websocket",
      "Connection"            => "Upgrade",
      "Sec-WebSocket-Key"     => "x3JJHMbDL1EzLkh9GBhXDw==",
      "Sec-WebSocket-Version" => "13",
    })
    assert_equal "501", res.code
  end
end
