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
 *   - `prepare(h, sql)` / `bind_{str,int}(h, idx, v)` / `step(h)` /
 *     `col_{str,int}(h, idx)` / `col_count(h)` / `finalize(h)`
 *                                                    -- one cursor
 *     and one prepared-statement cache per handle. Handles are
 *     independent, so threads that each open their own handle can
 *     query at once; a single handle must not be shared by threads.
 *   - `last_insert_rowid(h)`                         -- for INSERT
 *     ... RETURNING-less workflows.
 *
 * Out of scope (v1)
 * -----------------
 *   - Multi-cursor on one handle: nested queries (open one cursor,
 *     iterate, run another query inside) need a second handle.
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
#include <pthread.h>
#include <sqlite3.h>

#define TEP_SQLITE_MAX_HANDLES    16
#define TEP_SQLITE_CACHE_SLOTS    64       /* prepare-statement cache, per handle */
#define TEP_SQLITE_CACHE_SQL_MAX  512      /* longest cached SQL */

typedef struct {
    sqlite3_stmt *stmt;
    char          sql[TEP_SQLITE_CACHE_SQL_MAX];
} tep_sqlite_cache_entry;

/* When the current cursor came from the cache, finalize must only
 * reset it: the slot keeps it alive for reuse. */
typedef struct {
    sqlite3                *db;
    sqlite3_stmt           *stmt;
    int                     stmt_cached;
    tep_sqlite_cache_entry *cache;   /* TEP_SQLITE_CACHE_SLOTS entries */
} tep_sqlite_handle;

static tep_sqlite_handle tep_sqlite_handles[TEP_SQLITE_MAX_HANDLES];
/* Guards slot allocation in open/close; everything else touches only
 * the caller's own handle. */
static pthread_mutex_t   tep_sqlite_lock = PTHREAD_MUTEX_INITIALIZER;

static tep_sqlite_handle *tep_sqlite_get(int h) {
    if (h < 1 || h > TEP_SQLITE_MAX_HANDLES) return NULL;
    tep_sqlite_handle *hd = &tep_sqlite_handles[h - 1];
    return hd->db ? hd : NULL;
}

int tep_sqlite_open(const char *path) {
    tep_sqlite_cache_entry *cache = calloc(TEP_SQLITE_CACHE_SLOTS, sizeof(tep_sqlite_cache_entry));
    if (!cache) return -1;
    sqlite3 *db = NULL;
    if (sqlite3_open(path, &db) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        free(cache);
        return -1;
    }
    pthread_mutex_lock(&tep_sqlite_lock);
    int i;
    for (i = 0; i < TEP_SQLITE_MAX_HANDLES; i++) {
        if (tep_sqlite_handles[i].db == NULL) {
            tep_sqlite_handles[i].db = db;
            tep_sqlite_handles[i].stmt = NULL;
            tep_sqlite_handles[i].stmt_cached = 0;
            tep_sqlite_handles[i].cache = cache;
            pthread_mutex_unlock(&tep_sqlite_lock);
            return i + 1; /* 1-indexed: 0 reserved for "uninitialised" */
        }
    }
    pthread_mutex_unlock(&tep_sqlite_lock);
    sqlite3_close(db);
    free(cache);
    return -1;
}

int tep_sqlite_close(int h) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd) return -1;
    /* Finalize the cursor and every cached statement first, or
     * sqlite3_close returns SQLITE_BUSY. */
    if (hd->stmt && !hd->stmt_cached) sqlite3_finalize(hd->stmt);
    int i;
    for (i = 0; i < TEP_SQLITE_CACHE_SLOTS; i++) {
        if (hd->cache[i].stmt) sqlite3_finalize(hd->cache[i].stmt);
    }
    sqlite3_close(hd->db);
    free(hd->cache);
    pthread_mutex_lock(&tep_sqlite_lock);
    hd->stmt = NULL;
    hd->stmt_cached = 0;
    hd->cache = NULL;
    hd->db = NULL;
    pthread_mutex_unlock(&tep_sqlite_lock);
    return 0;
}

int tep_sqlite_exec(int h, const char *sql) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd) return -1;
    char *err = NULL;
    int rc = sqlite3_exec(hd->db, sql, NULL, NULL, &err);
    if (err) sqlite3_free(err);
    return rc == SQLITE_OK ? 0 : -1;
}

/* Cached stmts get reset + clear_bindings so the slot stays valid;
 * uncached ones are finalized. */
static void tep_sqlite_release_current(tep_sqlite_handle *hd) {
    if (!hd->stmt) return;
    if (hd->stmt_cached) {
        sqlite3_reset(hd->stmt);
        sqlite3_clear_bindings(hd->stmt);
    } else {
        sqlite3_finalize(hd->stmt);
    }
    hd->stmt = NULL;
    hd->stmt_cached = 0;
}

int tep_sqlite_prepare(int h, const char *sql) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd) return -1;
    tep_sqlite_release_current(hd);
    if (sqlite3_prepare_v2(hd->db, sql, -1, &hd->stmt, NULL) != SQLITE_OK) {
        hd->stmt = NULL;
        return -1;
    }
    return 0;
}

/* Cached variant: reuses the statement prepared earlier for the same
 * SQL on this handle; when the cache is full it prepares uncached.
 * SQL is matched literally, so format it consistently. */
int tep_sqlite_prepare_cached(int h, const char *sql) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd) return -1;
    size_t sql_len = strlen(sql);
    if (sql_len >= TEP_SQLITE_CACHE_SQL_MAX) return tep_sqlite_prepare(h, sql);
    tep_sqlite_release_current(hd);
    int i, empty = -1;
    for (i = 0; i < TEP_SQLITE_CACHE_SLOTS; i++) {
        tep_sqlite_cache_entry *e = &hd->cache[i];
        if (!e->stmt) {
            if (empty < 0) empty = i;
            continue;
        }
        if (strcmp(e->sql, sql) == 0) {
            hd->stmt = e->stmt;
            hd->stmt_cached = 1;
            return 0;
        }
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(hd->db, sql, -1, &stmt, NULL) != SQLITE_OK) return -1;
    hd->stmt = stmt;
    if (empty < 0) {
        hd->stmt_cached = 0;
        return 0;
    }
    hd->cache[empty].stmt = stmt;
    memcpy(hd->cache[empty].sql, sql, sql_len + 1);
    hd->stmt_cached = 1;
    return 0;
}

int tep_sqlite_bind_str(int h, int idx, const char *value) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return -1;
    return sqlite3_bind_text(hd->stmt, idx, value, -1, SQLITE_TRANSIENT) == SQLITE_OK ? 0 : -1;
}

/* 64-bit (`:long`), so a value > 2^31 isn't truncated (issue #171). */
int tep_sqlite_bind_int(int h, int idx, long value) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return -1;
    return sqlite3_bind_int64(hd->stmt, idx, (sqlite3_int64)value) == SQLITE_OK ? 0 : -1;
}

/* 1 -> row available, 0 -> done (no more rows), -1 -> error */
int tep_sqlite_step(int h) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return -1;
    int rc = sqlite3_step(hd->stmt);
    if (rc == SQLITE_ROW) return 1;
    if (rc == SQLITE_DONE) return 0;
    return -1;
}

/* Returned as is: Spinel copies a `:str` result into a new String on
 * return, so the pointer only has to live until then, and values of
 * any length come back whole. */
const char *tep_sqlite_col_str(int h, int idx) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return "";
    const unsigned char *t = sqlite3_column_text(hd->stmt, idx);
    return t ? (const char *)t : "";
}

/* 64-bit read: sqlite3_column_int wrapped values > 2^31 negative (#171). */
long tep_sqlite_col_int(int h, int idx) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return 0;
    return (long)sqlite3_column_int64(hd->stmt, idx);
}

int tep_sqlite_col_count(int h) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return 0;
    return sqlite3_column_count(hd->stmt);
}

int tep_sqlite_finalize(int h) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd) return 0;
    tep_sqlite_release_current(hd);
    return 0;
}

int tep_sqlite_last_insert_rowid(int h) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd) return -1;
    return (int)sqlite3_last_insert_rowid(hd->db);
}

/* Reset the current statement so it can be re-stepped with new binds. */
int tep_sqlite_reset(int h) {
    tep_sqlite_handle *hd = tep_sqlite_get(h);
    if (!hd || !hd->stmt) return -1;
    return sqlite3_reset(hd->stmt) == SQLITE_OK ? 0 : -1;
}
