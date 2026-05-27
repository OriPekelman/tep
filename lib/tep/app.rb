# Tep::App -- the registered route table + filter slots + 404 handler.
#
# Each filter slot holds a single Tep::Filter instance. Spinel's
# `PtrArray` is homogeneously-typed and doesn't carry cls_id tags,
# so an array of mixed Filter subclasses falls through to base-class
# dispatch (the user's #before / #after never runs). A single slot
# typed as a union of subclasses keeps virtual dispatch working.
# Users compose multiple filters by writing one class that calls
# the others.
module Tep
  class App
    attr_accessor :router, :static_root, :session_secret
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
    attr_accessor :asset_bodies, :asset_mimes
    attr_accessor :sched_fibers, :sched_wake_at, :sched_current
    attr_accessor :sched_io_fd, :sched_io_mode, :sched_io_ready
    # Tep::Server::Scheduled needs a stash for per-connection state
    # that the connection-fiber reads on entry. Closure capture across
    # a Fiber.new { ... } boundary mis-lowers under spinel (heap-cell
    # access emitted without a declaration); the stash sidesteps that
    # by writing the values to App-state and yielding so the new fiber
    # reads them before the next accept iteration overwrites.
    attr_accessor :pending_listen_fd, :pending_client_fd, :pending_quiet
    # Tep::Job background-worker idempotency flag. App-level so a
    # single-shot spawn from a before-filter doesn't fire repeatedly.
    # Per-worker (each prefork child has its own Tep::APP, so each
    # worker spawns one background fiber).
    attr_accessor :user_bg_started

    def initialize
      @router         = Router.new
      @static_root    = ""
      @session_secret = ""
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
      @asset_bodies   = Tep.str_hash # path -> bytes (filled at boot
      @asset_mimes    = Tep.str_hash # by Tep::Assets._add lines
                                     # the bin/tep translator emits)
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
      # Tep::Server::Scheduled hand-off stash.
      @pending_listen_fd = -1
      @pending_client_fd = -1
      @pending_quiet     = false
      @user_bg_started   = false
    end

    def add_asset(path, body, mime)
      @asset_bodies[path] = body
      @asset_mimes[path]  = mime
    end

    def set_session_secret(s)
      @session_secret = s
    end

    def add_route(verb, pattern, handler)
      @router.add(verb, pattern, handler)
    end

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
    def set_not_found(h);         @nf_handler = h; end

    def dispatch(req, res)
      # Pull a signed session cookie into req.session, when configured.
      secret = Tep.session_secret
      if secret.length > 0
        cv = req.cookies[Tep::COOKIE_NAME]
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

    def try_static(req, res)
      if @static_root.length == 0
        return false
      end
      if req.verb != "GET" && req.verb != "HEAD"
        return false
      end
      if Tep.str_find(req.path, "..", 0) >= 0
        return false
      end
      full = @static_root + req.path
      sz = Sock.sphttp_filesize(full)
      if sz < 0
        return false
      end
      res.headers["Content-Type"] = App.guess_mime(full)
      res.headers["X-Tep-Static"] = "1"
      res.send_file(full)
      true
    end

    def self.guess_mime(path)
      lower = path.downcase
      if lower.end_with?(".html") || lower.end_with?(".htm")
        return "text/html; charset=utf-8"
      end
      if lower.end_with?(".css");  return "text/css"; end
      if lower.end_with?(".js");   return "application/javascript"; end
      if lower.end_with?(".json"); return "application/json"; end
      if lower.end_with?(".png");  return "image/png"; end
      if lower.end_with?(".jpg") || lower.end_with?(".jpeg"); return "image/jpeg"; end
      if lower.end_with?(".gif");  return "image/gif"; end
      if lower.end_with?(".svg");  return "image/svg+xml"; end
      if lower.end_with?(".txt");  return "text/plain; charset=utf-8"; end
      "application/octet-stream"
    end
  end
end
