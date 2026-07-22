require_relative "helper"

# Tep::Broadcast PG backend: cross-worker pub/sub via
# LISTEN/NOTIFY. Gated on PG_TEST_URL like test_pg.rb.
#
#   PG_TEST_URL=postgresql://postgres:postgres@127.0.0.1:5432/postgres \
#     ruby test/test_broadcast_pg.rb
#
# Test strategy: configure the backend at on_start, then exercise
# publish() + poll_pg_once() within a single tep app instance. PG's
# LISTEN/NOTIFY delivers a worker's own NOTIFYs back to it (the
# "LISTEN sees own publishes" property), so a single-process app
# can validate the full wire round-trip without needing to spin up
# a second worker.
class TestBroadcastPg < TepTest
  PG_URL = ENV["PG_TEST_URL"]
  CHANNEL = "tep_broadcast_test_#{$$}"

  app_source <<~RB
    require 'sinatra'
    require "tep/pg"          # opt-in PG backend (#216)

    PG_URL  = "#{PG_URL}"
    CHANNEL = "#{CHANNEL}"

    on_start do
      Tep::Broadcast.enable_pg_backend(PG_URL, CHANNEL)
    end

    before do
      res.headers["Content-Type"] = "text/plain"
    end

    get '/reset' do
      Tep::Broadcast.clear.to_s
    end

    get '/subscribe' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Broadcast.subscribe(topic, fd).to_s
    end

    get '/publish' do
      topic   = params[:topic]
      payload = params[:payload]
      Tep::Broadcast.publish(topic, payload).to_s
    end

    get '/poll' do
      timeout = params[:timeout].to_i
      Tep::Broadcast.poll_pg_once(timeout).to_s
    end

    get '/encode_wire' do
      topic   = params[:topic]
      payload = params[:payload]
      Tep::Broadcast.encode_wire(topic, payload)
    end

    get '/decode_wire' do
      wire = params[:wire]
      Tep::Broadcast.deliver_wire_local(wire).to_s
    end
  RB

  def setup
    if PG_URL.nil? || PG_URL.empty?
      skip "PG_TEST_URL not set (e.g. PG_TEST_URL=postgresql:///postgres). " \
           "See test/test_pg.rb header for the docker recipe."
    end
    super
    get("/reset")
  end

  # ---- Wire format round-trip (no PG, no NOTIFY -- pure encoding) ----

  def test_encode_wire_length_prefixed
    res = get("/encode_wire?topic=room:lobby&payload=hello")
    # "10:room:lobbyhello" -- 10 chars in topic "room:lobby" then payload "hello"
    assert_equal "10:room:lobbyhello", res.body
  end

  def test_encode_wire_empty_payload
    res = get("/encode_wire?topic=t&payload=")
    assert_equal "1:t", res.body
  end

  def test_decode_wire_delivers_to_local_subs
    # Subscribe a fake fd to a topic, then decode-and-deliver a
    # wire-format payload as if it had come in via PG NOTIFY.
    get("/subscribe?topic=room:lobby&fd=-1")
    res = get("/decode_wire?wire=10:room:lobbyhello")
    # Matched 1 local subscriber.
    assert_equal "1", res.body
  end

  def test_decode_wire_unsubscribed_topic_zero
    res = get("/decode_wire?wire=4:nope")
    assert_equal "0", res.body
  end

  # ---- End-to-end PG NOTIFY round trip ----

  def test_publish_then_poll_round_trips_via_pg
    # Publish a message -- NOTIFY's PG.
    get("/publish?topic=pg_round_trip&payload=ping")
    # Poll for the NOTIFY (we sent it; LISTEN sees own publishes).
    res = get("/poll?timeout=2000")
    assert_equal "1", res.body
  end

  def test_poll_returns_zero_on_timeout
    # Test order is randomized and the LISTEN channel is shared:
    # another test's publish can leave an unconsumed NOTIFY queued.
    # Drain first, then assert a clean timeout.
    5.times do
      break if get("/poll?timeout=50").body == "0"
    end
    res = get("/poll?timeout=100")
    assert_equal "0", res.body
  end

  def test_publish_with_local_sub_also_matches_local
    # Local fan-out still works alongside PG NOTIFY. Subscribe a
    # local fake fd, publish -- match count reflects the local sub.
    get("/subscribe?topic=mixed_topic&fd=-1")
    res = get("/publish?topic=mixed_topic&payload=hi")
    assert_equal "1", res.body
  end

  def test_publish_with_no_local_sub_matches_zero_but_still_notifies
    # No local subs -- match count is 0, but publish still ran the
    # PG NOTIFY (subsequent poll confirms).
    res = get("/publish?topic=remote_only&payload=hi")
    assert_equal "0", res.body
    poll_res = get("/poll?timeout=2000")
    assert_equal "1", poll_res.body
  end
end
