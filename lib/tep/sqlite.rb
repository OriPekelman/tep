# Tep::SQLite -- a thin wrapper around the system libsqlite3 for
# spinel-AOT'd apps. Uses tep_sqlite.c (compiled to tep_sqlite.o)
# as a stable C ABI surface, exposed via spinel's `ffi_func` DSL.
#
# Why not the `sqlite3` gem? It's a CRuby-MRI native extension
# (loadable .so/.bundle), which spinel can't link -- spinel
# produces a single static binary with everything resolved at
# compile time. The C-shim approach (same pattern as tep's HTTP
# server in sphttp.c) replaces "load a gem at runtime" with
# "link a .o at compile time."
#
# Usage
# -----
#
#   db = Tep::SQLite.new
#   db.open("./app.db")
#   db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT)")
#
#   # Parameterised insert: prepare once, bind, step, finalize.
#   db.prepare("INSERT INTO notes (body) VALUES (?)")
#   db.bind_str(1, "hello")
#   db.step
#   db.finalize
#   id = db.last_rowid
#
#   # Single-row, single-column read.
#   body = db.first_str("SELECT body FROM notes WHERE id = ?", id.to_s)
#
#   # Iterating rows.
#   db.prepare("SELECT id, body FROM notes ORDER BY id")
#   while db.step == 1
#     puts db.col_int(0).to_s + ": " + db.col_str(1)
#   end
#   db.finalize
#
# Constraints
# -----------
#   - One in-flight cursor per process (the `prepare`/`step`/`finalize`
#     trio shares a single C-side `sqlite3_stmt *`). Nesting one
#     query inside another's loop will overwrite the parent cursor.
#     The framework runs handlers serially per worker so this is
#     fine for "one DB call per request".
#   - Columns are read as either str or int. Floats / blobs / NULL
#     aren't first-class -- a NULL column returns "" (str) or 0 (int).
#   - The C side caps a single col_str result at 64 KiB. Large blobs
#     would truncate.
#
# All FFI plumbing lives at the top level (parallel to `Sock`) so
# spinel's name resolver finds it from anywhere in the Tep tree.
module Sqlite
  ffi_cflags "@TEP_SQLITE_O@"
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

    def initialize
      @dbh = -1
    end

    # Returns true on success, false on failure. Path may be a real
    # file or `:memory:` for an anonymous in-memory db. Multiple
    # opens on the same instance leak the prior handle; close first.
    def open(path)
      h = Sqlite.tep_sqlite_open(path)
      if h < 0
        return false
      end
      @dbh = h
      true
    end

    def close
      if @dbh >= 0
        Sqlite.tep_sqlite_close(@dbh)
        @dbh = -1
      end
      0
    end

    # Run a statement that returns no rows (CREATE / INSERT /
    # UPDATE / DELETE / PRAGMA / BEGIN / COMMIT). Returns true on
    # success. No bind in this form -- inline literal SQL is fine
    # for DDL and constants; for any user-supplied value use
    # prepare + bind + step + finalize.
    def exec(sql)
      if @dbh < 0
        return false
      end
      Sqlite.tep_sqlite_exec(@dbh, sql) == 0
    end

    # Open a cursor on a parameterised query. Subsequent
    # bind_str / bind_int calls fill in `?` markers (1-indexed).
    # Always pair with `finalize` once iteration is done.
    def prepare(sql)
      if @dbh < 0
        return false
      end
      Sqlite.tep_sqlite_prepare(@dbh, sql) == 0
    end

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
    def prepare_cached(sql)
      if @dbh < 0
        return false
      end
      Sqlite.tep_sqlite_prepare_cached(@dbh, sql) == 0
    end

    def bind_str(idx, value); Sqlite.tep_sqlite_bind_str(idx, value); end
    def bind_int(idx, value); Sqlite.tep_sqlite_bind_int(idx, value); end

    # 1 -> row available, 0 -> done (no more rows), -1 -> error.
    def step;       Sqlite.tep_sqlite_step;       end
    def col_str(i); Sqlite.tep_sqlite_col_str(i); end
    def col_int(i); Sqlite.tep_sqlite_col_int(i); end
    def col_count;  Sqlite.tep_sqlite_col_count;  end
    def finalize;   Sqlite.tep_sqlite_finalize;   end
    def reset;      Sqlite.tep_sqlite_reset;      end

    def last_rowid
      if @dbh < 0
        return -1
      end
      Sqlite.tep_sqlite_last_insert_rowid(@dbh)
    end

    # Convenience: prepare a single-row, single-column query, bind
    # one optional string param (pass "" for "no param"), step
    # once, return col[0]. Always finalises the cursor before
    # returning so the caller doesn't have to.
    def first_str(sql, p1)
      if @dbh < 0
        return ""
      end
      if Sqlite.tep_sqlite_prepare(@dbh, sql) != 0
        return ""
      end
      if p1.length > 0
        Sqlite.tep_sqlite_bind_str(1, p1)
      end
      result = ""
      if Sqlite.tep_sqlite_step == 1
        result = Sqlite.tep_sqlite_col_str(0)
      end
      Sqlite.tep_sqlite_finalize
      result
    end

    def first_int(sql, p1)
      if @dbh < 0
        return 0
      end
      if Sqlite.tep_sqlite_prepare(@dbh, sql) != 0
        return 0
      end
      if p1.length > 0
        Sqlite.tep_sqlite_bind_str(1, p1)
      end
      result = 0
      if Sqlite.tep_sqlite_step == 1
        result = Sqlite.tep_sqlite_col_int(0)
      end
      Sqlite.tep_sqlite_finalize
      result
    end
  end
end
