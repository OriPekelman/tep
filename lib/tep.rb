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
require_relative "tep/server_scheduled"
require_relative "tep/sqlite"
require_relative "tep/json"
require_relative "tep/logger"
require_relative "tep/jwt"
require_relative "tep/password"
require_relative "tep/security"
require_relative "tep/assets"
require_relative "tep/scheduler"
require_relative "tep/shell"
require_relative "tep/http"
require_relative "tep/llm"
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
  def self.run!(port, workers, quiet, scheduled)
    if scheduled
      Server::Scheduled.new(APP).run(port, workers, quiet)
    else
      Server.new(APP).run(port, workers, quiet)
    end
  end
end
