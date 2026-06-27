# Tep ships the PG battery -- a libpq wrapper that mirrors the
# ruby-pg gem's public surface (PG::Connection / PG::Result /
# PG::Error and SQLSTATE-keyed subclasses) so an eventual
# ActiveRecord-on-spinel port reuses the existing AR pg adapter
# with minimal divergence.
#
# Implementation:
#   - lib/tep/tep_pg.c   -- the libpq C shim (integer-handle slot
#     tables, rotating return-string buffer, param accumulator).
#   - this file          -- the Ruby surface.
#
# Why not the `pg` gem? It's a CRuby native extension against MRI's
# ABI; spinel produces a static binary with no MRI runtime. The
# C-shim model (same pattern as Tep::SQLite) replaces "load a gem"
# with "link a .o at compile time."
#
# Namespace note: PG lives at the top level (matching `require 'pg'`
# from gem-shaped code), not under Tep::. This is the one battery
# that bends the Tep::Foo convention to keep AR-portability free.
#
# See docs/PG-BATTERY.md for the full design + per-method
# compatibility table.

module Pg
  ffi_cflags "@TEP_PG_O@"
  ffi_cflags "@TEP_PG_CFLAGS@"

  # Result-status constants (collapsed from libpq's 8-value enum
  # into the 4 callers care about; see tep_pg.c). Stable across
  # libpq versions.
  ffi_const :RES_TUPLES,   0
  ffi_const :RES_COMMAND,  1
  ffi_const :RES_EMPTY,    2
  ffi_const :RES_ERROR,    3

  # Connection lifecycle
  ffi_func :tep_pg_connect,                [:str],             :int
  ffi_func :tep_pg_connect_kv,             [:str, :str, :int], :int
  ffi_func :tep_pg_finish,                 [:int],             :int
  ffi_func :tep_pg_reset,                  [:int],             :int
  ffi_func :tep_pg_status,                 [:int],             :int
  ffi_func :tep_pg_transaction_status,     [:int],             :int
  ffi_func :tep_pg_error_message,          [:int],             :str
  ffi_func :tep_pg_server_version,         [:int],             :int
  ffi_func :tep_pg_set_client_encoding,    [:int, :str],       :int

  # Sync exec + param accumulator
  ffi_func :tep_pg_exec,                   [:int, :str],       :int
  ffi_func :tep_pg_param_clear,            [],                 :int
  ffi_func :tep_pg_param_push_str,         [:str],             :int
  ffi_func :tep_pg_param_push_null,        [],                 :int
  ffi_func :tep_pg_exec_params,            [:int, :str],       :int

  # Result inspection
  ffi_func :tep_pg_clear,                  [:int],             :int
  ffi_func :tep_pg_result_status,          [:int],             :int
  ffi_func :tep_pg_result_error_message,   [:int],             :str
  ffi_func :tep_pg_result_error_field,     [:int, :int],       :str
  ffi_func :tep_pg_cmd_status,             [:int],             :str
  ffi_func :tep_pg_cmd_tuples,             [:int],             :int

  ffi_func :tep_pg_ntuples,                [:int],             :int
  ffi_func :tep_pg_nfields,                [:int],             :int
  ffi_func :tep_pg_fname,                  [:int, :int],       :str
  ffi_func :tep_pg_fnumber,                [:int, :str],       :int
  ffi_func :tep_pg_ftype,                  [:int, :int],       :int
  ffi_func :tep_pg_fformat,                [:int, :int],       :int
  ffi_func :tep_pg_fmod,                   [:int, :int],       :int
  ffi_func :tep_pg_getvalue,               [:int, :int, :int], :str
  ffi_func :tep_pg_getisnull,              [:int, :int, :int], :int
  ffi_func :tep_pg_getlength,              [:int, :int, :int], :int

  # Escape
  ffi_func :tep_pg_escape_string,          [:int, :str],       :str
  ffi_func :tep_pg_escape_literal,         [:int, :str],       :str
  ffi_func :tep_pg_escape_identifier,      [:int, :str],       :str

  # Async connect (libpq PQconnectStart + PQconnectPoll). Used by
  # Connection#initialize when called inside a scheduled fiber, so
  # the connect's TCP handshake + auth round-trip parks via
  # Tep::Scheduler.io_wait instead of blocking the worker fiber.
  # PG::Pool's eager open at construction benefits when N
  # connections warm up in parallel under Scheduled.
  ffi_func :tep_pg_connect_start,          [:str],             :int
  ffi_func :tep_pg_connect_poll,           [:int],             :int

  # Async exec (libpq non-blocking surface). Used by
  # Connection#async_exec to park the fiber on Tep::Scheduler.io_wait
  # between PG round-trips under Tep::Server::Scheduled, so other
  # fibers in the same worker can run while the query is in flight.
  ffi_func :tep_pg_socket,                 [:int],             :int
  ffi_func :tep_pg_set_nonblocking,        [:int, :int],       :int
  ffi_func :tep_pg_send_query,             [:int, :str],       :int
  ffi_func :tep_pg_send_query_params,      [:int, :str],       :int
  ffi_func :tep_pg_flush,                  [:int],             :int
  ffi_func :tep_pg_consume_input,          [:int],             :int
  ffi_func :tep_pg_is_busy,                [:int],             :int
  ffi_func :tep_pg_get_result,             [:int],             :int

  # LISTEN / NOTIFY. Used by Tep::Broadcast's PG backend
  # (Battery 2 chunk 2.2) for cross-worker pub/sub. Channel names
  # are SQL identifiers (caller's responsibility to keep safe);
  # payloads are escaped server-side via PQescapeLiteral.
  ffi_func :tep_pg_listen,                 [:int, :str],       :int
  ffi_func :tep_pg_unlisten,               [:int, :str],       :int
  ffi_func :tep_pg_notify,                 [:int, :str, :str], :int
  ffi_func :tep_pg_poll_notification,      [:int, :int],       :int
  ffi_func :tep_pg_notify_channel,         [],                 :str
  ffi_func :tep_pg_notify_payload,         [],                 :str

  # Version
  ffi_func :tep_pg_libpq_version,          [],                 :str
end

# Public-facing PG module -- mirrors the ruby-pg gem's class
# layout. Callers write `PG.connect(...)`, `PG::Connection`,
# `PG::Result#each`, `rescue PG::UniqueViolation => e`, ...
module PG
  # Connection status constants (libpq's ConnStatusType collapsed
  # to the two values tep cares about).
  CONNECTION_OK  = 0
  CONNECTION_BAD = 1

  # Transaction status (libpq's PGTransactionStatusType).
  PQTRANS_IDLE    = 0
  PQTRANS_ACTIVE  = 1
  PQTRANS_INTRANS = 2
  PQTRANS_INERROR = 3
  PQTRANS_UNKNOWN = 4

  # Diagnostic field codes for Result#error_field. libpq uses single
  # ASCII chars internally (PG_DIAG_SQLSTATE = 'C' = 67); expose
  # them as integer constants here so callers can write
  # `r.error_field(PG::DIAG_SQLSTATE)` without magic numbers.
  DIAG_SEVERITY         = 83   # 'S'
  DIAG_SQLSTATE         = 67   # 'C'
  DIAG_MESSAGE_PRIMARY  = 77   # 'M'
  DIAG_MESSAGE_DETAIL   = 68   # 'D'
  DIAG_MESSAGE_HINT     = 72   # 'H'
  DIAG_STATEMENT_POSITION = 80 # 'P'
  DIAG_CONTEXT          = 87   # 'W'
  DIAG_SCHEMA_NAME      = 115  # 's'
  DIAG_TABLE_NAME       = 116  # 't'
  DIAG_COLUMN_NAME      = 99   # 'c'
  DIAG_DATATYPE_NAME    = 100  # 'd'
  DIAG_CONSTRAINT_NAME  = 110  # 'n'

  # Convenience constructor matching ruby-pg's PG.connect entry.
  # opts is either a libpq conninfo String ("postgresql://...") or
  # a String=>String Hash of libpq keys (host, port, dbname, user,
  # password, sslmode, ...).
  #
  # Unlike ruby-pg (which raises PG::ConnectionBad), connect does NOT
  # raise on failure: it returns a connection-failed Connection
  # (`connected?` false, `last_error_message` set). This is deliberate
  # -- PG::Pool type-seeds its free list with `PG::Connection.new("")`
  # at module load, before any server is reachable, so the constructor
  # has to be non-raising. Check `conn.connected?` before use. (Query
  # methods #exec / #exec_params DO raise; see Connection#exec.)
  def self.connect(opts)
    Connection.new(opts)
  end

  class Connection
    # `:pgh` rather than `:handle` -- same poly-dispatch widening
    # concern as Tep::SQLite#dbh (sharing a method name with
    # Tep::Handler#handle confuses spinel's same-named-imeth-across-
    # classes unifier).
    attr_accessor :pgh
    # Error context for the most recent exception raised by this
    # connection. Spinel's `raise X.new(msg, ...)` lowering doesn't
    # handle custom initializers (#622), so the SQLSTATE / message /
    # owning-result-handle live here instead. Read after
    # `rescue PG::Error => e`:
    #
    #     begin; conn.exec_params(sql, params)
    #     rescue PG::Error => e
    #       sqlstate = conn.last_sqlstate
    #       full_msg = conn.last_error_message
    #     end
    #
    # AR's `translate_exception_class(message, sql, binds)` uses
    # `e.is_a?(PG::UniqueViolation)` etc., which still works -- the
    # class hierarchy is intact; only the per-exception accessors
    # move to the connection.
    attr_accessor :last_sqlstate, :last_error_message, :last_result_rh

    def initialize(opts)
      @pgh = -1
      @last_sqlstate = ""
      @last_error_message = ""
      @last_result_rh = -1
      if opts.is_a?(String)
        if Tep::Scheduler.scheduled_context?
          h = Connection.async_connect(opts)
        else
          h = Pg.tep_pg_connect(opts)
        end
      else
        # Hash-conninfo form: pack the key/value pairs into NUL-delimited
        # buffers for the C shim. (`opts` narrows to Hash in this
        # is_a?(String) ELSE branch -- the narrowing gap that blocked the
        # re-pin, matz/spinel#1434, is fixed as of the SPINEL_PIN bump.)
        keys = ""
        vals = ""
        n = 0
        opts.each do |k, v|
          keys = keys + k + "\0"
          vals = vals + v + "\0"
          n += 1
        end
        h = Pg.tep_pg_connect_kv(keys, vals, n)
      end
      if h < 0
        # Slot 0 holds the most recent connect-failure error message
        # (PQstatus on a failed PQconnectdb still gives a readable
        # error, but the conn itself is closed by the time we get
        # here -- the shim stashes the message before PQfinish).
        @last_error_message = Pg.tep_pg_error_message(0)
        @last_sqlstate = ""
        # Connection-failure surfaces via `c.last_error_message` +
        # `c.connected?` after the constructor returns -- the
        # constructor stays non-raising on purpose (PG::Pool seeds its
        # free list with `PG::Connection.new("")` before a server is
        # reachable; a raising constructor would blow up at module
        # load). Callers must check `c.connected?` before exec. NB:
        # this is the lone non-raising path -- query methods raise
        # PG::Error subclasses now that spinel supports namespaced
        # raise + rescue (matz/spinel#627 + #1041).
      end
      @pgh = h
    end

    def connected?
      @pgh >= 0
    end

    def close
      if @pgh >= 0
        Pg.tep_pg_finish(@pgh)
        @pgh = -1
      end
      0
    end

    def finish
      close
    end

    def reset
      if @pgh >= 0
        Pg.tep_pg_reset(@pgh)
      end
      self
    end

    def status
      @pgh < 0 ? PG::CONNECTION_BAD : Pg.tep_pg_status(@pgh)
    end

    def transaction_status
      @pgh < 0 ? PG::PQTRANS_UNKNOWN : Pg.tep_pg_transaction_status(@pgh)
    end

    def server_version
      @pgh < 0 ? 0 : Pg.tep_pg_server_version(@pgh)
    end

    def error_message
      @pgh < 0 ? "" : Pg.tep_pg_error_message(@pgh)
    end

    # LISTEN / NOTIFY (Battery 2 chunk 2.2). Used by
    # Tep::Broadcast's PG backend for cross-worker pub/sub.
    # Channel names must be safe SQL identifiers (no caller-
    # controlled interpolation -- use a hard-coded constant).
    # Payload max size is 8000 bytes per PG default.
    def listen(channel)
      return -1 if @pgh < 0
      Pg.tep_pg_listen(@pgh, channel)
    end

    def unlisten(channel)
      return -1 if @pgh < 0
      Pg.tep_pg_unlisten(@pgh, channel)
    end

    def notify(channel, payload)
      return -1 if @pgh < 0
      Pg.tep_pg_notify(@pgh, channel, payload)
    end

    # Block up to `timeout_ms` waiting for one notification on the
    # connection. Returns 1 on receipt (caller then reads
    # #last_notify_channel + #last_notify_payload), 0 on timeout,
    # -1 on connection error. Connection must already be in LISTEN
    # mode for the channel of interest.
    def poll_notification(timeout_ms)
      return -1 if @pgh < 0
      Pg.tep_pg_poll_notification(@pgh, timeout_ms)
    end

    def last_notify_channel
      Pg.tep_pg_notify_channel
    end

    def last_notify_payload
      Pg.tep_pg_notify_payload
    end

    # Run a no-params query. Returns a PG::Result on success.
    #
    # ON ERROR IT RAISES the SQLSTATE-mapped PG::Error subclass
    # (PG::UniqueViolation, PG::UndefinedTable, ... -> PG::ServerError
    # for unmapped states) -- the ruby-pg / AR shape. The failed
    # PGresult is freed before the raise; the SQLSTATE / message stay
    # readable on `conn.last_sqlstate` / `#last_error_message` for
    # post-rescue inspection:
    #
    #     begin
    #       c.exec(sql)
    #     rescue PG::UniqueViolation => e
    #       ...                     # e.message + c.last_sqlstate
    #     rescue PG::Error => e     # base catches any server error
    #       ...
    #     end
    #
    # Raising (instead of the old Result-on-error sentinel) became
    # viable once spinel learned namespaced raise + hierarchy-walking
    # rescue (matz/spinel#627 + #1041). NB: PG.connect is the one path
    # that still does NOT raise -- it returns a connection-failed
    # instance so PG::Pool can type-seed without a live server (check
    # `conn.connected?`).
    #
    # Under `Tep::Server::Scheduled` this routes through the libpq
    # async surface (PQsendQuery + PQflush + PQconsumeInput parked
    # on Tep::Scheduler.io_wait), so other fibers in the same
    # worker can run while the query is in flight. Under prefork
    # it routes through the blocking PQexec. Both raise identically.
    def exec(sql)
      if Tep::Scheduler.scheduled_context?
        return async_exec(sql)
      end
      rh = Pg.tep_pg_exec(@pgh, sql)
      r = PG::Result.new(rh)
      Connection.record_error_if_any(self, r)
      r
    end

    # Parameterised query with positional binds ($1, $2, ...).
    # `params` is an Array of String / Integer / nil. Same
    # raise-on-error contract + auto-routing as `exec`.
    def exec_params(sql, params)
      Pg.tep_pg_param_clear
      i = 0
      n = params.length
      while i < n
        p = params[i]
        if p == nil
          Pg.tep_pg_param_push_null
        else
          Pg.tep_pg_param_push_str(p.to_s)
        end
        i += 1
      end
      if Tep::Scheduler.scheduled_context?
        return async_exec_params_after_clear(sql)
      end
      rh = Pg.tep_pg_exec_params(@pgh, sql)
      r = PG::Result.new(rh)
      Connection.record_error_if_any(self, r)
      r
    end

    # Explicit async exec. Same shape as `exec` but doesn't
    # context-detect -- always uses the libpq async surface. If
    # called outside Tep::Server::Scheduled, Tep::Scheduler.io_wait
    # falls back to a single-shot poll(2), so this still works
    # under prefork (just without the cross-fiber concurrency
    # win).
    def async_exec(sql)
      Pg.tep_pg_set_nonblocking(@pgh, 1)
      ok = Pg.tep_pg_send_query(@pgh, sql)
      if ok != 1
        Connection.raise_send_failure(self)
      end
      Connection.drain_send(@pgh)
      Connection.wait_for_result_ready(@pgh)
      rh = Pg.tep_pg_get_result(@pgh)
      r = PG::Result.new(rh)
      # Drain trailing NULL terminator (libpq requires reading
      # until PQgetResult returns NULL to mark the conn ready for
      # the next send_query).
      Connection.drain_remaining_results(@pgh)
      Connection.record_error_if_any(self, r)
      r
    end

    # Parameterised async exec. `params` is an Array of
    # String / Integer / nil; same conversion as exec_params.
    def async_exec_params(sql, params)
      Pg.tep_pg_param_clear
      i = 0
      n = params.length
      while i < n
        p = params[i]
        if p == nil
          Pg.tep_pg_param_push_null
        else
          Pg.tep_pg_param_push_str(p.to_s)
        end
        i += 1
      end
      async_exec_params_after_clear(sql)
    end

    # Internal: param accumulator has already been populated by
    # the caller (either exec_params routing here on context
    # detect, or async_exec_params after its own push loop).
    def async_exec_params_after_clear(sql)
      Pg.tep_pg_set_nonblocking(@pgh, 1)
      ok = Pg.tep_pg_send_query_params(@pgh, sql)
      if ok != 1
        Connection.raise_send_failure(self)
      end
      Connection.drain_send(@pgh)
      Connection.wait_for_result_ready(@pgh)
      rh = Pg.tep_pg_get_result(@pgh)
      r = PG::Result.new(rh)
      Connection.drain_remaining_results(@pgh)
      Connection.record_error_if_any(self, r)
      r
    end

    # --- Async connect helper ---

    # Drive PQconnectStart + PQconnectPoll, parking on io_wait
    # between poll calls. Returns the conn slot (>=1) on success
    # or -1 on failure. The C shim's tep_pg_connect_poll stashes
    # the libpq error message on a FAILED return so
    # `Pg.tep_pg_error_message(0)` still surfaces the diagnostic
    # for the Connection.new "connect failed" branch.
    #
    # libpq's PostgresPollingStatusType:
    #   0 = PGRES_POLLING_FAILED
    #   1 = PGRES_POLLING_READING    (wait for fd READ-ready)
    #   2 = PGRES_POLLING_WRITING    (wait for fd WRITE-ready)
    #   3 = PGRES_POLLING_OK         (connected; stop polling)
    def self.async_connect(conninfo)
      h = Pg.tep_pg_connect_start(conninfo)
      if h < 0
        return -1
      end
      fd = Pg.tep_pg_socket(h)
      while true
        state = Pg.tep_pg_connect_poll(h)
        if state == 3
          # PGRES_POLLING_OK
          Pg.tep_pg_set_client_encoding(h, "UTF8")
          return h
        end
        if state == 0
          # PGRES_POLLING_FAILED. The shim has already stashed the
          # error message; we PQfinish the slot.
          Pg.tep_pg_finish(h)
          return -1
        end
        mode = state == 1 ? Tep::Scheduler::READ : Tep::Scheduler::WRITE
        Tep::Scheduler.io_wait(fd, mode, 10)
      end
      -1
    end

    # --- Internal helpers for the async loop ---

    # PQsendQuery returned 0 (immediate failure -- conn already
    # closed, send buffer error, etc.). Mirror the error onto the
    # conn's last_* and raise, matching the exec error path (ruby-pg
    # surfaces a send failure as PG::UnableToSend < PG::Error). No
    # SQLSTATE is available pre-result, so this maps to the transport
    # leaf rather than going through raise_for_sqlstate.
    def self.raise_send_failure(conn)
      conn.last_sqlstate = ""
      conn.last_error_message = conn.error_message
      conn.last_result_rh = -1
      raise PG::UnableToSend, conn.error_message
    end

    # Drain libpq's send buffer. PQflush returns 0 when done; 1
    # when the kernel send-buffer is full and we should park on
    # WRITE-ready; -1 on error. Timeout is generous (10s); a
    # genuinely-stuck PG is the rare case worth bailing on.
    def self.drain_send(pgh)
      fd = Pg.tep_pg_socket(pgh)
      while true
        rc = Pg.tep_pg_flush(pgh)
        if rc == 0
          return 0
        end
        if rc < 0
          return -1
        end
        # rc == 1: send buffer full, park on writability.
        Tep::Scheduler.io_wait(fd, Tep::Scheduler::WRITE, 10)
      end
      0
    end

    # Wait until PQisBusy returns 0 (PQgetResult won't block).
    # Pumps PQconsumeInput in between io_wait calls so the
    # libpq state machine advances. Timeout is generous (30s)
    # since the query itself can take that long; the io_wait
    # timeout is per-iteration, not cumulative.
    def self.wait_for_result_ready(pgh)
      fd = Pg.tep_pg_socket(pgh)
      while true
        if Pg.tep_pg_consume_input(pgh) != 1
          return -1
        end
        if Pg.tep_pg_is_busy(pgh) == 0
          return 0
        end
        Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, 30)
      end
      0
    end

    # After the first PQgetResult returned a real Result, libpq
    # requires the conn be drained via additional PQgetResult
    # calls until NULL is returned. This is a fast in-memory drain
    # (no network), but it has to happen between async_exec calls
    # or the next send_query will fail. Each tep_pg_get_result
    # call that produces a non-NULL result stashes it in the slot
    # table; we PQclear those immediately since they're trailing
    # status results we don't expose.
    def self.drain_remaining_results(pgh)
      while true
        rh = Pg.tep_pg_get_result(pgh)
        if rh < 0
          return 0
        end
        # A trailing result -- shouldn't normally happen for
        # single-statement queries, but defensively free.
        Pg.tep_pg_clear(rh)
      end
      0
    end

    def escape_string(s)
      Pg.tep_pg_escape_string(@pgh, s)
    end

    def escape_identifier(s)
      Pg.tep_pg_escape_identifier(@pgh, s)
    end

    def escape_literal(s)
      Pg.tep_pg_escape_literal(@pgh, s)
    end

    # Class-method form -- ruby-pg allows escape_string and
    # quote_ident without a live conn. We route through slot 0
    # which the shim treats as "no conn, fall back to standalone
    # PQescapeString". Use the instance method when a conn is
    # available -- it goes through PQescapeStringConn which is
    # the standards-compliant path.
    def self.escape_string(s)
      Pg.tep_pg_escape_string(0, s)
    end

    def self.quote_ident(s)
      # PQescapeIdentifier requires a conn; without one we fall
      # through to "" which is wrong but rare. Apps with a live
      # PG::Connection should use the instance method.
      Pg.tep_pg_escape_identifier(0, s)
    end

    # If the Result is in an error state, mirror SQLSTATE +
    # message + result-handle onto the conn so post-rescue (or
    # post-`if !r.ok?`) callers can read them via `conn.last_*`.
    # No raise here -- see the docstring on `exec` for why.
    def self.record_error_if_any(conn, r)
      st = r.status
      if st == Pg::RES_TUPLES || st == Pg::RES_COMMAND || st == Pg::RES_EMPTY
        return 0
      end
      sqlstate = r.error_field(PG::DIAG_SQLSTATE)
      msg = r.error_message
      if msg.length == 0
        msg = conn.error_message
      end
      conn.last_sqlstate = sqlstate
      conn.last_error_message = msg
      # Free the failed PGresult NOW: once we raise out of
      # exec/exec_params the caller's `r.clear` never runs, so this is
      # the only chance to release it. The SQLSTATE / message are
      # already copied onto conn.last_* (Strings) for post-rescue
      # inspection, so dropping the handle loses nothing callers need.
      conn.last_result_rh = -1
      r.clear
      # ruby-pg / AR parity: raise the SQLSTATE-mapped PG::Error
      # subclass (live since matz/spinel#627 + #1041 -- namespaced
      # raise + hierarchy-walking rescue). Callers `rescue
      # PG::UniqueViolation` (leaf) or `rescue PG::Error` (base).
      PG.raise_for_sqlstate(sqlstate, msg)
      0
    end
  end

  class Result
    attr_accessor :rh

    def initialize(rh)
      @rh = rh
    end

    def status
      @rh < 0 ? Pg::RES_ERROR : Pg.tep_pg_result_status(@rh)
    end

    # True when the query reached the server and produced a
    # non-error result (rows, command success, or empty query).
    # Inspect `error_message` / `error_field(5)` on a non-ok result.
    def ok?
      st = status
      st == Pg::RES_TUPLES || st == Pg::RES_COMMAND || st == Pg::RES_EMPTY
    end

    def error_message
      @rh < 0 ? "" : Pg.tep_pg_result_error_message(@rh)
    end

    def error_field(code)
      @rh < 0 ? "" : Pg.tep_pg_result_error_field(@rh, code)
    end

    def cmd_status
      @rh < 0 ? "" : Pg.tep_pg_cmd_status(@rh)
    end

    # ruby-pg's PG::Result#error_field shortcut: 5-char SQLSTATE
    # string. Empty when the result isn't an error.
    def sql_state
      error_field(PG::DIAG_SQLSTATE)
    end

    def cmd_tuples
      @rh < 0 ? 0 : Pg.tep_pg_cmd_tuples(@rh)
    end

    def ntuples
      @rh < 0 ? 0 : Pg.tep_pg_ntuples(@rh)
    end

    def nfields
      @rh < 0 ? 0 : Pg.tep_pg_nfields(@rh)
    end

    # ruby-pg aliases for ntuples / nfields.
    def num_tuples; ntuples; end
    def num_fields; nfields; end

    def fname(col)
      @rh < 0 ? "" : Pg.tep_pg_fname(@rh, col)
    end

    def fnumber(name)
      @rh < 0 ? -1 : Pg.tep_pg_fnumber(@rh, name)
    end

    def ftype(col)
      @rh < 0 ? 0 : Pg.tep_pg_ftype(@rh, col)
    end

    def fformat(col)
      @rh < 0 ? 0 : Pg.tep_pg_fformat(@rh, col)
    end

    def fmod(col)
      @rh < 0 ? -1 : Pg.tep_pg_fmod(@rh, col)
    end

    def getvalue(row, col)
      @rh < 0 ? "" : Pg.tep_pg_getvalue(@rh, row, col)
    end

    def getisnull(row, col)
      @rh < 0 ? true : Pg.tep_pg_getisnull(@rh, row, col) == 1
    end

    def getlength(row, col)
      @rh < 0 ? 0 : Pg.tep_pg_getlength(@rh, row, col)
    end

    # ruby-pg's #value is an alias for #getvalue.
    def value(row, col)
      getvalue(row, col)
    end

    def fields
      out = [""]
      out.delete_at(0)
      w = nfields
      j = 0
      while j < w
        out.push(fname(j))
        j += 1
      end
      out
    end

    def values
      rows = [[""]]
      rows.delete_at(0)
      n = ntuples
      w = nfields
      i = 0
      while i < n
        row = [""]
        row.delete_at(0)
        j = 0
        while j < w
          row.push(getvalue(i, j))
          j += 1
        end
        rows.push(row)
        i += 1
      end
      rows
    end

    def column_values(col)
      out = [""]
      out.delete_at(0)
      n = ntuples
      i = 0
      while i < n
        out.push(getvalue(i, col))
        i += 1
      end
      out
    end

    # Array-yielding iteration. Cleaner shape than #each for hot
    # paths -- no Hash allocation per row.
    def each_row
      n = ntuples
      w = nfields
      i = 0
      while i < n
        row = [""]
        row.delete_at(0)
        j = 0
        while j < w
          row.push(getvalue(i, j))
          j += 1
        end
        yield row
        i += 1
      end
      self
    end

    # Hash-yielding iteration -- matches ruby-pg's #each. Pre-builds
    # the field-name array to skip a per-row fname call. The Hash
    # shape is pinned to str_str_hash via a seed in lib/tep.rb;
    # without that seed spinel widens to poly_poly_hash on first
    # use.
    def each
      flds = fields
      n = ntuples
      w = flds.length
      i = 0
      while i < n
        row = Tep.str_hash
        j = 0
        while j < w
          row[flds[j]] = getvalue(i, j)
          j += 1
        end
        yield row
        i += 1
      end
      self
    end

    def clear
      if @rh >= 0
        Pg.tep_pg_clear(@rh)
        @rh = -1
      end
      0
    end
  end

  # libpq version string ("16.2.0" etc.). Diagnostic / banner use.
  def self.libpq_version
    Pg.tep_pg_libpq_version
  end

  # -------- Exception hierarchy --------
  #
  # Mirrors ruby-pg's PG::Error tree. ActiveRecord's adapter
  # pattern-matches with `e.is_a?(PG::UniqueViolation)` etc.; the
  # leaf classes are what makes that pattern work without a SQLSTATE
  # parse at every callsite.
  #
  # v1 ships base + ConnectionBad + UnableToSend + ServerError; the
  # SQLSTATE-keyed leaves below are the v1.5 surface (AR-coverage
  # subset). Adding a leaf is one class definition + one line in
  # error_class_for_sqlstate.

  # PG::Error hierarchy -- ruby-pg-shape, SQLSTATE-keyed. AR's
  # pg adapter does `e.is_a?(PG::UniqueViolation)` to translate
  # libpq errors; the class identity has to match. Live since
  # matz/spinel#627 (rescue ParentClass + is_a?(ParentClass) walk
  # the class hierarchy).
  #
  # Raised by Connection#exec / #exec_params via the two-arg
  # `raise PG::Klass, msg` form (spinel can't lower `raise
  # X.new(msg, ...)` for custom Exception initializers --
  # matz/spinel#622). SQLSTATE / result-handle context lives on
  # `conn.last_sqlstate` / `#last_error_message` / `#last_result_rh`
  # for callers who need them post-rescue.
  class Error < StandardError; end

  class ConnectionBad < Error; end
  class UnableToSend  < Error; end
  class ServerError   < Error; end

  # SQLSTATE class 23 -- integrity constraint violation
  class IntegrityConstraintViolation < ServerError; end
  class NotNullViolation     < IntegrityConstraintViolation; end   # 23502
  class ForeignKeyViolation  < IntegrityConstraintViolation; end   # 23503
  class UniqueViolation      < IntegrityConstraintViolation; end   # 23505
  class CheckViolation       < IntegrityConstraintViolation; end   # 23514
  class ExclusionViolation   < IntegrityConstraintViolation; end   # 23P01

  # SQLSTATE class 25 -- invalid transaction state
  class InFailedSqlTransaction < ServerError; end                  # 25P02
  class ReadOnlySqlTransaction < ServerError; end                  # 25006

  # SQLSTATE class 40 -- transaction rollback
  class SerializationFailure   < ServerError; end                  # 40001
  class DeadlockDetected       < ServerError; end                  # 40P01

  # SQLSTATE class 42 -- syntax / access rule violation
  class SyntaxError            < ServerError; end                  # 42601
  class UndefinedColumn        < ServerError; end                  # 42703
  class UndefinedFunction      < ServerError; end                  # 42883
  class UndefinedTable         < ServerError; end                  # 42P01
  class DuplicateColumn        < ServerError; end                  # 42701
  class DuplicateTable         < ServerError; end                  # 42P07
  class InsufficientPrivilege  < ServerError; end                  # 42501

  # SQLSTATE class 57 -- operator intervention
  class QueryCanceled          < ServerError; end                  # 57014
  class AdminShutdown          < ServerError; end                  # 57P01

  # SQLSTATE class 08 -- connection exception
  class ConnectionException    < ServerError; end                  # 08000
  class ConnectionDoesNotExist < ServerError; end                  # 08003

  # Pool-side error (no SQLSTATE): raised by PG::Pool#checkout when
  # the pool stays empty past the checkout timeout. Subclasses Error
  # so callers can `rescue PG::PoolExhausted` or the broader
  # `rescue PG::Error`. (Raising namespaced errors from instance
  # methods became viable with matz/spinel#1041; before that, checkout
  # surfaced exhaustion as a sentinel nil-equivalent Connection.)
  class PoolExhausted          < Error; end

  # Raise the PG::Error subclass mapped from a 5-char SQLSTATE.
  # Connection#exec / #exec_params call this (via record_error_if_any)
  # so a failed query surfaces as a typed exception -- the ruby-pg / AR
  # shape, where the adapter does `rescue PG::UniqueViolation` /
  # `e.is_a?(PG::UndefinedTable)`. An unmapped SQLSTATE falls through to
  # PG::ServerError, so `rescue PG::Error` still catches every server
  # error. The mapping is the SQLSTATE-keyed subset the leaf classes
  # cover (AR-coverage); add a leaf + an arm here together.
  #
  # Literal-class dispatch (one `raise PG::Klass` per arm) rather than
  # `raise klass_var` -- raising a Class held in a local doesn't lower
  # under spinel; the constant-path raise is what matz/spinel#1041 made
  # work.
  def self.raise_for_sqlstate(state, msg)
    # 23 -- integrity constraint violation
    if state == "23502"
      raise PG::NotNullViolation, msg
    elsif state == "23503"
      raise PG::ForeignKeyViolation, msg
    elsif state == "23505"
      raise PG::UniqueViolation, msg
    elsif state == "23514"
      raise PG::CheckViolation, msg
    elsif state == "23P01"
      raise PG::ExclusionViolation, msg
    # 25 -- invalid transaction state
    elsif state == "25P02"
      raise PG::InFailedSqlTransaction, msg
    elsif state == "25006"
      raise PG::ReadOnlySqlTransaction, msg
    # 40 -- transaction rollback
    elsif state == "40001"
      raise PG::SerializationFailure, msg
    elsif state == "40P01"
      raise PG::DeadlockDetected, msg
    # 42 -- syntax / access rule violation
    elsif state == "42601"
      raise PG::SyntaxError, msg
    elsif state == "42703"
      raise PG::UndefinedColumn, msg
    elsif state == "42883"
      raise PG::UndefinedFunction, msg
    elsif state == "42P01"
      raise PG::UndefinedTable, msg
    elsif state == "42701"
      raise PG::DuplicateColumn, msg
    elsif state == "42P07"
      raise PG::DuplicateTable, msg
    elsif state == "42501"
      raise PG::InsufficientPrivilege, msg
    # 57 -- operator intervention
    elsif state == "57014"
      raise PG::QueryCanceled, msg
    elsif state == "57P01"
      raise PG::AdminShutdown, msg
    # 08 -- connection exception
    elsif state == "08000"
      raise PG::ConnectionException, msg
    elsif state == "08003"
      raise PG::ConnectionDoesNotExist, msg
    else
      raise PG::ServerError, msg
    end
  end

  # -------- Connection pool --------
  #
  # PG::Pool -- a fixed-size connection pool for PG::Connection
  # instances. Mirrors ruby-pg's `PG::Pool` shape from the
  # external pg_pool gem (and the same idea as AR's
  # ConnectionPool): hold N pre-opened connections, hand them out
  # via `checkout` / take them back via `checkin`, park
  # cooperatively under `Tep::Server::Scheduled` when the free
  # list is empty.
  #
  # Typical use:
  #
  #     POOL = PG::Pool.new(ENV["DATABASE_URL"], 8)
  #
  #     get '/users/:id' do
  #       c = POOL.checkout
  #       r = c.exec_params("SELECT name FROM users WHERE id = $1",
  #                         [params[:id]])
  #       name = r.getvalue(0, 0)
  #       r.clear
  #       POOL.checkin(c)
  #       name
  #     end
  #
  # The block-form `with { |c| ... }` is deferred until spinel
  # lights up instance-method typed yields (matz/spinel#628 covers
  # the top-level def case but not instance methods); manual
  # checkout/checkin is the v1 shape.
  #
  # Concurrency model:
  #
  #   - Under prefork (Tep::Server, the default): one Pool per
  #     worker process; eagerly opens its N conns at boot. N tunes
  #     the per-worker in-flight query count.
  #   - Under Tep::Server::Scheduled: one Pool for the whole
  #     worker; checkouts that find the free list empty park via
  #     `Tep::Scheduler.pause(0.001)` until a checkin happens.
  #     Other fibers run in the meantime; eventually a checkin
  #     refills the free list and the parked fiber retries.
  #
  # On exhaustion (non-scheduled callers only), checkout raises
  # PG::PoolExhausted once it has waited past @checkout_timeout_ms.
  # This used to be a sentinel nil-equivalent return because spinel
  # couldn't rescue module-namespaced exception classes; matz/spinel#1041
  # fixed that, so `rescue PG::PoolExhausted` / `rescue PG::Error` now
  # work. The scheduled path parks indefinitely (waking on checkin) and
  # so has no exhaustion timeout -- only the spin fallback does.
  class Pool
    attr_accessor :url, :size, :free, :waiter_idxs, :checkout_timeout_ms

    def initialize(url, size)
      @url = url
      @size = size
      @checkout_timeout_ms = 5000  # 5s default; bump for slow upstreams
      # Type-seed @free as PtrArray<PG::Connection>. PG::Connection.new
      # with an empty conninfo returns a connection-failed instance
      # (@pgh=-1, populated @last_error_message) rather than raising,
      # so this is safe to run at module load even when PG isn't
      # reachable.
      @free = [PG::Connection.new("")]
      @free.delete_at(0)
      # Waiter queue: IntArray of fiber indices into Tep::APP.sched_fibers.
      # `checkout` parks the current fiber here when @free is empty
      # (under Scheduled); `checkin` resumes the oldest waiter by
      # setting its wake_at = -1. Type-seed with an int + delete.
      @waiter_idxs = [0]
      @waiter_idxs.delete_at(0)
      # Eager open of N real conns. If the URL isn't reachable, each
      # Connection will have @pgh=-1; the caller can check
      # `pool.healthy?` after construction.
      i = 0
      while i < size
        c = PG::Connection.new(url)
        @free.push(c)
        i += 1
      end
    end

    # True iff every pooled connection opened successfully. Use
    # after construction to fail loud rather than handing out
    # broken conns:
    #
    #     POOL = PG::Pool.new(url, 8)
    #     raise "PG unreachable" unless POOL.healthy?
    def healthy?
      i = 0
      while i < @free.length
        if !@free[i].connected?
          return false
        end
        i += 1
      end
      @free.length == @size
    end

    def set_checkout_timeout_ms(ms)
      @checkout_timeout_ms = ms
    end

    # Acquire a connection. Returns a PG::Connection on success.
    #
    # Two paths:
    #
    #   - Under Tep::Server::Scheduled: park the current fiber in
    #     the pool's waiter queue (via Fiber.yield with a far-future
    #     wake_at sentinel). `checkin` wakes the oldest waiter by
    #     setting its wake_at=-1, which marks it as due on the next
    #     scheduler tick. No busy-spin -- the scheduler runs other
    #     fibers (handlers, accept loop, async-exec parkers) until
    #     a checkin happens.
    #
    #   - Outside scheduled context (prefork-blocking or top-level
    #     code): fall back to a small-step pause-and-retry. Each
    #     worker is single-threaded in prefork, so a busy
    #     checkout-on-empty only happens if user code holds two
    #     checkouts inside one handler. Document; rarely matters.
    def checkout
      if @free.length > 0
        return @free.delete_at(0)
      end
      if !Tep::Scheduler.scheduled_context?
        return checkout_spin_fallback
      end
      # Cooperative wait. Stash our fiber index, park, wait for
      # checkin to set wake_at=-1.
      idx = Tep::APP.sched_current
      @waiter_idxs.push(idx)
      # Far-future sentinel: the scheduler won't pick us as
      # time-due until checkin lowers our wake_at. Tep::Scheduler's
      # int-second resolution means "not soon enough to matter"
      # = a few hours.
      Tep::APP.sched_wake_at[idx] = Time.now.to_i + 86400
      Fiber.yield
      # When we resume, checkin pushed a conn to @free + woke us.
      # Pop it.
      @free.delete_at(0)
    end

    # Return a connection to the pool. If there's a parked waiter,
    # wake it (push to @free + set wake_at=-1 on the waiter's
    # fiber index). Otherwise just push to @free.
    def checkin(c)
      @free.push(c)
      if @waiter_idxs.length > 0
        widx = @waiter_idxs.delete_at(0)
        # wake_at = -1 makes the fiber the "earliest due" in the
        # next tick's pick (the tick comparator chooses the lowest
        # wake_at among the time-due set, so -1 always wins).
        Tep::APP.sched_wake_at[widx] = -1
      end
      0
    end

    # Pause-and-retry fallback for non-scheduled callers. Used by
    # checkout when called outside a fiber. Since pause's seconds
    # arg is stored as an mrb_int (rounds sub-second values to 0),
    # this actually busy-spins under the scheduler -- but the
    # branch is only taken outside scheduled context, so there's
    # no fiber starvation concern: the worker is single-threaded
    # and either has a free conn or doesn't.
    def checkout_spin_fallback
      waited_ms = 0
      while @free.length == 0
        Tep::Scheduler.pause(1)   # full-second pause; non-scheduled fallback
        waited_ms += 1000
        if waited_ms >= @checkout_timeout_ms
          raise PG::PoolExhausted,
                "PG::Pool#checkout timed out after " +
                @checkout_timeout_ms.to_s + "ms; all " +
                @size.to_s + " connections in use"
        end
      end
      @free.delete_at(0)
    end

    # Diagnostic: how many connections are currently available.
    def available
      @free.length
    end

    # Close every connection. Call at app shutdown if needed; the
    # OS recovers them on process exit anyway.
    def close_all
      while @free.length > 0
        c = @free.delete_at(0)
        c.close
      end
      0
    end
  end
end

# ===================================================================
# Opt-in PG backend overrides (#216). Loaded only via `require "tep/pg"`.
# These REDEFINE the no-op hooks in core Broadcast/Presence (last-
# definition-wins) so a PG app gets the real LISTEN/NOTIFY + mirror
# behavior, while a non-PG app keeps the no-ops and DCEs libpq.
# ===================================================================
module Tep
  module Broadcast
    # Cross-worker NOTIFY override (#216). Replaces the core no-op so a
    # `require "tep/pg"` app fans publishes out to other workers over the
    # LISTEN/NOTIFY channel. Mirrors the pre-#216 inline branch in
    # Broadcast.publish.
    def self.cross_worker_notify(topic, payload)
      if Tep::APP.broadcast_pg_enabled != 0
        wire = Tep::Broadcast.encode_wire(topic, payload)
        Tep::APP.broadcast_pg_conn.notify(
          Tep::APP.broadcast_pg_channel, wire)
      end
      0
    end

    def self.enable_pg_backend(conninfo, channel)
      conn = PG::Connection.new(conninfo)
      if conn.pgh < 0
        return -1
      end
      if conn.listen(channel) < 0
        return -1
      end
      Tep::APP.set_broadcast_pg_conn(conn)
      Tep::APP.set_broadcast_pg_channel(channel)
      Tep::APP.set_broadcast_pg_enabled(1)
      0
    end

    def self.disable_pg_backend
      if Tep::APP.broadcast_pg_enabled == 0
        return 0
      end
      Tep::APP.broadcast_pg_conn.unlisten(Tep::APP.broadcast_pg_channel)
      Tep::APP.broadcast_pg_conn.finish
      Tep::APP.set_broadcast_pg_enabled(0)
      0
    end

    def self.poll_pg_once(timeout_ms)
      if Tep::APP.broadcast_pg_enabled == 0
        return -1
      end
      r = Tep::APP.broadcast_pg_conn.poll_notification(timeout_ms)
      if r != 1
        return r
      end
      wire = Tep::APP.broadcast_pg_conn.last_notify_payload
      Tep::Broadcast.deliver_wire_local(wire)
      1
    end

    def self.encode_wire(topic, payload)
      topic.length.to_s + ":" + topic + payload
    end

    def self.deliver_wire_local(wire)
      colon = Tep.str_find(wire, ":", 0)
      if colon <= 0
        return -1
      end
      len_str = wire[0, colon]
      tlen    = len_str.to_i
      if tlen < 0 || colon + 1 + tlen > wire.length
        return -1
      end
      topic   = wire[colon + 1, tlen]
      payload = wire[colon + 1 + tlen, wire.length - colon - 1 - tlen]
      Tep::Broadcast.publish_local_only(topic, payload)
    end

  end

  module Presence
    def self.enable_pg_mirror(conninfo)
      conn = PG::Connection.new(conninfo)
      if conn.pgh < 0
        return -1
      end
      # exec raises PG::Error on failure now; degrade gracefully
      # (close + return -1) rather than letting it escape the worker.
      begin
        r = conn.exec(Tep::Presence.schema_sql)
        r.clear
        # Heartbeat table for the prune-stale-workers path (#47).
        r = conn.exec(Tep::Presence.worker_schema_sql)
        r.clear
      rescue PG::Error
        conn.finish
        return -1
      end
      Tep::APP.set_presence_pg_conn(conn)
      worker_id = Sock.sphttp_getpid.to_s + "-" + Time.now.to_i.to_s
      Tep::APP.set_presence_pg_worker_id(worker_id)
      Tep::APP.set_presence_pg_enabled(1)
      # Drop any rows from a prior worker that managed to leave
      # stale entries with this same worker_id (unlikely thanks
      # to the boot-epoch suffix, but defensive). Best-effort.
      Tep::Presence.mirror_exec(
        "DELETE FROM tep_presence WHERE worker_id = $1",
        [worker_id])
      # Register this worker's heartbeat row immediately. Apps
      # refresh it periodically via Tep::Presence.heartbeat;
      # prune_stale_workers deletes rows whose heartbeat is stale.
      Tep::Presence.heartbeat
      0
    end

    def self.disable_pg_mirror
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      # Best-effort cleanup -- swallow PG errors (we're tearing the
      # mirror down regardless) and still finish + disable below.
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "DELETE FROM tep_presence WHERE worker_id = $1",
          [Tep::APP.presence_pg_worker_id])
        r.clear
        # Remove the heartbeat row so prune_stale_workers doesn't
        # see this worker as live after we're gone.
        r = Tep::APP.presence_pg_conn.exec_params(
          "DELETE FROM tep_presence_worker WHERE worker_id = $1",
          [Tep::APP.presence_pg_worker_id])
        r.clear
      rescue PG::Error
        # swallow -- shutting the mirror down anyway
      end
      Tep::APP.presence_pg_conn.finish
      Tep::APP.set_presence_pg_enabled(0)
      0
    end

    def self.schema_sql
      "CREATE TABLE IF NOT EXISTS tep_presence (" +
        "worker_id    TEXT NOT NULL, " +
        "topic        TEXT NOT NULL, " +
        "fd           INTEGER NOT NULL, " +
        "principal_id TEXT NOT NULL, " +
        "kind         TEXT NOT NULL, " +
        "agent_id     TEXT NOT NULL, " +
        "since_ts     BIGINT NOT NULL, " +
        "status_state TEXT NOT NULL, " +
        "status_note  TEXT NOT NULL, " +
        "status_until BIGINT NOT NULL, " +
        "PRIMARY KEY (worker_id, topic, fd)" +
      ")"
    end

    def self.worker_schema_sql
      "CREATE TABLE IF NOT EXISTS tep_presence_worker (" +
        "worker_id    TEXT PRIMARY KEY, " +
        "last_seen_ts BIGINT NOT NULL" +
      ")"
    end

    def self.heartbeat
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      wid = Tep::APP.presence_pg_worker_id
      if wid.length == 0
        return 0
      end
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "INSERT INTO tep_presence_worker (worker_id, last_seen_ts) " +
          "VALUES ($1, $2) " +
          "ON CONFLICT (worker_id) DO UPDATE SET " +
          "  last_seen_ts = EXCLUDED.last_seen_ts",
          [wid, Time.now.to_i.to_s])
        r.clear
      rescue PG::Error
        return 0
      end
      1
    end

    def self.prune_stale_workers(ttl_seconds)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      cutoff = Time.now.to_i - ttl_seconds
      conn = Tep::APP.presence_pg_conn
      begin
        # Drop dead heartbeats first; the second DELETE then walks
        # the worker_id space that's still alive.
        r1 = conn.exec_params(
          "DELETE FROM tep_presence_worker WHERE last_seen_ts < $1",
          [cutoff.to_s])
        r1.clear
        # Now drop presence rows whose worker_id isn't in the live
        # heartbeat table. NOT IN handles both crashed-and-pruned
        # workers and workers that never registered (legacy rows
        # from before this prune feature shipped).
        r2 = conn.exec(
          "DELETE FROM tep_presence " +
          "WHERE worker_id NOT IN (SELECT worker_id FROM tep_presence_worker)")
        n = r2.cmd_tuples
        r2.clear
      rescue PG::Error
        return 0
      end
      n
    end

    def self.mirror_exec(sql, params)
      begin
        r = Tep::APP.presence_pg_conn.exec_params(sql, params)
        r.clear
      rescue PG::Error
        # swallow -- advisory mirror, local presence is authoritative
      end
      0
    end

    def self.mirror_insert(entry)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      Tep::Presence.mirror_exec(
        "INSERT INTO tep_presence " +
        "(worker_id, topic, fd, principal_id, kind, agent_id, " +
        " since_ts, status_state, status_note, status_until) " +
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) " +
        "ON CONFLICT (worker_id, topic, fd) DO UPDATE SET " +
        "  principal_id = EXCLUDED.principal_id, " +
        "  kind         = EXCLUDED.kind, " +
        "  agent_id     = EXCLUDED.agent_id, " +
        "  since_ts     = EXCLUDED.since_ts, " +
        "  status_state = EXCLUDED.status_state, " +
        "  status_note  = EXCLUDED.status_note, " +
        "  status_until = EXCLUDED.status_until",
        [
          Tep::APP.presence_pg_worker_id,
          entry.topic,
          entry.fd.to_s,
          entry.principal_id,
          entry.kind.to_s,
          entry.agent_id,
          entry.since.to_s,
          entry.status_state.to_s,
          entry.status_note,
          entry.status_until.to_s
        ])
    end

    def self.mirror_delete(topic, fd)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      Tep::Presence.mirror_exec(
        "DELETE FROM tep_presence " +
        "WHERE worker_id = $1 AND topic = $2 AND fd = $3",
        [Tep::APP.presence_pg_worker_id, topic, fd.to_s])
    end

    def self.mirror_status(topic, fd, state, note, until_ts)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      Tep::Presence.mirror_exec(
        "UPDATE tep_presence " +
        "SET status_state = $4, status_note = $5, status_until = $6 " +
        "WHERE worker_id = $1 AND topic = $2 AND fd = $3",
        [Tep::APP.presence_pg_worker_id, topic, fd.to_s,
         state.to_s, note, until_ts.to_s])
    end

    def self.list_global(topic)
      result = [Tep::PresenceEntry.new("", "", :human, "", -1, 0)]
      result.delete_at(0)
      if Tep::APP.presence_pg_enabled == 0
        return result
      end
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "SELECT principal_id, kind, agent_id, fd, since_ts, " +
          "       status_state, status_note, status_until " +
          "FROM tep_presence WHERE topic = $1 ORDER BY since_ts",
          [topic])
      rescue PG::Error
        return result
      end
      i = 0
      n = r.ntuples
      while i < n
        kind_sym = :human
        if r.getvalue(i, 1) == "agent_for"
          kind_sym = :agent_for
        end
        state_sym = :available
        sstr = r.getvalue(i, 5)
        if sstr == "busy"
          state_sym = :busy
        elsif sstr == "blocked"
          state_sym = :blocked
        end
        e = Tep::PresenceEntry.new(
          topic,
          r.getvalue(i, 0),
          kind_sym,
          r.getvalue(i, 2),
          r.getvalue(i, 3).to_i,
          r.getvalue(i, 4).to_i)
        e.status_state = state_sym
        e.status_note  = r.getvalue(i, 6)
        e.status_until = r.getvalue(i, 7).to_i
        result.push(e)
        i += 1
      end
      r.clear
      result
    end

    def self.count_global(topic)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "SELECT count(*) FROM tep_presence WHERE topic = $1",
          [topic])
      rescue PG::Error
        return 0
      end
      n = r.getvalue(0, 0).to_i
      r.clear
      n
    end

  end
end

# ===================================================================
# Opt-in PG seeds (#216, relocated from lib/tep.rb). Pin parameter /
# return C types for every PG-backed cmeth so a `require "tep/pg"`
# app compiles cleanly even when it exercises only a subset.
# PG::Connection.new("") returns a failed-conn instance (@pgh<0)
# rather than raising, so all of this is safe at module load.
# ===================================================================

# Broadcast PG-backend setters + cmeths. set_* via constant because
# PG::Connection.new cannot run inside App#initialize (Tep::APP is
# mid-construction). enable_pg_backend("","") connect-fails (-1).
Tep::APP.set_broadcast_pg_enabled(0)
Tep::APP.set_broadcast_pg_channel("")
Tep::APP.set_broadcast_pg_conn(PG::Connection.new(""))
Tep::Broadcast.enable_pg_backend("", "")
Tep::Broadcast.poll_pg_once(0)
Tep::Broadcast.disable_pg_backend
Tep::Broadcast.encode_wire("", "")
Tep::Broadcast.deliver_wire_local("0:")
Tep::Broadcast.cross_worker_notify("_seed", "")

# Presence PG mirror cmeths. mirror_insert needs a PresenceEntry.
_tep_pg_seed_entry = Tep::PresenceEntry.new("_seed", "_seed", :human, "", -1, 0)
Tep::Presence.enable_pg_mirror("")
Tep::Presence.schema_sql
Tep::Presence.mirror_insert(_tep_pg_seed_entry)
Tep::Presence.mirror_delete("_seed", -1)
Tep::Presence.mirror_status("_seed", -1, :available, "", 0)
Tep::Presence.list_global("_seed")
Tep::Presence.count_global("_seed")
Tep::Presence.worker_schema_sql
Tep::Presence.heartbeat
Tep::Presence.prune_stale_workers(90)
Tep::Presence.disable_pg_mirror
Tep::APP.set_presence_pg_enabled(0)
Tep::APP.set_presence_pg_worker_id("")
Tep::APP.set_presence_pg_conn(PG::Connection.new(""))

  # PG::Connection / Result / Pool type-seeding.
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
