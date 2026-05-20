# Tep::PG -- libpq battery for spinel-AOT'd Tep apps

Status: v1 shipped (2026-05-20). The `Tep::PG` battery mirrors the
`pg` gem's public surface where spinel allows, lets a `tep build` app
talk to PostgreSQL via libpq with no CRuby gem in the loop, and stays
close enough to the upstream shape that an eventual ActiveRecord port
reuses the existing pg adapter with minimal divergence.

v1 shipped surface: `PG.connect`, `PG::Connection` (status / exec /
exec_params / escape_* / close), `PG::Result` (status / ok? / fields
/ values / each / each_row / getvalue / getisnull / fnumber / ftype /
cmd_tuples / clear / sql_state), `PG::Error` (single class for now),
named diagnostic-field constants. Files: `lib/tep/tep_pg.c` (libpq
C shim, ~430 LoC), `lib/tep/pg.rb` (Ruby surface, ~470 LoC),
`examples/pg_hello.rb` (smoke).

### v1 deviation from the design

The design doc anticipated a 20-class `PG::Error` hierarchy keyed by
SQLSTATE (`PG::UniqueViolation`, `PG::UndefinedTable`, ...) so AR's
`e.is_a?(PG::UniqueViolation)` would translate. Building the battery
surfaced **two spinel limitations** that defer that hierarchy:

1. **matz/spinel#622** — `raise X.new(msg, ...)` doesn't lower
   (custom `initialize` on an Exception subclass widens to a type
   mismatch into `sp_raise`).
2. **matz/spinel#627** — `rescue ParentClass => e` doesn't catch a
   subclass instance, and even `rescue Module::Klass => e` skips an
   exact-match raised `Module::Klass`. Class hierarchy and module
   namespacing are both invisible to spinel's rescue dispatch today.
   `is_a?` has the same gap.

Workable subset given those: **single `PG::Error` class**, raised
via the two-arg `raise PG::Error, msg` form, and rescue via the bare
`rescue => e` (which spinel does walk for StandardError-rooted
classes). For AR-shaped use, v1 sidesteps `raise` entirely and
**returns a Result on error** (`r.ok?` false). The leaf-class
hierarchy comes back in v1.5 once #627 lands.

The doc body below describes the v1 surface that actually shipped;
the AR-portability sections describe the v1.5+ target. The two
spinel issues track upstream progress.

> **Why mirror `pg`?** Two reasons, in order:
>
> 1. **Forward-compatibility with ActiveRecord.** AR's pg adapter
>    (~3k LOC) hardcodes the `PG::Connection` / `PG::Result` /
>    `PG::Error` surface. The closer Tep::PG sits to that surface,
>    the smaller the eventual AR-on-spinel port becomes. Method
>    names, return shapes, error class hierarchy, exception-raising
>    semantics — every one of those that diverges multiplies the
>    porting cost.
> 2. **Existing knowledge.** Most Ruby web devs already know `pg`'s
>    method names and exception classes. Reusing them costs us
>    nothing on the implementation side and saves users a battery-
>    specific lookup every time they hit a wall.
>
> The non-goal is **binary fidelity** with `pg`. We are not a
> drop-in replacement for the gem in CRuby — `require 'pg'` against
> a spinel-compiled binary gives Tep's `PG`, not Lautis's. The two
> can't share the same compiled artifact (theirs is a CRuby native
> extension; ours is libpq via FFI). The goal is **source-level
> portability**: code written against `PG::Connection.new(...).exec_params(sql, params)`
> compiles and behaves the same under both runtimes for the subset
> Tep::PG covers.

---

## Goals

**Primary**:

1. **`pg`-gem-faithful public surface** — namespace, class names,
   method names, signatures, exception class hierarchy. Where
   spinel forces a divergence (Hash yields, `**kwargs`, exception
   subclasses), document the delta inline with a rationale.
2. **AR-pg-adapter forward target** — the subset of `pg` that the
   AR adapter actually calls is covered in v1 or v1.5. The rest
   has a labelled phase.

**Secondary**:

3. **Same shim model as `Tep::SQLite`** — `tep_pg.c` is the libpq
   FFI shim, ~300 LoC, with the same conventions (integer-handle
   slot tables, rotating return-string buffer, `param_push_*`
   accumulator).
4. **One static binary** — no CRuby runtime, no pg.so loaded at
   start; libpq linked statically or as a shared library that lives
   on the deployment host.

**Out of scope for v1** (each is a phase below):

- **Async / non-blocking I/O** integrated with `Tep::Scheduler` —
  covered in v2 (this is what AR's `async_exec` path needs).
- **Prepared statements** — v1.5.
- **LISTEN/NOTIFY** — v2.5.
- **COPY streaming** — v3.
- **Binary-format result columns** — v3.
- **Type maps / decoders** (`PG::BasicTypeMapForResults`, etc.) —
  out of scope by design; the AR adapter implements its own type
  casting against textual values, which is what we surface.
- **Large objects, replication protocol, GSS auth** — niche; no plan.

**Non-goals (forever)**:

- **Drop-in CRuby `require 'pg'` replacement** (see header).
- **Encoder framework** (`PG::TextEncoder`, `PG::BinaryEncoder`) —
  callers stringify on the way in. AR coerces at the model layer.
- **Ractor integration** — irrelevant to spinel.

---

## What ActiveRecord's pg adapter actually uses

A grep through `activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb`
and friends (Rails 8.x) gives the relevant call surface. **This is the
v1 + v1.5 coverage target.**

### Connection lifecycle

```ruby
PG::Connection.new(conn_hash)        # or PG.connect(...)
conn.close / conn.finish
conn.reset                           # disconnect + reconnect with same opts
conn.status                          # PG::CONNECTION_OK / _BAD
conn.transaction_status              # PG::PQTRANS_IDLE / _ACTIVE / _INTRANS / _INERROR
conn.server_version                  # Integer, e.g. 160002
conn.set_notice_receiver { |result| ... }   # silenced by default in AR
```

### Sync exec (used by AR's `execute_unprepared_query` path)

```ruby
conn.exec(sql)                       # raises PG::Error on failure
conn.exec_params(sql, params)        # text-format params
```

### Prepared statements (the AR hot path)

```ruby
conn.prepare(name, sql)              # returns PG::Result
conn.exec_prepared(name, params)     # returns PG::Result
```

### Async (the actual AR default since Rails 7)

```ruby
conn.async_exec(sql)                 # internally: send_query + wait + get_result
conn.async_exec_params(sql, params)
conn.async_exec_prepared(name, params)
```

These all behave like the sync versions to the caller, but release
the GIL during the network wait. In the Tep / Spinel world, "release
the GIL" becomes "park the fiber on `Tep::Scheduler.io_wait`."

### Escape

```ruby
conn.escape_string(s)                # for legacy interpolated SQL
conn.escape_identifier(s)            # for dynamic table/column names
PG::Connection.quote_ident(s)        # class method, same as above
PG::Connection.escape_string(s)      # class method
```

### Result reading

```ruby
result.values                        # Array<Array<String>>
result.fields                        # Array<String>
result.cmd_tuples                    # Integer; affected rows for INSERT/UPDATE/DELETE
result.cmd_status                    # String; "INSERT 0 1" / "SELECT"
result.column_values(n)              # Array<String> for one column across all rows
result.fnumber(name)                 # column index by name
result.fformat(n)                    # 0 (text) or 1 (binary)
result.ftype(n)                      # type OID
result.fmod(n)                       # type modifier
result.getvalue(row, col)            # single cell value
result.getisnull(row, col)
result.ntuples / result.nfields
result.each { |hash_row| ... }       # yields Hash<String, String>
result.each_row { |array_row| ... }  # yields Array<String>
result.clear                         # explicit free
```

### Errors

```ruby
PG::Error                            # base
PG::ConnectionBad                    # connect/network failure
PG::UnableToSend                     # write to backend failed
PG::ServerError                      # SQL-level error
  PG::SyntaxError                    # 42601
  PG::UndefinedTable                 # 42P01
  PG::UndefinedColumn                # 42703
  PG::UniqueViolation                # 23505
  PG::ForeignKeyViolation            # 23503
  PG::NotNullViolation               # 23502
  PG::CheckViolation                 # 23514
  PG::SerializationFailure           # 40001
  PG::DeadlockDetected               # 40P01
  PG::QueryCanceled                  # 57014
  PG::ReadOnlySqlTransaction         # 25006
  # ...and ~40 more leaf classes mapped from SQLSTATE
err.result                           # the PG::Result that triggered it (nilable)
err.sql_state                        # 5-char SQLSTATE
err.message                          # human-readable
```

The AR adapter `translate_exception_class(message, sql, binds)`
inspects `e.is_a?(PG::UniqueViolation)` etc. — so the **class
hierarchy matters**, not just the message.

### Total

~35 distinct methods on Connection/Result, plus ~50 error classes.
That's the AR adapter's actual coverage need. **Tep::PG v1 + v1.5 +
v2 covers all of it except COPY and LISTEN/NOTIFY (which AR doesn't
use).**

---

## Surface compatibility table

Per-method status against the `pg` gem, with Tep's planned
divergence (if any) and the phase that adds it.

| `pg` gem | Tep::PG | Phase | Divergence |
|---|---|---|---|
| `PG.connect(opts)` | `PG.connect(opts)` | v1 | opts is a String conninfo OR a `Hash<String,String>` (no Symbol keys; spinel widens). |
| `PG::Connection.new(opts)` | same | v1 | same |
| `conn.close` / `conn.finish` | same | v1 | — |
| `conn.reset` | same | v1.5 | — |
| `conn.status` | same | v1 | Returns `PG::CONNECTION_OK` (0) / `CONNECTION_BAD` (1). |
| `conn.transaction_status` | same | v1.5 | Same constants. |
| `conn.server_version` | same | v1 | Integer. |
| `conn.set_notice_receiver { ... }` | `conn.set_notice_receiver(handler)` | v1.5 | Block ↔ Handler class shape (spinel block-capture limits). |
| `conn.exec(sql)` | same | v1 | **Raises `PG::Error` on failure** (vs returning a sentinel). |
| `conn.exec_params(sql, params)` | same | v1 | params is `Array<String \| Integer \| nil>`. No Hash-shaped binary param form. |
| `conn.prepare(name, sql)` | same | v1.5 | — |
| `conn.exec_prepared(name, params)` | same | v1.5 | — |
| `conn.async_exec(sql)` | same | v2 | Wraps the libpq async surface + `Tep::Scheduler.io_wait`. |
| `conn.async_exec_params` / `_prepared` | same | v2 | — |
| `conn.escape_string(s)` | same | v1 | — |
| `conn.escape_identifier(s)` | same | v1 | — |
| `PG::Connection.quote_ident(s)` | same | v1 | Class method delegates to libpq's literal quote helper (no conn needed). |
| `PG::Connection.escape_string(s)` | same | v1 | Same. |
| `result.values` | same | v1 | `Array<Array<String>>`. |
| `result.fields` | same | v1 | `Array<String>`. |
| `result.cmd_tuples` | same | v1 | Integer. |
| `result.cmd_status` | same | v1.5 | String, e.g. `"INSERT 0 1"`. |
| `result.column_values(n)` | same | v1.5 | `Array<String>`. |
| `result.fnumber(name)` | same | v1 | Integer column index. |
| `result.fformat(n)` | same | v1.5 | 0 = text (v1 always); 1 = binary (v3). |
| `result.ftype(n)` | same | v1 | Type OID. |
| `result.fmod(n)` | same | v1.5 | Type modifier. |
| `result.getvalue(row, col)` | same | v1 | — |
| `result.getisnull(row, col)` | same | v1 | — |
| `result.ntuples` / `result.nfields` | same | v1 | — |
| `result.each { ... }` (Hash yield) | same | v1 | **Caveat**: yields `Hash<String,String>`; spinel will type the hash polymorphically. See "Hash row shape" below. |
| `result.each_row { ... }` (Array yield) | same | v1 | Cleaner shape for hot paths. |
| `result.clear` | same | v1 | — |
| `PG::Error` + subclass tree | same | v1 (base) / v1.5 (leaf classes) | See "Error class hierarchy" below. |
| `err.result` / `err.sql_state` | same | v1 | — |
| `result[i]` (Hash indexing) | same | v1.5 | Sugar for `each.to_a[i]`. |
| `result.each_with_index` / `each_row_with_index` | omit | — | Spinel lacks Enumerator; caller manages `i`. |
| `conn.send_query(sql)` / `consume_input` / `is_busy` / `get_result` | same | v2 | The async primitives. AR uses these inside `async_exec`. |
| `conn.put_copy_data` / `put_copy_end` / `get_copy_data` | same | v3 | COPY streaming. |
| `conn.notifies` / `LISTEN` | same | v2.5 | — |
| `PG::Connection.connect_start` | same | v2 | Async connect; AR uses for pre-warming. |
| `conn.encoder_type_map=` / `decoder_type_map=` | omit | — | No type-map framework. |
| `conn.copy_data { ... }` | omit | v3 deferred | Block-shaped wrapper around put_/get_copy_data. |

---

## Hash row shape

`result.each { |row| ... }` yields a `Hash<String, String>`. Spinel
widens unknown-shape Hash literals to `poly_poly_hash`, so the
straightforward `{ fields[j] => values[i][j] }` build would lose
typed dispatch downstream.

Two mitigations:

1. **Seed the type at module load.** `lib/tep.rb`'s seed block
   gets a `_seed_pg_row = {"" => ""}; _seed_pg_row.delete("")`
   line that pins one hash to `str_str_hash`. Spinel propagates the
   shape through the iteration. This is the same trick the existing
   batteries (`Url.parse_query`, etc.) use for str-str hashes.
2. **Provide `each_row` as the typed-Array fast path.** Yields
   `Array<String>` directly, no hash. Users who don't need column-
   name access (or who already cached `fnumber`) get the cheaper
   shape.

`result.each` (Hash yield) remains available; the seed handles the
type. The doc string on `each` says "for AR-shaped iteration; prefer
each_row for hot paths."

---

## Error class hierarchy

`PG::Error` (the base) plus the leaf classes AR actually checks for.
v1 ships the base + the constructor; v1.5 fills in the leaf classes
keyed by SQLSTATE.

```ruby
module PG
  class Error < StandardError
    attr_reader :result      # PG::Result or nil
    attr_reader :sql_state   # 5-char SQLSTATE
    attr_reader :connection  # PG::Connection or nil (set when raised from a Connection method)

    def initialize(msg, result = nil, sql_state = "", conn = nil)
      super(msg)
      @result = result
      @sql_state = sql_state
      @connection = conn
    end
  end

  class ConnectionBad < Error;       end   # network / startup failure
  class UnableToSend < Error;        end   # write to backend failed
  class ServerError < Error;         end   # SQL-level (base for SQLSTATE leaves)

  # SQLSTATE class 23 -- integrity constraint violation
  class IntegrityConstraintViolation < ServerError;  end
  class NotNullViolation < IntegrityConstraintViolation;        end   # 23502
  class ForeignKeyViolation < IntegrityConstraintViolation;     end   # 23503
  class UniqueViolation < IntegrityConstraintViolation;         end   # 23505
  class CheckViolation < IntegrityConstraintViolation;          end   # 23514
  class ExclusionViolation < IntegrityConstraintViolation;      end   # 23P01

  # SQLSTATE class 25 -- invalid transaction state
  class InFailedSqlTransaction < ServerError;    end   # 25P02
  class ReadOnlySqlTransaction < ServerError;    end   # 25006

  # SQLSTATE class 40 -- transaction rollback
  class SerializationFailure < ServerError;      end   # 40001
  class DeadlockDetected < ServerError;          end   # 40P01

  # SQLSTATE class 42 -- syntax / access rule violation
  class SyntaxError < ServerError;               end   # 42601
  class UndefinedColumn < ServerError;           end   # 42703
  class UndefinedFunction < ServerError;         end   # 42883
  class UndefinedTable < ServerError;            end   # 42P01
  class DuplicateColumn < ServerError;           end   # 42701
  class DuplicateTable < ServerError;            end   # 42P07
  class InsufficientPrivilege < ServerError;     end   # 42501

  # SQLSTATE class 57 -- operator intervention
  class QueryCanceled < ServerError;             end   # 57014
  class AdminShutdown < ServerError;             end   # 57P01

  # SQLSTATE class 08 -- connection exception (server-side; the client
  # version is ConnectionBad above)
  class ConnectionException < ServerError;       end   # 08000
  class ConnectionDoesNotExist < ServerError;    end   # 08003

  # The full ruby-pg tree has ~40 more leaf classes. We ship the
  # subset AR's translate_exception_class actually pattern-matches
  # against; everything else surfaces as the parent class (e.g. a
  # rare 22xxx string-data error lands as PG::ServerError, which is
  # still rescuable). Adding more leaves is a one-line change per
  # class + a SQLSTATE-prefix lookup table entry.
end
```

**SQLSTATE → exception class mapping** lives in
`PG::Connection.error_class_for_sqlstate(state)` — a flat case/when
that the shim doesn't touch. The shim hands up the SQLSTATE string;
the Ruby side picks the class and raises.

### Why exceptions, not Result.ok?

The existing draft of this doc returned a `Result` even on error
(caller checks `r.ok?`). Flipping to **raise on error** to match
`pg`:

- **AR compatibility**: AR's adapter is built around `begin; conn.exec_params(...); rescue PG::Error => e`. A return-result-on-error API would force the AR port to wrap every call.
- **Spinel exception support is partial but workable**: `raise PG::Error.new(msg)` lowers; `rescue PG::Error` lowers; tep already uses exception-shaped control flow (`raise NoMatchingRouteError` in router fallback, etc.).
- **The escape hatch**: a `Connection#exec_raw(sql)` variant that returns Result-or-nil (no raise) for callers in tight loops who don't want the exception cost. Not in the v1 surface; surfaces if a real workload needs it.

The cost: spinel's stack-unwinding-through-fibers story is uneven.
For v1 we keep the raise-and-rescue at the **handler boundary** —
rescued in the route block, never crossing a `Fiber.yield`. AR
follows the same pattern already.

---

## Why a C shim (and not pure FFI to libpq)

Same three reasons as the earlier draft, retained:

1. **Opaque pointers don't compose well in spinel.** `PGconn *` and
   `PGresult *` are pointers; spinel can't put them into a
   `poly_array` or generic `Hash` without widening. Integer handles
   into a shim-owned slot table dodge this entirely. `Tep::SQLite#dbh`
   is the precedent.
2. **`PQexecParams` takes `const char * const *`.** Spinel's FFI has
   `:str` for one string but no `:str_array`. The shim exposes a
   stateful "param push" builder that materialises the `char * const *`
   in C from successive `tep_pg_param_push_*` calls.
3. **String lifetime.** `PQgetvalue` returns a pointer valid only
   until `PQclear`. A rotating buffer inside the shim matches the
   `tep_sqlite_col_str` model: the caller gets a string valid for
   "a few" subsequent calls before it rotates out.

The shim is small (~300 lines for v1). The clarity buys back any
"wasted" indirection.

---

## File layout

```
lib/tep/tep_pg.c            -- libpq shim (~300 lines for v1)
lib/tep/pg.rb               -- FFI module + PG / PG::Connection /
                               PG::Result / PG::Error tree (~400 lines)
sig/tep/pg.rbs              -- RBS for editor tooling + spinel seeds
test/test_pg.rb             -- end-to-end against PG_TEST_URL
examples/pg_hello.rb        -- "hello world" with a SELECT
docs/PG-BATTERY.md          -- this file
```

Files to modify:

```
Makefile                    -- add tep_pg.o target + extend `helper`
bin/tep                     -- add @TEP_PG_O@ / @TEP_PG_CFLAGS@ placeholders
lib/tep.rb                  -- require_relative "tep/pg" + the str_str_hash seed
README.md                   -- one-line entry in the batteries table
```

**Namespace decision**: top-level `PG` (matches the gem), not `Tep::PG`.
Inside the lib/ tree the file lives at `lib/tep/pg.rb` (file-layout
consistency); the contents define `module PG; class Connection; ...
end; end`. This is the one place the Tep battery convention bends to
the AR-portability goal. Documented in the file's doc string. The
seed block in `lib/tep.rb` adds the necessary `PG.constants_seed`
call (or equivalent) to anchor the inference.

---

## The C shim (`lib/tep/tep_pg.c`)

### Design constants

```c
#define TEP_PG_MAX_CONNS         8
#define TEP_PG_MAX_RESULTS       64
#define TEP_PG_MAX_PARAMS        32
#define TEP_PG_PARAM_BUFSIZE     262144   /* 256 KiB; AR migrations push big DDL params */
#define TEP_PG_STR_BUFSIZE       65536
#define TEP_PG_STR_BUF_SLOTS     128      /* AR's load_one row reads many cols; doubled from earlier draft */
```

### Slot tables

```c
static PGconn   *tep_pg_conns[TEP_PG_MAX_CONNS]    = {0};
static PGresult *tep_pg_results[TEP_PG_MAX_RESULTS] = {0};
static int       tep_pg_result_conn[TEP_PG_MAX_RESULTS];   /* conn slot the result belongs to */

/* Parameter accumulator for the next exec_params call. */
static const char *tep_pg_param_ptrs[TEP_PG_MAX_PARAMS];
static int         tep_pg_param_is_null[TEP_PG_MAX_PARAMS];
static char        tep_pg_param_buf[TEP_PG_PARAM_BUFSIZE];
static int         tep_pg_param_buf_used = 0;
static int         tep_pg_param_count    = 0;

/* Rotating return-string buffer. */
static char tep_pg_str_buf[TEP_PG_STR_BUF_SLOTS][TEP_PG_STR_BUFSIZE];
static int  tep_pg_str_slot = 0;
```

### Function table (v1)

22 entry points for v1, covering the surface AR's pg adapter calls
synchronously. Async (v2) adds ~10 more, prepared (v1.5) adds 3.

| C function | libpq backing | Purpose |
|---|---|---|
| `int tep_pg_connect(const char *conninfo)` | `PQconnectdb` + `PQstatus` | 1-indexed handle, -1 on failure. |
| `int tep_pg_connect_kv(const char *keys, const char *vals)` | `PQconnectdbParams` | For Hash-form opts. `keys`/`vals` are `\0`-delimited concat strings. |
| `int tep_pg_finish(int h)` | `PQfinish` | Frees the conn + clears any results belonging to it. |
| `int tep_pg_reset(int h)` | `PQreset` | Disconnect + reconnect with same params. |
| `int tep_pg_status(int h)` | `PQstatus` | `CONNECTION_OK`=0, `CONNECTION_BAD`=1. |
| `int tep_pg_transaction_status(int h)` | `PQtransactionStatus` | `PQTRANS_IDLE`=0, `_ACTIVE`=1, `_INTRANS`=2, `_INERROR`=3, `_UNKNOWN`=4. |
| `const char *tep_pg_error_message(int h)` | `PQerrorMessage` | |
| `int tep_pg_server_version(int h)` | `PQserverVersion` | Integer, e.g. 160002. |
| `int tep_pg_set_client_encoding(int h, const char *enc)` | `PQsetClientEncoding` | |
| `int tep_pg_exec(int h, const char *sql)` | `PQexec` | Returns result handle; sets last-error on the conn slot if invalid. |
| `int tep_pg_param_clear(void)` | (shim) | Reset accumulator. |
| `int tep_pg_param_push_str(const char *s)` | (shim) | Append a text param. |
| `int tep_pg_param_push_null(void)` | (shim) | Append a SQL NULL. |
| `int tep_pg_exec_params(int h, const char *sql)` | `PQexecParams` | Uses accumulator. |
| `int tep_pg_clear(int rh)` | `PQclear` | |
| `int tep_pg_result_status(int rh)` | `PQresultStatus` | `PGRES_TUPLES_OK`=0, `_COMMAND_OK`=1, `_EMPTY_QUERY`=2, `_FATAL_ERROR`=3 (collapsed from libpq's 8). |
| `const char *tep_pg_result_error_message(int rh)` | `PQresultErrorMessage` | |
| `const char *tep_pg_result_error_field(int rh, int code)` | `PQresultErrorField` | `code` ∈ {5 (SQLSTATE), 'M', 'D', 'H'}. |
| `const char *tep_pg_cmd_status(int rh)` | `PQcmdStatus` | e.g. `"INSERT 0 1"`. |
| `int tep_pg_cmd_tuples(int rh)` | `PQcmdTuples` parsed to int | |
| `int tep_pg_ntuples(int rh)` | `PQntuples` | |
| `int tep_pg_nfields(int rh)` | `PQnfields` | |
| `const char *tep_pg_fname(int rh, int col)` | `PQfname` | |
| `int tep_pg_fnumber(int rh, const char *name)` | `PQfnumber` | -1 if not found. |
| `int tep_pg_ftype(int rh, int col)` | `PQftype` | Type OID. |
| `int tep_pg_fformat(int rh, int col)` | `PQfformat` | 0 (text) / 1 (binary). |
| `int tep_pg_fmod(int rh, int col)` | `PQfmod` | Type modifier. |
| `const char *tep_pg_getvalue(int rh, int row, int col)` | `PQgetvalue` | |
| `int tep_pg_getisnull(int rh, int row, int col)` | `PQgetisnull` | |
| `int tep_pg_getlength(int rh, int row, int col)` | `PQgetlength` | |
| `const char *tep_pg_escape_string(int h, const char *s)` | `PQescapeStringConn` | |
| `const char *tep_pg_escape_literal(int h, const char *s)` | `PQescapeLiteral` + `PQfreemem` | |
| `const char *tep_pg_escape_identifier(int h, const char *s)` | `PQescapeIdentifier` + `PQfreemem` | |
| `const char *tep_pg_libpq_version(void)` | `PQlibVersion` (rendered) | |

(That's 30. The earlier draft's 22 + 8 to fill out the AR surface.)

### Implementation notes

Carried from earlier draft:

1. **`PQfinish` on a slot with live results** — walk
   `tep_pg_results[]`, `PQclear` any whose `tep_pg_result_conn[]`
   matches.
2. **`PQconnectdb` always returns non-NULL** — must check `PQstatus`.
3. **`PQescape*` returns `PQfreemem`-managed pointer** — copy into
   rotating buf, then free.
4. **Param accumulator is shared, not thread/fiber-safe at the
   push boundary** — finish push/exec in one synchronous run; the
   Ruby `Connection#exec_params` does the full sequence atomically.
5. **`PQsetClientEncoding(conn, "UTF8")`** immediately after
   successful connect.
6. **Result slot table linear scan** for next-free is fine at
   `TEP_PG_MAX_RESULTS = 64`.

New for the AR-portability version:

7. **`tep_pg_result_conn[rh]` carries the conn slot.** Used by
   `tep_pg_finish` to clean up results, and by the Ruby side when
   raising `PG::Error` so `err.connection` can resolve.
8. **`tep_pg_connect_kv` for Hash conninfo.** Caller pre-joins
   keys / values with `\0` delimiters and passes both strings + a
   count. Empty value = use libpq default for that key. Matches the
   way ruby-pg lowers `PG.connect(host: "x", dbname: "y")` to
   `PQconnectdbParams`.

---

## The Ruby side (`lib/tep/pg.rb`)

Mirror `pg` gem class layout: top-level `PG` module containing
`Connection`, `Result`, `Error` (+ subclasses).

```ruby
# lib/tep/pg.rb -- ruby-pg-faithful surface on top of libpq via FFI.
#
# Mirrors PG::Connection / PG::Result / PG::Error from the pg gem
# (https://github.com/ged/ruby-pg). The class names and method
# signatures match upstream so AR's pg adapter ports forward with
# minimal divergence.
#
# Implementation lives in lib/tep/tep_pg.c (the libpq shim) +
# this file (the user-facing Ruby surface). See docs/PG-BATTERY.md
# for the design doc and the per-method compatibility table.

# Top-level FFI module -- the C-level seam. End users don't touch
# `Pg.*`; they use `PG::Connection`, `PG::Result`, etc.
module Pg
  ffi_cflags "@TEP_PG_O@"
  ffi_cflags "-lpq"
  ffi_cflags "@TEP_PG_CFLAGS@"

  # Result-status constants (collapsed from libpq's enum; see shim).
  ffi_const :RES_TUPLES,   0
  ffi_const :RES_COMMAND,  1
  ffi_const :RES_EMPTY,    2
  ffi_const :RES_ERROR,    3

  ffi_func :tep_pg_connect,                [:str],             :int
  ffi_func :tep_pg_connect_kv,             [:str, :str, :int], :int
  ffi_func :tep_pg_finish,                 [:int],             :int
  ffi_func :tep_pg_reset,                  [:int],             :int
  ffi_func :tep_pg_status,                 [:int],             :int
  ffi_func :tep_pg_transaction_status,     [:int],             :int
  ffi_func :tep_pg_error_message,          [:int],             :str
  ffi_func :tep_pg_server_version,         [:int],             :int
  ffi_func :tep_pg_set_client_encoding,    [:int, :str],       :int

  ffi_func :tep_pg_exec,                   [:int, :str],       :int
  ffi_func :tep_pg_param_clear,            [],                 :int
  ffi_func :tep_pg_param_push_str,         [:str],             :int
  ffi_func :tep_pg_param_push_null,        [],                 :int
  ffi_func :tep_pg_exec_params,            [:int, :str],       :int

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

  ffi_func :tep_pg_escape_string,          [:int, :str],       :str
  ffi_func :tep_pg_escape_literal,         [:int, :str],       :str
  ffi_func :tep_pg_escape_identifier,      [:int, :str],       :str
  ffi_func :tep_pg_libpq_version,          [],                 :str
end

# Public surface -- mirrors ruby-pg. `PG.connect`, `PG::Connection`,
# `PG::Result`, `PG::Error` and the SQLSTATE-keyed subclass tree.
module PG
  # Status constants from libpq, surfaced for user-side comparison.
  CONNECTION_OK  = 0
  CONNECTION_BAD = 1

  PQTRANS_IDLE    = 0
  PQTRANS_ACTIVE  = 1
  PQTRANS_INTRANS = 2
  PQTRANS_INERROR = 3
  PQTRANS_UNKNOWN = 4

  # PG.connect(opts) -- opts is either a conninfo String
  # ("postgresql://...") or a Hash<String,String> of libpq keys.
  # Returns a PG::Connection; raises PG::ConnectionBad on failure.
  def self.connect(opts)
    Connection.new(opts)
  end

  class Connection
    attr_accessor :pgh         # integer handle into the shim's slot table
    # NB: renamed from `:handle` because spinel's poly-recv dispatch
    # collides with Tep::Handler#handle. Same rename as Tep::SQLite#dbh.

    def initialize(opts)
      @pgh = -1
      if opts.is_a?(String)
        h = Pg.tep_pg_connect(opts)
      else
        # Hash -- pack into \0-delimited parallel strings.
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
        # PQstatus(-1) doesn't work, but the shim stashes the error
        # message on a per-process "last connect failure" slot at
        # index 0; that's what tep_pg_error_message(0) reads.
        raise PG::ConnectionBad.new(Pg.tep_pg_error_message(0), nil, "", nil)
      end
      @pgh = h
      Pg.tep_pg_set_client_encoding(@pgh, "UTF8")
    end

    def close
      if @pgh >= 0
        Pg.tep_pg_finish(@pgh)
        @pgh = -1
      end
      nil
    end

    def finish
      close
    end

    def reset
      Pg.tep_pg_reset(@pgh)
      self
    end

    def status
      Pg.tep_pg_status(@pgh)
    end

    def transaction_status
      Pg.tep_pg_transaction_status(@pgh)
    end

    def server_version
      Pg.tep_pg_server_version(@pgh)
    end

    def error_message
      Pg.tep_pg_error_message(@pgh)
    end

    def exec(sql)
      rh = Pg.tep_pg_exec(@pgh, sql)
      r = PG::Result.new(rh)
      Connection.raise_if_error(self, r)
      r
    end

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
      Connection.raise_if_error(self, r)
      r
    end

    def escape_string(s)
      Pg.tep_pg_escape_string(@pgh, s)
    end

    def escape_identifier(s)
      Pg.tep_pg_escape_identifier(@pgh, s)
    end

    def self.escape_string(s)
      # Class-method form -- ruby-pg allows this without a conn.
      # We still need a conn to call PQescapeStringConn; if no
      # default exists, fall back to a single-shot one via PQescape
      # which is deprecated but exists. Document this in v1.5.
      Pg.tep_pg_escape_string(0, s)   # 0 = use unset-conn fallback
    end

    def self.quote_ident(s)
      Pg.tep_pg_escape_identifier(0, s)
    end

    # Internal: inspect the Result's status; raise the matching
    # PG::Error subclass if it's an error. Raises with conn context
    # so `err.connection` resolves on AR's side.
    def self.raise_if_error(conn, r)
      st = r.status
      return if st == Pg::RES_TUPLES || st == Pg::RES_COMMAND || st == Pg::RES_EMPTY
      sqlstate = r.error_field(5)   # PG_DIAG_SQLSTATE
      msg = r.error_message
      cls = PG.error_class_for_sqlstate(sqlstate)
      raise cls.new(msg, r, sqlstate, conn)
    end
  end

  class Result
    attr_accessor :rh

    def initialize(rh)
      @rh = rh
    end

    def status;            @rh < 0 ? Pg::RES_ERROR : Pg.tep_pg_result_status(@rh); end
    def error_message;     @rh < 0 ? "" : Pg.tep_pg_result_error_message(@rh); end
    def error_field(code); @rh < 0 ? "" : Pg.tep_pg_result_error_field(@rh, code); end
    def cmd_status;        @rh < 0 ? "" : Pg.tep_pg_cmd_status(@rh); end
    def cmd_tuples;        @rh < 0 ?  0 : Pg.tep_pg_cmd_tuples(@rh); end

    def ntuples; @rh < 0 ? 0 : Pg.tep_pg_ntuples(@rh); end
    def nfields; @rh < 0 ? 0 : Pg.tep_pg_nfields(@rh); end
    alias_method :num_tuples, :ntuples   # ruby-pg name
    alias_method :num_fields, :nfields

    def fname(col);   @rh < 0 ? "" : Pg.tep_pg_fname(@rh, col); end
    def fnumber(name); @rh < 0 ? -1 : Pg.tep_pg_fnumber(@rh, name); end
    def ftype(col);    @rh < 0 ?  0 : Pg.tep_pg_ftype(@rh, col); end
    def fformat(col);  @rh < 0 ?  0 : Pg.tep_pg_fformat(@rh, col); end
    def fmod(col);     @rh < 0 ?  0 : Pg.tep_pg_fmod(@rh, col); end

    def getvalue(row, col); @rh < 0 ? "" : Pg.tep_pg_getvalue(@rh, row, col); end
    def getisnull(row, col); @rh < 0 ? true : Pg.tep_pg_getisnull(@rh, row, col) == 1; end
    def getlength(row, col); @rh < 0 ? 0 : Pg.tep_pg_getlength(@rh, row, col); end

    # ruby-pg name; same as getvalue with NULL-as-nil semantics.
    def value(row, col); getvalue(row, col); end

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

    # Hash-yielding iteration -- matches ruby-pg's `Result#each`.
    # The pre-built field-name array avoids a per-row fname call.
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
      nil
    end
  end

  # --- Exception hierarchy ---
  # (Definitions as shown in the "Error class hierarchy" section
  # above. ~25 leaf classes total in v1.5; the v1 file ships the
  # base + ConnectionBad + UnableToSend + ServerError, with the
  # leaves expanded in v1.5.)

  class Error < StandardError
    attr_reader :result, :sql_state, :connection
    def initialize(msg, result, sql_state, conn)
      super(msg)
      @result = result
      @sql_state = sql_state
      @connection = conn
    end
  end

  class ConnectionBad < Error; end
  class UnableToSend  < Error; end
  class ServerError   < Error; end

  # (v1.5: SQLSTATE-keyed leaves -- see hierarchy section.)

  # Map SQLSTATE to a leaf class. Flat case/when so spinel emits a
  # straight jump table; no Hash lookup. Stable across libpq versions.
  def self.error_class_for_sqlstate(state)
    return PG::ServerError if state.length < 5
    # First 2 chars are the class, last 3 are the subclass.
    klass = state[0, 2]
    full  = state
    if klass == "23"
      return PG::NotNullViolation       if full == "23502"
      return PG::ForeignKeyViolation    if full == "23503"
      return PG::UniqueViolation        if full == "23505"
      return PG::CheckViolation         if full == "23514"
      return PG::IntegrityConstraintViolation
    end
    if klass == "40"
      return PG::SerializationFailure   if full == "40001"
      return PG::DeadlockDetected       if full == "40P01"
    end
    if klass == "42"
      return PG::SyntaxError            if full == "42601"
      return PG::UndefinedColumn        if full == "42703"
      return PG::UndefinedFunction      if full == "42883"
      return PG::UndefinedTable         if full == "42P01"
      return PG::DuplicateColumn        if full == "42701"
      return PG::DuplicateTable         if full == "42P07"
      return PG::InsufficientPrivilege  if full == "42501"
    end
    if klass == "57"
      return PG::QueryCanceled          if full == "57014"
      return PG::AdminShutdown          if full == "57P01"
    end
    if klass == "08"
      return PG::ConnectionException
    end
    PG::ServerError
  end
end
```

### Why these signatures and not the earlier draft's

The earlier draft (sibling-of-SQLite stance) returned a `Result`
even on error, expected `r.ok?` checks at every callsite, kept the
namespace at `Tep::PG`, and explicitly avoided Hash yields. Each of
those was the right call **if AR portability wasn't on the table**.

Once it is:

- **Top-level `PG`** matches `require 'pg'` from gem-shaped code.
- **Raise on error** matches AR's exception-based control flow.
- **`PG::Error` subclass tree keyed by SQLSTATE** is what AR's
  `translate_exception_class` switches on.
- **Hash `each`** is what every `pg`-using ORM (AR, Sequel,
  ROM) expects.
- **`values` / `fields` / `column_values` arrays** match
  ruby-pg's iteration helpers.

The price: spinel's exception path needs to be exercised more
heavily than it currently is in tep (raised + rescued in handlers,
without crossing fiber boundaries). That's the integration risk
worth flagging — see "Spinel-imposed divergences" below.

---

## Sinatra-style usage (target)

```ruby
require 'sinatra'

on_start do
  c = PG.connect("postgresql:///myapp")
  c.exec("CREATE TABLE IF NOT EXISTS posts (id SERIAL PRIMARY KEY, title TEXT, body TEXT)")
  c.close
end

get '/posts' do
  c = PG.connect("postgresql:///myapp")
  out = ""
  begin
    r = c.exec("SELECT id, title FROM posts ORDER BY id LIMIT 50")
    r.each do |row|
      out = out + row["id"] + ": " + row["title"] + "\n"
    end
    r.clear
  rescue PG::Error => e
    status 500
    out = "db error: " + e.sql_state
  end
  c.close
  out
end

post '/posts' do
  c = PG.connect("postgresql:///myapp")
  begin
    r = c.exec_params(
      "INSERT INTO posts (title, body) VALUES ($1, $2) RETURNING id",
      [params[:title], params[:body]]
    )
    id = r.getvalue(0, 0)
    r.clear
    c.close
    "inserted=" + id
  rescue PG::UniqueViolation => e
    c.close
    status 409
    "duplicate: " + e.message
  end
end
```

Note `$1`, `$2` placeholders (libpq's positional bind syntax). This is
PG's native shape; AR's adapter emits these directly when building
prepared statements, so matching them costs nothing.

---

## Pool (`PG::Pool`)

Fixed-size connection pool, eager-open at construction. Per-worker
under prefork, one-per-worker under `Tep::Server::Scheduled`. The
shape mirrors AR's `ConnectionPool` and the external `pg_pool` gem:

```ruby
POOL = PG::Pool.new(ENV["DATABASE_URL"], 8)
raise "PG unreachable" unless POOL.healthy?

get '/users/:id' do
  c = POOL.checkout
  r = c.exec_params("SELECT name FROM users WHERE id = $1",
                    [params[:id]])
  name = r.getvalue(0, 0)
  r.clear
  POOL.checkin(c)
  name
end
```

API:

| Method | What |
|---|---|
| `PG::Pool.new(url, size)` | Eagerly open `size` PG::Connections against `url`. If any conn fails, its instance has `@pgh=-1`; check with `#healthy?`. |
| `pool.checkout` | Returns a Connection from the free list. If empty, parks via `Tep::Scheduler.pause(0.001)` until a checkin or timeout (`5s` default; override via `set_checkout_timeout_ms`). |
| `pool.checkin(c)` | Return `c` to the free list. |
| `pool.size` | Total conns the pool was built with. |
| `pool.available` | Current count in the free list (0..size). |
| `pool.healthy?` | True iff every pooled conn opened successfully and the free list is at full size (so call before any checkouts). |
| `pool.set_checkout_timeout_ms(ms)` | Override the 5s default checkout timeout. |
| `pool.close_all` | Close every conn in the free list. |

### v1 deliberately omits

- **`pool.with { |c| ... }`** — block form is the AR / pg_pool
  ergonomic shape. Spinel's instance-method typed yields still
  mis-type at the block-local binding (matz/spinel#628 covers the
  top-level def case only). Manual checkout/checkin is the v1
  workaround; `with` becomes a one-paragraph add when #628 closes.
- **`pool.checkout` raise-on-timeout** — depends on
  module-namespaced `rescue PG::ConnectionBad` working, which is
  the matz/spinel#627 follow-on. Today checkout-on-exhausted-pool
  returns the original seed slot; AR-shape exception flow lights
  up post-fix.
- **`pool.with_connection` (AR's name)** — synonym for `with`;
  same blocker, same fix path.
- **Waiter queue on `checkout` under Scheduled** (shipped Phase
  2.5): `pool.checkout` parks the current fiber via
  `@waiter_idxs.push(sched_current); Fiber.yield` (with a
  far-future wake_at sentinel) instead of the prior spin-via-
  pause shape. `pool.checkin` wakes the oldest waiter by setting
  `Tep::APP.sched_wake_at[widx] = -1`, which the scheduler picks
  as "earliest due" on the next tick. Outside scheduled context
  the fallback is a 1s pause-and-retry (the worker's single-
  threaded under prefork so no fiber starvation concern).

### Where the pool pays off

**Under prefork (the default `Tep::Server`)**: each worker is a
single-threaded process; only one handler runs at a time per worker.
Adding pool conns doesn't increase per-worker concurrency. The pool
still helps if a single handler wants to issue multiple PG queries
concurrently from forked subprocesses (`Tep::Parallel`), but the
common-case throughput stays at `workers × 1`.

**Under `Tep::Server::Scheduled` + cooperative `Tep::PG` (the v2
target)**: each worker hosts many fibers; each fiber can hold a pool
conn while parked on `io_wait` for the PG round-trip. Pool conns
become real parallelism. This is where the AR-on-spinel story plays
— async libpq via `PQsendQuery` + `PQconsumeInput` + `PQsocket`
parked on `Tep::Scheduler.io_wait`, with `PG::Pool` as the conn
multiplexer.

The bench numbers in [`bench/run_pg_solo.sh`](../bench/run_pg_solo.sh)
+ [`bench/pg_pool_bench.rb`](../bench/pg_pool_bench.rb) confirm
this: under prefork-blocking, pool-of-N doesn't move throughput vs
pool-of-1 (the extra conns sit idle). Re-running with cooperative
`Tep::PG` is the v2 deliverable.

### Concurrency-model summary

| Server | Pool size | In-flight |
|---|---|---|
| `Tep::Server` (prefork) | 1 per worker | `workers × 1` (pool size irrelevant) |
| `Tep::Server::Scheduled`, sync `Tep::PG` | N | `workers × 1` still (handler fiber blocks on PG recv) |
| `Tep::Server::Scheduled`, async `Tep::PG` (v2) | N | `workers × N` (each fiber can hold a conn while parked) |

---

## ActiveRecord adapter sketch (v2 target, after async lands)

A `Tep::AR::PGAdapter` (or whatever the namespace ends up) reuses
AR's `PostgreSQLAdapter` upstream with the following swaps:

1. `require 'pg'` is removed; Tep's `lib/tep/pg.rb` is inlined by
   `bin/tep`.
2. `PG::Connection.new(opts)` works as-is — same constructor shape.
3. `PG::Result#each { |row| ... }` works as-is — same Hash yield
   shape. The AR adapter's `result_as_array` and friends route
   through it.
4. `PG::Error` and subclasses work as-is — AR's
   `translate_exception_class` does `e.is_a?(PG::UniqueViolation)`
   etc., and the class identities match.
5. **`prepare` + `exec_prepared`** are required (AR caches prepared
   statements aggressively). This is v1.5; until then, AR runs in
   "no prepared statements" mode (a supported AR config — there's a
   `prepared_statements: false` adapter option).
6. **`async_exec`** is the default since Rails 7; AR will fall back
   to sync `exec` if async isn't there. v1's sync-only is workable;
   v2's async makes it good.
7. **Type casting**: AR's pg adapter handles this itself via its
   `OID` type registry. AR pulls types via `SELECT oid, typname
   FROM pg_type`, so Tep::PG only needs to deliver the
   `result.ftype(col)` OID + textual value. AR does the rest.
8. **Connection pooling**: AR has its own pool. Tep::PG doesn't
   need to provide a pool — AR wraps Tep::PG::Connection instances
   inside its `ConnectionPool`.

AR-on-spinel is its own ~3-month project. This doc isn't claiming
otherwise — only that **the surface here doesn't add to that
project's friction**. Diverging now would.

---

## Build integration

(Unchanged from the earlier draft — Makefile, bin/tep, lib/tep.rb,
RBS file changes are mechanical and identical.)

### `Makefile` changes

```make
export TEP_PG_O := $(LIB_DIR)/tep_pg.o

TEP_PG_CFLAGS ?= $(shell pkg-config --cflags libpq 2>/dev/null || pg_config --cflags 2>/dev/null)
TEP_PG_LIBS   ?= $(shell pkg-config --libs libpq 2>/dev/null || echo "-lpq")
export TEP_PG_CFLAGS TEP_PG_LIBS

helper: spinel-fresh $(LIB_DIR)/sphttp.o $(LIB_DIR)/tep_sqlite.o $(LIB_DIR)/tep_pg.o

$(LIB_DIR)/tep_pg.o: $(LIB_DIR)/tep_pg.c
	cc -O2 -c $(TEP_PG_CFLAGS) $< -o $@
```

`pkg-config libpq` is the canonical lookup on Linux + Homebrew
(both ship a `.pc` file). `pg_config` is the fallback.

### `bin/tep` placeholder substitution

```ruby
pg_o    = ENV.fetch("TEP_PG_O",    File.join(LIB_DIR, "tep", "tep_pg.o"))
pg_cflg = ENV.fetch("TEP_PG_CFLAGS", "")
pg_libs = ENV.fetch("TEP_PG_LIBS",  "-lpq")

combined = combined.gsub("@TEP_PG_O@",     pg_o)
combined = combined.gsub("@TEP_PG_CFLAGS@", pg_cflg + " " + pg_libs)
```

### `lib/tep.rb`

```ruby
require_relative "tep/pg"

# In the seed block:
_seed_pg_row = Tep.str_hash
_seed_pg_row["k"] = "v"
# (this pins the Hash<String,String> shape PG::Result#each yields.)
```

---

## Spinel-imposed divergences (the honest list)

Things where Tep::PG and ruby-pg can't be bit-identical:

1. **Block forwarding through method boundaries.** ruby-pg's
   `conn.set_notice_receiver { |result| ... }` stores a block on
   the connection and yields to it from a libpq callback. Spinel's
   block-as-value support is limited; we expose
   `set_notice_receiver(handler)` taking a `PG::NoticeReceiver`
   subclass with a `handle(result)` method instead. Same shape,
   different binding form.

2. **`PG::Result#each_with_index` and other Enumerator helpers.**
   Spinel doesn't have Enumerator. We ship `each` and `each_row`;
   users wanting an index manage `i` manually. AR's adapter doesn't
   use these.

3. **Frozen-string semantics on returned strings.** ruby-pg returns
   frozen strings from `getvalue` since Ruby 3.0. Spinel strings
   under the rotating-buffer model are mutable but the caller
   shouldn't write to them — they get clobbered on rotation. The
   convention is "treat them as frozen even though the runtime
   doesn't enforce it." Same as `tep_sqlite_col_str`.

4. **Type maps.** ruby-pg's `conn.type_map_for_results = ...` and
   the encoder/decoder framework do not have a Tep::PG analog. The
   contract is: shim hands up text + OID; caller (or AR) coerces.
   This is intentional, not a planned-fix divergence.

5. **`PG::TypeMap` / `PG::Coder` classes.** Absent entirely. Any AR
   patterns that lean on these get rewritten to the simpler
   text-in / text-out form when porting AR.

6. **`PG::TextEncoder::Numeric` and the encoder hierarchy.**
   Absent. Callers stringify on the way in (Integer → `n.to_s`,
   nil → SQL NULL via `param_push_null`).

7. **Connection methods that take a block + auto-rollback.**
   `conn.transaction { ... }` in ruby-pg rolls back on raised
   exception. Spinel's exception-through-block path works at v1
   (`begin/rescue` inside a route block), but the
   `Connection#transaction(&block)` shape captures the block; we
   ship it but only verify the path in tests where the block is a
   simple sequence of `exec_params` calls.

8. **Async transactions** spanning multiple fiber yields. v2
   territory — the libpq async surface plus `Tep::Scheduler.io_wait`
   gives us the primitives, but transactional semantics across
   yields require careful state management. AR doesn't yield mid-
   transaction by default, so this is a "we'll cross it when AR
   does" concern.

---

## RBS (`sig/tep/pg.rbs`)

```rbs
module PG
  CONNECTION_OK: Integer
  CONNECTION_BAD: Integer

  PQTRANS_IDLE: Integer
  PQTRANS_ACTIVE: Integer
  PQTRANS_INTRANS: Integer
  PQTRANS_INERROR: Integer
  PQTRANS_UNKNOWN: Integer

  def self.connect: (String | Hash[String, String] opts) -> PG::Connection

  class Connection
    attr_accessor pgh: Integer

    def initialize: (String | Hash[String, String] opts) -> void
    def close: () -> nil
    def finish: () -> nil
    def reset: () -> Connection
    def status: () -> Integer
    def transaction_status: () -> Integer
    def server_version: () -> Integer
    def error_message: () -> String

    def exec: (String sql) -> Result
    def exec_params: (String sql, Array[String | Integer | nil] params) -> Result

    def escape_string: (String s) -> String
    def escape_identifier: (String s) -> String
    def self.escape_string: (String s) -> String
    def self.quote_ident: (String s) -> String
  end

  class Result
    attr_accessor rh: Integer
    def initialize: (Integer rh) -> void

    def status: () -> Integer
    def error_message: () -> String
    def error_field: (Integer code) -> String
    def cmd_status: () -> String
    def cmd_tuples: () -> Integer

    def ntuples: () -> Integer
    def nfields: () -> Integer
    def num_tuples: () -> Integer
    def num_fields: () -> Integer

    def fname: (Integer col) -> String
    def fnumber: (String name) -> Integer
    def ftype: (Integer col) -> Integer
    def fformat: (Integer col) -> Integer
    def fmod: (Integer col) -> Integer

    def getvalue: (Integer row, Integer col) -> String
    def getisnull: (Integer row, Integer col) -> bool
    def getlength: (Integer row, Integer col) -> Integer
    def value: (Integer row, Integer col) -> String

    def fields: () -> Array[String]
    def values: () -> Array[Array[String]]
    def column_values: (Integer col) -> Array[String]

    def each_row: () { (Array[String]) -> void } -> Result
    def each: () { (Hash[String, String]) -> void } -> Result
    def clear: () -> nil
  end

  class Error < StandardError
    attr_reader result: Result?
    attr_reader sql_state: String
    attr_reader connection: Connection?
    def initialize: (String msg, Result? result, String sql_state, Connection? conn) -> void
  end

  class ConnectionBad < Error; end
  class UnableToSend  < Error; end
  class ServerError   < Error; end
  # v1.5: leaf classes.

  def self.error_class_for_sqlstate: (String state) -> Class
end
```

---

## Testing strategy

(Unchanged from earlier draft. `PG_TEST_URL` env gate, opt-in
`make test-pg` target, ~12 tests covering DDL / INSERT / SELECT /
params / NULL / errors / transactions / escape / multi-result.)

New coverage targets for the AR-portability path:

13. **Hash `each` yields `Hash<String, String>`** — values match
    `each_row` for the same rows.
14. **`PG::UniqueViolation` is raised** on a duplicate INSERT —
    `rescue PG::UniqueViolation` catches; `e.sql_state == "23505"`.
15. **`PG::UndefinedTable`** on a `SELECT FROM nonexistent` —
    `e.sql_state == "42P01"`.
16. **`PG::ServerError` parent rescue catches all** — a
    `rescue PG::Error` block catches `PG::UniqueViolation`,
    `PG::SyntaxError`, etc.
17. **`fields` / `values` / `column_values`** — array shapes match
    ruby-pg.
18. **`fnumber(name)`** — returns the right column index;
    `-1` for unknown name.
19. **`Connection#exec_params` round-trips an integer** — `42`
    in, `"42"` out from `getvalue` (text format).

---

## Phased delivery

### Phase 0 — scaffolding (half day)

- [ ] `lib/tep/tep_pg.c` with `connect`, `connect_kv`, `finish`,
      `status`, `error_message`, `server_version`, `libpq_version`.
- [ ] `lib/tep/pg.rb` with FFI declarations + `PG.connect` +
      `PG::Connection` stub.
- [ ] `Makefile` + `bin/tep` substitutions.
- [ ] `require_relative "tep/pg"` in `lib/tep.rb` + the
      str_str_hash seed.
- [ ] Smoke test: connect, print `server_version`, finish.

### Phase 1 — exec + result reading + Error base (1-2 days)

- [ ] All exec / result / escape entry points in the shim.
- [ ] Ruby-side `Connection#exec`, `#exec_params`, `#escape_*`.
- [ ] `Result` class with `values` / `fields` / `each` / `each_row`
      / `getvalue` / `getisnull` / `fnumber` / `ftype` / `clear`.
- [ ] `PG::Error` base + `ConnectionBad` + `UnableToSend` +
      `ServerError`. `error_class_for_sqlstate` returns
      `PG::ServerError` for everything in v1.
- [ ] Tests 1-7 + 13, 17-19.

Acceptance: tests pass against a real local PG. AR's
`PostgreSQLAdapter#execute` path is mechanically reachable
(prepared statements off).

### Phase 1.5 — error leaves + prepare/exec_prepared (1 day)

- [ ] All ~25 leaf PG::Error subclasses.
- [ ] `error_class_for_sqlstate` flat case/when filled out.
- [ ] `tep_pg_prepare` / `tep_pg_exec_prepared` / `tep_pg_deallocate`
      in the shim.
- [ ] `Connection#prepare`, `#exec_prepared`.
- [ ] Tests 14, 15, 16.

Acceptance: AR adapter runs with prepared statements on.

### Phase 2 — async + Tep::Scheduler integration (shipped 2026-05-20)

Connection#async_exec / async_exec_params drive the libpq non-
blocking surface (PQsendQuery + PQflush + PQconsumeInput +
PQisBusy + PQgetResult), parking the fiber on
`Tep::Scheduler.io_wait(fd, READ|WRITE)` between recv calls. Under
prefork the io_wait falls back to a single-shot poll(2), so the
same code is correct under either server -- the cross-fiber
concurrency win only materialises under Tep::Server::Scheduled.

`Connection#exec` / `#exec_params` runtime-detect the scheduler
context (`Tep::Scheduler.scheduled_context?`) and auto-route through
the async path when called inside a scheduled fiber. Apps don't
have to choose between sync and async at the call site.

C shim additions in lib/tep/tep_pg.c:

  * tep_pg_socket(h)             -> PQsocket fd
  * tep_pg_set_nonblocking(h, b) -> PQsetnonblocking
  * tep_pg_send_query(h, sql)
  * tep_pg_send_query_params(h, sql)
  * tep_pg_flush(h)
  * tep_pg_consume_input(h)
  * tep_pg_is_busy(h)
  * tep_pg_get_result(h)

The Ruby loop lives in PG::Connection.drain_send /
.wait_for_result_ready / .drain_remaining_results. async_exec
+ async_exec_params are the public methods.

Followups:

  * **Async connect** (shipped Phase 2.5): `Connection.new`
    under scheduled context routes through `Connection.async_connect`
    which drives `PQconnectStart` + `PQconnectPoll` parked on
    io_wait. PG::Pool's eager open at construction now warms N
    connections in parallel under Scheduled.
  * Pool checkout-on-empty waiter queue (shipped Phase 2.5; see
    "Pool" section above).
  * **High-concurrency cooperative-server scaling (Phase 2.6,
    open)**: under wrk at conn >= 4, both pool-bench and
    no-pool-single-conn-per-request scenarios collapse to 0-100
    req/s instead of climbing past the prefork baseline.
    Single-conn (`wrk -c1`) hits ~2.5k req/s correctly, so the
    async path itself works. Suspect shared global state in
    `tep_pg.c` under concurrent fibers: `tep_pg_param_buf`
    (single global accumulator), the rotating return-string
    slots, the conn / result slot tables. Diagnostic next:
    instrument the shim to detect interleaved param-push from
    multiple in-flight async_exec calls. The single-conn-per-
    fiber pool design assumes thread-local-like per-fiber state
    in the shim, which isn't there yet.

### Phase 2 — original notes (kept for reference; superseded by above)

(Detail unchanged from earlier draft.)

- [ ] `tep_pg_send_query`, `_consume_input`, `_is_busy`,
      `_get_result`, `_socket`, `_flush`, `_set_nonblocking`.
- [ ] `Connection#async_exec`, `#async_exec_params`,
      `#async_exec_prepared`. Internal loop parks fibers on
      `Tep::Scheduler.io_wait`.
- [ ] `PQconnectStartParams` for async connect (used by AR's
      adapter-pool warmup).

Acceptance: an AR-on-Tep proof of concept boots and serves a
simple CRUD page through `async_exec`.

### Phase 2.5 — LISTEN/NOTIFY (1 day)

- [ ] `tep_pg_notifies(h)`. Caller pattern documented.

### Phase 3 — COPY + binary format (1-2 days)

- [ ] `put_copy_data` / `_end`, `get_copy_data`.
- [ ] `fformat == 1` result-reading path (binary OIDs surface;
      caller decodes).

---

## Known gotchas (from sqlite battery + new ones)

1. **`:dbh` rename for `:handle`** (same as sqlite) — `Connection#pgh`
   not `#handle`.
2. **`each` Hash seed is load-bearing.** Without `_seed_pg_row` in
   `lib/tep.rb`, the per-row hash widens to `poly_poly_hash` on
   first use. The seed pins it to `str_str_hash` at module load.
3. **Exception path through fiber boundaries.** v1 keeps
   `begin/rescue PG::Error` at the handler boundary only — no
   `Fiber.yield` between the raise and the rescue. Async (v2)
   needs to revisit; spinel's exception-across-yields story is
   currently uneven.
4. **`exec`/`exec_params` raise on error.** Callers that need
   "don't raise" semantics can rescue inline (`begin; conn.exec(sql);
   rescue PG::Error; nil; end`) or wait for a `Connection#exec_raw`
   variant (deferred until a real workload asks for it).
5. **Param buffer is 256 KiB now.** AR sends large `INSERT ...
   VALUES (...), (...), (...)` batches; the earlier 64 KiB cap was
   tight. If a single param exceeds 256 KiB the push returns -1 and
   `exec_params` raises `PG::UnableToSend` with `"param too large"`.
6. **Result slot table at 64 entries.** AR can hold a few cursors
   open at once (e.g. during a `with_lock` block). 64 is generous
   but finite; if it ever bites, the next bump is to 256.
7. **`PG::Connection.new(Hash)` requires String keys.** Symbol
   keys widen to poly. Document the constraint in the class doc
   string. ruby-pg accepts both; AR uses string keys via the
   adapter config, so this is fine for the AR path.
8. **The `0` slot for "no connection."** `Connection.escape_string`
   class method needs to call libpq without a live conn. We
   reserve slot 0 for an internal "default conn" the shim
   instantiates lazily (or use the deprecated `PQescapeString`
   which doesn't need a conn). Class-method-with-no-conn is rare
   enough that the lazy default is acceptable.
9. **`exec("BEGIN")` then a failing statement leaves the conn in
   `PQTRANS_INERROR`.** Subsequent statements all fail with
   `current transaction is aborted`. Document: callers wanting
   savepoint semantics use `SAVEPOINT` / `ROLLBACK TO SAVEPOINT`
   inside a transaction. AR handles this internally; user-facing
   `Connection#transaction` block also `rescue PG::Error; ROLLBACK`
   wraps it.

---

## Open questions to revisit at implementation time

1. **`PG::Connection.new(opts)` opts shape.** ruby-pg accepts a
   conninfo String, a Hash with Symbol keys, OR positional args
   (`PG.connect(host, port, options, tty, dbname, login, password)`,
   the legacy form). We ship String + `Hash<String, String>`; the
   positional form is undocumented in ruby-pg today and AR doesn't
   use it. Skip.

2. **Connection pool.** Shipped as `PG::Pool` (see "Pool" section
   below). v1 covers checkout/checkin + cooperative wait; the
   block-form `with { |c| ... }` is deferred until spinel lights
   up instance-method typed yields. v1 pays off when paired with
   cooperative `Tep::PG` (the v2 async path).

3. **`Connection#trace` / pg verbosity.** Diagnostic helpers from
   ruby-pg that aren't on the AR path. Skip until asked.

4. **macOS Homebrew libpq path.** `pkg-config libpq` works after
   `brew install libpq` (the .pc file ships in the keg-only
   prefix; `PKG_CONFIG_PATH` needs to point at
   `/opt/homebrew/opt/libpq/lib/pkgconfig`). Document.

5. **Namespace overlap with `Tep::PG` (if anyone tries).** Today
   it's `PG` only; the Tep convention bends. If a user defines
   their own top-level `PG` constant for something else, they
   conflict. The mitigation: tep's `PG` module is the same one
   you'd `require 'pg'` for, so user `PG` references should
   resolve to ours unambiguously. Document the deviation from the
   `Tep::Foo` pattern.

---

## Reference: libpq surface used

(Carried verbatim from the earlier draft; 22 calls for v1, +3 for
v1.5 prepared, +10 for v2 async, +4 for COPY in v3.)

---

## Done-criteria checklist

v1:

- [ ] `make` builds `tep_pg.o` cleanly on macOS (Homebrew) + Linux
      (Ubuntu / Debian).
- [ ] `make test-pg` (new target) passes against a real local PG.
- [ ] `examples/pg_hello.rb` builds + runs.
- [ ] `sig/tep/pg.rbs` parses (`rake rbs:validate`).
- [ ] README batteries table entry.
- [ ] `make test` (without PG_TEST_URL) still passes everything else.

v1.5:

- [ ] Prepared statements working end-to-end (test 14-15 style).
- [ ] SQLSTATE-keyed PG::Error subclasses raise correctly.
- [ ] AR's `translate_exception_class` switch logic compiles
      against `Tep::PG` (a tiny scratch test that imports the AR
      function and exercises the `is_a?` branches with mocked
      Tep::PG errors).

v2 (async):

- [ ] An AR-on-Tep proof-of-concept (`examples/ar_blog/` or
      similar) boots and serves /posts via `async_exec`.
- [ ] Per-request `async_exec` does not block the worker fiber.
- [ ] Documented latency / throughput vs sync `exec`.

---

## Appendix: a worked example of the param-accumulator flow

(Carried from earlier draft; unchanged. The accumulator semantics
match ruby-pg's internal param-array building — caller-visible API
is `exec_params(sql, params)` either way.)

---

## Appendix: why this is the right scope

The user prompt that produced this revision:

> "We should try as much as possible to keep the shape such as that
> when porting ActiveRecord for example we could keep the `pg`
> surface as close to the original as possible."

What "as close as possible" means in the Tep context:

- **Class names**: identical (`PG::Connection`, `PG::Result`,
  `PG::Error` + subclasses).
- **Method names**: identical (`exec`, `exec_params`, `prepare`,
  `exec_prepared`, `escape_string`, `escape_identifier`,
  `getvalue`, `each`, `each_row`, `values`, `fields`,
  `cmd_tuples`, `fnumber`, etc.).
- **Return shapes**: identical for the methods we ship
  (`values` → `Array<Array<String>>`, `each` → `Hash<String,String>`,
  etc.).
- **Exception classes**: identical for the SQLSTATE-keyed leaves
  AR actually rescues; v1.5 fills the full subset.
- **Constants**: identical (`PG::CONNECTION_OK`, `PG::PQTRANS_*`).
- **Signature shapes**: same positional order, String vs Hash opts
  on `connect`.

What we deliberately diverge on:

- **Block-stored callbacks** (`set_notice_receiver`) — Handler
  class form instead.
- **Enumerator** — absent (spinel).
- **Type maps / encoders** — absent (out of scope).
- **`**kwargs`** — absent (spinel). Positional only.
- **Exception-across-fiber-yield** — works at handler boundary only
  in v1; v2's async needs to revisit.

These divergences are the irreducible "spinel cost." Everything else
is matched. The AR-on-spinel port (whenever it happens) reuses the
adapter's pg-shaped code paths without rewriting them.
