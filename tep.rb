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

# --- stock-Ruby guard --------------------------------------------------
# tep's lib/ is Spinel-AOT source: it's COMPILED into a native binary
# (or inlined by `tep build`), not run under CRuby. A plain
# `require "tep"` on MRI/JRuby/TruffleRuby has no FFI runtime and would
# otherwise die with a cryptic `undefined method 'ffi_cflags'` deep in a
# sub-file. RUBY_ENGINE is defined on every stock Ruby but NOT in a
# Spinel binary, so this fires only under a real `require` and stays a
# dead no-op once compiled (it inlines harmlessly into every app).
if defined?(RUBY_ENGINE)
  raise "tep is a Spinel-AOT framework, not a CRuby library -- " \
        "`require \"tep\"` has no runtime here. tep compiles your " \
        "Sinatra-style app to a native binary; build it with the " \
        "translator:\n" \
        "    tep build app.rb && ./app -p 4567\n" \
        "or declare `gem \"tep\"` in a bundler-spinel (spinelgems) " \
        "Gemfile and let `spinel-compat vendor` inline it. " \
        "See https://github.com/OriPekelman/tep"
end

require_relative "tep/version"
require "spinel_kit/url"
require "spinel_kit/hex"
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
require_relative "tep/cache"
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
# tep/pg is OPT-IN (#216): NOT required here. An app that needs
# PostgreSQL does `require "tep/pg"`, which bin/tep splices in at build
# time (and the test suite requires explicitly). Keeping it out of the
# core require tree is what lets a non-PG app DCE the libpq closure.
require_relative "tep/json"
require_relative "tep/json_decoder"
require_relative "tep/mcp"
require "spinel_kit/log"
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

  # Read a request cookie. A missing cookie reads as "" -- that is the
  # documented `cookies["k"]` DSL contract (test_cookies pins it) --
  # while the underlying hash reads nil for a missing key. bin/tep
  # rewrites `cookies[k]` reads to this call.
  def self.cookie(req, k)
    v = req.cookies[k]
    v = "" if v.nil?
    v
  end

  # Read a request param. A missing param reads as "" -- tep's
  # documented `params[k]` DSL contract (test_params pins it; a
  # deliberate divergence from sinatra's nil, ledgered in
  # docs/mirrors/sinatra.md). bin/tep rewrites `params[k]` reads to
  # this call; direct `req.params[...]` access keeps raw Hash
  # semantics (nil on miss).
  def self.param(req, k)
    v = req.params[k]
    v = "" if v.nil?
    v
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

  # Inbound TLS (tep#148 phase 2). Point these at a PEM cert + key and
  # Tep::Server terminates HTTPS itself; unset (default) = plain HTTP.
  #   Tep.tls_cert = "cert.pem"; Tep.tls_key = "key.pem"
  def self.tls_cert;     APP.tls_cert;        end
  def self.tls_cert=(v); APP.set_tls_cert(v); end
  def self.tls_key;      APP.tls_key;         end
  def self.tls_key=(v);  APP.set_tls_key(v);  end

  # Type contract (tep#199): method param/return/ivar types are
  # pinned by tep's own sig/*.rbs via `spinel --rbs sig` (wired in
  # bin/tep). This replaces the module-load `_tep_seed_*` block that
  # used to force every setter/method call to lock its FFI types --
  # which also did real I/O at boot (a bare-container hazard, #223).
  # App#initialize (tep/app.rb) still establishes all runtime
  # defaults; only the type-seeding calls are gone.

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
  def self.options(pattern, handler); APP.add_route("OPTIONS", pattern, handler); end
  # head routes match explicitly; a HEAD with no head route serves the
  # GET route body-less (App#dispatch fallback, tep#246). This method
  # was MISSING although DSL_VERBS advertised it -- an explicit `head`
  # route in an app could never compile before the #246 work.
  def self.head(pattern, handler);    APP.add_route("HEAD",    pattern, handler); end


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
