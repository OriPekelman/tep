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
        # otherwise leave at 0.
        seed = req.params["seed"]
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
end
