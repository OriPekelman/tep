require_relative "helper"
require "shellwords"

# HTTP-level smoke tests for the real-world examples we claim to
# support. Each test compiles the example to a temporary binary,
# starts it on a fresh port, probes it with curl-equivalent
# requests, and kills it.
#
# Failure mode this catches: an example that *compiles* but
# doesn't actually serve correctly (the SINATRA_COMPAT.md matrix
# previously called out only build vs. serve via spot-checks; this
# is the automated version).
#
# These run alongside the curated tests but are stamped at the
# real_world/ source paths so they don't conflict with anything
# else.
class TestRealWorld < TepTest
  # Override TepTest's class-level boot. Each test in here brings
  # up its own example binary.
  def self.boot!; end
  def setup;     end
  def teardown;  end

  EXAMPLES_DIR = File.expand_path("real_world", __dir__)
  PORT_BASE    = 4900 + ($$ % 100)

  @@port_counter = 0
  def self.next_port
    @@port_counter += 1
    PORT_BASE + 100 + @@port_counter
  end

  def with_app(example_filename)
    src = File.join(EXAMPLES_DIR, example_filename)
    bin = Dir.mktmpdir + "/app"
    out = `#{Shellwords.escape(File.expand_path("../bin/tep", __dir__))} build #{Shellwords.escape(src)} -o #{Shellwords.escape(bin)} 2>&1`
    raise "build failed:\n#{out}" unless $?.success?
    port = TestRealWorld.next_port
    pid = Process.spawn(bin, "-p", port.to_s, "-q",
                        pgroup: true, out: "/dev/null", err: "/dev/null")
    wait_for_port(port)
    @port = port
    begin
      yield port
    ensure
      TepHarness.reap(pid)
    end
  end

  def wait_for_port(port, timeout: 3.0)
    deadline = Time.now + timeout
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", port).close
        return
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
    raise "server on :#{port} didn't come up"
  end

  # ---- 01: simple ----

  def test_01_simple_root_returns_text
    with_app("01_simple.rb") do
      res = get("/")
      assert_equal "200", res.code
      assert_match(/this is a simple app/, res.body)
    end
  end

  # ---- 02: lifecycle ----

  def test_02_lifecycle_root_renders
    with_app("02_lifecycle.rb") do
      res = get("/")
      assert_equal "200", res.code
      assert_match(/lifecycle events/, res.body)
    end
  end

  # ---- 04: health api ----

  def test_04_health_endpoints
    with_app("04_health_api.rb") do
      assert_match(/"status":"ok"/, get("/healthz").body)
      assert_match(/"version":"1\.4\.2"/, get("/version").body)
      assert_match(/"endpoints"/, get("/").body)
      # not_found block returns a JSON 404
      res = get("/missing")
      assert_equal "404", res.code
      assert_match(/"error":"not found"/, res.body)
      assert_match(/"path":"\/missing"/, res.body)
    end
  end

  # ---- 05: todo api ----

  def test_05_todo_crud_round_trip
    with_app("05_todo_api.rb") do
      # Empty list at boot.
      assert_equal "[]", get("/todos").body.strip

      # Create two.
      r1 = post("/todos", "text=buy-milk")
      assert_match(/"id":1,"text":"buy-milk"/, r1.body)
      r2 = post("/todos", "text=ship-tep")
      assert_match(/"id":2,"text":"ship-tep"/, r2.body)

      # List has both.
      list = get("/todos").body
      assert_match(/"id":1/, list)
      assert_match(/"id":2/, list)

      # Delete the first.
      d = delete("/todos/1")
      assert_match(/"deleted":1/, d.body)

      # 404 on missing id.
      d404 = delete("/todos/9999")
      assert_equal "404", d404.code
    end
  end

  # ---- 06: basic auth ----

  def test_06_basic_auth_blocks_admin_without_token
    with_app("06_basic_auth.rb") do
      assert_equal "200", get("/").code

      r_no = get("/admin/dashboard")
      assert_equal "401", r_no.code

      r_bad = get("/admin/dashboard", {"x-token" => "wrong"})
      assert_equal "401", r_bad.code

      r_ok = get("/admin/dashboard", {"x-token" => "sekret-42"})
      assert_equal "200", r_ok.code
      assert_match(/admin: ok/, r_ok.body)

      assert_equal "200", get("/admin/users", {"x-token" => "sekret-42"}).code
    end
  end

  # ---- showcase: examples/blog ----
  # Exercises sqlite + json + jwt + password + sessions + erb-with-
  # ivars + logger + security in one app. The blog ships an admin
  # user (alice / hunter2) on first boot.

  def with_blog
    src = File.expand_path("../examples/blog/app.rb", __dir__)
    bin = Dir.mktmpdir + "/blog"
    db  = File.join(File.dirname(bin), "blog.db")
    File.unlink(db) if File.exist?(db)
    out = `TEP_BLOG_DB=#{Shellwords.escape(db)} #{Shellwords.escape(File.expand_path("../bin/tep", __dir__))} build #{Shellwords.escape(src)} -o #{Shellwords.escape(bin)} 2>&1`
    raise "blog build failed:\n#{out}" unless $?.success?
    port = TestRealWorld.next_port
    pid = Process.spawn({"TEP_BLOG_DB" => db}, bin, "-p", port.to_s, "-q",
                        pgroup: true, out: "/dev/null", err: "/dev/null")
    wait_for_port(port)
    @port = port
    begin
      yield port
    ensure
      TepHarness.reap(pid)
    end
  end

  def test_blog_homepage_lists_posts
    with_blog do
      res = get("/")
      assert_equal "200", res.code
      assert_match(/tep blog/, res.body)
      # First boot seeds an intro post so the homepage isn't empty.
      assert_match(/Welcome to tep \+ spinel/, res.body)
    end
  end

  def test_blog_homepage_renders_seed_post
    with_blog do
      res = get("/post/1")
      assert_equal "200", res.code
      assert_match(/<h1>Welcome to tep \+ spinel<\/h1>/, res.body)
      assert_match(/by alice/, res.body)
    end
  end

  def test_blog_api_token_and_post_round_trip
    with_blog do
      # Issue a JWT for the seeded admin.
      tok_res = post("/api/token", '{"user":"alice","password":"hunter2"}')
      assert_equal "200", tok_res.code
      token = tok_res.body[/"token":"([^"]+)"/, 1]
      refute_nil token, "token field present in /api/token response"

      # Create a post via the JSON API. With the seed post present
      # this is row 2; assertion is shape-only.
      hdr = {"Authorization" => "Bearer #{token}"}
      r_create = post("/api/posts", '{"title":"hello","body":"first post"}', hdr)
      assert_equal "201", r_create.code
      created_id = r_create.body[/"id":(\d+)/, 1].to_i
      assert created_id >= 1

      # Read it back via the public list.
      r_list = get("/api/posts")
      assert_match(/"title":"hello"/, r_list.body)
      assert_match(/"author":"alice"/, r_list.body)

      # Web view renders the post.
      r_show = get("/post/#{created_id}")
      assert_equal "200", r_show.code
      assert_match(/<h1>hello<\/h1>/, r_show.body)
      assert_match(/by alice/, r_show.body)
    end
  end

  def test_blog_api_token_rejects_bad_password
    with_blog do
      res = post("/api/token", '{"user":"alice","password":"wrong"}')
      assert_equal "401", res.code
      assert_match(/invalid credentials/, res.body)
    end
  end

  def test_blog_api_posts_requires_jwt
    with_blog do
      # No Authorization header.
      r1 = post("/api/posts", '{"title":"x","body":"y"}')
      assert_equal "401", r1.code

      # Tampered token.
      r2 = post("/api/posts", '{"title":"x","body":"y"}',
                {"Authorization" => "Bearer not.a.token"})
      assert_equal "401", r2.code
    end
  end

  def test_blog_web_login_protects_admin
    with_blog do
      # Without session: 401 on admin.
      r_admin = get("/admin/new")
      assert_equal "401", r_admin.code

      # With a successful login + cookie jar...
      uri = URI("http://127.0.0.1:#{@port}/login")
      net = Net::HTTP.new(uri.host, uri.port)
      # Explicit form Content-Type: this direct net.post bypasses the
      # harness req() helper, and Ruby 4.0's Net::HTTP no longer auto-sets
      # it for a bodied request (3.x did), so without it the login form
      # isn't parsed -> 401 instead of 302.
      r_login = net.post(uri.path, "user=alice&password=hunter2",
                         {"Content-Type" => "application/x-www-form-urlencoded"})
      assert_equal "302", r_login.code
      cookie = r_login["Set-Cookie"]
      refute_nil cookie

      r_admin2 = get("/admin/new", {"Cookie" => cookie.split(";").first})
      assert_equal "200", r_admin2.code
      assert_match(/posting as.*alice/, r_admin2.body)
    end
  end

  # ---- showcase: examples/chat ----
  # Live chat with SSE streaming + presence. Each open SSE
  # connection occupies one tep worker, so we boot with -w 4.

  def with_chat
    src = File.expand_path("../examples/chat/app.rb", __dir__)
    bin = Dir.mktmpdir + "/chat"
    db  = File.join(File.dirname(bin), "chat.db")
    File.unlink(db) if File.exist?(db)
    out = `TEP_CHAT_DB=#{Shellwords.escape(db)} #{Shellwords.escape(File.expand_path("../bin/tep", __dir__))} build #{Shellwords.escape(src)} -o #{Shellwords.escape(bin)} 2>&1`
    raise "chat build failed:\n#{out}" unless $?.success?
    port = TestRealWorld.next_port
    # Single worker, fresh process group so we can SIGTERM the
    # whole tree on teardown. Prefork (-w >1) leaks orphan workers
    # under macOS SO_REUSEPORT semantics that confuse subsequent
    # boots in the same test run.
    pid = Process.spawn({"TEP_CHAT_DB" => db}, bin, "-p", port.to_s, "-w", "1", "-q",
                        pgroup: true, out: "/dev/null", err: "/dev/null")
    wait_for_port(port)
    @port = port
    begin
      yield port
    ensure
      TepHarness.reap(pid)
    end
  end

  def test_chat_homepage_renders
    with_chat do
      res = get("/")
      assert_equal "200", res.code
      assert_match(/tep chat/, res.body)
      assert_match(/EventSource/, res.body)
    end
  end

  def test_chat_send_then_recent
    with_chat do
      r1 = post("/chat/send", "author=alice&body=hello")
      assert_equal "200", r1.code
      assert_match(/"id":1/, r1.body)

      r2 = post("/chat/send", "author=bob&body=hi+alice")
      assert_match(/"id":2/, r2.body)

      list = get("/chat/recent")
      assert_match(/"author":"alice","body":"hello"/, list.body)
      assert_match(/"author":"bob","body":"hi alice"/, list.body)
    end
  end

  def test_chat_send_validates_required_fields
    with_chat do
      assert_equal "400", post("/chat/send", "body=missing-author").code
      assert_equal "400", post("/chat/send", "author=alice").code
    end
  end

  def test_chat_who_reflects_heartbeats
    with_chat do
      # No-one before any heartbeat.
      assert_equal "[]", get("/chat/who").body.strip

      post("/chat/heartbeat", "user=alice")
      post("/chat/heartbeat", "user=bob")
      who = get("/chat/who").body
      assert_match(/"user":"alice"/, who)
      assert_match(/"user":"bob"/, who)
    end
  end

  def test_chat_recent_since_param
    with_chat do
      post("/chat/send", "author=a&body=one")
      post("/chat/send", "author=b&body=two")
      post("/chat/send", "author=c&body=three")

      # since=1 should drop msg #1 and return #2 + #3.
      list = get("/chat/recent?since=1").body
      refute_match(/"body":"one"/, list)
      assert_match(/"body":"two"/, list)
      assert_match(/"body":"three"/, list)
    end
  end

  def test_chat_serves_bundled_assets
    with_chat do
      css = get("/style.css")
      assert_equal "200", css.code
      assert_match(/text\/css/, css["content-type"])
      assert_match(/--accent/, css.body)        # spot-check our content
      assert_match(/max-age=3600/, css["cache-control"])

      svg = get("/logo.svg")
      assert_equal "200", svg.code
      assert_match(/image\/svg\+xml/, svg["content-type"])
      assert_match(/<svg/, svg.body)

      # An asset that isn't bundled falls through to 404 via the
      # normal not-found path, not the asset layer.
      assert_equal "404", get("/missing.css").code
    end
  end

  def test_chat_stream_emits_backlog_and_keepalive
    with_chat do
      # Seed messages BEFORE the stream opens.
      post("/chat/send", "author=a&body=pre1")
      post("/chat/send", "author=b&body=pre2")

      # Pull bytes directly from the SSE socket so we don't have to
      # wait STREAM_MAX (30s) for Net::HTTP to call it done.
      sock = TCPSocket.new("127.0.0.1", @port)
      sock.write("GET /chat/stream?since=0 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      events = String.new
      deadline = Time.now + 4
      while Time.now < deadline
        IO.select([sock], nil, nil, 0.5) or next
        chunk = sock.read_nonblock(4096) rescue nil
        break if chunk.nil? || chunk.empty?
        events << chunk
        # Stop early once we've seen everything we expect.
        break if events.include?("pre1") && events.include?("pre2") && events.include?(": tick")
      end
      sock.close

      # Live "send while streaming" is a separate concurrency
      # property that depends on prefork SO_REUSEPORT actually
      # load-balancing -- which it doesn't reliably on macOS. The
      # streaming pipeline itself (backlog + keepalive frames) is
      # what we cover here.
      assert_match(/"body":"pre1"/, events)
      assert_match(/"body":"pre2"/, events)
      assert_match(/: tick/, events)
      assert_match(/Transfer-Encoding: chunked/i, events)
      assert_match(/Content-Type: text\/event-stream/i, events)
    end
  end
end
