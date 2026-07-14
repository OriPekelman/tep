module Sock
  ffi_cflags "/home/oripekelman/sites/tep/tep/sphttp.o"
  # Outbound TLS (sphttp_connect_tls) is backed by the system
  # libssl/libcrypto. Linked for every app (like sqlite3 elsewhere);
  # the plaintext path never calls into it, so apps that make no HTTPS
  # requests pay only the link cost, not runtime. See tep#148.
  #
  # OpenSSL include/lib paths come via @TEP_SPHTTP_CFLAGS@ (the
  # pkg_config sibling in spinel-ext.json -- `pkg-config openssl`,
  # fallback `-lssl -lcrypto`), mirroring @TEP_PG_CFLAGS@. On Linux it's
  # often just the libs (headers on the default path); on macOS/Homebrew
  # it supplies the keg-only -I/-L too, so sphttp.c compiles + the
  # ffi_lib "ssl"/"crypto" below resolve. See tep#208.
  ffi_cflags "-lssl -lcrypto"
  ffi_lib "ssl"
  ffi_lib "crypto"

  ffi_func :sphttp_listen,        [:int, :int],     :int
  ffi_func :sphttp_accept,        [:int],           :int
  # Non-blocking accept variant used by Tep::Server::Scheduled.
  # Listen fd must be in non-blocking mode (sphttp_set_nonblock).
  # Returns -1 with errno EAGAIN/EWOULDBLOCK if no pending connection.
  ffi_func :sphttp_accept_nb,     [:int],           :int
  ffi_func :sphttp_read_request,  [:int],           :int
  ffi_func :sphttp_request_buf,   [],               :str
  ffi_func :sphttp_request_len,   [],               :int
  ffi_func :sphttp_drain_body,    [:int, :int],     :str
  ffi_func :sphttp_write_str,     [:int, :str],     :int

  # Binary-safe write + recv pair, used by Tep::WebSocket (and any
  # other caller that needs to send/receive bytes containing 0x00).
  # The recv side mirrors the request_buf / _len accessor pattern.
  # See sphttp.c for the binary-safety contract.
  ffi_func :sphttp_write_bytes,   [:int, :str, :int], :int
  ffi_func :sphttp_recv_into_frame, [:int],         :int
  ffi_func :sphttp_recv_frame_buf, [],              :str
  ffi_func :sphttp_recv_frame_len, [],              :int

  # Shutdown-on-signal plumbing. Install once at server start;
  # sphttp_shutdown_requested polls the flag (sigaction sets it on
  # SIGTERM/SIGINT). The server's accept loop checks the flag after
  # sphttp_accept returns -1 and runs Tep.on_shutdown before exit.
  ffi_func :sphttp_install_term_handlers, [], :int
  ffi_func :sphttp_shutdown_requested,    [], :int

  # Millisecond sleep helper for sub-second pacing. spinel's
  # Tep::Scheduler.pause is integer-second only; this exposes the
  # POSIX nanosleep path. Returns 0 on success, -1 on EINTR. Used by
  # Tep::Proxy's retry-backoff loop.
  ffi_func :sphttp_sleep_ms,              [:int], :int

  # HTTP/1.1 outbound connection pool (chunk 6.7a). Per-process pool
  # keyed by (host, port). checkout returns an idle fd or -1; checkin
  # registers one; close_idle sweeps entries older than idle_seconds.
  # Stat getters fetch one counter each (avoids a struct-return over
  # FFI). See Tep::Http::Pool for the Ruby surface.
  ffi_func :sphttp_pool_checkout,         [:str, :int],     :int
  ffi_func :sphttp_pool_checkin,          [:int, :str, :int], :int
  ffi_func :sphttp_pool_close_idle,       [:int],           :int
  ffi_func :sphttp_pool_stat_checkouts,   [],               :int
  ffi_func :sphttp_pool_stat_checkins,    [],               :int
  ffi_func :sphttp_pool_stat_hits,        [],               :int
  ffi_func :sphttp_pool_stat_misses,      [],               :int

  # uname-based host introspection for the toy/v1 envelope (see
  # docs/events-schema.md). sphttp_os_kind returns lowercased
  # uname.sysname ("linux" / "darwin" / ...); sphttp_arch_kind
  # returns uname.machine as-is ("aarch64" / "x86_64" / ...). Both
  # return "unknown" on uname() failure.
  ffi_func :sphttp_os_kind,       [],               :str
  ffi_func :sphttp_arch_kind,     [],               :str

  # ISO-8601 UTC timestamp for an epoch-seconds value. Used by
  # Tep::Events (toy/v1 envelope) for run_start/run_end wall-clock
  # fields -- spinel's Time.now is integer-epoch only.
  ffi_func :sphttp_iso8601_utc,   [:int],           :str
  # RFC 1123 GMT date (HTTP Date / Last-Modified / Expires) <-> epoch.
  # parse returns -1 if the string doesn't parse.
  ffi_func :sphttp_http_date,       [:int],         :str
  ffi_func :sphttp_parse_http_date, [:str],         :int

  ffi_func :sphttp_sendfile,      [:int, :str],     :int
  ffi_func :sphttp_filesize,      [:str],           :int
  ffi_func :sphttp_file_mtime,    [:str],           :int
  ffi_func :sphttp_close,         [:int],           :int
  ffi_func :sphttp_fork,          [],               :int
  ffi_func :sphttp_exit,          [:int],           :int
  ffi_func :sphttp_getpid,        [],               :int
  ffi_func :sphttp_wait_any,      [],               :int
  ffi_func :sphttp_write_chunk,   [:int, :str],     :int
  ffi_func :sphttp_write_chunk_end, [:int],         :int

  # Poll-based I/O readiness, used by Tep::Scheduler.io_wait. Mode
  # bits in/out: 1=READ, 2=WRITE.
  ffi_func :sphttp_poll_reset,    [],               :int
  ffi_func :sphttp_poll_add,      [:int, :int],     :int
  ffi_func :sphttp_poll_run,      [:int],           :int
  ffi_func :sphttp_poll_ready,    [:int],           :int
  ffi_func :sphttp_set_nonblock,  [:int],           :int
  # Bound a blocking recv (SO_RCVTIMEO, ms). Used by the pooled
  # outbound client so a no-Content-Length keep-alive response can't
  # hang the worker. 0 clears the timeout.
  ffi_func :sphttp_set_recv_timeout, [:int, :int],  :int

  # Outbound TCP for clients (Tep::Http, etc.).
  ffi_func :sphttp_connect,       [:str, :int],     :int
  # TLS variant: TCP connect + verified TLS handshake (SNI + hostname
  # + peer cert). Returns an fd whose write/recv/close transparently
  # route through the SSL*. -1 on connect/handshake/verify failure.
  ffi_func :sphttp_connect_tls,   [:str, :int],     :int
  # Inbound (server) TLS (tep#148 phase 2). server_init loads cert+key
  # once (before prefork); accept_tls wraps an accepted fd in a TLS
  # handshake (0 ok / -1 fail, caller closes). read/write/close then
  # route through the SSL* via the same fd registry.
  ffi_func :sphttp_tls_server_init, [:str, :str],   :int
  ffi_func :sphttp_accept_tls,      [:int],         :int
  # Non-blocking TLS (tep#150 outbound coop + scheduled inbound). *_start
  # sets up the SSL but does NOT run the handshake; handshake_step drives
  # one SSL_do_handshake (0=done / 1=want-read / 2=want-write / -1=fail)
  # so a fiber parks on io_wait between steps. io_status reports the last
  # recv/handshake want-state (0 ok / 1 read / 2 write / 3 eof / -1 err)
  # so the coop recv loops tell a TLS partial record from a real EOF.
  ffi_func :sphttp_tls_connect_start,  [:str, :int], :int
  ffi_func :sphttp_tls_accept_start,   [:int],       :int
  ffi_func :sphttp_tls_handshake_step, [:int],       :int
  ffi_func :sphttp_io_status,          [],           :int
  ffi_func :sphttp_recv_some,     [:int, :int],     :str
  ffi_func :sphttp_recv_all,      [:int, :int],     :str

  # popen-shaped shell capture used by Tep::Shell.run. File I/O goes
  # through spinel's built-in File.read / File.write since master
  # (matz/spinel#505 made File.write binary-safe).
  ffi_func :sphttp_shell_capture, [:str, :int],     :str
end

# Crypto FFI -- SHA-256/HMAC/PBKDF2/B64URL/random. Symbols live in
# spinel's libspinel_rt.a (added upstream as lib/sp_crypto.c via
# matz/spinel#514), which the spinel driver auto-links into every
# binary. No ffi_cflags needed; just declare the signatures.
module Tep
  class Request
    attr_accessor :verb, :path, :raw_path, :http_version
    attr_accessor :params, :query, :req_headers, :raw_body, :cookies, :session
    attr_accessor :remote_host
    attr_accessor :ivars
    # Set by the auth-filter (Tep::AuthFilter, run before the user's
    # before-filter -- see Tep::App#auth_filter). Always populated:
    # Tep::Identity.anonymous when no provider matched, otherwise
    # the matched provider's Identity. Handlers and filters can
    # rely on req.identity being non-nil.
    attr_accessor :identity


    attr_accessor :passed



    # True when the request body is a multipart/form-data submission
    # (browsers use this for any form built via `new FormData(...)`
    # or carrying file inputs). Tep::Multipart.parse handles the
    # text fields; file-upload parts are skipped in v1.

    # ---- Rack::Request-style accessors (reads only, no .ip yet) ----
    # These are convenience getters over headers we already parse;
    # `.ip` would need a sphttp_accept_with_peer C helper before it
    # can land cleanly, so it's deferred.



    # Pull any remaining body bytes from `client_fd` up to the
    # advertised Content-Length, then merge form / multipart fields
    # into @params. Used by Tep::Server (prefork, blocking fds) --
    # under the prefork model recv() blocks naturally until bytes
    # arrive, so `sphttp_drain_body` (a tight blocking-recv loop)
    # is the right primitive.
    #
    # Tep::Server::Scheduled uses `consume_body_via_scheduler` below
    # instead, because its client fd is non-blocking + a blocking
    # recv would starve the whole worker.
    #
    # No-op on bodyless requests. Form parsing handles
    # `application/x-www-form-urlencoded`; multipart handles
    # `multipart/form-data` (text fields only; file uploads skipped).
    # Other content types leave @raw_body intact for handlers that
    # want to consume it directly.

    # Scheduler-friendly body drain. Loops on
    # `Sock.sphttp_recv_some` + `Tep::Scheduler.io_wait` so other
    # fibers keep running while we wait for body bytes. Per-recv
    # timeout caps the wait at 5s -- a client that opened the
    # request but never sent the body gets dropped instead of
    # hanging the fiber forever.
    #
    # Returns @raw_body.length after the drain. Body parsing
    # (form / multipart -> @params) happens at the end via
    # parse_form_body, same shape as consume_body.

    # Shared form / multipart -> @params merge. Both server-side
    # body-drain paths call this once their drain step has filled
    # @raw_body to Content-Length.
  end
end

# --- inlined: tep/response.rb ---
# Tep::Response -- what the handler writes back. Headers are a Bag
# (string-keyed); the framework adds Content-Length / Connection
# automatically when serializing.
module Tep
  class Response
    attr_accessor :status, :headers, :body, :halted, :file_path, :set_cookies


    attr_accessor :streamer, :streaming
    attr_accessor :upgrading_ws, :ws_accept_key, :ws_driver
    attr_reader :lastmod_epoch

    # ---- HTTP caching helpers (issue #152) ----

    # Set the Cache-Control header verbatim.

    # Common Cache-Control shortcuts.

    # Strong ETag validator (quoted per RFC 7232).
    def etag(value)
      @headers["ETag"] = "\"" + value + "\""
      self
    end

    # Last-Modified validator from Unix epoch seconds. Remembers the
    # epoch so conditional GET can compare it to If-Modified-Since.

    def start_stream(streamer)
      @streamer  = streamer
      @streaming = true
    end

    # Mark the response as a WebSocket upgrade. The server writes a
    # 101 Switching Protocols response with the accept-key, assigns
    # the live client fd onto the driver, then runs the recv loop.

    # Sinatra-style cookie writer. `opts` is a Bag-of-strings
    # (path, expires, max-age, domain, samesite, httponly, secure).
    # Empty `opts` is fine: just writes "name=value".


    # Spinel's polymorphic-receiver write codegen emits a no-op for
    # `res.body = x` when called from a context that has a poly
    # value, so we force the assignment through this method (where
    # `self` is unambiguously Response).
    def set_body_if_empty(s)
      if @body.length == 0 && s.length > 0
        @body = s
      end
    end

    # Unconditional body setter. Same poly-write rationale as
    # set_body_if_empty (self is unambiguously Response here, so the
    # `@body = s` codegens correctly), but always assigns -- used by
    # Tep::Proxy, which writes the upstream body whether or not it's
    # empty (a 204 / empty upstream body must overwrite, not skip).

  end
end

# --- inlined: tep/cache.rb ---
# Tep::Cache -- HTTP conditional-GET evaluation (issue #152).
#
# A response opts in by setting a validator (res.etag / res.last_modified).
# The server then short-circuits to 304 Not Modified (no body) when the
# request carries a matching precondition, so the client reuses its
# cached copy. Responses that set no validator are unaffected.
module Tep
  class Handler
    def handle(req, res)
      ""
    end



    # Default returns an empty str_array. Subclasses for regex routes
    # return up to 9 capture strings.
  end
end

# --- inlined: tep/filter.rb ---
# Tep::Filter -- before/after hooks. Override #before(req, res) and/or
# #after(req, res). The default base methods are non-empty (they touch
# their parameters) so Spinel correctly registers them as the dispatch
# fallback; an empty base method body confuses the codegen and causes
# overrides to be silently dropped.
#
#   class TimerFilter < Tep::Filter
#     def after(req, res); res.headers["X-Took"] = "ok"; end
#   end
#   Tep.before TimerFilter.new
module Tep
  class App
    attr_accessor :router, :static_root, :session_secret
    attr_accessor :tls_cert, :tls_key
    attr_accessor :before_filter, :after_filter, :nf_handler
    # The auth-filter runs BEFORE before_filter so handler bodies and
    # user filters always see a populated req.identity. Separate slot
    # (rather than wedging into before_filter) so user-installed
    # filters and the auth populate don't fight for the single slot
    # tep otherwise imposes. Default is a no-op Tep::Filter; the
    # Auth battery installs Tep::AuthFilter on top via
    # Tep::Auth.install!.
    attr_accessor :auth_filter
    # Shared HS256 secret consumed by Tep::AuthBearerToken. Stored on
    # APP (rather than a class var) so spinel routes the read through
    # the canonical instance-attr path.
    attr_accessor :auth_bearer_secret
    # Per-process OAuth2 client registry + ephemeral authorization-code
    # store. See Tep::AuthOAuth2 for the issuance flow.
    attr_accessor :auth_oauth2_clients
    attr_accessor :auth_oauth2_codes
    # Per-process Broadcast subscriber registry. Each entry pairs a
    # topic with an output fd; publish iterates + writes the payload
    # to every matching fd.
    attr_accessor :broadcast_subs
    # Per-process Presence entry registry. Each entry is one
    # (principal, session, topic) tracking, with kind/agent_id +
    # structured-status fields inline. See Tep::Presence.
    attr_accessor :presence_entries
    # PG-mirror state for cross-worker visibility. `enabled` is 0
    # when off, 1 when on. `worker_id` uniquely identifies this
    # worker's rows in the tep_presence table (PID + boot epoch
    # so a restart on the same PID isn't aliased). See
    # Tep::Presence.enable_pg_mirror.
    attr_accessor :presence_pg_enabled
    attr_accessor :presence_pg_worker_id
    attr_accessor :presence_pg_conn
    # PG-backed cross-worker pub/sub state. `broadcast_pg_enabled`
    # is 0 when off, 1 when on. The dedicated LISTEN connection
    # lives in `broadcast_pg_conn`; channel name in
    # `broadcast_pg_channel`. Configured by
    # Tep::Broadcast.enable_pg_backend.
    attr_accessor :broadcast_pg_enabled
    attr_accessor :broadcast_pg_channel
    attr_accessor :broadcast_pg_conn
    # Tep::Llm::OpenAI::Server backend (Battery 7). Set by
    # Server.use(backend) at boot; the route handlers dispatch through
    # it per request. Seeded with a base Backend in lib/tep.rb (after
    # openai_server.rb loads -- not in initialize, since the class
    # isn't defined yet there), same pattern as broadcast_pg_conn.
    attr_accessor :openai_backend
    # Tep::Events emitter for the openai-server (7.1c). Configured by
    # Server.serve!(events_jsonl); empty path => zero-overhead disabled.
    # Late-seeded for the same reason as openai_backend.
    attr_accessor :openai_events
    attr_accessor :asset_bodies, :asset_mimes, :asset_etags
    attr_accessor :sched_fibers, :sched_wake_at, :sched_current
    attr_accessor :sched_io_fd, :sched_io_mode, :sched_io_ready
    # Tep::Job background-worker idempotency flag. App-level so a
    # single-shot spawn from a before-filter doesn't fire repeatedly.
    # Per-worker (each prefork child has its own Tep::APP, so each
    # worker spawns one background fiber).
    attr_accessor :user_bg_started

    def initialize
      @router         = Router.new
      @static_root    = ""
      @session_secret = ""
      @tls_cert       = ""   # inbound TLS cert path (tep#148 ph2; "" = plain HTTP)
      @tls_key        = ""   # inbound TLS key path
      @before_filter  = Filter.new   # no-op default
      @after_filter   = Filter.new
      @auth_filter    = Filter.new   # no-op until Tep::Auth.install!
      @auth_bearer_secret = ""
      # Type-seed the OAuth2 registries with a single dummy entry +
      # immediate drop so the PtrArray slot type is pinned.
      @auth_oauth2_clients = [Tep::AuthOAuth2Client.new("_", "", "", [:_])]
      @auth_oauth2_clients.delete_at(0)
      @auth_oauth2_codes = [Tep::AuthOAuth2Code.new("_", "", "", "", 0)]
      @auth_oauth2_codes.delete_at(0)
      # Same type-seed pattern for the Broadcast subscriber registry.
      @broadcast_subs = [Tep::BroadcastSubscription.new("_", -1, 0)]
      @broadcast_subs.delete_at(0)
      # And for the Presence entry registry.
      @presence_entries = [Tep::PresenceEntry.new("_", "", :human, "", -1, 0)]
      @presence_entries.delete_at(0)
      @presence_pg_enabled   = 0
      @presence_pg_worker_id = ""
      @broadcast_pg_enabled = 0
      @broadcast_pg_channel = ""
      # Seed broadcast_pg_conn later via lib/tep.rb's setter seed
      # (APP.set_broadcast_pg_conn(PG::Connection.new(""))) -- module
      # load order means PG::Connection isn't safely callable from
      # App#initialize when this is loaded before pg.rb's full surface.
      @nf_handler     = Handler.new
      # No-op default so a never-mounted OpenAI server doesn't leave
      # @openai_events null. Tep.on_shutdown calls openai_events.enabled?
      # unconditionally; under Spinel a null receiver is a hard null-deref
      # (not a NoMethodError), so any app that doesn't call
      # Tep::Llm::OpenAI::Server.serve! would SEGV on shutdown after a
      # SIGTERM. "" => enabled? is false (zero I/O). (matz/spinel#1259)
      @openai_events  = Tep::Events.new("")
      @asset_bodies   = Tep.str_hash # path -> bytes (filled at boot
      @asset_mimes    = Tep.str_hash # by Tep::Assets._add lines
                                     # the bin/tep translator emits)
      @asset_etags    = Tep.str_hash # path -> content-hash ETag (#152)
      # FiberSlot array for the cooperative scheduler. Initialise
      # with a noop-bodied slot to pin the array element type, then
      # drop it. Each slot holds one Fiber + a timer entry in the
      # parallel `sched_wake_at` int array.
      @sched_fibers   = [Tep::FiberSlot.new(Fiber.new { Tep.seed_fiber_noop })]
      @sched_fibers.delete_at(0)
      @sched_wake_at  = [0]
      @sched_wake_at.delete_at(0)
      @sched_current  = -1               # currently-running fiber idx
                                         # (-1 = scheduler root).
      # Parallel I/O-wait arrays. `sched_io_fd[i] == -1` means the
      # fiber isn't parked on I/O (pure timer wait, or ready). When
      # parked: `sched_io_mode[i]` carries the requested READ/WRITE
      # bits, and tick() writes back the observed-ready bits into
      # `sched_io_ready[i]`. io_wait returns those bits to its caller.
      @sched_io_fd    = [0]
      @sched_io_fd.delete_at(0)
      @sched_io_mode  = [0]
      @sched_io_mode.delete_at(0)
      @sched_io_ready = [0]
      @sched_io_ready.delete_at(0)
      @user_bg_started   = false
    end

    def add_asset(path, body, mime)
      @asset_bodies[path] = body
      @asset_mimes[path]  = mime
      # Content-hash ETag for cache revalidation (#152). SHA-1 is used
      # purely as a fast content fingerprint here (not a security hash --
      # collision resistance is irrelevant for an ETag, same as git's
      # content addressing). Computed once at boot. (Binary bodies with
      # embedded NULs hash by their leading bytes via the FFI string
      # boundary; still stable per content, which is all an ETag needs.)
      @asset_etags[path] = Crypto.sp_crypto_sha1_hex(body)
    end


    # Inbound TLS cert/key paths (tep#148 phase 2). Set via
    # Tep.tls_cert= / Tep.tls_key=; read by Tep::Server.run at boot.



    def set_static_root(root);    @static_root = root; end
    def set_before(f);            @before_filter = f; end
    def set_after(f);             @after_filter = f; end
    def set_auth_filter(f);       @auth_filter = f; end
    def set_auth_bearer_secret(s); @auth_bearer_secret = s; end
    def set_broadcast_pg_enabled(v); @broadcast_pg_enabled = v; end
    def set_broadcast_pg_channel(s); @broadcast_pg_channel = s; end
    def set_broadcast_pg_conn(c);    @broadcast_pg_conn    = c; end
    def set_presence_pg_enabled(v);   @presence_pg_enabled   = v; end
    def set_presence_pg_worker_id(s); @presence_pg_worker_id = s; end
    def set_presence_pg_conn(c);      @presence_pg_conn      = c; end
    def set_openai_backend(b);        @openai_backend        = b; end
    def set_openai_events(e);         @openai_events         = e; end
    def set_not_found(h);         @nf_handler = h; end

    def dispatch(req, res)
      # Pull a signed session cookie into req.session, when configured.
      secret = Tep.session_secret
      if secret.length > 0
        cv = req.cookies[Tep::COOKIE_NAME]
        cv = "" if cv.nil?
        if cv.length > 0
          req.session.load_from(cv, secret)
        end
      end

      asset_served = false
      # Auth filter populates req.identity (anonymous or matched
      # provider's Identity) before the user's before-filter runs,
      # so user code can always rely on req.identity being set.
      @auth_filter.before(req, res)
      if res.halted
        # Auth filter signalled "deny" -- skip the user filter +
        # route dispatch, fall through to after-filter + session.
      end
      @before_filter.before(req, res)
      if !res.halted
        # Bundled assets (everything under <app>/assets/, baked into
        # the binary by bin/tep) take precedence over the route
        # table. Match by exact path; on hit we set the body + ct
        # and skip route dispatch + 404 fallback. The after-filter
        # and session cookie writing still run normally.
        if Tep::Assets.serve(req.path, res)
          asset_served = true
        end
      end
      if !res.halted && !asset_served
        route = @router.match(req)
        # `pass` loop: a handler can signal skip-to-next-route by
        # setting req.passed. Iterate until a handler doesn't pass,
        # or we run out of matching routes.
        served = false
        while route != nil && !served
          route.fold_captures(req)
          req.passed = false
          out = route.handler.handle(req, res)
          if req.passed
            idx   = @router.index_of(route)
            route = @router.match_after(req, idx)
          else
            res.set_body_if_empty(out)
            served = true
          end
        end
        if !served
          if !try_static(req, res)
            out = @nf_handler.handle(req, res)
            res.set_status(404)
            if out.length > 0
              res.set_body_if_empty(out)
            else
              res.set_body_if_empty("<h1>404 Not Found</h1><p>" +
                                    req.verb + " " + req.path + "</p>\n")
            end
          end
        end
      end
      @after_filter.after(req, res)

      # If the handler / filters mutated the session, sign + emit a
      # Set-Cookie line. Path=/ so the cookie applies to the whole
      # app; HttpOnly to keep it out of JS.
      secret_w = Tep.session_secret
      if secret_w.length > 0 && req.session.dirty
        opts = Tep.str_hash
        opts["Path"]      = "/"
        opts["HttpOnly"]  = ""
        opts["SameSite"]  = "Lax"
        res.set_cookie(Tep::COOKIE_NAME, req.session.to_cookie_value(secret_w), opts)
      end
    end


  end
end

# --- inlined: tep/auth_bearer_token.rb ---
# Tep::AuthBearerToken -- JWT-HS256 bearer-token provider for the
# Auth battery. Sniffs `Authorization: Bearer <token>`, verifies
# the signature with the app's configured secret, decodes the
# flat-JSON payload, and builds a Tep::Identity (with optional
# Tep::AgentDelegation when the token represents an agent).
#
# Configuration:
#
#   Tep::AuthBearerToken.set_secret(ENV["JWT_SECRET"])
#
# Token payload schema (flat JSON, single level -- matches
# Tep::Json's flat-object extraction surface):
#
#   {
#     "sub":      "user:42",                    # principal_id (required)
#     "exp":      1716396000,                   # unix epoch seconds
#     "caps":     "read,write,post_summary",    # comma-separated symbols
#     "delegate": "summarizer-bot|1716392400|1716396000|token"
#                                               # optional; presence flips
#                                               # the identity to an agent.
#                                               # Format:
#                                               # agent_id|issued_at|expires_at|origin
#   }
#
# Why flat (not nested `acting_via: { ... }`): Tep::Json today
# extracts flat keys only. A nested-object getter is a separate
# tiny battery; for v1 of Auth the flat pipe-encoded delegate
# string is the smallest thing that ships and round-trips
# cleanly. The Identity / AgentDelegation Ruby surface stays
# nested -- the encoding is only on the wire.
#
# Why a flat top-level class name (not Tep::Auth::BearerToken):
# two-level namespacing on classes carries spinel cls_id risk
# (see memory note [[spinel_widening_dispatch]]). The Tep::Auth
# module owns the conceptual grouping; the class itself lives at
# Tep:: level so dispatch is shallow.
module Tep

  class Server
    attr_accessor :app




    # Keep-alive loop on a single accepted connection.



  end
end

# --- inlined: tep/server_scheduled.rb ---
# Tep::Server::Scheduled -- Falcon-shape fiber-per-connection HTTP
# server, built on Tep::Scheduler + sphttp non-blocking accept/recv.
#
# Why this exists
# ---------------
# The default Tep::Server (in server.rb) is prefork + blocking per
# worker -- N workers <=> N concurrent connections. WebSockets and
# slow keep-alive clients tie up a worker for the full connection
# duration, so the prefork pool's effective concurrency degrades
# to N regardless of actual CPU work. The scheduled variant accepts
# in a fiber, spawns one fiber per accepted connection, and parks
# all I/O on Tep::Scheduler.io_wait -- N workers serve M >> N
# concurrent connections, bounded only by per-fiber memory.
#
# Fiber bodies use ordinary closure capture for sfd / client now
# (matz/spinel#564 + #1007 both closed; the heap-cell-reset fix
# in spinel commit 48594d6 lets multi-method capture chains lower
# correctly). cmeths still preferred for accept_loop /
# handle_connection so the bodies read cleanly without per-instance
# state, but the per-connection fd flows through closure capture,
# not the earlier `Tep::APP.pending_*` stash + pause(0) handoff.
module Sqlite
  ffi_cflags "/home/oripekelman/.cache/tep/ext/tep/tep_sqlite.o"
  ffi_lib    "sqlite3"

  ffi_func :tep_sqlite_open,              [:str],          :int
  ffi_func :tep_sqlite_close,             [:int],          :int
  ffi_func :tep_sqlite_exec,              [:int, :str],    :int
  ffi_func :tep_sqlite_prepare,           [:int, :str],    :int
  ffi_func :tep_sqlite_prepare_cached,    [:int, :str],    :int
  ffi_func :tep_sqlite_bind_str,          [:int, :str],    :int
  # bind_int / col_int are 64-bit: the value arg + return use the FFI
  # `:long` (64-bit on LP64) routed through sqlite3_bind_int64 /
  # sqlite3_column_int64, so an integer column > 2^31 round-trips
  # without the 32-bit truncation that wrapped large values negative
  # (issue #171). Spinel's mrb_int is pointer-width, so the Ruby side
  # holds the full range. `:long` still maps to the `int` Spinel token,
  # so callers see an Integer exactly as before.
  ffi_func :tep_sqlite_bind_int,          [:int, :long],   :int
  ffi_func :tep_sqlite_step,              [],              :int
  ffi_func :tep_sqlite_col_str,           [:int],          :str
  ffi_func :tep_sqlite_col_int,           [:int],          :long
  ffi_func :tep_sqlite_col_count,         [],              :int
  ffi_func :tep_sqlite_finalize,          [],              :int
  ffi_func :tep_sqlite_reset,             [],              :int
  ffi_func :tep_sqlite_last_insert_rowid, [:int],          :int
end

module Tep
  class SQLite
    # `:dbh` (rather than the natural `:handle`) -- spinel widens
    # poly dispatch return types when a method name is shared across
    # classes with different signatures. `Tep::Handler#handle(req, res)`
    # is the heart of the framework and returns String; an attr_accessor
    # `handle` on Tep::SQLite would emit a 0-arg / int-return arm,
    # widening the dispatch's return type to poly and cascading
    # through `set_body_if_empty(s)` -> `Response#body` -> the
    # sphttp_write_str(int, const char *) call. (See the gemini-bot
    # commentary in spinel PR #391.)
    attr_accessor :dbh


    # Returns true on success, false on failure. Path may be a real
    # file or `:memory:` for an anonymous in-memory db. Multiple
    # opens on the same instance leak the prior handle; close first.


    # Run a statement that returns no rows (CREATE / INSERT /
    # UPDATE / DELETE / PRAGMA / BEGIN / COMMIT). Returns true on
    # success. No bind in this form -- inline literal SQL is fine
    # for DDL and constants; for any user-supplied value use
    # prepare + bind + step + finalize.

    # Open a cursor on a parameterised query. Subsequent
    # bind_str / bind_int calls fill in `?` markers (1-indexed).
    # Always pair with `finalize` once iteration is done.

    # Cached variant. Same surface as `prepare`, but the underlying
    # `sqlite3_stmt *` is memoised per-(db, sql); subsequent calls
    # with the same SQL string reuse the prepared statement, paying
    # the parse cost only once per process. Pair with `finalize` as
    # usual; on the cached path `finalize` becomes
    # `sqlite3_reset + sqlite3_clear_bindings` (the slot stays
    # alive). The cache is bounded (currently 64 distinct SQL
    # strings per process); apps that exceed the bound fall through
    # to uncached prepare so correctness is preserved.
    #
    # Use for hot-path SQL where the string is known + fixed at
    # codegen / boot time. Apps that build SQL with varying
    # whitespace miss the cache (match is literal); format
    # consistently.


    # Convenience: prepare a single-row, single-column query, bind
    # one optional string param (pass "" for "no param"), step
    # once, return col[0]. Always finalises the cursor before
    # returning so the caller doesn't have to.

  end
end

# --- inlined: tep/json.rb ---
# VENDORED from OriPekelman/spinelkit @ 09e8558 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
# Tep::Json -- Spinel-safe JSON ENCODERS (stateless).
#
# This file holds the encode half of the codec; the decode half lives in
# spinel_kit/json_decoder.rb (also `Tep::Json`), and the incremental
# object builder in spinel_kit/json_builder.rb (`Tep::Json::Builder`).
# The three are split because Spinel has no tree-shaking: every loaded method
# is compiled, and a set of uncalled methods can degrade each other's params
# (e.g. the dead decoder walkers collectively widening `escape`'s string arg
# to int, which silently miscompiled string keys to ""). Keeping
# encode/decode/build in separate files means a consumer compiles only the
# surface it calls, and each surface is independently warning-clean. Require
# only what you use:
#
#   require_relative "tep/json"          # encoders (this file)
#   require_relative "tep/json_decoder"  # decoders
# (absorbed from spinel_kit 0.1.x when upstream retired the codec in
#  0.3.0 — tep owns this surface now; see tep#217)
#
# WHY HAND-ROLLED. Spinel cannot lower the stdlib `json` gem (C-ext fast path
# + metaprogrammed pure fallback); `oj`/`yajl`/`multi_json` are C extensions.
# The spinelgems catalog confirms no verified pure-Ruby JSON gem exists. This
# is tep's encoder, standardized (the `j_`/`tj_` prefixes that worked around a
# now-fixed Spinel inference bug are gone -- see docs/spinel-discipline.md).
#
# Compose objects in user code by concatenation:
#
#   "{" + Tep::Json.encode_pair_str("name", name) + "," +
#         Tep::Json.encode_pair_int("age", age) + "}"
module Tep
  class Json
    # Escape a string for inclusion inside a JSON string literal (does NOT
    # add the surrounding quotes -- use `quote(s)` for that). Handles ", \,
    # and the JSON-required control-char escapes (\b, \f, \n, \r, \t);
    # other control bytes go through \u00XX. Forward slash is left
    # unescaped (legal either way; unescaped is shorter/readable).
    def self.escape(s)
      out = ""
      i = 0
      n = s.length
      while i < n
        c = s[i]
        if c == "\""
          out = out + "\\\""
        elsif c == "\\"
          out = out + "\\\\"
        elsif c == "\n"
          out = out + "\\n"
        elsif c == "\r"
          out = out + "\\r"
        elsif c == "\t"
          out = out + "\\t"
        elsif c == "\b"
          out = out + "\\b"
        elsif c == "\f"
          out = out + "\\f"
        elsif c < " "
          # Other control byte -- emit \u00XX. c.getbyte(0) is the raw
          # byte value, mapped to two hex digits.
          b = c.getbyte(0)
          out = out + "\\u00" + Json.hex2(b)
        else
          out = out + c
        end
        i += 1
      end
      out
    end

    # Two-digit lowercase hex of a byte (0..255).
    def self.hex2(n)
      hex = "0123456789abcdef"
      out = ""
      out = out + hex[(n / 16) % 16, 1]
      out = out + hex[n % 16, 1]
      out
    end

    # Wrap a string in JSON quotes, escaping its body.
    def self.quote(s)
      "\"" + Json.escape(s) + "\""
    end

    # Encode a single key/value pair as `"k":"v"` (escaped both sides).
    def self.encode_pair_str(k, v)
      Json.quote(k) + ":" + Json.quote(v)
    end

    # Same shape, integer value side. `v` is rendered via `.to_s` so
    # JSON-numeric output without quoting.
    def self.encode_pair_int(k, v)
      Json.quote(k) + ":" + v.to_s
    end

    # Encode a Hash<String,String> as a JSON object.
    def self.from_str_hash(h)
      out = "{"
      first = true
      h.each do |k, v|
        if !first
          out = out + ","
        end
        first = false
        out = out + Json.quote(k) + ":" + Json.quote(v)
      end
      out + "}"
    end

    # Same shape with integer values. JSON-numeric, no quoting.
    def self.from_int_hash(h)
      out = "{"
      first = true
      h.each do |k, v|
        if !first
          out = out + ","
        end
        first = false
        out = out + Json.quote(k) + ":" + v.to_s
      end
      out + "}"
    end

    # Encode a string array as a JSON array of quoted strings.
    def self.from_str_array(a)
      out = "["
      i = 0
      while i < a.length
        if i > 0
          out = out + ","
        end
        out = out + Json.quote(a[i])
        i += 1
      end
      out + "]"
    end

    # Encode an int array as a JSON array of numbers.
    def self.from_int_array(a)
      out = "["
      i = 0
      while i < a.length
        if i > 0
          out = out + ","
        end
        out = out + a[i].to_s
        i += 1
      end
      out + "]"
    end
  end
end

# --- inlined: tep/json_decoder.rb ---
# VENDORED from OriPekelman/spinelkit @ 09e8558 -- DO NOT EDIT HERE.
# Edit upstream and re-sync with `make vendor-spinelkit`.
# Tep::Json -- Spinel-safe JSON DECODERS (flat-key, top-level only).
#
# The decode half of the codec; encoders are in spinel_kit/json.rb. Split out
# so an encode-only consumer never compiles these walkers (their dead-code
# degradation otherwise widens the encoders' string args to int -- see the
# header of json.rb and docs/spinel-discipline.md).
#
# `get_str(s, key)` finds the entry for `key` in the top-level object literal
# `s` and returns its value as a string. Returns "" when `key` is absent or
# the value isn't a string. Same shape for `get_int`. `has_key?(s, key)`
# returns a boolean independent of value type. The parser is a hand-rolled
# state machine that walks one `{ "k": <value>, ... }` pair at a time,
# skipping over any value (including nested objects / arrays) it doesn't need.
# Strings inside values are honoured for escape sequences so that `\"` doesn't
# terminate the string and corrupt the walk. Decodes the escape sequences
# `Tep::Json.escape` produces.
module Tep
  class Json
    def self.get_str(s, key)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return ""
      end
      Json.parse_str_value(s, pos)
    end

    def self.get_int(s, key)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return 0
      end
      Json.parse_int_value(s, pos)
    end

    # Decode a JSON number value at `key` -> Float. Accepts both
    # integer-literal (`42`) and float-literal (`3.14`, `-0.5`, `1e2`)
    # JSON-number syntax; the integer form returns N.0. Missing key or
    # malformed value returns 0.0 (consistent with the other getters'
    # missing-key defaults).
    #
    # Implementation: delegates the value-span walking to skip_value (already
    # handles all JSON-number syntax + structural-char boundaries), then
    # String#to_f on the substring. Inlined rather than factored into a
    # parse_float_value helper because spinel's type inference mis-widens `s`
    # to int through the indirection. NOTE: that is a value-walk indirection
    # concern, NOT the name-collision bug (which was fixed) -- keep it inlined.
    def self.get_float(s, key)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return 0.0
      end
      pos = Json.skip_ws(s, pos)
      if pos >= s.length
        return 0.0
      end
      end_pos = Json.skip_value(s, pos)
      if end_pos <= pos
        return 0.0
      end
      s[pos, end_pos - pos].to_f
    end

    def self.has_key?(s, key)
      Json.find_value_start(s, key) >= 0
    end

    # Decode a flat JSON array of integers at `key` -> Array[Integer].
    # A missing or non-array value yields [] (the typed-empty-array idiom);
    # non-int elements are skipped.
    def self.get_int_array(s, key)
      out = [0]
      out.delete_at(0)
      pos = Json.find_value_start(s, key)
      if pos < 0
        return out
      end
      pos = Json.skip_ws(s, pos)
      if pos >= s.length || s[pos] != "["
        return out
      end
      pos += 1
      while pos < s.length
        pos = Json.skip_ws(s, pos)
        if pos >= s.length
          return out
        end
        c = s[pos]
        if c == "]"
          return out
        elsif c == ","
          pos += 1
        elsif (c >= "0" && c <= "9") || c == "-"
          out.push(Json.parse_int_value(s, pos))
          # Advance past the number parse_int_value just consumed
          # (optional '-' then digits).
          if s[pos] == "-"
            pos += 1
          end
          while pos < s.length && s[pos] >= "0" && s[pos] <= "9"
            pos += 1
          end
        else
          # Non-int element (string / object / etc.): skip it.
          pos = Json.skip_value(s, pos)
        end
      end
      out
    end

    # ---- Internal helpers ----

    # Skip whitespace starting at `pos`, return the new position.
    def self.skip_ws(s, pos)
      while pos < s.length
        c = s[pos]
        if c == " " || c == "\t" || c == "\n" || c == "\r"
          pos += 1
        else
          return pos
        end
      end
      pos
    end

    # Walk a JSON-quoted string starting at `pos` (which must point at the
    # opening `"`). Returns the position one past the closing `"`. Returns
    # -1 on malformed input.
    def self.skip_str(s, pos)
      if pos >= s.length || s[pos] != "\""
        return -1
      end
      pos += 1
      while pos < s.length
        c = s[pos]
        if c == "\\"
          # Skip the escape and the escaped character. \uXXXX spans 6
          # chars total but skipping 2 still keeps us inside the string
          # for the rest of the walk -- the remaining 4 hex digits look
          # like ordinary string bytes and won't terminate the literal.
          pos += 2
        elsif c == "\""
          return pos + 1
        else
          pos += 1
        end
      end
      -1
    end

    # Walk a JSON value starting at `pos` (which must point at the first
    # non-ws char of the value). Returns the position one past the value
    # (or the input length on truncation).
    def self.skip_value(s, pos)
      pos = Json.skip_ws(s, pos)
      if pos >= s.length
        return pos
      end
      c = s[pos]
      if c == "\""
        return Json.skip_str(s, pos)
      end
      if c == "{" || c == "["
        return Json.skip_container(s, pos)
      end
      # number / true / false / null -- read until the next structural /
      # whitespace char.
      while pos < s.length
        c = s[pos]
        if c == "," || c == "}" || c == "]" ||
           c == " " || c == "\t" || c == "\n" || c == "\r"
          return pos
        end
        pos += 1
      end
      pos
    end

    # Walk a balanced { ... } or [ ... ] starting at `pos`. Honours string
    # literals so that `{` / `}` inside a value-string don't confuse the
    # brace counter. Returns position one past the matching closer.
    def self.skip_container(s, pos)
      open_c = s[pos]
      close_c = open_c == "{" ? "}" : "]"
      depth = 1
      pos += 1
      while pos < s.length && depth > 0
        c = s[pos]
        if c == "\""
          # whole nested string -- skip past it
          npos = Json.skip_str(s, pos)
          if npos < 0
            return s.length
          end
          pos = npos
        elsif c == open_c
          depth += 1
          pos += 1
        elsif c == close_c
          depth -= 1
          pos += 1
        else
          pos += 1
        end
      end
      pos
    end

    # Read a JSON-quoted string at `pos` and return its decoded contents
    # (no surrounding quotes). Decodes the same escape sequences that
    # `escape` produces. Returns "" on malformed input.
    def self.parse_str_value(s, pos)
      pos = Json.skip_ws(s, pos)
      if pos >= s.length || s[pos] != "\""
        return ""
      end
      pos += 1
      out = ""
      while pos < s.length
        c = s[pos]
        if c == "\""
          return out
        end
        if c == "\\"
          if pos + 1 >= s.length
            return out
          end
          esc = s[pos + 1]
          if esc == "\""
            out = out + "\""
          elsif esc == "\\"
            out = out + "\\"
          elsif esc == "/"
            out = out + "/"
          elsif esc == "n"
            out = out + "\n"
          elsif esc == "r"
            out = out + "\r"
          elsif esc == "t"
            out = out + "\t"
          elsif esc == "b"
            out = out + "\b"
          elsif esc == "f"
            out = out + "\f"
          elsif esc == "u"
            # \u00XX -> map the two-digit hex back to a byte. Wider
            # codepoints (U+0100+ or surrogate pairs) aren't decoded; the
            # byte we emit is the low byte of the codepoint, which
            # round-trips ASCII at minimum.
            if pos + 5 < s.length
              h1 = Json.hex_nibble(s[pos + 4])
              h2 = Json.hex_nibble(s[pos + 5])
              if h1 >= 0 && h2 >= 0
                # rebuild the byte and push it -- spinel strings are
                # byte-blobs, so this works for ASCII; for non-ASCII the
                # original encoder would have used a passthrough byte
                # anyway.
                b = h1 * 16 + h2
                out = out + Json.byte_to_chr(b)
                pos += 6
                next
              end
            end
            out = out + "?"
            pos += 2
            next
          else
            out = out + esc
          end
          pos += 2
        else
          out = out + c
          pos += 1
        end
      end
      out
    end

    def self.hex_nibble(c)
      if c >= "0" && c <= "9"
        return c.getbyte(0) - "0".getbyte(0)
      end
      if c >= "a" && c <= "f"
        return c.getbyte(0) - "a".getbyte(0) + 10
      end
      if c >= "A" && c <= "F"
        return c.getbyte(0) - "A".getbyte(0) + 10
      end
      -1
    end

    # Build a single-byte string from an integer 0..255. Spinel doesn't
    # expose `n.chr` for arbitrary bytes uniformly; the table covers the
    # ASCII printable range and falls back to "?" for anything else (the
    # JSON encoder side never produces non-ASCII via \u, so the fallback
    # is reachable only for malformed input).
    def self.byte_to_chr(n)
      printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
      if n >= 32 && n < 127
        return printable[n - 32, 1]
      end
      if n == 9
        return "\t"
      end
      if n == 10
        return "\n"
      end
      if n == 13
        return "\r"
      end
      "?"
    end

    # Read an integer at `pos`. Accepts an optional leading `-`. Returns 0
    # on no-digit / non-numeric input (caller can use `has_key?` first if
    # 0-vs-absent matters).
    def self.parse_int_value(s, pos)
      pos = Json.skip_ws(s, pos)
      if pos >= s.length
        return 0
      end
      neg = false
      if s[pos] == "-"
        neg = true
        pos += 1
      end
      n = 0
      saw_digit = false
      while pos < s.length
        c = s[pos]
        if c >= "0" && c <= "9"
          n = n * 10 + (c.getbyte(0) - "0".getbyte(0))
          saw_digit = true
          pos += 1
        else
          break
        end
      end
      if !saw_digit
        return 0
      end
      neg ? -n : n
    end

    # Walk the top-level object looking for the entry whose key matches
    # `target_key`; return the position of the value's first non-ws
    # character. Returns -1 if not found.
    def self.find_value_start(s, target_key)
      pos = Json.skip_ws(s, 0)
      if pos >= s.length || s[pos] != "{"
        return -1
      end
      pos += 1
      while pos < s.length
        pos = Json.skip_ws(s, pos)
        if pos >= s.length
          return -1
        end
        if s[pos] == "}"
          return -1
        end
        # Read a key.
        if s[pos] != "\""
          return -1
        end
        key_start = pos
        pos = Json.skip_str(s, pos)
        if pos < 0
          return -1
        end
        # Decode the key for comparison (handles \" inside keys).
        key = Json.parse_str_value(s, key_start)
        # Skip ws, ":".
        pos = Json.skip_ws(s, pos)
        if pos >= s.length || s[pos] != ":"
          return -1
        end
        pos += 1
        pos = Json.skip_ws(s, pos)
        if key == target_key
          return pos
        end
        # Skip the value, then the comma (if any).
        pos = Json.skip_value(s, pos)
        pos = Json.skip_ws(s, pos)
        if pos < s.length && s[pos] == ","
          pos += 1
        elsif pos < s.length && s[pos] == "}"
          return -1
        end
      end
      -1
    end
  end
end

# --- inlined: tep/mcp.rb ---
# Tep::MCP -- runtime helpers for the MCP battery (chunk 5.1).
#
# Most of the action happens in the bin/tep translator: each
# `mcp_tool` declaration generates a per-tool dispatch cmeth + a
# direct HTTP route, and the translator-emitted dispatcher class
# at POST /mcp routes JSON-RPC 2.0 messages to those cmeths by
# name. This file holds the runtime helpers the generated code
# leans on -- nested-key JSON extraction, result builders, and
# JSON-RPC envelope formatters.
#
# Public surface (chunk 5.1):
#
#   Tep::MCP.text(s)              -> Result with text content
#   Tep::MCP.error(s)             -> Result marked isError = true
#   Tep::MCP.nested_extract(j, k) -> sub-JSON string for a nested key
#   Tep::MCP.initialize_envelope(id, name, version)
#   Tep::MCP.tools_list_envelope(id, tools_json)
#   Tep::MCP.tools_call_envelope(id, result)
#   Tep::MCP.unknown_tool_envelope(id, name)
#   Tep::MCP.method_not_found_envelope(id, method)
#
# Apps wire the battery via `mcp_tool '...' do ... end` blocks at
# the top level; bin/tep does the rest. The runtime here stays
# small + spinel-friendly (no class-hierarchy dispatch, no
# heterogeneous arrays). See docs/MCP-BATTERY.md for the design.
module Tep
  class Assets
    def self._add(path, body, mime)
      Tep::APP.add_asset(path, body, mime)
    end

    def self.has?(path)
      Tep::APP.asset_bodies.has_key?(path)
    end

    # Serve `path` if it's known. Sets Content-Type / body and
    # returns true; returns false if the path isn't bundled.
    def self.serve(path, res)
      if !Tep::APP.asset_bodies.has_key?(path)
        return false
      end
      res.headers["Content-Type"] = Tep::APP.asset_mimes[path]
      res.headers["Cache-Control"] = "public, max-age=3600"
      # Content-hash ETag (#152): lets the browser revalidate with
      # If-None-Match and get a 304 (handled by the server's
      # Tep::Cache short-circuit) instead of re-downloading the body.
      res.etag(Tep::APP.asset_etags[path])
      res.set_body_if_empty(Tep::APP.asset_bodies[path])
      true
    end
  end
end

# --- inlined: tep/scheduler.rb ---
# Tep::Scheduler -- a tiny fiber-based cooperative scheduler.
#
# Spinel ships Fiber today (ucontext-based, GC-aware, ivars persist
# across yields). What was missing was the layer above: a way to run
# multiple cooperating fibers within a single worker process so a
# long-running response (SSE stream, long-poll, slow batch) doesn't
# pin the worker for the whole connection lifetime.
#
# This covers two parking modes:
#
#   * **Time**: register a fiber to be resumed at-or-after `wake_at`
#     via `Tep::Scheduler.pause(seconds)`.
#   * **I/O**: park a fiber on (fd, mode) via `Tep::Scheduler.io_wait`.
#     tick() runs a poll(2) round, marks ready fibers, and resumes them
#     (along with any time-ready ones) on the same pass.
#
# Storage shape
# -------------
# Parallel arrays on the Tep::APP singleton -- one entry per fiber:
#   sched_fibers    PtrArray<FiberSlot>  the Fiber itself
#   sched_wake_at   IntArray             unix-seconds; -1 = ready now
#   sched_io_fd     IntArray             fd parked on; -1 = no I/O wait
#   sched_io_mode   IntArray             requested mode bits (1=R, 2=W)
#   sched_io_ready  IntArray             observed-ready bits (0=not yet)
#
# Spinel handles same-shaped typed arrays cleanly; using a single
# array of structs would force a poly_array. Same App-instance
# pattern as Tep::Assets.
#
# What it doesn't do (yet)
# ------------------------
# **Implicit yield on blocking calls.** Ruby 3.0's
# `Fiber::SchedulerInterface` makes every blocking I/O auto-yield
# to a registered scheduler. Spinel doesn't recognise that hook;
# fibers yield explicitly via `Tep::Scheduler.pause / io_wait`.
#
# **Non-blocking accept on the listening socket.** The Server's
# worker_loop still does a blocking accept(); fibers cooperate
# *within* a single request lifetime, not across requests. Adding
# poll-on-accept needs the worker_loop to opt into the scheduler.
module Tep
  class Llm
    attr_accessor :base_url, :model, :api_key, :system_prompt


    def set_model(name)
      @model = name
    end

    def set_api_key(key)
      @api_key = key
      if key.length > 0
        @http.set_header("Authorization", "Bearer " + key)
      end
    end

    def set_system_prompt(s)
      @system_prompt = s
    end

    # POST to <base_url>/v1/chat/completions with the messages array.
    # Returns a Tep::Llm::Response. On any transport / parse failure
    # `.content` is "" and `.stop_reason` is "error".

    # Streaming variant. Opens a connection, sends the request with
    # `stream: true`, decodes the SSE response (handling either
    # close-delimited or HTTP/1.1 chunked-transfer-encoded bodies),
    # and writes each `{"content":"<delta>"}` event to `out_stream`
    # (anything with a `write(String) -> Integer` -- typically the
    # framework-provided Tep::Stream from a Tep::Streamer#pump).
    # Each SSE line is `data: {"content":"<delta>"}\n\n`. A final
    # `data: [DONE]\n\n` marks the end (after stop / disconnect).
    # Returns the accumulated assistant content as a String so the
    # caller can persist it.

    # Hand-rolled JSON build. Tep::Json doesn't ship nested
    # array-of-hash support (its public encoders are flat); the
    # request body is a fixed shape so the inline assembly stays
    # bounded.
    def self.build_request_body(model, system_prompt, messages)
      out = "{\"model\":" + Tep::Json.quote(model) + ",\"messages\":["
      first = true
      if system_prompt.length > 0
        out = out + "{\"role\":\"system\",\"content\":" + Tep::Json.quote(system_prompt) + "}"
        first = false
      end
      i = 0
      while i < messages.length
        if !first
          out = out + ","
        end
        msg = messages[i]
        out = out + "{\"role\":" + Tep::Json.quote(msg.role) +
                    ",\"content\":" + Tep::Json.quote(msg.content) + "}"
        first = false
        i += 1
      end
      out = out + "]}"
      out
    end

    # OpenAI response shape:
    #   {"choices":[{"message":{"role":"assistant","content":"..."},
    #                "finish_reason":"stop"}], ...}
    # We extract two fields, both inside choices[0]. Tep::Json's
    # flat-key decoder doesn't dive that deep, so we hand-walk the
    # JSON looking for `"message":{...}` and pull "content" + (the
    # surrounding) "finish_reason" out of it.
    def self.parse_response(http_response)
      out = Tep::Llm::Response.new
      if http_response.status == 0
        out.stop_reason = "error"
        return out
      end
      if http_response.status >= 400
        out.stop_reason = "http_" + http_response.status.to_s
        return out
      end

      json = http_response.body
      # Find the assistant message block. The first `"message":{` in
      # the body is choices[0].message; subsequent ones would be
      # tool-call descriptors etc., which v1 doesn't surface.
      m_at = Tep.str_find(json, "\"message\"", 0)
      if m_at < 0
        out.stop_reason = "no_message"
        return out
      end
      out.content     = Llm.extract_str_field(json, "content", m_at)
      out.role        = Llm.extract_str_field(json, "role", m_at)
      out.stop_reason = Llm.extract_str_field(json, "finish_reason", m_at)
      out
    end

    # Extract `"key":"value"` from `json` starting the search at
    # `from`. Walks the post-key string honouring \" / \\ / \n / \t
    # escapes. Returns "" if the field isn't found.
    def self.extract_str_field(json, key, from)
      needle = "\"" + key + "\""
      k_at = Tep.str_find(json, needle, from)
      if k_at < 0
        return ""
      end
      # Skip past `"key"` to the colon, then the opening quote.
      pos = k_at + needle.length
      # Walk past whitespace + `:`.
      while pos < json.length && json[pos] != "\""
        pos += 1
      end
      if pos >= json.length
        return ""
      end
      pos += 1  # past opening quote
      out = ""
      while pos < json.length
        c = json[pos]
        if c == "\\"
          if pos + 1 < json.length
            nxt = json[pos + 1]
            if nxt == "n"
              out = out + "\n"
            elsif nxt == "t"
              out = out + "\t"
            elsif nxt == "\""
              out = out + "\""
            elsif nxt == "\\"
              out = out + "\\"
            elsif nxt == "/"
              out = out + "/"
            elsif nxt == "r"
              out = out + "\r"
            else
              out = out + nxt
            end
            pos += 2
          else
            pos += 1
          end
        elsif c == "\""
          return out
        else
          out = out + c
          pos += 1
        end
      end
      out
    end

    # Streaming SSE reader. Parks the fiber on Tep::Scheduler.io_wait
    # between recvs, decodes the response body (either raw bytes if
    # the server respected Connection: close, or HTTP/1.1 chunked
    # transfer encoding -- detected via the Transfer-Encoding
    # header), splits on the "\n\n" SSE event boundary, extracts
    # `choices[0].delta.content` from each `data: <json>` event,
    # and writes a `data: {"content":"<delta>"}\n\n` to `out_stream`
    # for each non-empty delta. Returns the accumulated content.
    #
    # Terminates on: SSE "[DONE]" event, EOF, finish_reason set,
    # or 60-second I/O-wait timeout.

    # Process every complete "\n\n"-terminated event in
    # `state.leftover`. Mutates state.acc / state.leftover / state.done.
    def self.consume_sse_events(out_stream, state)
      body_buf = state.leftover
      while true
        sep = Tep.str_find(body_buf, "\n\n", 0)
        if sep < 0
          state.leftover = body_buf
          return 0
        end
        event = body_buf[0, sep]
        body_buf = body_buf[sep + 2, body_buf.length - sep - 2]
        # Each event is "data: <json>" (or "data: [DONE]", or "" for
        # the SSE keepalive ": tick" / comment lines we ignore).
        if event.length >= 6 && event[0, 6] == "data: "
          payload = event[6, event.length - 6]
          if payload == "[DONE]"
            state.done = true
            state.leftover = body_buf
            return 0
          end
          # Extract choices[0].delta.content. Same shape Tep::Llm
          # already walks for non-streaming responses.
          delta = Llm.extract_str_field(payload, "content", 0)
          if delta.length > 0
            state.acc = state.acc + delta
            out_stream.write("data: {" + Tep::Json.encode_pair_str("content", delta) + "}\n\n")
          end
          # finish_reason on the last frame -- not load-bearing for
          # the accumulator but signals upstream end-of-stream.
          fr = Llm.extract_str_field(payload, "finish_reason", 0)
          if fr.length > 0
            state.done = true
            state.leftover = body_buf
            return 0
          end
        end
      end
      state.leftover = body_buf
      0
    end

    # Internal: walks the bytes-of-chunk-prefix-and-bytes form once
    # and returns the consumed dechunked bytes. Anything mid-chunk
    # (incomplete length or partial body) is dropped from the
    # consumed return and surfaces via dechunk_leftover.
    def self.dechunk_consume(s)
      out = ""
      i = 0
      while i < s.length
        # Find "\r\n" terminating the hex length line.
        eol = Tep.str_find(s, "\r\n", i)
        if eol < 0
          # No full chunk header yet.
          return out
        end
        hex = s[i, eol - i]
        # to_int parses the leading hex (so a `size;ext` chunk-extension
        # yields the size, not a parse error) and is >= 0, so 0 -- empty or
        # no leading hex -- is the terminating chunk / give-up point.
        n = SpinelKit::Hex.to_int(hex)
        if n == 0
          # Last chunk -- done.
          return out
        end
        if eol + 2 + n + 2 > s.length
          # Body bytes not all here yet.
          return out
        end
        out = out + s[eol + 2, n]
        i = eol + 2 + n + 2  # past chunk body + trailing \r\n
      end
      out
    end

    # Inverse of dechunk_consume: returns the bytes that weren't
    # consumed (the trailing partial chunk). Keep these for the
    # next recv loop. The two functions intentionally do the
    # parse twice rather than share state -- spinel's tuple/
    # multi-return support is uneven, simpler to pay the cost.
    def self.dechunk_leftover(s)
      i = 0
      while i < s.length
        eol = Tep.str_find(s, "\r\n", i)
        if eol < 0
          return s[i, s.length - i]
        end
        hex = s[i, eol - i]
        n = SpinelKit::Hex.to_int(hex)   # leading-hex, >= 0 (see dechunk_consume)
        if n == 0
          return ""
        end
        if eol + 2 + n + 2 > s.length
          return s[i, s.length - i]
        end
        i = eol + 2 + n + 2
      end
      ""
    end

    # Stub used by read_sse_response when dechunk_consume's split
    # logic gets hoisted. Left in place as a no-op return for the
    # str_find sentinel routing.
    def self.dechunk_pass(s)
      s
    end

    # On EOF: feed whatever's in body_buf to consume_sse_events
    # one last time (some servers omit the trailing \n\n on close).
    def self.drain_sse_buf(body_buf, out_stream, acc)
      if body_buf.length == 0
        return acc
      end
      # Append a synthetic \n\n so the splitter finishes the tail.
      state = Tep::Llm::StreamState.new
      state.acc      = acc
      state.leftover = body_buf + "\n\n"
      Llm.consume_sse_events(out_stream, state)
      state.acc
    end

    # Per-stream state carried across consume_sse_events / read
    # loop iterations. See chat_stream + read_sse_response for use.
    class StreamState
      attr_accessor :acc, :leftover, :done

    end

    class Message
      attr_accessor :role, :content

    end

    class Response
      attr_accessor :content, :role, :stop_reason

    end
  end
end

# --- inlined: tep/openai_server.rb ---
# Tep::Llm::OpenAI::Server -- serve OpenAI-compatible HTTP from local
# compute (Battery 7). Unlike Tep::Proxy there's no upstream: the route
# + events shell is tep, the actual inference is a pluggable Backend an
# app supplies. See docs/OPENAI-SERVER-BATTERY.md.
#
# Chunk 7.1a (this file): the Backend interface apps subclass, the
# Server.use / .serve! DSL, and GET /v1/models. Token-level completions
# (/v1/completions), events emission, and streaming land in later
# chunks (7.1b / 7.2).
#
#   class ToyBackend < Tep::Llm::OpenAI::Backend
#     def list_models; ["smollm2-135m"]; end
#     # generate_from_tokens / device_kind / ... overridden as needed
#   end
#   Tep::Llm::OpenAI::Server.use(ToyBackend.new)
#   Tep::Llm::OpenAI::Server.serve!
#
# Why subclass-and-override + `use(ConcreteBackend.new)`: the concrete
# instance flows into the APP.openai_backend slot from the user's
# `.new`, so spinel's observed-class set includes it and the route's
# `APP.openai_backend.list_models` dispatches to the override (verified
# spike). Same shape Tep::LiveView uses for its view instances.
module Tep
  class Llm
    module OpenAI
      # The interface an app's backend implements. Defaults make a
      # bare backend safe to compile + serve (empty model list, chat
      # unsupported, cpu device). Subclasses override what they offer.
      class Backend
        # Available model names -> [String]. /v1/models wraps these.
        def list_models
          empty = [""]
          empty.delete_at(0)
          empty
        end

        # PRIMARY shape: token-level generation (maps to
        # /v1/completions, non-streaming). `token_ids` is the encoded
        # prompt (Array[Integer]); `sampling` is a
        # Tep::Llm::OpenAI::Sampling. Returns a
        # Tep::Llm::OpenAI::Completion (text + usage). The base returns
        # an empty completion so a bare backend compiles; real backends
        # override.
        def generate_from_tokens(model, token_ids, sampling)
          Tep::Llm::OpenAI::Completion.new
        end

        # STREAMING shape (7.2): the per-token variant for SSE
        # /v1/completions when the request carries "stream": true.
        # The backend writes each token to `sink` via
        # sink.emit_token(piece); the sink (Tep::Llm::OpenAI::StreamSink)
        # formats it as an OpenAI SSE frame and writes to the
        # outbound chunked stream. Blocks/yields don't lower across the
        # spinel boundary, so a typed sink replaces the block --
        # backends never see SSE wire format or the client fd.
        # Base no-op (subclasses override).
        def generate_stream_from_tokens(model, token_ids, sampling, sink)
          0
        end

        # Does this backend implement message-level (chat) generation?
        # When false, /v1/chat/completions returns 501. (The chat
        # template is per-model + an ML concern; tep doesn't ship one.)
        def supports_chat?
          false
        end

        # Message-level (chat) generation. Mirrors generate_from_tokens
        # but receives the raw req so the backend can parse the
        # messages array itself + apply its own chat template. Tep
        # doesn't pre-build a Message[] because templating + role
        # ordering is per-model; the JSON tools live in Tep::Json. The
        # return is reused from the token path (text becomes the
        # assistant message's content). Base no-op; subclasses override.
        # Only reached when supports_chat? returns true -- the handler
        # gates with a 501 otherwise.
        def chat_completion(req)
          Tep::Llm::OpenAI::Completion.new
        end

        # Streaming chat (#127). Per-token variant for SSE
        # /v1/chat/completions when the request carries "stream":true.
        # Backend writes each token to `sink` via sink.emit_token(piece);
        # the sink formats it as the OpenAI chat-streaming delta frame
        # and writes one chunked frame. Same subclass-override-sink
        # pattern as 7.2 (generate_stream_from_tokens). Base no-op.
        def chat_completion_stream(req, sink)
          0
        end

        # Backend's device, surfaced into the run_start event's
        # backend.kind at serve! time. Defaults to cpu.
        def device_kind
          "cpu"
        end

        # owned_by value for each entry in the /v1/models list. Defaults
        # to "tep"; a backend overrides to attribute models to its own
        # project (e.g. toy returns "toy").

        # Backends that can embed override this -> true (gates
        # /v1/embeddings, chunk 7.3).
        def supports_embeddings?
          false
        end

        # Embedding generation for /v1/embeddings. `token_ids` is the
        # encoded input (Array[Integer]; this server speaks IDs only,
        # tokenize client-side, same policy as generate_from_tokens).
        # Returns the pooled embedding as an Array[Float] of length
        # d_model -- the backend owns the lookup + pooling strategy
        # (toy mean-pools per-token embeddings). Base returns an empty
        # vector so a bare backend compiles; only reached when
        # supports_embeddings? is true (EmbeddingsHandler gates 501).
      end

      # The mountable server. Class methods because an app wires one
      # backend per process at boot (`use`) then mounts the standard
      # routes (`serve!`).
      class Server
        # Register the app's backend. Pass a concrete Backend subclass
        # instance; it's stored on Tep::APP and dispatched per request.
        def self.use(backend)
          Tep::APP.set_openai_backend(backend)
          0
        end

        # Mount the standard OpenAI routes + (optionally) start the
        # toy/v1 events stream. `events_jsonl` is a JSONL path the
        # per-request inference event + the run_start at boot append
        # to; an empty path (the default) disables emission with zero
        # overhead. Backwards-compatible with the 7.1a/b no-arg form.
      end

      # Parse the `messages` array from an OpenAI chat request body.
      # Returns [Tep::Llm::Message, ...] (one per `{role, content}`
      # object); empty if the key is missing or the value isn't an
      # array.
      #
      # Helper for `chat_completion(req)` overrides — backends that
      # need the parsed messages array (most do, for applying their
      # chat template) can call this instead of writing their own
      # JSON walker:
      #
      #   def chat_completion(req)
      #     messages = Tep::Llm::OpenAI.parse_messages(req.raw_body)
      #     # ...apply template, tokenize, generate...
      #   end
      #
      # Honors only `role` + `content` (the v1 fields). Other fields
      # in the message object (e.g. `name`, `tool_calls`) are ignored
      # for now; future chunks may extend the shape.
      def self.parse_messages(body)
        out = [Tep::Llm::Message.new("", "")]
        out.delete_at(0)
        pos = Tep::Json.find_value_start(body, "messages")
        if pos < 0
          return out
        end
        pos = Tep::Json.skip_ws(body, pos)
        if pos >= body.length || body[pos] != "["
          return out
        end
        pos += 1
        while pos < body.length
          pos = Tep::Json.skip_ws(body, pos)
          if pos >= body.length
            return out
          end
          c = body[pos]
          if c == "]"
            return out
          end
          if c == ","
            pos += 1
            next
          end
          if c == "{"
            obj_end = Tep::Json.skip_container(body, pos)
            # Parse role + content within this object range. Run two
            # passes scoped via Tep::Json's existing key search: the
            # body-wide find could match a key in a sibling object so
            # we instead walk the bytes between `pos` and `obj_end`
            # manually, looking only for `"role"` / `"content"`.
            role = Tep::Llm::OpenAI.find_obj_key_str(body, pos, obj_end, "role")
            cont = Tep::Llm::OpenAI.find_obj_key_str(body, pos, obj_end, "content")
            out.push(Tep::Llm::Message.new(role, cont))
            pos = obj_end
          else
            pos = Tep::Json.skip_value(body, pos)
          end
        end
        out
      end

      # Scan body[obj_start..obj_end) for `"key":"<value>"` and return
      # the unescaped value. Returns "" if the key isn't present. Used
      # by parse_messages above to extract per-message fields without
      # crossing into adjacent message objects.
      def self.find_obj_key_str(body, obj_start, obj_end, key)
        needle = "\"" + key + "\""
        pos = Tep.str_find(body, needle, obj_start)
        if pos < 0 || pos >= obj_end
          return ""
        end
        pos = pos + needle.length
        pos = Tep::Json.skip_ws(body, pos)
        if pos >= obj_end || body[pos] != ":"
          return ""
        end
        pos += 1
        pos = Tep::Json.skip_ws(body, pos)
        if pos >= obj_end
          return ""
        end
        Tep::Json.parse_str_value(body, pos)
      end

      # Sampling parameters handed to the backend. v1 carries
      # max_tokens + temperature + top_p (the three OpenAI completion
      # knobs every client sets). Floats parsed via Tep::Json.get_float.
      # Defaults match OpenAI's API defaults so a backend that ignores
      # sampling gets pass-through behavior.
      class Sampling
        attr_accessor :max_tokens, :temperature, :top_p

      end

      # A backend's generation result: the decoded text + token usage.
      #
      # token_ids carries the GENERATED token IDs for an IDs-only backend
      # (no detokenizer): when non-empty, CompletionsHandler emits them as
      # choices[0].ids alongside text (which such a backend leaves ""),
      # matching the "tokenize/detokenize client-side" serving contract.
      # Text backends leave token_ids empty and the ids field is omitted.
      # finish_reason defaults to "stop"; a fixed-length greedy backend
      # sets "length".
      #
      # id is the completion id echoed as the response `id` (and the
      # inference event's request_id). It defaults to "cmpl-tep"; a backend
      # that mints its own per-request ids (e.g. so a downstream byte-exact
      # ingest keeps unique ids) sets it. Leaving it default keeps existing
      # consumers byte-identical.
      class Completion
        attr_accessor :text, :prompt_tokens, :completion_tokens
        attr_accessor :token_ids, :finish_reason
        attr_accessor :id

      end

      # The per-token write surface a streaming backend uses (7.2). One
      # method: `emit_token(piece)`. The sink formats `piece` as an
      # OpenAI text-completion SSE frame and writes one chunked frame
      # to the outbound stream. Counts emitted tokens for the
      # inference event's completion_tokens.
      #
      # Why a sink object instead of a block: spinel can't lower a
      # block parameter across the backend call boundary; a typed
      # object with one method does the same job through ordinary
      # virtual dispatch.
      class StreamSink
        attr_accessor :out, :model, :completion_count


        # Write one SSE event carrying a single text delta. Matches
        # OpenAI's text_completion streaming shape: one choices[].text
        # per event, finish_reason: null until the streamer sends
        # [DONE]. created uses Time.now.to_i (epoch seconds).
        def emit_token(piece)
          @completion_count = @completion_count + 1
          frame = "{" +
            Tep::Json.encode_pair_str("id", "cmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "text_completion") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              Tep::Json.encode_pair_str("text", piece) + "," +
              "\"finish_reason\":null" +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end
      end

      # Runs one streaming completion. Subclass of Tep::Streamer so the
      # server pumps `pump(out)` cooperatively; we own the SSE shape
      # end-to-end: drive the backend through StreamSink, write the
      # terminating data:[DONE], then emit the toy/v1 serving event
      # (kind:eval, phase:serve, name:request) via Events#inference.
      class CompletionsStreamer < Tep::Streamer
        attr_accessor :model, :token_ids, :sampling
        attr_accessor :prompt_tokens, :t0, :request_id, :principal_id


      end

      # Chat-streaming write surface (#127). Three emit_* methods
      # cover the OpenAI chat-streaming wire shape:
      #
      #   1. emit_role_prelude("assistant") -> first frame carries
      #      `delta:{role:"assistant"}` (no content).
      #   2. emit_token(piece) -> N content frames, each
      #      `delta:{content:<piece>}` with finish_reason:null.
      #   3. emit_finish("stop") -> last frame carries an empty
      #      `delta:{}` with finish_reason set; the streamer then
      #      writes the terminating data:[DONE].
      #
      # Backends typically: sink.emit_role_prelude("assistant"); then
      # call sink.emit_token(piece) per generated token. emit_finish
      # is invoked by the streamer after the backend returns -- not
      # the backend's responsibility.
      class ChatStreamSink
        attr_accessor :out, :model, :completion_count


        # First frame: role-only delta, no content. Per OpenAI's
        # wire shape, sent once before content frames.
        def emit_role_prelude(role)
          frame = "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion.chunk") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"delta\":{" +
                Tep::Json.encode_pair_str("role", role) +
              "}," +
              "\"finish_reason\":null" +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end

        # Content delta. One per generated token.
        def emit_token(piece)
          @completion_count = @completion_count + 1
          frame = "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion.chunk") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"delta\":{" +
                Tep::Json.encode_pair_str("content", piece) +
              "}," +
              "\"finish_reason\":null" +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end

        # Final frame: empty delta + populated finish_reason. The
        # streamer writes data:[DONE] after this.
        def emit_finish(reason)
          frame = "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion.chunk") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"delta\":{}," +
              Tep::Json.encode_pair_str("finish_reason", reason) +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end
      end

      # Runs one streaming chat completion. Subclass of Tep::Streamer.
      # Drives backend.chat_completion_stream through ChatStreamSink,
      # writes the terminating data:[DONE], then emits the toy/v1
      # serving event (kind:eval, phase:serve, name:request) with
      # sink.completion_count (mirrors CompletionsStreamer's #128 shape).
      class ChatCompletionsStreamer < Tep::Streamer
        attr_accessor :req_ref, :model, :prompt_tokens
        attr_accessor :t0, :request_id, :principal_id


      end

      # GET /v1/models -- the standard OpenAI list envelope, built from
      # backend.list_models. Dispatches through APP.openai_backend so
      # the app's subclass override is what answers.
      class ModelsHandler < Tep::Handler
      end

      # POST /v1/completions -- token-level OpenAI shape (the primary
      # completion route). Parses model / prompt (token ids) /
      # max_tokens, calls backend.generate_from_tokens, and formats the
      # standard text_completion response. Dispatches through
      # APP.openai_backend (the app's subclass override answers).
      class CompletionsHandler < Tep::Handler
      end

      # POST /v1/chat/completions -- message-level OpenAI shape. Skeleton
      # for now: gated 501 when backend.supports_chat? is false (the
      # default; chat templating is per-model + an ML concern tep
      # doesn't ship). When a backend opts in (overrides supports_chat?
      # to true + chat_completion), this dispatches to it and formats
      # the standard chat.completion envelope around the returned
      # Completion (the text field becomes the assistant message's
      # content). Streaming chat lands later.
      class ChatCompletionsHandler < Tep::Handler
      end

      # POST /v1/embeddings -- OpenAI embeddings shape. Gated 501 when
      # backend.supports_embeddings? is false (the default). When a
      # backend opts in, parses the IDs-only `input` array, asks the
      # backend for the pooled vector, and formats the standard
      # embeddings envelope. Mirrors toy's mean-pooled handler -- the
      # pooling strategy lives in the backend, not here.
      class EmbeddingsHandler < Tep::Handler
      end
    end
  end
end

# --- inlined: tep/websocket/frame.rb ---
# Tep::WebSocket::Frame -- single-frame codec.
#
# Surface:
#   - Frame.new(fin, opcode, payload)             build for emit
#   - frame.encode_unmasked -> String             server-side emit bytes
#   - Frame.parse_from_buf(bytes_at, bytes_len)   parse a recv'd frame
#       returns a ParseResult (frame + bytes_consumed, OR an error code).
#
# Server-side emit: never masks (RFC 6455 §5.3 -- server MUST NOT
# mask). Client-side emit isn't shipped here; tep is server-shaped.
#
# Parse handles three length encodings (7-bit / 16-bit / 64-bit),
# the 4-byte mask key, and applies the mask to recover the plaintext
# payload. Returns a structural error code (close-code-shaped) for
# the family of malformed-frame cases that warrant a 1002 close:
#   - reserved bits set
#   - reserved opcode
#   - client frame not masked
#   - control frame payload > 125
#   - control frame fragmented
module Tep
  module WebSocket
    class Frame
      attr_accessor :fin, :opcode, :payload


      # Build the unmasked server-side wire bytes. Length-encoding
      # picks the smallest form that fits the payload. No mask.
      def encode_unmasked
        head = ""
        b0 = (@fin ? 0x80 : 0x00) | (@opcode & 0x0f)
        head = head + Frame.byte_to_chr(b0)

        plen = @payload.length
        if plen <= 125
          head = head + Frame.byte_to_chr(plen)
        elsif plen <= 65535
          head = head + Frame.byte_to_chr(126)
          head = head + Frame.byte_to_chr((plen >> 8) & 0xff)
          head = head + Frame.byte_to_chr(plen & 0xff)
        else
          head = head + Frame.byte_to_chr(127)
          i = 7
          while i >= 0
            head = head + Frame.byte_to_chr((plen >> (i * 8)) & 0xff)
            i -= 1
          end
        end
        head + @payload
      end

      # Convert a single byte value (0..255) to a 1-char String.
      def self.byte_to_chr(n)
        (n & 0xff).chr
      end

      # Parse one frame from the sphttp recv frame buffer. `start`
      # is the byte offset to begin reading; `avail` is the count of
      # valid bytes in the buffer. Byte reads go through the Ruby
      # String binding sphttp_recv_frame_buf returns; matz/spinel#657
      # made slice / bytes[i] survive embedded NULs so binary
      # payloads parse correctly without the per-byte C accessor we
      # used before.
      #
      # Returns a ParseResult with one of three shapes:
      #   .status == "ok"      -> .frame populated + .consumed bytes used
      #   .status == "need"    -> need more bytes (consumed == 0)
      #   .status == "close"   -> protocol violation; close with .close_code
      def self.parse_from_buf(start, avail)
        out = Tep::WebSocket::ParseResult.new
        if avail - start < 2
          out.outcome = "need"
          return out
        end

        buf = Sock.sphttp_recv_frame_buf
        bs  = buf.bytes
        b0 = bs[start]
        b1 = bs[start + 1]
        fin    = (b0 & 0x80) != 0
        rsv    = b0 & 0x70
        opcode = b0 & 0x0f
        masked = (b1 & 0x80) != 0
        len7   = b1 & 0x7f

        if rsv != 0
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end
        if Frame.reserved_opcode?(opcode)
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end
        if Frame.control_opcode?(opcode)
          if !fin
            out.outcome = "close"
            out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
            return out
          end
          if len7 > 125
            out.outcome = "close"
            out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
            return out
          end
        end
        if !masked
          # Server MUST close on unmasked client frame (§5.3).
          out.outcome = "close"
          out.close_code = Tep::WebSocket::CLOSE_PROTOCOL_ERROR
          return out
        end

        # Decode payload length.
        pos = start + 2
        plen = 0
        if len7 < 126
          plen = len7
        elsif len7 == 126
          if avail - pos < 2
            out.outcome = "need"
            return out
          end
          h = bs[pos]
          l = bs[pos + 1]
          plen = (h << 8) | l
          pos += 2
        else
          # 64-bit length
          if avail - pos < 8
            out.outcome = "need"
            return out
          end
          plen = 0
          i = 0
          while i < 8
            plen = (plen << 8) | bs[pos + i]
            i += 1
          end
          pos += 8
        end

        # 4-byte mask key.
        if avail - pos < 4
          out.outcome = "need"
          return out
        end
        m0 = bs[pos]
        m1 = bs[pos + 1]
        m2 = bs[pos + 2]
        m3 = bs[pos + 3]
        pos += 4

        # Payload bytes.
        if avail - pos < plen
          out.outcome = "need"
          return out
        end

        # Decode + unmask in one pass.
        payload = ""
        i = 0
        while i < plen
          b = bs[pos + i]
          mask_byte = 0
          if (i & 3) == 0
            mask_byte = m0
          elsif (i & 3) == 1
            mask_byte = m1
          elsif (i & 3) == 2
            mask_byte = m2
          else
            mask_byte = m3
          end
          payload = payload + Frame.byte_to_chr(b ^ mask_byte)
          i += 1
        end

        out.outcome   = "ok"
        out.frame    = Tep::WebSocket::Frame.new(fin, opcode, payload)
        out.consumed = pos + plen - start
        out
      end

      def self.reserved_opcode?(op)
        if op == Tep::WebSocket::OPCODE_CONTINUATION
          return false
        end
        if op == Tep::WebSocket::OPCODE_TEXT
          return false
        end
        if op == Tep::WebSocket::OPCODE_BINARY
          return false
        end
        if op == Tep::WebSocket::OPCODE_CLOSE
          return false
        end
        if op == Tep::WebSocket::OPCODE_PING
          return false
        end
        if op == Tep::WebSocket::OPCODE_PONG
          return false
        end
        true
      end

      def self.control_opcode?(op)
        op == Tep::WebSocket::OPCODE_CLOSE ||
          op == Tep::WebSocket::OPCODE_PING ||
          op == Tep::WebSocket::OPCODE_PONG
      end
    end

    # ParseResult carries either a parsed frame, a "need more
    # bytes" signal, or a close-code for a protocol violation.
    # Field is named `outcome` (not `status`) because attr_accessor
    # :status collides with Tep::Response.status (Integer) under
    # spinel's same-name-attr unification family
    # (matz/spinel#537 / #538), widening Tep.reason(status) to
    # accept poly and breaking the build.
    class ParseResult
      attr_accessor :outcome, :frame, :consumed, :close_code

    end
  end
end

# --- inlined: tep/websocket/handshake.rb ---
# Tep::WebSocket::Handshake -- RFC 6455 §1.3 server-side handshake.
#
# `check(req)`:
#   Returns a Result with `.valid` true if the request is a proper
#   WebSocket upgrade, `.accept_key` set to the Sec-WebSocket-Accept
#   value the server should echo, and `.protocols` parsed from
#   Sec-WebSocket-Protocol. Invalid uses set `.valid = false` +
#   `.reason` for logging.
#
# `build_response(accept_key, protocol)`:
#   Returns the raw HTTP/1.1 101 Switching Protocols response bytes,
#   ready to write to the socket. `protocol` is the subprotocol to
#   echo (empty string = omit the header per RFC §1.3 -- the safe
#   default per rubys's pushback on tep#8).
module Tep
  module WebSocket
    class Driver
      attr_accessor :fd, :max_frame_size, :subprotocol
      # Callback slots. Each holds a subclass of Tep::WebSocket::Handler
      # (or the base) that gets `handle_event(event)` called when the
      # corresponding wire event arrives. Defaults to a no-op base
      # so the slot is type-safe pre-set.
      attr_accessor :h_open, :h_message, :h_close, :h_ping, :h_pong, :h_error


      def set_max_frame_size(n)
        @max_frame_size = n
      end

      # Reassign the underlying fd. Used by the server-side upgrade
      # path: the user handler builds the Driver with a placeholder
      # fd (since the client fd isn't visible at handler-dispatch
      # time), and the write_response branch sets the real fd here
      # right before constructing the Connection.

      def set_subprotocol(name)
        @subprotocol = name
      end

      def set_on_open(h);    @h_open = h;    end
      def set_on_message(h); @h_message = h; end
      def set_on_close(h);   @h_close = h;   end
      def set_on_ping(h);    @h_ping = h;    end
      def set_on_pong(h);    @h_pong = h;    end
      def set_on_error(h);   @h_error = h;   end

      # Send a text frame.
      def text(s)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_TEXT, s)
      end

      # Streamer-shape alias for `text` so a Driver can stand in
      # anywhere `Tep::Streamer`-style code calls `out.write(s)`.
      # Used by Tep::Llm.chat_stream to write LLM deltas as WS
      # frames (one frame per SSE-shaped chunk).

      # Send a binary frame.
      def binary(bytes)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_BINARY, bytes)
      end

      # Send a ping with optional payload (<=125 bytes).
      def ping(payload)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_PING, payload)
      end

      # Send a pong with the matching ping's payload (per §5.5.3).
      def pong(payload)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_PONG, payload)
      end

      # Send a close frame with code + reason. Reason capped at
      # 123 bytes so the 2-byte code + reason fits in a control
      # frame's 125-byte payload limit.
      def close(code, reason)
        body = Driver.encode_close_payload(code, reason)
        Driver.send_frame(@fd, Tep::WebSocket::OPCODE_CLOSE, body)
      end

      # Build the frame bytes (unmasked, server-side) and write via
      # sphttp_write_bytes (binary-safe, explicit length).
      def self.send_frame(fd, opcode, payload)
        frame = Tep::WebSocket::Frame.new(true, opcode, payload)
        bytes = frame.encode_unmasked
        Sock.sphttp_write_bytes(fd, bytes, bytes.length)
      end

      # Close payload: 2-byte big-endian code + UTF-8 reason. Per
      # §5.5.1 the payload may be omitted (close with no body); if
      # `code == 0` we emit an empty payload.
      def self.encode_close_payload(code, reason)
        if code == 0
          return ""
        end
        out = Tep::WebSocket::Frame.byte_to_chr((code >> 8) & 0xff) +
              Tep::WebSocket::Frame.byte_to_chr(code & 0xff)
        if reason.length > 123
          out + reason[0, 123]
        else
          out + reason
        end
      end
    end

    # Event passed to handler callbacks. Holds `data` (the payload
    # as String for text/binary, raw bytes for ping/pong, or the
    # close code+reason for close) and a numeric `code` for close.
    class Event
      attr_accessor :data, :code, :reason

    end

    # Base class for event handlers. Subclass + override
    # `handle_event(event)`. The Driver stores one Handler instance
    # per event type and dispatches via `@h_message.handle_event(evt)`.
    # The explicit-Handler shape (vs faye's block-based `driver.on(:msg)
    # { ... }`) is chosen because it stays compatible with future
    # Fiber.storage per-connection state plumbing without re-typing
    # the callback boundary.
    #
    # `req` is set at WS upgrade time by the route handler the
    # translator emits, giving on_X handler bodies access to the
    # request that initiated the connection (req.identity,
    # req.session, headers, ...). It stays the same across every
    # event on the connection -- there's no per-frame "request".
    class Handler
      attr_accessor :req


      def handle_event(event)
        0
      end
    end
  end
end

# --- inlined: tep/websocket/connection.rb ---
# Tep::WebSocket::Connection -- per-connection recv loop.
#
# Designed to run inside a Tep::Scheduler-managed fiber spawned by
# the upgrade route after the 101 response is written. The fiber:
#   1. Parks on Tep::Scheduler.io_wait(fd, READ, timeout) for bytes.
#   2. Reads via Sock.sphttp_recv_into_frame into the binary frame buf.
#   3. Walks the accumulated buffer with Frame.parse_from_buf,
#      dispatching events to the Driver's handlers.
#   4. On close (sent OR received), exits cleanly + closes the fd.
#
# The recv buffer (sphttp_frame_buf, 64 KiB) is the per-fork static
# from Phase 0.5; cross-fiber sharing within one worker process is
# bounded by the worker's cooperative scheduling -- only one fiber
# parses at a time. A future Phase 2.1 (or whenever multi-fiber WS
# concurrency-per-worker becomes a goal) replaces this with
# per-fiber buffers via Fiber.storage (matz/spinel#578).
module Tep
  module WebSocket
    # Standard opcodes.
    OPCODE_CONTINUATION = 0
    OPCODE_TEXT         = 1
    OPCODE_BINARY       = 2
    OPCODE_CLOSE        = 8
    OPCODE_PING         = 9
    OPCODE_PONG         = 10

    # Close codes (RFC 6455 §7.4). Caller-facing ones only -- the
    # internal-error / protocol-error codes are emitted by the
    # Driver directly, not exposed.
    CLOSE_NORMAL          = 1000
    CLOSE_GOING_AWAY      = 1001
    CLOSE_PROTOCOL_ERROR  = 1002
    CLOSE_UNSUPPORTED     = 1003
    CLOSE_INVALID_UTF8    = 1007
    CLOSE_POLICY_VIOLATION = 1008
    CLOSE_MESSAGE_TOO_BIG = 1009

    # Frame-size cap. Configurable via Driver#set_max_frame_size;
    # default is 16 MiB (large enough for any realistic chat /
    # Action Cable payload, bounded so an oversized frame can be
    # closed with 1009 rather than OOM-ing the worker).
    DEFAULT_MAX_FRAME = 16 * 1024 * 1024
  end
end


# --- inlined: tep/parallel.rb ---
# Tep::Parallel -- grosser/parallel-shaped process fan-out.
#
# Why
# ---
# Spinel doesn't ship Ractors, doesn't expose the GVL'd threading
# story, and the `parallel` gem (heavy use of `Marshal`,
# `IO.pipe`, dynamic `Proc` invocation) doesn't lower. Fork is
# however a perfectly cheap C call here, so the smallest useful
# slice of `parallel` -- "run this worker over a list of items,
# one child per item, collect the results" -- is implementable
# directly on top of sphttp's `sphttp_fork` + a tiny file-based
# IPC channel.
#
# API
# ---
#   results = Tep::Parallel.map_processes(items, worker)
#   #=> [String, String, ...]   -- one entry per input, in order
#
# `worker.run(item)` must return a String. Each child runs the
# worker once, writes its return value to a per-index file under
# /tmp, exits; the parent reaps everyone and reads the files
# back. The String constraint exists because passing structured
# data across fork would need Marshal, which spinel doesn't
# emit -- and HTTP-shaped APIs (the dashboard) round-trip
# strings naturally.
#
# Fire-and-forget shape:
#
#   Tep::Parallel.each_process(items, worker)
#
# Forks one child per item, doesn't capture results.
#
# Scope (v1)
# ----------
#   * One child per item -- no fixed-size pool. Fine up to a few
#     dozen items; for larger fan-outs the caller should chunk
#     beforehand or write the round-trip into Tep::Job.
#   * String return values only.
#   * No thread mode -- spinel doesn't lower MRI's Thread reliably.
#
# Closeness to grosser/parallel
# -----------------------------
# `parallel`'s top-level API is
#
#   Parallel.map(items, in_processes: N) { |x| ... }
#
# spinel can't take a block as a value, so we lift the body into
# a Worker class instead. Spinel also can't auto-cast subclass
# pointers at cmeth call sites (#429-shaped), which means cmeth
# args typed as a worker base class widen to poly at the call
# site and the C compile fails. The fix: store the worker in an
# instance field of `Tep::Parallel` -- typed-slot imeth dispatch
# works the same way `@before_filter.before(req, res)` does for
# `Tep::Filter`. Resulting shape:
#
#   p = Tep::Parallel.new(MyWorker.new)
#   results = p.map_processes(items)
#
# Worker base class
# -----------------
# Real workers subclass `Tep::ParallelWorker` and override `run(item)`.
# Two spinel landings made this name viable: matz/spinel#531 (270eceb)
# narrowed the poly-receiver dispatch table by ivar observed-class set
# (so `Tep::Server#run` no longer leaks into `@worker.run`'s switch),
# and matz/spinel#549 (1d561ad) collapsed the dispatch result to a
# scalar when all reachable arms agree on the return type (so the
# result lands as `const char *` instead of sp_RbVal).
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

  # Session signing secret. Empty by default, which disables session
  # writes (the Set-Cookie path no-ops). Set at app load time:
  #
  #   Tep.session_secret = ENV.fetch("TEP_SESSION_SECRET")
  #
  # Stored on the APP instance (spinel doesn't reliably type-track
  # module-level `@@cvars` or globals).

  APP = App.new


  # (PG::Connection / Result / Pool type-seeding relocated to
  # lib/tep/pg.rb -- #216. PG.Connection.new("") is a failed-conn
  # instance, not a raise, so the seeds stay safe at module load.)

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

  # SpinelKit::Log seed -- pin parameter types for every method even
  # when an app uses one but not another. The level-name string
  # ("info") and the messages ("") pin the :str shape; the file-
  # path setter pins to_file's :str arg.
  _tep_seed_logger = SpinelKit::Log.new
  _tep_seed_logger.set_level("info")
  _tep_seed_logger.to_file("")
  _tep_seed_logger.to_stderr
  _tep_seed_logger.debug("")
  _tep_seed_logger.info("")
  _tep_seed_logger.warn("")
  _tep_seed_logger.error("")
  SpinelKit::Log.level_value("info")

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
  #
  # These run at MODULE LOAD, so the paths must be readable in EVERY
  # deploy environment, not just gx10. `/etc/hostname` is absent in a
  # bare container (e.g. Upsun); under the engine's now-correct
  # ENOENT-raising File.read it threw at boot and 502'd the native
  # serve_bin (tep#199 boot-hazard report). `/dev/null` exists on every
  # POSIX target (Linux containers, macOS) and reads as empty, so it
  # pins the same :str param type without the missing-file crash. The
  # full fix -- no boot-time seed I/O at all -- is tep#199 (--rbs sig).
  Tep::Shell.run(":")
  Tep::Shell.run_limited(":", 1)
  Tep::Shell.read("/dev/null")
  Tep::Shell.read_limited("/dev/null", 64)

  # SpinelKit::Url seed -- the new split_url has to land at compile time.
  SpinelKit::Url.split_url("http://x/")

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

  # #127 chat streaming: ChatStreamSink + ChatCompletionsStreamer.
  # Mirror the 7.2 seed shape so spinel pins the sink's emit_*
  # arities + the streamer's accessor slots.
  _tep_seed_oai_chat_sink = Tep::Llm::OpenAI::ChatStreamSink.new
  _tep_seed_oai_chat_sink.out   = _tep_seed_oai_stream
  _tep_seed_oai_chat_sink.model = "m"
  _tep_seed_oai_chat_sink.completion_count
  _tep_seed_oai_chat_sink.emit_role_prelude("assistant")
  _tep_seed_oai_chat_sink.emit_token("seed")
  _tep_seed_oai_chat_sink.emit_finish("stop")
  _tep_seed_oai_backend.chat_completion_stream(_tep_seed_proxy_req, _tep_seed_oai_chat_sink)
  _tep_seed_oai_chat_streamer = Tep::Llm::OpenAI::ChatCompletionsStreamer.new
  _tep_seed_oai_chat_streamer.req_ref       = _tep_seed_proxy_req
  _tep_seed_oai_chat_streamer.model         = "m"
  _tep_seed_oai_chat_streamer.prompt_tokens = 0
  _tep_seed_oai_chat_streamer.t0            = 0
  _tep_seed_oai_chat_streamer.request_id    = ""
  _tep_seed_oai_chat_streamer.principal_id  = ""
  _tep_seed_proxy_res.start_stream(_tep_seed_oai_chat_streamer)

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
  SpinelKit::Hex.to_int("")

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
end

