require_relative "helper"
require "json"

# Tep::Http::Pool (chunk 6.7a). The C-side pool primitives + Ruby
# wrapper, exercised directly. No Tep::Http.send_req integration
# yet -- that's 6.7b (needs the HTTP/1.1 keep-alive recv-N-bytes
# path). Tests assert the pool keys, evicts LRU, and surfaces the
# right stats.
class TestHttpPool < TepTest
  app_source <<~RB
    require 'sinatra'

    # Scheduled server so self-calls (sphttp_connect to our own port
    # for the /pool/register fd) don't deadlock the single worker.
    set :scheduler, :scheduled
    set :workers, 1

    # Reset by closing all idle fds (well past their use). Used to
    # make per-test state deterministic.
    post '/pool/reset' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Http::Pool.close_idle(-1).to_s   # idle > -1s -> closes all
    end

    # Open a real socket to ourselves + checkin to the pool. Returns
    # the fd we just registered. The test treats the fd as opaque +
    # only asserts on the pool's behaviour.
    post '/pool/register' do
      res.headers["Content-Type"] = "text/plain"
      fd = Sock.sphttp_connect("127.0.0.1", params[:port].to_i)
      if fd < 0
        return "connect_failed"
      end
      Tep::Http::Pool.release(fd, "127.0.0.1", params[:port].to_i).to_s
    end

    # Claim and report the fd (>=0 hit, -1 miss). Close on hit so
    # the test doesn't leak.
    get '/pool/claim/:port' do
      res.headers["Content-Type"] = "text/plain"
      fd = Tep::Http::Pool.claim("127.0.0.1", params[:port].to_i)
      if fd >= 0
        Sock.sphttp_close(fd)
        return "hit"
      end
      "miss"
    end

    # Stats snapshot as JSON.
    get '/pool/stats' do
      res.headers["Content-Type"] = "application/json"
      s = Tep::Http::Pool.stats
      "{" +
        Tep::Json.encode_pair_int("checkouts", s["checkouts"].to_i) + "," +
        Tep::Json.encode_pair_int("checkins",  s["checkins"].to_i) + "," +
        Tep::Json.encode_pair_int("hits",      s["hits"].to_i) + "," +
        Tep::Json.encode_pair_int("misses",    s["misses"].to_i) +
      "}"
    end

    # Trivial route the pool's TCP open targets -- the connect
    # itself is what we care about; the response shape is unused.
    get '/ping' do
      "pong"
    end
  RB

  def setup
    super
    # Drain the pool + reset counters via "miss" cycles isn't possible
    # (stats are monotonic process-wide). Tests assert DELTAS, not
    # absolute counts.
    post("/pool/reset", "")
  end

  def stats_now
    JSON.parse(get("/pool/stats").body)
  end

  def test_release_then_claim_is_a_hit
    s0 = stats_now
    # Register an fd in the pool.
    res = post("/pool/register?port=#{@port}", "")
    assert_equal "200", res.code
    assert_equal "0", res.body, "release should succeed (returned 0)"

    # First claim should HIT.
    res = get("/pool/claim/#{@port}")
    assert_equal "hit", res.body, "expected pool hit for the released fd"

    s1 = stats_now
    assert_equal s0["hits"] + 1, s1["hits"]
    assert_equal s0["checkins"] + 1, s1["checkins"]
  end

  def test_claim_on_empty_pool_is_a_miss
    s0 = stats_now
    res = get("/pool/claim/#{@port}")
    assert_equal "miss", res.body
    s1 = stats_now
    assert_equal s0["misses"] + 1, s1["misses"]
    assert_equal s0["hits"], s1["hits"]
  end

  def test_second_claim_after_one_release_misses
    # Register one fd; claim it; second claim should miss.
    post("/pool/register?port=#{@port}", "")
    res = get("/pool/claim/#{@port}")
    assert_equal "hit", res.body
    res = get("/pool/claim/#{@port}")
    assert_equal "miss", res.body
  end

  def test_close_idle_removes_pooled_fds
    # Register an fd then sweep with idle_seconds=-1 (every fd is
    # older than -1s from "now") -- subsequent claim should miss.
    post("/pool/register?port=#{@port}", "")
    post("/pool/reset", "")
    res = get("/pool/claim/#{@port}")
    assert_equal "miss", res.body
  end
end
