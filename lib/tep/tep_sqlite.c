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

#define TEP_SQLITE_MAX_HANDLES   16
#define TEP_SQLITE_COL_BUFSIZE   65536
#define TEP_SQLITE_COL_BUF_SLOTS 16

static sqlite3      *tep_sqlite_handles[TEP_SQLITE_MAX_HANDLES] = {0};
static sqlite3_stmt *tep_sqlite_stmt = NULL;
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
        sqlite3_finalize(tep_sqlite_stmt);
        tep_sqlite_stmt = NULL;
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

int tep_sqlite_prepare(int h, const char *sql) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return -1;
    sqlite3 *db = tep_sqlite_handles[h - 1];
    if (db == NULL) return -1;
    if (tep_sqlite_stmt) {
        sqlite3_finalize(tep_sqlite_stmt);
        tep_sqlite_stmt = NULL;
    }
    if (sqlite3_prepare_v2(db, sql, -1, &tep_sqlite_stmt, NULL) != SQLITE_OK) {
        tep_sqlite_stmt = NULL;
        return -1;
    }
    return 0;
}

int tep_sqlite_bind_str(int idx, const char *value) {
    if (!tep_sqlite_stmt) return -1;
    /* SQLITE_TRANSIENT -> sqlite copies the string before returning,
     * so the caller's pointer doesn't need to outlive the bind. */
    return sqlite3_bind_text(tep_sqlite_stmt, idx, value, -1, SQLITE_TRANSIENT)
                == SQLITE_OK ? 0 : -1;
}

int tep_sqlite_bind_int(int idx, int value) {
    if (!tep_sqlite_stmt) return -1;
    return sqlite3_bind_int(tep_sqlite_stmt, idx, value) == SQLITE_OK ? 0 : -1;
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

int tep_sqlite_col_int(int idx) {
    if (!tep_sqlite_stmt) return 0;
    return sqlite3_column_int(tep_sqlite_stmt, idx);
}

int tep_sqlite_col_count(void) {
    if (!tep_sqlite_stmt) return 0;
    return sqlite3_column_count(tep_sqlite_stmt);
}

int tep_sqlite_finalize(void) {
    if (!tep_sqlite_stmt) return 0;
    sqlite3_finalize(tep_sqlite_stmt);
    tep_sqlite_stmt = NULL;
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
