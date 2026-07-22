/* tep_sqlite.c - thin libsqlite3 wrapper for spinel-AOT'd tep apps.
 *
 * Pattern mirrors sphttp.c: spinel can't load CRuby C extensions
 * (the `sqlite3` gem ships native code via Ruby's MRI ABI), so we
 * write a small C shim with stable, str/int-typed entry points and
 * expose them via spinel's `ffi_func` DSL.
 *
 * Scope of v1
 * -----------
 *   - `open(path)` / `close(h)`                      -- multiple DB
 *     handles (up to TEP_SQLITE_MAX_HANDLES) tracked in a static
 *     slot table so handles fit in spinel's :int FFI return.
 *   - `exec(h, sql)`                                 -- run a
 *     statement that returns no rows (CREATE / INSERT / UPDATE /
 *     DELETE / PRAGMA). No bind in this form; for parameterised
 *     writes use prepare + bind + step + finalize.
 *   - `prepare(h, sql)` / `bind_{str,int}(idx, v)` / `step()` /
 *     `col_{str,int}(idx)` / `col_count()` / `finalize()`
 *                                                    -- a single
 *     global cursor (one in-flight statement per process). Spinel
 *     workers are single-threaded, and the framework never holds
 *     two cursors at once -- handlers run serially per worker.
 *   - `last_insert_rowid(h)`                         -- for INSERT
 *     ... RETURNING-less workflows.
 *
 * Out of scope (v1)
 * -----------------
 *   - Multi-cursor: nested queries (open one cursor, iterate, run
 *     another query inside). Document and revisit.
 *   - Blob / NULL columns: col_str returns "" for NULL, callers
 *     can't distinguish empty-string from NULL.
 *   - Transactions: works via `exec("BEGIN")` / `exec("COMMIT")`.
 *
 * Errors
 * ------
 * Most functions return 0 on success and -1 on error. Detailed
 * errmsg surfacing isn't wired through (spinel's :str return
 * lifetime would make it awkward); the C shim could expose
 * `tep_sqlite_errmsg()` as a static-buffer copy if needed.
 */

#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

#define TEP_SQLITE_MAX_HANDLES    16
#define TEP_SQLITE_COL_BUFSIZE    65536
#define TEP_SQLITE_COL_BUF_SLOTS  16
#define TEP_SQLITE_CACHE_SLOTS    64       /* prepare-statement cache */
#define TEP_SQLITE_CACHE_SQL_MAX  512      /* longest cached SQL */

static sqlite3      *tep_sqlite_handles[TEP_SQLITE_MAX_HANDLES] = {0};
static sqlite3_stmt *tep_sqlite_stmt = NULL;
/* When the current cursor came from the prepare-statement cache, we
 * must NOT sqlite3_finalize it on tep_sqlite_finalize -- the slot
 * stays alive for reuse, and finalize becomes reset+clear_bindings.
 * Same applies to tep_sqlite_prepare's stmt-swap path. */
static int           tep_sqlite_stmt_cached = 0;

/* prepare-statement cache (chunk per #75). Linear scan by (h, sql);
 * n is small so O(n) is fine. Bounded by TEP_SQLITE_CACHE_SLOTS;
 * if full, prepare_cached falls through to an uncached prepare. */
typedef struct {
    int           h;                                 /* db handle index (1-based), 0 = empty */
    sqlite3_stmt *stmt;
    char          sql[TEP_SQLITE_CACHE_SQL_MAX];
} tep_sqlite_cache_entry;
static tep_sqlite_cache_entry tep_sqlite_cache[TEP_SQLITE_CACHE_SLOTS] = {0};
/* Rotating return buffers for col_str. spinel's `:str` return type
 * wants a pointer that stays valid until "the caller is done with
 * it", but in practice callers stash multiple col_str results into
 * variables / hashes / array entries before the buffer would
 * otherwise rotate. A single static buf would alias all those
 * entries to whatever the most recent call wrote.
 *
 * We rotate across SLOTS buffers; each call lands in the next
 * slot. With 16 slots a typical handler doing
 *
 *     a = first_str(...); b = first_str(...); c = first_str(...)
 *
 * sees three independent strings.
 *
 * The aliasing window only collapses for callers who hold > 16
 * live col_str references concurrently -- e.g. iterating a query
 * and pushing every row into an array without copying. Document
 * that lifetime in `Tep::SQLite#col_str`. */
static char          tep_sqlite_col_buf[TEP_SQLITE_COL_BUF_SLOTS][TEP_SQLITE_COL_BUFSIZE];
static int           tep_sqlite_col_slot = 0;

int tep_sqlite_open(const char *path) {
    int i;
    for (i = 0; i < TEP_SQLITE_MAX_HANDLES; i++) {
        if (tep_sqlite_handles[i] == NULL) {
            sqlite3 *db = NULL;
            if (sqlite3_open(path, &db) != SQLITE_OK) {
                if (db) sqlite3_close(db);
                return -1;
            }
            tep_sqlite_handles[i] = db;
            return i + 1; /* 1-indexed: 0 reserved for "uninitialised" */
        }
    }
    return -1;
}

int tep_sqlite_close(int h) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return -1;
    sqlite3 *db = tep_sqlite_handles[h - 1];
    if (db == NULL) return -1;
    /* Finalize any cursor that was on this handle to avoid
     * sqlite_close returning SQLITE_BUSY. */
    if (tep_sqlite_stmt && sqlite3_db_handle(tep_sqlite_stmt) == db) {
        if (!tep_sqlite_stmt_cached) {
            sqlite3_finalize(tep_sqlite_stmt);
        }
        /* Cached stmts get finalized below by the cache walk. */
        tep_sqlite_stmt = NULL;
        tep_sqlite_stmt_cached = 0;
    }
    /* Finalize every cached statement that belongs to this handle
     * before closing the db. Cache slots are owner-keyed by `h`. */
    int i;
    for (i = 0; i < TEP_SQLITE_CACHE_SLOTS; i++) {
        if (tep_sqlite_cache[i].h == h && tep_sqlite_cache[i].stmt) {
            sqlite3_finalize(tep_sqlite_cache[i].stmt);
            tep_sqlite_cache[i].stmt = NULL;
            tep_sqlite_cache[i].h    = 0;
            tep_sqlite_cache[i].sql[0] = '\0';
        }
    }
    sqlite3_close(db);
    tep_sqlite_handles[h - 1] = NULL;
    return 0;
}

int tep_sqlite_exec(int h, const char *sql) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return -1;
    sqlite3 *db = tep_sqlite_handles[h - 1];
    if (db == NULL) return -1;
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (err) sqlite3_free(err);
    return rc == SQLITE_OK ? 0 : -1;
}

/* Drop or reset whatever's currently on the singleton cursor before
 * we install a new one. Cached stmts get reset+clear_bindings (so
 * the cached slot stays valid); uncached stmts get finalized. */
static void tep_sqlite_release_current(void) {
    if (!tep_sqlite_stmt) return;
    if (tep_sqlite_stmt_cached) {
        sqlite3_reset(tep_sqlite_stmt);
        sqlite3_clear_bindings(tep_sqlite_stmt);
    } else {
        sqlite3_finalize(tep_sqlite_stmt);
    }
    tep_sqlite_stmt = NULL;
    tep_sqlite_stmt_cached = 0;
}

int tep_sqlite_prepare(int h, const char *sql) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return -1;
    sqlite3 *db = tep_sqlite_handles[h - 1];
    if (db == NULL) return -1;
    tep_sqlite_release_current();
    if (sqlite3_prepare_v2(db, sql, -1, &tep_sqlite_stmt, NULL) != SQLITE_OK) {
        tep_sqlite_stmt = NULL;
        return -1;
    }
    /* uncached */
    return 0;
}

/* Cached variant: looks up `sql` for db handle `h` in the cache;
 * on hit reuses the prepared statement (with reset + clear_bindings);
 * on miss prepares + stashes in the first free slot; if the cache is
 * full, falls back to an uncached prepare so the caller still works.
 *
 * SQL is matched literally (no normalization). Apps that generate
 * SQL with varying whitespace miss the cache; format consistently. */
int tep_sqlite_prepare_cached(int h, const char *sql) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return -1;
    sqlite3 *db = tep_sqlite_handles[h - 1];
    if (db == NULL) return -1;
    /* SQL longer than the cache's per-slot buffer: just do an
     * uncached prepare. The caller still gets correct behavior. */
    size_t sql_len = strlen(sql);
    if (sql_len >= TEP_SQLITE_CACHE_SQL_MAX) {
        return tep_sqlite_prepare(h, sql);
    }
    tep_sqlite_release_current();
    /* Cache lookup. */
    int i;
    for (i = 0; i < TEP_SQLITE_CACHE_SLOTS; i++) {
        if (tep_sqlite_cache[i].h == h &&
            tep_sqlite_cache[i].stmt &&
            strcmp(tep_sqlite_cache[i].sql, sql) == 0) {
            tep_sqlite_stmt = tep_sqlite_cache[i].stmt;
            sqlite3_reset(tep_sqlite_stmt);
            sqlite3_clear_bindings(tep_sqlite_stmt);
            tep_sqlite_stmt_cached = 1;
            return 0;
        }
    }
    /* Cache miss -- find an empty slot. */
    int empty = -1;
    for (i = 0; i < TEP_SQLITE_CACHE_SLOTS; i++) {
        if (tep_sqlite_cache[i].h == 0) { empty = i; break; }
    }
    if (empty < 0) {
        /* Cache full: prepare uncached so the caller works. The
         * existing tep_sqlite_finalize path will sqlite3_finalize
         * this one as today. */
        if (sqlite3_prepare_v2(db, sql, -1, &tep_sqlite_stmt, NULL) != SQLITE_OK) {
            tep_sqlite_stmt = NULL;
            return -1;
        }
        tep_sqlite_stmt_cached = 0;
        return 0;
    }
    /* Prepare + stash. */
    sqlite3_stmt *new_stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &new_stmt, NULL) != SQLITE_OK) {
        tep_sqlite_stmt = NULL;
        return -1;
    }
    tep_sqlite_cache[empty].h    = h;
    tep_sqlite_cache[empty].stmt = new_stmt;
    memcpy(tep_sqlite_cache[empty].sql, sql, sql_len);
    tep_sqlite_cache[empty].sql[sql_len] = '\0';
    tep_sqlite_stmt        = new_stmt;
    tep_sqlite_stmt_cached = 1;
    return 0;
}

int tep_sqlite_bind_str(int idx, const char *value) {
    if (!tep_sqlite_stmt) return -1;
    /* SQLITE_TRANSIENT -> sqlite copies the string before returning,
     * so the caller's pointer doesn't need to outlive the bind. */
    return sqlite3_bind_text(tep_sqlite_stmt, idx, value, -1, SQLITE_TRANSIENT)
                == SQLITE_OK ? 0 : -1;
}

/* 64-bit bind. `long` is the FFI `:long` type (64-bit on the LP64
 * targets Spinel compiles for); routed through sqlite3_bind_int64 so a
 * value > 2^31 isn't truncated on the way in (issue #171). */
int tep_sqlite_bind_int(int idx, long value) {
    if (!tep_sqlite_stmt) return -1;
    return sqlite3_bind_int64(tep_sqlite_stmt, idx, (sqlite3_int64)value) == SQLITE_OK ? 0 : -1;
}

/* 1 -> row available, 0 -> done (no more rows), -1 -> error */
int tep_sqlite_step(void) {
    if (!tep_sqlite_stmt) return -1;
    int rc = sqlite3_step(tep_sqlite_stmt);
    if (rc == SQLITE_ROW) return 1;
    if (rc == SQLITE_DONE) return 0;
    return -1;
}

const char *tep_sqlite_col_str(int idx) {
    if (!tep_sqlite_stmt) return "";
    const unsigned char *t = sqlite3_column_text(tep_sqlite_stmt, idx);
    if (!t) return "";
    size_t n = strlen((const char *)t);
    if (n >= TEP_SQLITE_COL_BUFSIZE) n = TEP_SQLITE_COL_BUFSIZE - 1;
    char *buf = tep_sqlite_col_buf[tep_sqlite_col_slot];
    tep_sqlite_col_slot = (tep_sqlite_col_slot + 1) % TEP_SQLITE_COL_BUF_SLOTS;
    memcpy(buf, t, n);
    buf[n] = '\0';
    return buf;
}

/* 64-bit column read. sqlite3_column_int (32-bit) silently wrapped a
 * value > 2^31 negative -- e.g. a 3.4e9 download count read back as
 * -867422609 (issue #171). sqlite3_column_int64 + a `long` (FFI
 * `:long`, 64-bit) return path preserves the full range; mrb_int is
 * pointer-width so the Ruby side holds it losslessly. */
long tep_sqlite_col_int(int idx) {
    if (!tep_sqlite_stmt) return 0;
    return (long)sqlite3_column_int64(tep_sqlite_stmt, idx);
}

int tep_sqlite_col_count(void) {
    if (!tep_sqlite_stmt) return 0;
    return sqlite3_column_count(tep_sqlite_stmt);
}

/* Finalize semantics depend on whether the current stmt came from
 * the prepare-statement cache. Cached stmts get reset + clear_bindings
 * and stay alive in their slot (the whole point of the cache); only
 * uncached stmts actually sqlite3_finalize. The Ruby-side API
 * (`db.finalize`) is unchanged either way. */
int tep_sqlite_finalize(void) {
    if (!tep_sqlite_stmt) return 0;
    if (tep_sqlite_stmt_cached) {
        sqlite3_reset(tep_sqlite_stmt);
        sqlite3_clear_bindings(tep_sqlite_stmt);
    } else {
        sqlite3_finalize(tep_sqlite_stmt);
    }
    tep_sqlite_stmt = NULL;
    tep_sqlite_stmt_cached = 0;
    return 0;
}

int tep_sqlite_last_insert_rowid(int h) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return -1;
    sqlite3 *db = tep_sqlite_handles[h - 1];
    if (db == NULL) return -1;
    return (int)sqlite3_last_insert_rowid(db);
}

/* Reset the current statement so it can be re-stepped (e.g. inside
 * a loop where bound params change between iterations). Returns 0
 * on success. */
int tep_sqlite_reset(void) {
    if (!tep_sqlite_stmt) return -1;
    return sqlite3_reset(tep_sqlite_stmt) == SQLITE_OK ? 0 : -1;
}
