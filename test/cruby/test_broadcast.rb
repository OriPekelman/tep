require_relative "helper"

# Tep::Broadcast: in-process topic broker. v1 stores (topic, fd)
# pairs; publish writes payload bytes to every matching fd. These
# tests exercise the registry shape via fake fds (-1 / synthetic
# ints); real delivery to live sockets gets covered when the WS
# battery lands and integrates Broadcast end-to-end. The publish()
# return value is "matched count," not "successful writes" -- bad
# fds silently fail at sphttp_write_str without affecting the
# match count.
class TestBroadcast < TepTest
  app_source <<~RB
    require 'sinatra'

    before do
      res.headers["Content-Type"] = "text/plain"
    end

    # Reset between cases so test ordering doesn't matter.
    get '/reset' do
      Tep::Broadcast.clear.to_s
    end

    get '/subscribe' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Broadcast.subscribe(topic, fd).to_s
    end

    get '/subscribe_ws' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Broadcast.subscribe_ws(topic, fd).to_s
    end

    get '/unsubscribe' do
      sub_id = params[:sub_id].to_i
      Tep::Broadcast.unsubscribe(sub_id).to_s
    end

    get '/unsubscribe_fd' do
      fd = params[:fd].to_i
      Tep::Broadcast.unsubscribe_fd(fd).to_s
    end

    get '/publish' do
      topic   = params[:topic]
      payload = params[:payload]
      Tep::Broadcast.publish(topic, payload).to_s
    end

    get '/subscriber_count' do
      Tep::Broadcast.subscriber_count.to_s
    end

    get '/subscribers_for' do
      topic = params[:topic]
      Tep::Broadcast.subscribers_for(topic).to_s
    end
  RB

  # Helper: reset between tests so state doesn't carry.
  def setup
    super
    get("/reset")
  end

  def subscribe(topic, fd)
    get("/subscribe?topic=#{topic}&fd=#{fd}").body.to_i
  end

  def publish(topic, payload)
    get("/publish?topic=#{topic}&payload=#{payload}").body.to_i
  end

  def subscriber_count
    get("/subscriber_count").body.to_i
  end

  def subscribers_for(topic)
    get("/subscribers_for?topic=#{topic}").body.to_i
  end

  # ---- empty registry ----

  def test_publish_to_empty_registry_returns_zero
    assert_equal 0, publish("room:lobby", "hello")
  end

  def test_subscriber_count_starts_at_zero
    assert_equal 0, subscriber_count
  end

  def test_subscribers_for_unknown_topic_is_zero
    assert_equal 0, subscribers_for("never-subscribed")
  end

  # ---- subscribe + count ----

  def test_subscribe_grows_registry
    subscribe("room:lobby", -1)
    assert_equal 1, subscriber_count
    assert_equal 1, subscribers_for("room:lobby")
  end

  def test_multiple_subscribers_same_topic
    subscribe("room:lobby", -1)
    subscribe("room:lobby", -2)
    subscribe("room:lobby", -3)
    assert_equal 3, subscribers_for("room:lobby")
  end

  def test_subscribers_segregated_by_topic
    subscribe("room:lobby", -1)
    subscribe("room:lobby", -2)
    subscribe("room:other", -3)
    assert_equal 2, subscribers_for("room:lobby")
    assert_equal 1, subscribers_for("room:other")
  end

  # ---- publish matching ----

  def test_publish_returns_matched_count
    subscribe("room:lobby", -1)
    subscribe("room:lobby", -2)
    subscribe("room:other", -3)
    assert_equal 2, publish("room:lobby", "hi")
  end

  def test_publish_to_unmatched_topic_zero
    subscribe("room:lobby", -1)
    assert_equal 0, publish("never", "hi")
  end

  # ---- unsubscribe (by sub_id) ----

  def test_unsubscribe_by_id_drops_one
    sub_id = subscribe("room:lobby", -1)
    subscribe("room:lobby", -2)
    get("/unsubscribe?sub_id=#{sub_id}")
    assert_equal 1, subscribers_for("room:lobby")
  end

  # ---- unsubscribe_fd (by fd, multi-topic) ----

  def test_unsubscribe_fd_drops_all_for_fd
    subscribe("room:lobby", -1)
    subscribe("room:other", -1)   # same fd, different topic
    subscribe("room:lobby", -2)
    dropped = get("/unsubscribe_fd?fd=-1").body.to_i
    assert_equal 2, dropped
    assert_equal 1, subscribers_for("room:lobby")
    assert_equal 0, subscribers_for("room:other")
  end

  def test_unsubscribe_fd_unknown_zero
    subscribe("room:lobby", -1)
    dropped = get("/unsubscribe_fd?fd=-999").body.to_i
    assert_equal 0, dropped
  end

  # ---- subscribe_ws (WebSocket frame mode) ----

  def test_subscribe_ws_grows_registry
    get("/subscribe_ws?topic=room:lobby&fd=-1")
    assert_equal 1, subscriber_count
    assert_equal 1, subscribers_for("room:lobby")
  end

  def test_subscribe_ws_publish_match_count
    # Subscribe two WS, one raw -- all three should match a publish
    # to that topic (delivery mode doesn't affect match counting).
    get("/subscribe_ws?topic=room:lobby&fd=-1")
    get("/subscribe_ws?topic=room:lobby&fd=-2")
    get("/subscribe?topic=room:lobby&fd=-3")
    assert_equal 3, publish("room:lobby", "hi")
  end

  def test_subscribe_ws_unsubscribe_fd_drops
    # Mixed-mode subscriptions for one fd: subscribe_ws on a
    # different topic + subscribe on the same fd. unsubscribe_fd
    # drops both.
    get("/subscribe_ws?topic=room:lobby&fd=-1")
    get("/subscribe?topic=room:other&fd=-1")
    dropped = get("/unsubscribe_fd?fd=-1").body.to_i
    assert_equal 2, dropped
  end

  # ---- clear ----

  def test_clear_drops_everything
    subscribe("room:lobby", -1)
    subscribe("room:other", -2)
    get("/reset")
    assert_equal 0, subscriber_count
  end
end
