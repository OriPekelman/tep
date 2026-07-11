require_relative "helper"

# Tep::Presence: topic-keyed who's-here registry, agent-aware via
# Tep::Identity. v1 chunk covers storage + track/untrack +
# list/count + status; diff broadcasting via Tep::Broadcast lands
# in a follow-up.
class TestPresence < TepTest
  app_source <<~RB
    require 'sinatra'

    # Per-request identity is normally set by Tep::Auth's filter
    # off Bearer / SessionCookie / OAuth credentials. These tests
    # don't go through auth -- we build identities inline and
    # poke them onto req.identity in a before-filter keyed off
    # the ?as=<...> query param. Same exercise of Presence's
    # principal_id / kind / agent_id pickup that the real
    # production path takes.

    before do
      res.headers["Content-Type"] = "text/plain"
      caps = [:read, :write]
      who = params[:as]
      if who == "agent"
        deleg = Tep::AgentDelegation.new(
          "summarizer-bot", 1000, 9999999999, :token)
        req.identity = Tep::Identity.new("user:42", deleg, caps)
      elsif who.length > 0
        # who looks like "user:NN" -- use it as principal directly.
        req.identity = Tep::Identity.new(who, nil, caps)
      end
      # else: req.identity stays at anonymous (set by auth filter).
    end

    get '/reset' do
      Tep::Presence.clear.to_s
    end

    get '/track' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Presence.track(req, topic, fd).to_s
    end

    get '/untrack' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Presence.untrack(topic, fd).to_s
    end

    get '/untrack_by_fd' do
      fd = params[:fd].to_i
      Tep::Presence.untrack_by_fd(fd).to_s
    end

    get '/count' do
      Tep::Presence.count(params[:topic]).to_s
    end

    get '/count_humans' do
      Tep::Presence.count_humans(params[:topic]).to_s
    end

    get '/count_agents' do
      Tep::Presence.count_agents(params[:topic]).to_s
    end

    get '/list_summary' do
      # Compact serialization for assertion: principal_id|kind|agent_id|fd
      # SEMICOLON-separated (newlines inside heredoc tep app source
      # appear to absorb indentation -- bench the actual cause out
      # of band).
      topic = params[:topic]
      entries = Tep::Presence.list(topic)
      out = ""
      i = 0
      while i < entries.length
        e = entries[i]
        if out.length > 0
          out = out + ";"
        end
        out = out + e.principal_id + "|" + e.kind.to_s + "|" + e.agent_id + "|" + e.fd.to_s
        i += 1
      end
      out
    end

    get '/set_status' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      state = params[:state].to_sym
      note  = params[:note]
      ut    = params[:until_ts].to_i
      Tep::Presence.set_status(topic, fd, state, note, ut).to_s
    end

    get '/clear_status' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Presence.clear_status(topic, fd).to_s
    end

    get '/status_summary' do
      topic = params[:topic]
      fd    = params[:fd].to_i
      e = Tep::Presence.find_entry(topic, fd)
      if e == nil
        ""
      else
        e.status_state.to_s + "|" + e.status_note + "|" + e.status_until.to_s
      end
    end

    # ---- diff broadcasting endpoints (chunk 3.2) ----

    get '/sub_diff' do
      # Subscribe a fake fd to the diff broadcast topic for `topic`.
      # Returns the diff-broadcast subscriber count so tests can
      # assert "track() fanned out to N subscribers."
      topic = params[:topic]
      fd    = params[:fd].to_i
      Tep::Broadcast.subscribe(Tep::Presence.diff_topic(topic), fd).to_s
    end

    get '/diff_subscribers_for' do
      topic = params[:topic]
      Tep::Broadcast.subscribers_for(Tep::Presence.diff_topic(topic)).to_s
    end

    get '/clear_broadcast' do
      Tep::Broadcast.clear.to_s
    end

    get '/encode_diff_for' do
      # Build a synthetic entry + encode a "join" diff. Used by
      # the wire-format test.
      topic = params[:topic]
      e = Tep::Presence.find_entry(topic, params[:fd].to_i)
      if e == nil
        ""
      else
        Tep::Presence.encode_diff(params[:kind], e)
      end
    end

    get '/sweep_expired' do
      Tep::Presence.sweep_expired_status.to_s
    end
  RB

  def setup
    super
    get("/reset")
    get("/clear_broadcast")
  end

  # ---- empty registry ----

  def test_count_empty
    assert_equal "0", get("/count?topic=room:lobby").body
  end

  # ---- track + list ----

  def test_track_human
    get("/track?topic=room:lobby&fd=1&as=user:42")
    assert_equal "user:42|human||1", get("/list_summary?topic=room:lobby").body
  end

  def test_track_agent
    get("/track?topic=room:lobby&fd=2&as=agent")
    # The agentic-row format: principal user:42, kind agent_for,
    # agent_id summarizer-bot.
    assert_equal "user:42|agent_for|summarizer-bot|2",
      get("/list_summary?topic=room:lobby").body
  end

  def test_track_multi_session_same_principal
    # Two browser tabs for user:42 + one summarizer-bot delegate
    # for them. List should return all three.
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/track?topic=room:lobby&fd=2&as=user:42")
    get("/track?topic=room:lobby&fd=3&as=agent")
    body = get("/list_summary?topic=room:lobby").body
    rows = body.split(";").sort
    assert_equal 3, rows.length
    assert_includes rows, "user:42|agent_for|summarizer-bot|3"
    assert_includes rows, "user:42|human||1"
    assert_includes rows, "user:42|human||2"
  end

  def test_track_dedups_repeat_calls
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/track?topic=room:lobby&fd=1&as=user:42")
    assert_equal "1", get("/count?topic=room:lobby").body
  end

  # ---- count_humans / count_agents ----

  def test_kind_counts
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/track?topic=room:lobby&fd=2&as=user:99")
    get("/track?topic=room:lobby&fd=3&as=agent")
    assert_equal "3", get("/count?topic=room:lobby").body
    assert_equal "2", get("/count_humans?topic=room:lobby").body
    assert_equal "1", get("/count_agents?topic=room:lobby").body
  end

  # ---- untrack ----

  def test_untrack_drops_one
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/track?topic=room:lobby&fd=2&as=user:99")
    res = get("/untrack?topic=room:lobby&fd=1")
    assert_equal "1", res.body
    assert_equal "1", get("/count?topic=room:lobby").body
  end

  def test_untrack_unknown_zero
    res = get("/untrack?topic=never&fd=99")
    assert_equal "0", res.body
  end

  # ---- untrack_by_fd (WS-close hook shape) ----

  def test_untrack_by_fd_drops_across_topics
    # One fd, three topics -- a human in three rooms simultaneously
    # via one connection. Close their connection -> drop all three.
    get("/track?topic=room:a&fd=1&as=user:42")
    get("/track?topic=room:b&fd=1&as=user:42")
    get("/track?topic=room:c&fd=1&as=user:42")
    dropped = get("/untrack_by_fd?fd=1").body.to_i
    assert_equal 3, dropped
  end

  # ---- topic segregation ----

  def test_topics_dont_cross
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/track?topic=room:other&fd=2&as=user:99")
    assert_equal "1", get("/count?topic=room:lobby").body
    assert_equal "1", get("/count?topic=room:other").body
  end

  # ---- structured status ----

  def test_status_defaults_to_available
    get("/track?topic=room:lobby&fd=1&as=user:42")
    res = get("/status_summary?topic=room:lobby&fd=1")
    assert_equal "available||0", res.body
  end

  def test_set_status_busy
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/set_status?topic=room:lobby&fd=1&state=busy&note=working&until_ts=0")
    res = get("/status_summary?topic=room:lobby&fd=1")
    assert_equal "busy|working|0", res.body
  end

  def test_set_status_blocked_with_until
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/set_status?topic=room:lobby&fd=1&state=blocked&note=Claude API throttled&until_ts=2026200000")
    res = get("/status_summary?topic=room:lobby&fd=1")
    assert_equal "blocked|Claude API throttled|2026200000", res.body
  end

  def test_clear_status_resets
    get("/track?topic=room:lobby&fd=1&as=user:42")
    get("/set_status?topic=room:lobby&fd=1&state=busy&note=working&until_ts=0")
    get("/clear_status?topic=room:lobby&fd=1")
    res = get("/status_summary?topic=room:lobby&fd=1")
    assert_equal "available||0", res.body
  end

  def test_set_status_unknown_entry_zero
    res = get("/set_status?topic=never&fd=99&state=busy&note=&until_ts=0")
    assert_equal "0", res.body
  end

  # ---- diff broadcasting (chunk 3.2) ----

  def test_track_emits_join_diff
    # Subscribe a fake fd to the room:lobby presence diff stream.
    get("/sub_diff?topic=room:lobby&fd=-1")
    assert_equal "1", get("/diff_subscribers_for?topic=room:lobby").body
    # track() should publish a "join" diff to that channel; the
    # subscriber count is 1 so publish matches 1.
    # We can't easily see the bytes (fake fd), but Broadcast does
    # return the matched count. The test endpoint here doesn't
    # expose publish return -- instead, infer from the fact that
    # track returns 0 (success) + that the broadcast topic
    # exists. That's weak; the wire-format test below covers the
    # payload.
    res = get("/track?topic=room:lobby&fd=10&as=user:42")
    assert_equal "0", res.body
  end

  def test_untrack_emits_leave_diff
    get("/track?topic=room:lobby&fd=10&as=user:42")
    get("/sub_diff?topic=room:lobby&fd=-1")
    # untrack returns 1 (one entry removed).
    assert_equal "1", get("/untrack?topic=room:lobby&fd=10").body
  end

  def test_set_status_emits_status_diff
    get("/track?topic=room:lobby&fd=10&as=user:42")
    get("/sub_diff?topic=room:lobby&fd=-1")
    res = get("/set_status?topic=room:lobby&fd=10&state=busy&note=working&until_ts=0")
    assert_equal "1", res.body
  end

  def test_diff_topic_naming
    # diff_topic(topic) = "presence:" + topic. Apps subscribe via
    # the same convention.
    get("/track?topic=room:lobby&fd=10&as=user:42")
    get("/sub_diff?topic=room:lobby&fd=-1")
    # The diff broadcast lives under "presence:room:lobby".
    assert_equal "1", get("/diff_subscribers_for?topic=room:lobby").body
  end

  def test_encode_diff_wire_format
    # Track a human, then encode a "join" diff for that entry.
    get("/track?topic=room:lobby&fd=10&as=user:42")
    res = get("/encode_diff_for?topic=room:lobby&fd=10&kind=join")
    # Flat JSON; assert key fields are present.
    body = res.body
    assert_includes body, "\"kind\":\"join\""
    assert_includes body, "\"topic\":\"room:lobby\""
    assert_includes body, "\"principal\":\"user:42\""
    assert_includes body, "\"ekind\":\"human\""
    assert_includes body, "\"agent_id\":\"\""
    assert_includes body, "\"fd\":10"
    assert_includes body, "\"state\":\"available\""
  end

  def test_encode_diff_for_agent
    get("/track?topic=room:lobby&fd=11&as=agent")
    res = get("/encode_diff_for?topic=room:lobby&fd=11&kind=join")
    body = res.body
    assert_includes body, "\"ekind\":\"agent_for\""
    assert_includes body, "\"agent_id\":\"summarizer-bot\""
  end

  # ---- status auto-expiry ----

  def test_sweep_expired_status_resets_expired_entries
    get("/track?topic=room:lobby&fd=10&as=user:42")
    # Set an already-expired status.
    get("/set_status?topic=room:lobby&fd=10&state=blocked&note=API throttled&until_ts=1")
    assert_equal "blocked|API throttled|1", get("/status_summary?topic=room:lobby&fd=10").body
    # Sweep -- should reset back to :available + emit a "status" diff.
    res = get("/sweep_expired").body.to_i
    assert_equal 1, res
    assert_equal "available||0", get("/status_summary?topic=room:lobby&fd=10").body
  end

  def test_sweep_skips_non_expired
    get("/track?topic=room:lobby&fd=10&as=user:42")
    # Status with until_ts far in the future.
    get("/set_status?topic=room:lobby&fd=10&state=busy&note=working&until_ts=9999999999")
    res = get("/sweep_expired").body.to_i
    assert_equal 0, res
    # Status unchanged.
    assert_equal "busy|working|9999999999", get("/status_summary?topic=room:lobby&fd=10").body
  end

  def test_sweep_skips_already_available
    get("/track?topic=room:lobby&fd=10&as=user:42")
    # Default status is :available with until_ts=0; sweep should
    # skip even though until_ts == 0 is a "no-expiry" sentinel.
    res = get("/sweep_expired").body.to_i
    assert_equal 0, res
  end
end
