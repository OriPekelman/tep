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
  # password, sslmode, ...). Raises PG::ConnectionBad on failure.
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
        h = Pg.tep_pg_connect(opts)
      else
        # Hash form. Pack keys and values into parallel \0-delimited
        # buffers; the shim splits them apart and calls
        # PQconnectdbParams.
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
        # `c.connected?` after the constructor returns. Spinel can't
        # rescue module-namespaced exception classes today
        # (matz/spinel#627) -- raising would skip user-side rescue
        # and crash the worker. Document the contract: callers must
        # check `c.connected?` before exec.
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

    # Run a no-params query. Returns a PG::Result. On error the
    # result's `ok?` is false and `error_message` / `sql_state`
    # describe the failure; SQLSTATE + message are also mirrored
    # to `conn.last_sqlstate` / `#last_error_message`.
    #
    # v1 returns Result-on-error instead of raising because
    # spinel's `rescue Module::Klass` doesn't resolve the
    # constant path (top-level-class rescue is fixed but the
    # module-namespaced case lags; tracking comment on
    # matz/spinel#627). The PG::Error subclass tree is defined
    # below so future code that wants to introspect / subclass
    # has it; raising flips on once the namespace fix lands.
    def exec(sql)
      rh = Pg.tep_pg_exec(@pgh, sql)
      r = PG::Result.new(rh)
      Connection.record_error_if_any(self, r)
      r
    end

    # Parameterised query with positional binds ($1, $2, ...).
    # `params` is an Array of String / Integer / nil. Same
    # Result-on-error model as `exec`.
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
      rh = Pg.tep_pg_exec_params(@pgh, sql)
      r = PG::Result.new(rh)
      Connection.record_error_if_any(self, r)
      r
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
      conn.last_result_rh = r.rh
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
end
