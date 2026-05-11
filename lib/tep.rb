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
#   Tep.run!(4567, 1)
#
# Sinatra-classic source (with `do ... end` blocks) is supported via
# `bin/tep build app.rb`, which translates blocks into Handler
# subclasses before invoking spinel.

require_relative "tep/version"
require_relative "tep/url"
require_relative "tep/net"
require_relative "tep/session"
require_relative "tep/request"
require_relative "tep/response"
require_relative "tep/handler"
require_relative "tep/filter"
require_relative "tep/streamer"
require_relative "tep/parser"
require_relative "tep/router"
require_relative "tep/app"
require_relative "tep/server"
require_relative "tep/sqlite"
require_relative "tep/json"
require_relative "tep/logger"
require_relative "tep/jwt"
require_relative "tep/password"
require_relative "tep/security"
require_relative "tep/assets"
require_relative "tep/scheduler"

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
    _tep_seed_db.close
  end

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
  Tep::Scheduler.sleep(0)
  Tep::Scheduler.io_wait(-1, Tep::Scheduler::READ, 0)
  Tep::Scheduler.clear
  _tep_seed_str_arr = [""]
  _tep_seed_str_arr.delete_at(0)
  Tep::Json.from_str_array(_tep_seed_str_arr)
  _tep_seed_int_arr = [0]
  _tep_seed_int_arr.delete_at(0)
  Tep::Json.from_int_array(_tep_seed_int_arr)
  Tep::Json.get_str("{}", "")
  Tep::Json.get_int("{}", "")
  Tep::Json.has_key?("{}", "")

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
  # `Tep.run!`. This stays a plain three-arg dispatch.
  def self.run!(port, workers, quiet)
    Server.new(APP).run(port, workers, quiet)
  end
end
