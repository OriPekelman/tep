# All FFI plumbing lives at the top level so spinel's name resolver
# finds it from anywhere in the Tep tree (nested modules confuse it).
#
# The `@TEP_SPHTTP_O@` placeholder is substituted by `bin/tep` (or
# the Makefile) with the absolute path to the built sphttp.o on the
# current host. Spinel doesn't support `__dir__` or `ENV.fetch` in
# top-level ffi_cflags, so a build-time substitution is the cleanest
# portable shape.
module Sock
  ffi_cflags "@TEP_SPHTTP_O@"
  # Outbound TLS (sphttp_connect_tls) is backed by the system
  # libssl/libcrypto. Linked for every app (like sqlite3 elsewhere);
  # the plaintext path never calls into it, so apps that make no HTTPS
  # requests pay only the link cost, not runtime. See tep#148.
  # (When OpenSSL is off the default path -- macOS/Homebrew -- the build
  # finds it via CPATH/LIBRARY_PATH in the environment, not a cflag
  # here; spinel's ffi_cflags rejects an empty-string placeholder.)
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
module Crypto
  ffi_func :sp_crypto_hmac_sha256_hex,      [:str, :str],       :str
  ffi_func :sp_crypto_hmac_sha256_b64url,   [:str, :str],       :str
  ffi_func :sp_crypto_b64url_encode,        [:str],             :str
  ffi_func :sp_crypto_b64url_decode,        [:str],             :str
  ffi_func :sp_crypto_pbkdf2_sha256_b64url, [:str, :str, :int], :str
  ffi_func :sp_crypto_random_b64url,        [:int],             :str
  # SHA-1 + WebSocket accept-key compute. SHA-1 is shipped only
  # because RFC 6455 requires it for the Sec-WebSocket-Accept
  # derivation; do NOT use it for anything else (collision-broken).
  ffi_func :sp_crypto_sha1_hex,             [:str],             :str
  ffi_func :sp_crypto_websocket_accept,     [:str],             :str
end
