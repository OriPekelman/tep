/* tep_pg.c - thin libpq wrapper for spinel-AOT'd tep apps.
 *
 * Mirrors tep_sqlite.c's pattern: spinel can't load CRuby C
 * extensions (the `pg` gem ships native code against MRI's ABI),
 * so we expose a stable str/int-typed FFI surface that the Ruby
 * side wraps in PG::Connection / PG::Result / PG::Error.
 *
 * Surface scope is documented in docs/PG-BATTERY.md. This file
 * implements Phase 0 + Phase 1: connect / status / exec /
 * exec_params / result reading / escape. Phase 1.5 (prepared
 * statements) and Phase 2 (async) layer on top.
 *
 * Integer-handle slot tables avoid putting PGconn* / PGresult* into
 * spinel's poly value type. Strings come back via a rotating
 * static-buffer pool so callers can hold a few results live without
 * the lifetime-of-PQclear pointer alias biting them.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <libpq-fe.h>

#define TEP_PG_MAX_CONNS         8
#define TEP_PG_MAX_RESULTS       64
#define TEP_PG_MAX_PARAMS        32
#define TEP_PG_PARAM_BUFSIZE     262144   /* 256 KiB; AR migrations push big DDL params */
#define TEP_PG_STR_BUFSIZE       65536
#define TEP_PG_STR_BUF_SLOTS     128

static PGconn   *tep_pg_conns[TEP_PG_MAX_CONNS]      = {0};
static PGresult *tep_pg_results[TEP_PG_MAX_RESULTS]  = {0};
static int       tep_pg_result_conn[TEP_PG_MAX_RESULTS]; /* conn slot owning each result */

/* Per-process "no live conn" error stash. PQconnectdb returns
 * non-NULL even on failure; we keep its error message here long
 * enough for the Ruby side to read it, then PQfinish the conn.
 * Slot 0 is intentionally reserved for "no conn" -- tep_pg_error_message(0)
 * reads this stash, while tep_pg_error_message(h>=1) reads
 * PQerrorMessage on the corresponding live conn. */
#define TEP_PG_LAST_CONNECT_ERR_SIZE 1024
static char tep_pg_last_connect_err[TEP_PG_LAST_CONNECT_ERR_SIZE] = {0};

/* Parameter accumulator for exec_params. */
static const char *tep_pg_param_ptrs[TEP_PG_MAX_PARAMS];
static int         tep_pg_param_is_null[TEP_PG_MAX_PARAMS];
static char        tep_pg_param_buf[TEP_PG_PARAM_BUFSIZE];
static int         tep_pg_param_buf_used = 0;
static int         tep_pg_param_count    = 0;

/* Rotating return-string buffer. */
static char tep_pg_str_buf[TEP_PG_STR_BUF_SLOTS][TEP_PG_STR_BUFSIZE];
static int  tep_pg_str_slot = 0;

static char *tep_pg_next_str_buf(void) {
    char *buf = tep_pg_str_buf[tep_pg_str_slot];
    tep_pg_str_slot = (tep_pg_str_slot + 1) % TEP_PG_STR_BUF_SLOTS;
    return buf;
}

static char *tep_pg_return_str(const char *src) {
    char *buf = tep_pg_next_str_buf();
    if (src == NULL) { buf[0] = '\0'; return buf; }
    size_t n = strlen(src);
    if (n >= TEP_PG_STR_BUFSIZE) n = TEP_PG_STR_BUFSIZE - 1;
    memcpy(buf, src, n);
    buf[n] = '\0';
    return buf;
}

/* Find a free conn slot (1-indexed return). 0 = none free. */
static int tep_pg_alloc_conn_slot(void) {
    for (int i = 0; i < TEP_PG_MAX_CONNS; i++) {
        if (tep_pg_conns[i] == NULL) return i + 1;
    }
    return 0;
}

/* Find a free result slot (1-indexed return). 0 = none free. */
static int tep_pg_alloc_result_slot(void) {
    for (int i = 0; i < TEP_PG_MAX_RESULTS; i++) {
        if (tep_pg_results[i] == NULL) return i + 1;
    }
    return 0;
}

static PGconn *tep_pg_conn_for(int h) {
    if (h < 1 || h > TEP_PG_MAX_CONNS) return NULL;
    return tep_pg_conns[h - 1];
}

static PGresult *tep_pg_result_for(int rh) {
    if (rh < 1 || rh > TEP_PG_MAX_RESULTS) return NULL;
    return tep_pg_results[rh - 1];
}

/* --- Connection lifecycle --- */

int tep_pg_connect(const char *conninfo) {
    int slot = tep_pg_alloc_conn_slot();
    if (slot == 0) {
        snprintf(tep_pg_last_connect_err, TEP_PG_LAST_CONNECT_ERR_SIZE,
                 "tep_pg_connect: no free connection slot (max %d)",
                 TEP_PG_MAX_CONNS);
        return -1;
    }
    PGconn *c = PQconnectdb(conninfo ? conninfo : "");
    if (PQstatus(c) != CONNECTION_OK) {
        const char *m = PQerrorMessage(c);
        size_t n = m ? strlen(m) : 0;
        if (n >= TEP_PG_LAST_CONNECT_ERR_SIZE) n = TEP_PG_LAST_CONNECT_ERR_SIZE - 1;
        if (m) memcpy(tep_pg_last_connect_err, m, n);
        tep_pg_last_connect_err[n] = '\0';
        PQfinish(c);
        return -1;
    }
    /* Force UTF8 once; lets Ruby-side strings round-trip cleanly. */
    PQsetClientEncoding(c, "UTF8");
    tep_pg_conns[slot - 1] = c;
    return slot;
}

/* Hash-form connect. `keys` and `vals` are \0-delimited string
 * buffers of length `count` entries each; we walk them to build
 * the parallel `const char **` arrays PQconnectdbParams expects. */
int tep_pg_connect_kv(const char *keys, const char *vals, int count) {
    if (count < 0 || count > 32) {
        snprintf(tep_pg_last_connect_err, TEP_PG_LAST_CONNECT_ERR_SIZE,
                 "tep_pg_connect_kv: bad count %d (max 32)", count);
        return -1;
    }
    int slot = tep_pg_alloc_conn_slot();
    if (slot == 0) {
        snprintf(tep_pg_last_connect_err, TEP_PG_LAST_CONNECT_ERR_SIZE,
                 "tep_pg_connect_kv: no free connection slot");
        return -1;
    }
    /* Build parallel C arrays. PQconnectdbParams wants
     * keywords[i] and values[i] as NUL-terminated, with a final
     * NULL entry. count+1 to leave the terminator. */
    const char *kw[33];
    const char *vw[33];
    const char *kp = keys;
    const char *vp = vals;
    for (int i = 0; i < count; i++) {
        kw[i] = kp;
        vw[i] = vp;
        kp += strlen(kp) + 1;
        vp += strlen(vp) + 1;
    }
    kw[count] = NULL;
    vw[count] = NULL;
    PGconn *c = PQconnectdbParams(kw, vw, 0);
    if (PQstatus(c) != CONNECTION_OK) {
        const char *m = PQerrorMessage(c);
        size_t n = m ? strlen(m) : 0;
        if (n >= TEP_PG_LAST_CONNECT_ERR_SIZE) n = TEP_PG_LAST_CONNECT_ERR_SIZE - 1;
        if (m) memcpy(tep_pg_last_connect_err, m, n);
        tep_pg_last_connect_err[n] = '\0';
        PQfinish(c);
        return -1;
    }
    PQsetClientEncoding(c, "UTF8");
    tep_pg_conns[slot - 1] = c;
    return slot;
}

int tep_pg_finish(int h) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return -1;
    /* Clear any results belonging to this conn so libpq's "you
     * freed the conn but a result still references its OIDs" UB
     * doesn't surface. */
    for (int i = 0; i < TEP_PG_MAX_RESULTS; i++) {
        if (tep_pg_results[i] != NULL && tep_pg_result_conn[i] == h) {
            PQclear(tep_pg_results[i]);
            tep_pg_results[i] = NULL;
            tep_pg_result_conn[i] = 0;
        }
    }
    PQfinish(c);
    tep_pg_conns[h - 1] = NULL;
    return 0;
}

int tep_pg_reset(int h) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return -1;
    PQreset(c);
    return PQstatus(c) == CONNECTION_OK ? 0 : -1;
}

int tep_pg_status(int h) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return 1;  /* CONNECTION_BAD shape for "no slot" */
    return PQstatus(c) == CONNECTION_OK ? 0 : 1;
}

int tep_pg_transaction_status(int h) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return 4;  /* PQTRANS_UNKNOWN */
    return (int)PQtransactionStatus(c);
}

const char *tep_pg_error_message(int h) {
    if (h == 0) {
        /* "no live conn" stash -- used for connect failures. */
        return tep_pg_return_str(tep_pg_last_connect_err);
    }
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return tep_pg_return_str("");
    return tep_pg_return_str(PQerrorMessage(c));
}

int tep_pg_server_version(int h) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return 0;
    return PQserverVersion(c);
}

int tep_pg_set_client_encoding(int h, const char *enc) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return -1;
    return PQsetClientEncoding(c, enc);
}

/* --- Sync exec --- */

/* Stash the result in a slot, recording its owning conn. Returns
 * 1-indexed result handle, or -1 on slot exhaustion (PQclears the
 * orphan result first). */
static int tep_pg_stash_result(PGresult *r, int conn_handle) {
    if (r == NULL) return -1;
    int rs = tep_pg_alloc_result_slot();
    if (rs == 0) {
        PQclear(r);
        return -1;
    }
    tep_pg_results[rs - 1] = r;
    tep_pg_result_conn[rs - 1] = conn_handle;
    return rs;
}

int tep_pg_exec(int h, const char *sql) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return -1;
    return tep_pg_stash_result(PQexec(c, sql), h);
}

int tep_pg_param_clear(void) {
    tep_pg_param_count = 0;
    tep_pg_param_buf_used = 0;
    for (int i = 0; i < TEP_PG_MAX_PARAMS; i++) {
        tep_pg_param_ptrs[i] = NULL;
        tep_pg_param_is_null[i] = 0;
    }
    return 0;
}

int tep_pg_param_push_str(const char *s) {
    if (tep_pg_param_count >= TEP_PG_MAX_PARAMS) return -1;
    if (s == NULL) s = "";
    size_t n = strlen(s) + 1; /* include NUL terminator */
    if ((size_t)tep_pg_param_buf_used + n > TEP_PG_PARAM_BUFSIZE) return -1;
    char *dst = tep_pg_param_buf + tep_pg_param_buf_used;
    memcpy(dst, s, n);
    tep_pg_param_buf_used += (int)n;
    tep_pg_param_ptrs[tep_pg_param_count] = dst;
    tep_pg_param_is_null[tep_pg_param_count] = 0;
    tep_pg_param_count++;
    return 0;
}

int tep_pg_param_push_null(void) {
    if (tep_pg_param_count >= TEP_PG_MAX_PARAMS) return -1;
    tep_pg_param_ptrs[tep_pg_param_count] = NULL;
    tep_pg_param_is_null[tep_pg_param_count] = 1;
    tep_pg_param_count++;
    return 0;
}

int tep_pg_exec_params(int h, const char *sql) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL) return -1;
    /* PQexecParams: null paramTypes -> let libpq infer from the
     * query's $1::T cast or the destination column's type. null
     * paramLengths -> use strlen on each text-format param. null
     * paramFormats -> all text. resultFormat=0 -> text result. */
    PGresult *r = PQexecParams(
        c, sql,
        tep_pg_param_count,
        NULL,
        tep_pg_param_ptrs,
        NULL,
        NULL,
        0
    );
    return tep_pg_stash_result(r, h);
}

int tep_pg_clear(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return -1;
    PQclear(r);
    tep_pg_results[rh - 1] = NULL;
    tep_pg_result_conn[rh - 1] = 0;
    return 0;
}

/* --- Result inspection --- */

int tep_pg_result_status(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return 3; /* RES_ERROR */
    switch (PQresultStatus(r)) {
        case PGRES_TUPLES_OK:    return 0; /* RES_TUPLES */
        case PGRES_COMMAND_OK:   return 1; /* RES_COMMAND */
        case PGRES_EMPTY_QUERY:  return 2; /* RES_EMPTY */
        default:                 return 3; /* RES_ERROR */
    }
}

const char *tep_pg_result_error_message(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return tep_pg_return_str("");
    return tep_pg_return_str(PQresultErrorMessage(r));
}

const char *tep_pg_result_error_field(int rh, int code) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return tep_pg_return_str("");
    return tep_pg_return_str(PQresultErrorField(r, code));
}

const char *tep_pg_cmd_status(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return tep_pg_return_str("");
    return tep_pg_return_str(PQcmdStatus(r));
}

int tep_pg_cmd_tuples(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return 0;
    const char *s = PQcmdTuples(r);
    if (s == NULL || s[0] == '\0') return 0;
    return atoi(s);
}

int tep_pg_ntuples(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? PQntuples(r) : 0;
}

int tep_pg_nfields(int rh) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? PQnfields(r) : 0;
}

const char *tep_pg_fname(int rh, int col) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return tep_pg_return_str("");
    return tep_pg_return_str(PQfname(r, col));
}

int tep_pg_fnumber(int rh, const char *name) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return -1;
    return PQfnumber(r, name);
}

int tep_pg_ftype(int rh, int col) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? (int)PQftype(r, col) : 0;
}

int tep_pg_fformat(int rh, int col) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? PQfformat(r, col) : 0;
}

int tep_pg_fmod(int rh, int col) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? PQfmod(r, col) : -1;
}

const char *tep_pg_getvalue(int rh, int row, int col) {
    PGresult *r = tep_pg_result_for(rh);
    if (r == NULL) return tep_pg_return_str("");
    return tep_pg_return_str(PQgetvalue(r, row, col));
}

int tep_pg_getisnull(int rh, int row, int col) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? PQgetisnull(r, row, col) : 1;
}

int tep_pg_getlength(int rh, int row, int col) {
    PGresult *r = tep_pg_result_for(rh);
    return r ? PQgetlength(r, row, col) : 0;
}

/* --- Escape --- */

const char *tep_pg_escape_string(int h, const char *s) {
    PGconn *c = tep_pg_conn_for(h);
    char *buf = tep_pg_next_str_buf();
    if (s == NULL) { buf[0] = '\0'; return buf; }
    size_t slen = strlen(s);
    if (slen * 2 + 1 >= TEP_PG_STR_BUFSIZE) slen = (TEP_PG_STR_BUFSIZE - 1) / 2;
    int err = 0;
    if (c != NULL) {
        PQescapeStringConn(c, buf, s, slen, &err);
    } else {
        /* No live conn: fall back to the deprecated standalone form.
         * AR rarely hits this path (it always has a conn), but the
         * class-method PG::Connection.escape_string(s) needs it. */
        PQescapeString(buf, s, slen);
    }
    return err == 0 ? buf : tep_pg_return_str("");
}

const char *tep_pg_escape_literal(int h, const char *s) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL || s == NULL) return tep_pg_return_str("");
    char *q = PQescapeLiteral(c, s, strlen(s));
    if (q == NULL) return tep_pg_return_str("");
    const char *out = tep_pg_return_str(q);
    PQfreemem(q);
    return out;
}

const char *tep_pg_escape_identifier(int h, const char *s) {
    PGconn *c = tep_pg_conn_for(h);
    if (c == NULL || s == NULL) return tep_pg_return_str("");
    char *q = PQescapeIdentifier(c, s, strlen(s));
    if (q == NULL) return tep_pg_return_str("");
    const char *out = tep_pg_return_str(q);
    PQfreemem(q);
    return out;
}

/* --- Version --- */

const char *tep_pg_libpq_version(void) {
    int v = PQlibVersion();
    /* PQlibVersion returns NNxxYYzz where NN=major, xx=minor, YY=patch
     * for pre-10; for 10+ it's MMMMxxYY (major thousands). Render
     * generically as "major.minor.patch" (PG-10+: minor/patch from
     * the lower digits). */
    int major, minor, patch;
    if (v >= 100000) {
        major = v / 10000;
        minor = (v / 100) % 100;
        patch = v % 100;
    } else {
        major = v / 10000;
        minor = (v / 100) % 100;
        patch = v % 100;
    }
    char *buf = tep_pg_next_str_buf();
    snprintf(buf, TEP_PG_STR_BUFSIZE, "%d.%d.%d", major, minor, patch);
    return buf;
}
