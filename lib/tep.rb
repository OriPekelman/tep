# Tep -- a Sinatra-flavoured framework that compiles to a native
# binary via Spinel.
#
#   require_relative "../tep/lib/tep"
#
#   class Root < Tep::Handler
#     def handle(req, res)
#       "<h1>hello, world</h1>"
#     end
#   end
#   Tep.get "/", Root.new
#
#   Tep.run!(4567, 1, false)
#
# Sinatra-classic source (with `do ... end` blocks) is supported via
# `bin/tep build app.rb`, which translates blocks into Handler
# subclasses before invoking spinel.

require_relative "tep/version"
require_relative "tep/url"
require_relative "tep/multipart"
require_relative "tep/net"
require_relative "tep/agent_delegation"
require_relative "tep/identity"
# Auth + Broadcast + Presence data classes (no deps; storage on
# Tep::App references them, so they must load before app.rb).
require_relative "tep/auth_oauth2_client"
require_relative "tep/auth_oauth2_code"
require_relative "tep/broadcast_subscription"
require_relative "tep/presence_entry"
require_relative "tep/session"
require_relative "tep/request"
require_relative "tep/response"
require_relative "tep/handler"
require_relative "tep/filter"
require_relative "tep/streamer"
require_relative "tep/parser"
require_relative "tep/router"
require_relative "tep/app"
# Auth provider classes land after App so Tep::AuthFilter < Tep::Filter
# resolves and the install! helper can reach Tep::APP. References to
# Tep::Jwt / Tep::Json inside their method bodies resolve at runtime.
require_relative "tep/auth_bearer_token"
require_relative "tep/auth_session_cookie"
require_relative "tep/auth_oauth2"
require_relative "tep/auth"
require_relative "tep/broadcast"
require_relative "tep/presence"
require_relative "tep/live_view"
require_relative "tep/server"
require_relative "tep/server_scheduled"
require_relative "tep/sqlite"
require_relative "tep/pg"
require_relative "tep/json"
require_relative "tep/mcp"
require_relative "tep/logger"
require_relative "tep/jwt"
require_relative "tep/password"
require_relative "tep/security"
require_relative "tep/assets"
require_relative "tep/scheduler"
require_relative "tep/shell"
require_relative "tep/http"
require_relative "tep/proxy"
require_relative "tep/events"
require_relative "tep/llm"
require_relative "tep/openai_server"
require_relative "tep/websocket"
require_relative "tep/parallel"
require_relative "tep/job"

module Tep
  # Helper: spinel won't infer types on an empty `{}`, so we seed
  # with one entry then delete it. Used by Request/Response so
  # users get the natural Hash[] / Hash[]= surface (Sinatra-style
  # `params["name"]` works without a bespoke Bag wrapper).
  # Holder for a Fiber so we can keep them in a typed array.
  # Spinel's `[Fiber.new { ... }]` array literal infers IntArray
  # (Fiber is a built-in pointer type, not a user class spinel
  # tracks via PtrArray), so a one-attribute wrapper class is the
  # cheapest way to put them in a homogeneous container.
  class FiberSlot
    attr_accessor :f
    def initialize(f)
      @f = f
    end
  end

  def self.seed_fiber_noop
    0
  end

  # A canonical no-op fiber, used to type-seed Fiber-bearing
  # collections without running anything user-visible. The body is
  # a single method call (Fiber tests don't currently support
  # arbitrary inline-block bodies in spinel).
  def self.seed_fiber
    Fiber.new { Tep.seed_fiber_noop }
  end


  def self.str_hash
    h = {"" => ""}
    h.delete("")
    h
  end

  # str_find -- naive substring search returning the int position of
  # `needle` in `s` starting from `start`, or -1 if not found.
  #
  # History: workaround for spinel `0210389` which made `String#index`
  # return nil for not-found (was -1). spinel `28545ff` (matz/spinel#550)
  # added int|nil narrowing after an explicit nil-guard, so the
  # nil-side risk is upstream-resolved AND spinel supports the
  # offset overload `s.index(needle, start)` directly (emits
  # `sp_str_index_from_poly`). The helper stays solely for callsite
  # ergonomics: the 17 callers all use `if x < 0` style int comparison
  # (which can't narrow against int|nil under spinel's current
  # narrowing model). Removing it would require a mechanical
  # `< 0` -> `.nil?` refactor across http.rb / parser.rb / url.rb /
  # jwt.rb / app.rb. Worth doing eventually; not urgent.
  def self.str_find(s, needle, start)
    nlen = needle.length
    slen = s.length
    pos = start
    while pos <= slen - nlen
      if s[pos, nlen] == needle
        return pos
      end
      pos += 1
    end
    -1
  end

  # HTML-escape: minimum safe set for attribute and PCDATA contexts.
  # Used by the build-time Mustache compiler for the default
  # `{{var}}` (escaped) form. Char-by-char to avoid `gsub` (spinel's
  # gsub coverage on string-typed receivers is uneven).
  def self.h(s)
    out = ""
    i = 0
    n = s.length
    while i < n
      c = s[i]
      if c == "&"
        out = out + "&amp;"
      elsif c == "<"
        out = out + "&lt;"
      elsif c == ">"
        out = out + "&gt;"
      elsif c == "\""
        out = out + "&quot;"
      elsif c == "'"
        out = out + "&#39;"
      else
        out = out + c
      end
      i += 1
    end
    out
  end

  # Session signing secret. Empty by default, which disables session
  # writes (the Set-Cookie path no-ops). Set at app load time:
  #
  #   Tep.session_secret = ENV.fetch("TEP_SESSION_SECRET")
  #
  # Stored on the APP instance (spinel doesn't reliably type-track
  # module-level `@@cvars` or globals).

  APP = App.new

  def self.session_secret;     APP.session_secret;        end
  def self.session_secret=(v); APP.set_session_secret(v); end

  # Spinel infers method parameter types from concrete call sites.
  # If a user app never calls Tep.before / Tep.not_found / etc.,
  # spinel falls back to int and the underlying set_* assignment
  # mismatches the typed ivar. Force-calling each setter here with
  # the canonical default ensures the parameter type is locked in
  # regardless of which DSL methods the user app actually invokes.
  APP.set_static_root("")
  APP.set_before(Filter.new)
  APP.set_after(Filter.new)
  APP.set_auth_filter(Filter.new)
  APP.set_auth_bearer_secret("")
  # Broadcast PG-backend setter seeds. enable_pg_backend reaches
  # these via set_broadcast_pg_conn / _channel / _enabled when a
  # connect succeeds; the empty-conninfo seed below short-circuits
  # before getting there, so we exercise the setters directly.
  APP.set_broadcast_pg_enabled(0)
  APP.set_broadcast_pg_channel("")
  APP.set_broadcast_pg_conn(PG::Connection.new(""))
  APP.set_not_found(Handler.new)
  # Type-seeding: methods that may not be called by a given user app
  # would otherwise default their param C types to mrb_int and
  # mismatch the typed ivars they touch.
  _tep_seed_res = Response.new
  _tep_seed_res.set_cookie("", "", str_hash)
  APP.set_session_secret("")
  _tep_seed_sess = Session.new
  _tep_seed_sess.load_from("", "")
  _tep_seed_sess.to_cookie_value("")
  _tep_seed_sess.set("a", "")
  _tep_seed_sess.get("a")
  _tep_seed_sess.has?("a")
  _tep_seed_res.start_stream(Streamer.new)
  _tep_seed_stream = Stream.new(0)
  _tep_seed_res.streamer.pump(_tep_seed_stream)
  _tep_seed_stream.write("")   # pin the parameter type to :str
  Tep.h("")                    # pin Tep.h(s)'s param to :str
  # Multipart parser: pin all param types so the server-side
  # branches that call Tep::Multipart.parse have proper signatures
  # even when no user app exercises multipart on its own.
  Tep::Multipart.parse("", "")
  Tep::Multipart.extract_boundary("")
  Tep::Multipart.extract_field_name("")
  _tep_seed_res.start_websocket("", Tep::WebSocket::Driver.new(0))

  # AuthOAuth2 type-seeding. Every public cmeth needs at least one
  # top-level call so spinel locks the param C types in compile
  # units that don't otherwise exercise OAuth2 (e.g. test_llm.rb
  # builds an app that never touches Tep::AuthOAuth2; without
  # these seeds spinel defaults the params to mrb_int and the
  # AuthOAuth2Client / AuthOAuth2Code constructor calls inside
  # the methods mismatch the typed ivars).
  _tep_seed_oauth2_caps = [:_seed]
  _tep_seed_oauth2_caps.delete_at(0)
  Tep::AuthOAuth2.register_client("_seed", "", "", _tep_seed_oauth2_caps)
  Tep::AuthOAuth2.unregister_client("_seed")
  Tep::AuthOAuth2.find_client("_seed")
  _tep_seed_oauth2_code = Tep::AuthOAuth2.issue_code("_seed", "_seed", "", 0)
  Tep::AuthOAuth2.exchange_code(_tep_seed_oauth2_code, "_seed", 0)

  # Broadcast type-seeding. Same pattern: pin every cmeth's param C
  # types so compile units that don't otherwise exercise pub/sub
  # still get correct signatures.
  _tep_seed_broadcast_sub = Tep::Broadcast.subscribe("_seed", -1)
  Tep::Broadcast.subscribe_ws("_seed", -1)
  Tep::Broadcast.publish("_seed", "")
  Tep::Broadcast.subscribers_for("_seed")
  Tep::Broadcast.unsubscribe(_tep_seed_broadcast_sub)
  Tep::Broadcast.unsubscribe_fd(-1)
  Tep::Broadcast.subscriber_count
  Tep::Broadcast.clear

  # Broadcast PG-backend seeds. enable_pg_backend("", "") tries to
  # open a PG connection -- empty conninfo behaves the same as the
  # PG::Connection.new("") seed above: connect fails, returns -1.
  # The point is to pin parameter types on every cmeth.
  Tep::Broadcast.enable_pg_backend("", "")
  Tep::Broadcast.poll_pg_once(0)
  Tep::Broadcast.disable_pg_backend
  Tep::Broadcast.encode_wire("", "")
  Tep::Broadcast.deliver_wire_local("0:")
  Tep::Broadcast.publish_local_only("_seed", "")
  # The new PG::Connection LISTEN/NOTIFY method seeds live further
  # down with the rest of the PG seeds, where _tep_seed_pg_conn is
  # already defined.

  # Presence type-seeding. Same pattern as Broadcast: pin every
  # cmeth's param C types so compile units that don't otherwise
  # touch Presence still get correct signatures. track() requires
  # a req with a populated identity -- construct a synthetic one.
  _tep_seed_presence_caps = [:_seed]
  _tep_seed_presence_caps.delete_at(0)
  _tep_seed_presence_req = Tep::Request.new
  _tep_seed_presence_req.identity = Tep::Identity.new(
    "_seed", nil, _tep_seed_presence_caps)
  Tep::Presence.track(_tep_seed_presence_req, "_seed", -1)
  Tep::Presence.find_entry("_seed", -1)
  Tep::Presence.list("_seed")
  Tep::Presence.count("_seed")
  Tep::Presence.count_humans("_seed")
  Tep::Presence.count_agents("_seed")
  Tep::Presence.count_filtered("_seed", :both)
  Tep::Presence.set_status("_seed", -1, :busy, "", 0)
  Tep::Presence.clear_status("_seed", -1)
  Tep::Presence.untrack("_seed", -1)
  Tep::Presence.untrack_by_fd(-1)
  Tep::Presence.clear
  # Diff + auto-expiry seeds (chunk 3.2).
  Tep::Presence.diff_topic("_seed")
  _tep_seed_presence_entry = Tep::PresenceEntry.new(
    "_seed", "_seed", :human, "", -1, 0)
  Tep::Presence.encode_diff("join", _tep_seed_presence_entry)
  Tep::Presence.publish_diff("join", _tep_seed_presence_entry)
  Tep::Presence.sweep_expired_status
  # PG mirror seeds (chunk 3.3). enable_pg_mirror("") fails the
  # connect cleanly (-1) but still pins param types.
  Tep::Presence.enable_pg_mirror("")
  Tep::Presence.schema_sql
  Tep::Presence.mirror_insert(_tep_seed_presence_entry)
  Tep::Presence.mirror_delete("_seed", -1)
  Tep::Presence.mirror_status("_seed", -1, :available, "", 0)
  Tep::Presence.list_global("_seed")
  Tep::Presence.count_global("_seed")
  Tep::Presence.worker_schema_sql
  Tep::Presence.heartbeat
  Tep::Presence.prune_stale_workers(90)
  Tep::Presence.disable_pg_mirror
  # Same APP-setter-via-constant pattern as the broadcast_pg_conn
  # seed: PG::Connection.new can't run inside App#initialize
  # (Tep::APP is mid-construction; sched_current read segfaults).
  APP.set_presence_pg_enabled(0)
  APP.set_presence_pg_worker_id("")
  APP.set_presence_pg_conn(PG::Connection.new(""))

  # LiveView type-seeding (chunk 4.1). The render_page + dispatch_event
  # cmeths get pinned via top-level calls; the base-class mount /
  # render / handle_event imeths are pinned via a single noop
  # instance call so subclass dispatch widens cleanly.
  _tep_seed_live_view = Tep::LiveView.new
  _tep_seed_live_view_req = Tep::Request.new
  _tep_seed_live_view.mount(_tep_seed_live_view_req)
  _tep_seed_live_view.render
  _tep_seed_live_view.handle_event("", "", _tep_seed_live_view_req)
  _tep_seed_live_view.dispatch_event_json("{}", _tep_seed_live_view_req)
  _tep_seed_live_view.topic
  _tep_seed_live_view.broadcast_render
  _tep_seed_live_view.handle_presence_diff("{}")
  _tep_seed_live_view.apply_presence_diff_json("{}")
  Tep::LiveView.render_page("", "")

  # SQLite type-seeding. Each method below pins a parameter type
  # (or pulls the FFI return into use) so spinel emits the correct
  # signatures even for apps that include the require but don't hit
  # every method. We open an anonymous in-memory database, run a
  # tiny round-trip, then close -- the leak is one malloc'd handle
  # per process at startup, which exits with the worker.
  _tep_seed_db = Tep::SQLite.new
  if _tep_seed_db.open(":memory:")
    _tep_seed_db.exec("CREATE TABLE _seed (k TEXT, v INTEGER)")
    _tep_seed_db.prepare("INSERT INTO _seed (k, v) VALUES (?, ?)")
    _tep_seed_db.bind_str(1, "")
    _tep_seed_db.bind_int(2, 0)
    _tep_seed_db.step
    _tep_seed_db.finalize
    _tep_seed_db.last_rowid
    _tep_seed_db.prepare("SELECT k, v FROM _seed")
    _tep_seed_db.step
    _tep_seed_db.col_str(0)
    _tep_seed_db.col_int(1)
    _tep_seed_db.col_count
    _tep_seed_db.reset
    _tep_seed_db.finalize
    _tep_seed_db.first_str("SELECT k FROM _seed", "")
    _tep_seed_db.first_int("SELECT v FROM _seed", "")
    # Pin the prepare_cached param type so apps that don't call it
    # still see the FFI shape (`Sqlite.tep_sqlite_prepare_cached(int,
    # str)`) at module-load. Cache hit / miss / reuse paths are
    # exercised by test/test_sqlite_cached.rb at runtime.
    _tep_seed_db.prepare_cached("SELECT k FROM _seed")
    _tep_seed_db.step
    _tep_seed_db.finalize
    _tep_seed_db.close
  end

  # PG type-seeding. PG::Connection.new("") returns a connection-
  # failed instance (@pgh=-1) rather than raising, so this is safe
  # at module load regardless of whether libpq has a reachable
  # server. The point is to pin parameter / return types on every
  # public Connection / Result method so apps that don't exercise
  # one method still compile cleanly.
  _tep_seed_pg_conn = PG::Connection.new("")
  _tep_seed_pg_conn.connected?
  _tep_seed_pg_conn.status
  _tep_seed_pg_conn.transaction_status
  _tep_seed_pg_conn.server_version
  _tep_seed_pg_conn.error_message
  _tep_seed_pg_conn.escape_string("")
  _tep_seed_pg_conn.escape_identifier("")
  _tep_seed_pg_conn.escape_literal("")
  _tep_seed_pg_conn.last_sqlstate = ""
  _tep_seed_pg_conn.last_error_message = ""
  _tep_seed_pg_conn.last_result_rh = -1
  # Async surface seed -- calling these on a failed-conn instance
  # is harmless (the C shim short-circuits on conn slot < 1).
  _tep_seed_pg_conn.async_exec("")
  _tep_seed_pg_seed_arr = [""]
  _tep_seed_pg_seed_arr.delete_at(0)
  _tep_seed_pg_conn.async_exec_params("", _tep_seed_pg_seed_arr)
  # Async connect cmeth. Returns -1 for empty conninfo from a
  # non-scheduled context (the shim's PQconnectStart-then-FAILED
  # path), which is type-equivalent to the success path.
  PG::Connection.async_connect("")
  # LISTEN / NOTIFY surface (Tep::Broadcast PG backend lands here).
  _tep_seed_pg_conn.listen("_seed")
  _tep_seed_pg_conn.unlisten("_seed")
  _tep_seed_pg_conn.notify("_seed", "")
  _tep_seed_pg_conn.poll_notification(0)
  _tep_seed_pg_conn.last_notify_channel
  _tep_seed_pg_conn.last_notify_payload
  _tep_seed_pg_res = PG::Result.new(-1)
  _tep_seed_pg_res.ntuples
  _tep_seed_pg_res.nfields
  _tep_seed_pg_res.fname(0)
  _tep_seed_pg_res.fnumber("")
  _tep_seed_pg_res.ftype(0)
  _tep_seed_pg_res.fformat(0)
  _tep_seed_pg_res.fmod(0)
  _tep_seed_pg_res.getvalue(0, 0)
  _tep_seed_pg_res.getisnull(0, 0)
  _tep_seed_pg_res.getlength(0, 0)
  _tep_seed_pg_res.value(0, 0)
  _tep_seed_pg_res.error_field(67)
  _tep_seed_pg_res.cmd_status
  _tep_seed_pg_res.cmd_tuples
  _tep_seed_pg_res.error_message
  _tep_seed_pg_res.sql_state
  _tep_seed_pg_res.fields
  _tep_seed_pg_res.values
  _tep_seed_pg_res.column_values(0)
  _tep_seed_pg_res.clear
  _tep_seed_pg_conn.close
  # Pool seed -- size 0 so we don't try to open real conns at load.
  _tep_seed_pg_pool = PG::Pool.new("", 0)
  _tep_seed_pg_pool.healthy?
  _tep_seed_pg_pool.available
  _tep_seed_pg_pool.size
  _tep_seed_pg_pool.set_checkout_timeout_ms(0)
  _tep_seed_pg_pool.close_all
  # NB: don't checkout/checkin against the size-0 seed pool; it'd
  # spin until timeout. The seed has @free.length=0 forever.

  # Tep::Json type-seeding. Pin every public method's parameter
  # types so an app that uses one method but not another still
  # compiles cleanly. Calls have no side effects beyond producing
  # discardable strings.
  Tep::Json.escape("")
  Tep::Json.quote("")
  Tep::Json.encode_pair_str("", "")
  Tep::Json.encode_pair_int("", 0)
  _tep_seed_str_h = Tep.str_hash
  _tep_seed_str_h["k"] = "v"
  Tep::Json.from_str_hash(_tep_seed_str_h)
  _tep_seed_int_h = {"" => 0}
  _tep_seed_int_h.delete("")
  _tep_seed_int_h["k"] = 1
  Tep::Json.from_int_hash(_tep_seed_int_h)

  # Tep::Logger seed -- pin parameter types for every method even
  # when an app uses one but not another. The level-name string
  # ("info") and the messages ("") pin the :str shape; the file-
  # path setter pins to_file's :str arg.
  _tep_seed_logger = Tep::Logger.new
  _tep_seed_logger.set_level("info")
  _tep_seed_logger.to_file("")
  _tep_seed_logger.to_stderr
  _tep_seed_logger.debug("")
  _tep_seed_logger.info("")
  _tep_seed_logger.warn("")
  _tep_seed_logger.error("")
  Tep::Logger.level_value("info")

  # Tep::Jwt seed -- pin every method's :str arg types. The
  # secret + payload are blank but the call shapes pin the FFI
  # signature dispatch.
  Tep::Jwt.encode_hs256("", "")
  Tep::Jwt.verify_hs256("", "")
  Tep::Jwt.decode_payload("")
  Tep::Jwt.verify_and_decode("", "")
  Tep::Jwt.timing_safe_eq("", "")

  # Tep::Password seed -- one cheap PBKDF2 round at startup, just
  # to pin every method's parameter types. iters=1 keeps the cost
  # negligible.
  _tep_seed_pwd_hash = Tep::Password.hash("seed")
  Tep::Password.verify("seed", _tep_seed_pwd_hash)
  Tep::Password.split4("a$b$c$d")

  # Tep::Security seeding -- pin the filter classes' params.
  _tep_seed_cors = Tep::Security::Cors.new
  _tep_seed_cors.set_origin("")
  _tep_seed_cors.set_allowed_verbs("")
  _tep_seed_cors.set_allowed_headers("")
  _tep_seed_cors.set_max_age(0)
  _tep_seed_hdrs = Tep::Security::Headers.new
  _tep_seed_hdrs.set_hsts(0)

  # Tep::Assets seed -- pin the str args before any user-supplied
  # _add calls land. The asset hash starts empty; user apps that
  # have `<app>/assets/` get _add lines emitted by bin/tep at
  # build time.
  Tep::Assets._add("", "", "")
  Tep::Assets.has?("")
  _tep_seed_assets_res = Response.new
  Tep::Assets.serve("", _tep_seed_assets_res)

  # Tep::Scheduler seed -- run every public method once so spinel
  # pins the param/return types. The seed Fiber's body is an
  # immediately-finishing Tep.seed_fiber_noop, so resume + tick are
  # cheap. io_wait gets seeded outside any fiber context, which
  # exercises the idx < 0 single-shot poll path (fd=-1 returns
  # immediately on most kernels with a POLLNVAL, which we collapse
  # to 0 in sphttp_poll_ready).
  _tep_seed_fiber = Tep.seed_fiber
  Tep::Scheduler.spawn_fiber(_tep_seed_fiber)
  Tep::Scheduler.tick(0)
  Tep::Scheduler.poll_round(0)
  Tep::Scheduler.any_io_waiter
  Tep::Scheduler.alive_count
  Tep::Scheduler.next_wake
  Tep::Scheduler.run_until_empty
  Tep::Scheduler.run_for(0)
  Tep::Scheduler.pause(0)
  Tep::Scheduler.io_wait(-1, Tep::Scheduler::READ, 0)
  Tep::Scheduler.clear

  # Tep::Shell seed -- pin :str args at the FFI boundary.
  Tep::Shell.run(":")
  Tep::Shell.run_limited(":", 1)
  Tep::Shell.read("/etc/hostname")
  Tep::Shell.read_limited("/etc/hostname", 64)

  # Tep::Url seed -- the new split_url has to land at compile time.
  Tep::Url.split_url("http://x/")

  # Tep::Http seed -- every public method gets one canonical call so
  # spinel pins the param types. The URL "http://127.0.0.1:1/" won't
  # connect; send_req returns the empty Response, which is the
  # type-pinning behaviour we want without any real I/O.
  _tep_seed_http_headers = Tep.str_hash
  _tep_seed_http_headers["k"] = "v"
  Tep::Http.send_req("GET", "http://127.0.0.1:1/", "", _tep_seed_http_headers)
  Tep::Http.get("http://127.0.0.1:1/")
  Tep::Http.post("http://127.0.0.1:1/", "")
  Tep::Http.put("http://127.0.0.1:1/", "")
  Tep::Http.patch("http://127.0.0.1:1/", "")
  Tep::Http.delete("http://127.0.0.1:1/")
  Tep::Http.head("http://127.0.0.1:1/")
  Tep::Http.empty_headers
  # Pool seed (chunk 6.7a). Pin the (str, int) -> int / (int, str, int) -> int
  # arities so the FFI bindings resolve. Each call site exercises one
  # primitive against the empty pool -- harmless at boot.
  Tep::Http::Pool.claim("127.0.0.1", 1)
  Tep::Http::Pool.release(-1, "127.0.0.1", 1)
  Tep::Http::Pool.close_idle(30)
  Tep::Http::Pool.stats
  _tep_seed_http = Tep::Http.new("http://127.0.0.1:1")
  _tep_seed_http.set_header("k", "v")
  _tep_seed_http.do_get("/")
  _tep_seed_http.do_post("/", "")
  _tep_seed_http.do_put("/", "")
  _tep_seed_http.do_patch("/", "")
  _tep_seed_http.do_delete("/")
  _tep_seed_http.do_head("/")
  # parse_response and index_from are internal; let spinel infer
  # their types from the send_req call site rather than seeding
  # separately (which widens `out` to poly).

  # Tep::Proxy seed -- a base-class Proxy instance pins the handler
  # slot + every overridable hook signature so subclass call sites
  # in user code resolve cleanly (same idiom as set_before(Filter.new)
  # and the Parallel/Job seeds). handle() exercises the full forward
  # path against a dead port (status 0 -> 502), which fails fast like
  # the Tep::Http seed above.
  _tep_seed_proxy     = Tep::Proxy.new("http://127.0.0.1:1")
  _tep_seed_proxy_req = Tep::Request.new
  _tep_seed_proxy_res = Response.new
  _tep_seed_proxy_ureq = Tep::Proxy::UpstreamRequest.new
  _tep_seed_proxy_ureq.set_header("k", "v")
  _tep_seed_proxy.rewrite_path("/")
  _tep_seed_proxy.before_forward(_tep_seed_proxy_req, _tep_seed_proxy_res, _tep_seed_proxy_ureq)
  _tep_seed_proxy.after_forward(_tep_seed_proxy_req, Tep::Http::Response.new, _tep_seed_proxy_res)
  _tep_seed_proxy.handle(_tep_seed_proxy_req, _tep_seed_proxy_res)
  Tep::Proxy.hop_by_hop?("connection")
  # Streaming surface (chunk 6.2). Pin the hook signatures + the
  # UpstreamHead parser + the proxy's non-IO pump helpers. run_stream,
  # pump and read_upstream_head are NOT called here -- they do blocking
  # io_wait on a real fd; their param/return types self-pin from their
  # bodies, and ProxyStreamer flows into res.start_stream from
  # start_streaming_forward (statically reachable from handle), which
  # wires ProxyStreamer.pump (-> run_stream) into the Streamer dispatch.
  # 6.4 per-request upstream picker. Pin the Tep::Request param +
  # the :str return so subclass overrides resolve cleanly.
  _tep_seed_proxy.pick_upstream(_tep_seed_proxy_req)
  # 6.6 body-cap accessors. Type-pin the int setters / getters so
  # subclass overrides + block-DSL setters compile.
  _tep_seed_proxy.max_request_body_bytes  = 1
  _tep_seed_proxy.max_response_body_bytes = 1
  # 6.5 retry policy. Pin the RetryPolicy slot via instantiation +
  # the hook return type via a call to #retry_policy(req).
  _tep_seed_retry_policy = Tep::Proxy::RetryPolicy.new
  _tep_seed_retry_policy.max_attempts        = 1
  _tep_seed_retry_policy.base_backoff_ms     = 0
  _tep_seed_retry_policy.backoff_multiplier  = 2
  _tep_seed_retry_policy.retry_on_status     = [502, 503, 504]
  # Float-seconds setter (#133). Pin the Float -> int(ms) lowering
  # so the conversion call site resolves.
  _tep_seed_retry_policy.base_backoff_secs = 0.0
  _tep_seed_retry_policy.base_backoff_secs
  # Pin Sock.sphttp_sleep_ms's :int param so the backoff call site
  # resolves (called from Tep::Proxy#handle).
  Sock.sphttp_sleep_ms(0)
  # Tep::Json.get_float seed (#133). Pin the (String, String) -> Float
  # surface so callers (CompletionsHandler temperature/top_p,
  # backends that parse their own bodies) resolve cleanly.
  Tep::Json.get_float("{\"temperature\":0.7}", "temperature")
  _tep_seed_retry_policy.backoff_for(0)
  _tep_seed_retry_policy.retriable?(502)
  _tep_seed_proxy.retry_policy(_tep_seed_proxy_req)
  _tep_seed_proxy.stream_request?(_tep_seed_proxy_req)
  _tep_seed_pstats = Tep::Proxy::StreamStats.new
  _tep_seed_pchunk = Tep::Proxy::StreamChunk.new("data: x\n\n")
  _tep_seed_proxy.on_stream_chunk(_tep_seed_pchunk, _tep_seed_stream, _tep_seed_pstats)
  _tep_seed_proxy.on_stream_end(_tep_seed_proxy_req, _tep_seed_stream, _tep_seed_pstats)
  _tep_seed_proxy.drain_events(_tep_seed_stream, _tep_seed_pstats, "data: x\n\n")
  _tep_seed_proxy.dispatch_one(_tep_seed_stream, _tep_seed_pstats, "data: x\n\n")
  _tep_seed_uhead = Tep::Proxy::UpstreamHead.new
  _tep_seed_uhead.fill_from("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked")
  _tep_seed_pstreamer = Tep::Proxy::ProxyStreamer.new
  _tep_seed_pstreamer.proxy = _tep_seed_proxy
  _tep_seed_proxy_res.start_stream(_tep_seed_pstreamer)

  # Tep::Events seed (toy/v1 emitter). Seeded with a disabled ("")
  # path so the guards short-circuit before any File I/O at boot;
  # the JSON-building bodies + sphttp_iso8601_utc call still compile
  # statically, and the call args pin every param type.
  _tep_seed_events = Tep::Events.new("")
  _tep_seed_events.enabled?
  _tep_seed_events.run_start("host", "cpu", "model", "/path", "{}")
  _tep_seed_events.inference("model", 0, 0, 0, "{}")
  _tep_seed_events.record_error
  _tep_seed_events.run_end("ok")
  # #128: aggregated run_end (parent reads JSONL + sums). The seed
  # path is "" so the call short-circuits before any File I/O at
  # boot; this exists to pin the method's surface area so spinel's
  # codegen emits it.
  _tep_seed_events.run_end_aggregated("completed")
  _tep_seed_events.rel_t
  Sock.sphttp_iso8601_utc(0)

  # Tep::Llm::OpenAI::Server seed (Battery 7, chunk 7.1a). Pin the
  # Backend slot + interface + the ModelsHandler dispatch through
  # APP.openai_backend. serve! is NOT called here -- it mounts a route
  # (a global side effect); its types self-pin from its body.
  _tep_seed_oai_backend = Tep::Llm::OpenAI::Backend.new
  Tep::APP.set_openai_backend(_tep_seed_oai_backend)
  # 7.1c openai_events slot. Re-uses _tep_seed_events (already declared
  # above as the Tep::Events seed). Pins APP.openai_events so the route
  # handlers' `Tep::APP.openai_events.inference(...)` dispatch resolves.
  Tep::APP.set_openai_events(_tep_seed_events)
  Tep::Llm::OpenAI::Server.use(_tep_seed_oai_backend)
  _tep_seed_oai_backend.list_models
  _tep_seed_oai_backend.supports_chat?
  _tep_seed_oai_backend.device_kind
  _tep_seed_oai_backend.supports_embeddings?
  _tep_seed_oai_models = Tep::Llm::OpenAI::ModelsHandler.new
  _tep_seed_oai_models.handle(_tep_seed_proxy_req, _tep_seed_proxy_res)
  # 7.1b /v1/completions surface.
  Tep::Json.get_int_array("{}", "prompt")
  _tep_seed_oai_sampling = Tep::Llm::OpenAI::Sampling.new
  _tep_seed_oai_sampling.max_tokens  = 0
  _tep_seed_oai_sampling.temperature = 1.0
  _tep_seed_oai_sampling.top_p       = 1.0
  _tep_seed_oai_comp = Tep::Llm::OpenAI::Completion.new
  _tep_seed_oai_backend.generate_from_tokens("m", Tep::Json.get_int_array("{}", "prompt"), _tep_seed_oai_sampling)
  _tep_seed_oai_completions = Tep::Llm::OpenAI::CompletionsHandler.new
  _tep_seed_oai_completions.handle(_tep_seed_proxy_req, _tep_seed_proxy_res)
  # Chat completions skeleton (POST /v1/chat/completions). Default
  # backend.supports_chat? is false -> ChatCompletionsHandler returns
  # 501; the override path (supports_chat? = true, chat_completion
  # overridden) dispatches to the backend's chat_completion. Pin
  # Backend#chat_completion's `req` param + the ChatCompletionsHandler
  # dispatch through APP.openai_backend.
  _tep_seed_oai_backend.chat_completion(_tep_seed_proxy_req)
  # parse_messages helper. Type-pin the [Tep::Llm::Message] return so
  # backends that call `messages = Tep::Llm::OpenAI.parse_messages(...)`
  # get a typed array.
  Tep::Llm::OpenAI.parse_messages(
    "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
  Tep::Llm::OpenAI.find_obj_key_str("{}", 0, 2, "role")
  _tep_seed_oai_chat = Tep::Llm::OpenAI::ChatCompletionsHandler.new
  _tep_seed_oai_chat.handle(_tep_seed_proxy_req, _tep_seed_proxy_res)
  # 7.2 streaming completions: pin StreamSink + CompletionsStreamer
  # slots + exercise the backend's generate_stream_from_tokens(sink)
  # arity so the param type resolves. emit_token is called against a
  # fd=-1 Stream -- the seed never runs the actual write (the streamer
  # pump is never invoked at boot), it just gives spinel the surface.
  _tep_seed_oai_stream = Tep::Stream.new(-1)
  _tep_seed_oai_sink = Tep::Llm::OpenAI::StreamSink.new
  _tep_seed_oai_sink.out   = _tep_seed_oai_stream
  _tep_seed_oai_sink.model = "m"
  _tep_seed_oai_sink.completion_count
  # emit_token call site pins the `piece` parameter to String. fd=-1
  # makes the underlying sphttp_write_chunk a harmless EBADF at boot.
  _tep_seed_oai_sink.emit_token("seed")
  _tep_seed_oai_backend.generate_stream_from_tokens(
    "m", Tep::Json.get_int_array("{}", "prompt"), _tep_seed_oai_sampling, _tep_seed_oai_sink)
  _tep_seed_oai_cstreamer = Tep::Llm::OpenAI::CompletionsStreamer.new
  _tep_seed_oai_cstreamer.model         = "m"
  _tep_seed_oai_cstreamer.token_ids     = Tep::Json.get_int_array("{}", "prompt")
  _tep_seed_oai_cstreamer.sampling      = _tep_seed_oai_sampling
  _tep_seed_oai_cstreamer.prompt_tokens = 0
  _tep_seed_oai_cstreamer.t0            = 0
  _tep_seed_oai_cstreamer.request_id    = ""
  _tep_seed_oai_cstreamer.principal_id  = ""
  _tep_seed_proxy_res.start_stream(_tep_seed_oai_cstreamer)

  # Tep::Shell.write seed.
  Tep::Shell.write("/dev/null", "")

  # Tep::Parallel seed -- a base-class Parallel instance pins the
  # `worker` slot type to ParallelWorker; subclass call sites at
  # user code get auto-cast (same idiom as set_before(Filter.new)).
  _tep_seed_par = Tep::Parallel.new(Tep::ParallelWorker.new)
  _tep_seed_par_items = [""]
  _tep_seed_par_items.delete_at(0)
  _tep_seed_par.map_processes(_tep_seed_par_items)
  _tep_seed_par.each_process(_tep_seed_par_items)
  Tep::Parallel.scratch_dir

  # Tep::Job seed -- pin every public-surface method's parameter
  # types against an in-memory SQLite so the leak is one malloc'd
  # handle per process at startup. The base `perform(arg)` is also
  # pinned to :str so subclass overrides resolve cleanly.
  Tep::Job.init_schema(":memory:")
  _tep_seed_job = Tep::Job.new
  _tep_seed_job.perform("")
  Tep::Job.enqueue("seed", "", ":memory:")
  Tep::Job.fetch_next(":memory:")
  Tep::Job.mark_done(":memory:", 0, "")
  Tep::Job.mark_failed(":memory:", 0)
  _tep_seed_str_arr = [""]
  _tep_seed_str_arr.delete_at(0)
  Tep::Json.from_str_array(_tep_seed_str_arr)
  _tep_seed_int_arr = [0]
  _tep_seed_int_arr.delete_at(0)
  Tep::Json.from_int_array(_tep_seed_int_arr)
  Tep::Json.get_str("{}", "")
  Tep::Json.get_int("{}", "")
  Tep::Json.has_key?("{}", "")

  # Tep::MCP seeds (chunk 5.1). Tools register at compile time via
  # bin/tep's mcp_tool DSL; the runtime helpers below are the
  # shared shapes the translator-emitted dispatcher leans on.
  # Seed both Result-construction paths so neither widens via the
  # "no concrete caller -> int default" route. Read text + is_error
  # off both so attr_accessor types pin to String / Integer.
  _tep_seed_mcp_result     = Tep::MCP.text("seed")
  _tep_seed_mcp_result_err = Tep::MCP.error("seed")
  Tep::MCP.nested_extract("{}", "")
  Tep::MCP.initialize_envelope(0, "", "")
  Tep::MCP.tools_list_envelope(0, "[]")
  Tep::MCP.tools_call_envelope(0, "", 0)
  Tep::MCP.tools_call_envelope(0, "", 1)
  Tep::MCP.unknown_tool_envelope(0, "")
  Tep::MCP.method_not_found_envelope(0, "")
  # Resource seeds (chunk 5.3). resource_text gives us a typed
  # ResourceContent for the resources/read path; the envelope
  # builders take scalars to keep param-type inference tight.
  _tep_seed_mcp_rc = Tep::MCP.resource_text("seed-uri", "seed-text")
  _tep_seed_mcp_rc_uri  = _tep_seed_mcp_rc.uri
  _tep_seed_mcp_rc_mime = _tep_seed_mcp_rc.mime
  _tep_seed_mcp_rc_text = _tep_seed_mcp_rc.text
  Tep::MCP.resources_list_envelope(0, "[]")
  Tep::MCP.resources_read_envelope(0, "", "text/plain", "")
  Tep::MCP.unknown_resource_envelope(0, "")

  # Tep::Llm seeds. attr_accessor return types default to mrb_int
  # if spinel sees no concrete callsite -- and Tep::Llm.build_request_body
  # passes msg.role / msg.content into Tep::Json.quote(String) which
  # then mismatches. Pin Message + Response attrs to String, and
  # run one full encode + parse round-trip so the static analyzer
  # sees every public method called with concrete types.
  _tep_seed_llm_msg = Tep::Llm::Message.new("user", "")
  _tep_seed_llm_msg.role = ""
  _tep_seed_llm_msg.content = ""
  _tep_seed_llm_msgs = [_tep_seed_llm_msg]
  Tep::Llm.build_request_body("", "", _tep_seed_llm_msgs)
  _tep_seed_llm_resp = Tep::Llm::Response.new
  _tep_seed_llm_resp.content = ""
  _tep_seed_llm_resp.role = ""
  _tep_seed_llm_resp.stop_reason = ""
  _tep_seed_llm_http_res = Tep::Http::Response.new
  Tep::Llm.parse_response(_tep_seed_llm_http_res)
  Tep::Llm.extract_str_field("", "", 0)
  _tep_seed_llm_client = Tep::Llm.new("")
  _tep_seed_llm_client.set_model("")
  _tep_seed_llm_client.set_api_key("")
  _tep_seed_llm_client.set_system_prompt("")
  # Streaming surface seeds. The chat_stream signature wants a
  # Tep::Stream `out_stream` -- using fd=0 (stdin) for the seed
  # never executes the .write path here (this block runs at module
  # init; the chat_stream call below is type-seed-only and would
  # need a real connection to actually fire). Tep::Llm::StreamState
  # likewise pinned via attr writes.
  _tep_seed_llm_state = Tep::Llm::StreamState.new
  _tep_seed_llm_state.acc      = ""
  _tep_seed_llm_state.leftover = ""
  _tep_seed_llm_state.done     = false
  _tep_seed_llm_stream = Tep::Stream.new(0)
  Tep::Llm.consume_sse_events(_tep_seed_llm_stream, _tep_seed_llm_state)
  Tep::Llm.dechunk_consume("")
  Tep::Llm.dechunk_leftover("")
  Tep::Llm.dechunk_pass("")
  Tep::Llm.drain_sse_buf("", _tep_seed_llm_stream, "")
  Tep::Llm.hex_to_int("")

  # Tep::WebSocket seeds. Pins frame/handshake/driver/connection
  # surfaces to concrete typed callsites so the analyzer doesn't
  # default param types to mrb_int.
  _tep_seed_ws_frame = Tep::WebSocket::Frame.new(true, 1, "")
  _tep_seed_ws_frame.fin     = true
  _tep_seed_ws_frame.opcode  = 1
  _tep_seed_ws_frame.payload = ""
  _tep_seed_ws_frame.encode_unmasked
  Tep::WebSocket::Frame.byte_to_chr(0)
  Tep::WebSocket::Frame.parse_from_buf(0, 0)
  Tep::WebSocket::Frame.reserved_opcode?(0)
  Tep::WebSocket::Frame.control_opcode?(0)
  _tep_seed_ws_pr = Tep::WebSocket::ParseResult.new
  _tep_seed_ws_pr.outcome    = ""
  _tep_seed_ws_pr.consumed   = 0
  _tep_seed_ws_pr.close_code = 0
  _tep_seed_ws_pr.frame      = _tep_seed_ws_frame
  _tep_seed_ws_hsres = Tep::WebSocket::Handshake::Result.new
  _tep_seed_ws_hsres.valid      = false
  _tep_seed_ws_hsres.reason     = ""
  _tep_seed_ws_hsres.accept_key = ""
  Tep::WebSocket::Handshake.build_response("", "")
  Tep::WebSocket::Handshake.icontains("", "")
  Tep::WebSocket::Handshake.downcase("")
  Tep::WebSocket::Handshake.trim("")
  _tep_seed_ws_csv = Tep::WebSocket::Handshake.split_csv("")
  _tep_seed_ws_handler = Tep::WebSocket::Handler.new
  _tep_seed_ws_event   = Tep::WebSocket::Event.new
  _tep_seed_ws_event.data   = ""
  _tep_seed_ws_event.code   = 0
  _tep_seed_ws_event.reason = ""
  _tep_seed_ws_handler.handle_event(_tep_seed_ws_event)
  _tep_seed_ws_drv = Tep::WebSocket::Driver.new(0)
  _tep_seed_ws_drv.set_max_frame_size(0)
  _tep_seed_ws_drv.set_subprotocol("")
  _tep_seed_ws_drv.set_on_open(_tep_seed_ws_handler)
  _tep_seed_ws_drv.set_on_message(_tep_seed_ws_handler)
  _tep_seed_ws_drv.set_on_close(_tep_seed_ws_handler)
  _tep_seed_ws_drv.set_on_ping(_tep_seed_ws_handler)
  _tep_seed_ws_drv.set_on_pong(_tep_seed_ws_handler)
  _tep_seed_ws_drv.set_on_error(_tep_seed_ws_handler)
  _tep_seed_ws_drv.text("")
  _tep_seed_ws_drv.binary("")
  _tep_seed_ws_drv.ping("")
  _tep_seed_ws_drv.pong("")
  _tep_seed_ws_drv.close(1000, "")
  Tep::WebSocket::Driver.encode_close_payload(0, "")
  _tep_seed_ws_conn = Tep::WebSocket::Connection.new(_tep_seed_ws_drv)
  _tep_seed_ws_conn.set_idle_timeout(0)
  _tep_seed_ws_cs = Tep::WebSocket::ConnectionState.new
  _tep_seed_ws_cs.start = 0
  _tep_seed_ws_cs.avail = 0

  # ---------------- DSL ----------------
  # Spinel emits every defined method whether called or not, and
  # infers parameter types from concrete call sites; methods nobody
  # calls fall back to int parameters that mismatch the typed ivars
  # they assign. So the v0.1 surface only exposes what the bundled
  # demos actually use; richer DSL methods (before/after/not_found)
  # are layered on as the demos grow to exercise them.

  def self.get(pattern, handler);     APP.add_route("GET",     pattern, handler); end
  def self.post(pattern, handler);    APP.add_route("POST",    pattern, handler); end
  def self.put(pattern, handler);     APP.add_route("PUT",     pattern, handler); end
  def self.patch(pattern, handler);   APP.add_route("PATCH",   pattern, handler); end
  def self.delete(pattern, handler);  APP.add_route("DELETE",  pattern, handler); end


  def self.public_dir(root)
    APP.set_static_root(root)
  end

  def self.before(filter)
    APP.set_before(filter)
  end

  def self.after(filter)
    APP.set_after(filter)
  end

  def self.not_found(handler)
    APP.set_not_found(handler)
  end

  # ARGV access only emits `sp_argv` when used at top level, so the
  # translator emits the option-parsing loop itself before calling
  # `Tep.run!`. The `scheduled` flag picks between the prefork
  # blocking server (default) and the fiber-per-connection
  # Tep::Server::Scheduled (opt-in via `set :scheduler, :scheduled`
  # in the app source, or `-s` on the CLI). At the next major tep
  # release Scheduled becomes the default and Blocking is deleted;
  # the parallel-classes period exists only to make the rollback
  # path obvious during the transition.
  #
  # Single dispatch method (rather than parallel run! / run_scheduled!)
  # because spinel's codegen mis-declares heap-cell parameters when
  # two same-arity sibling methods are called from an if/else --
  # both branches reference `quiet` as a heap-cell but only the first
  # path declares it. Bundling the decision inside one method
  # sidesteps the codegen miss.
  #
  # `scheduled` defaults to false so apps that ship the historical
  # 3-arg call (Tep.run!(port, workers, quiet)) keep building. Spinel
  # accepts the call without the 4th arg only because it supports
  # default-value params; without this, the 3-arg call silently
  # miscompiled (matz/spinel arity-warning shape, tep#13).
  def self.run!(port, workers, quiet, scheduled = false)
    if scheduled
      Server::Scheduled.new(APP).run(port, workers, quiet)
    else
      Server.new(APP).run(port, workers, quiet)
    end
  end

  # Called by the SERVER PARENT (workers>1) or the single process
  # (workers=1) at SIGTERM/SIGINT, AFTER the worker children have
  # exited. Children no longer emit run_end themselves -- #128 moved
  # the emission here so a multi-worker deployment writes exactly ONE
  # run_end with aggregated stats from the events.jsonl, not N per
  # worker.
  #
  # reason: "completed" -- matches toy/v1 vocabulary (was "ok"; #115).
  # Cheap when nothing is configured: openai_events is seeded with an
  # empty path, whose enabled? short-circuits.
  def self.on_shutdown
    if APP.openai_events.enabled?
      APP.openai_events.run_end_aggregated("completed")
    end
    0
  end
end
