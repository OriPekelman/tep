/* _GNU_SOURCE: expose strptime(3) + timegm(3) (used by the HTTP-date
 * helpers below). Must precede any system header include. */
#define _GNU_SOURCE 1

/* sphttp.c - POSIX HTTP plumbing for Tep, called from Spinel via FFI.
 *
 * Scope: socket server + client + poll + fork + shell/file helpers.
 * Crypto (SHA-256/HMAC/PBKDF2/B64URL/random) lives in tep_crypto.c.
 *
 * The MVP stays single-threaded blocking; perf primitives (SO_REUSEPORT
 * for prefork, keep-alive friendly recv, and a "accept after fork" path)
 * are exposed so the Ruby side can do the rest. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <signal.h>
#include <time.h>

#define SPHTTP_BUFSIZE   65536
#define SPHTTP_RESP_MAX  (4 * 1024 * 1024)

/* ---------- TLS (libssl) binding -- outbound client; see tep#148 ----------
 *
 * The socket layer stays fd-based: sphttp_connect_tls returns a normal
 * socket fd and registers an SSL* for it in sphttp_ssl_tab, keyed by fd.
 * The read/write/close helpers consult the table and route through
 * SSL_read/SSL_write/SSL_shutdown when an SSL* is present, else plain
 * send/recv/close. So the FFI surface gains exactly one function
 * (sphttp_connect_tls) and everything downstream is TLS-transparent.
 * Sockets created via sphttp_connect_tls are BLOCKING, so SSL_read/
 * SSL_write either complete or hard-error (no WANT_READ/WANT_WRITE
 * churn). Inbound/server TLS (SSL_accept) is a later phase reusing
 * this same table + a server-side SSL_CTX. */
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#define SPHTTP_FD_MAX 4096
static SSL     *sphttp_ssl_tab[SPHTTP_FD_MAX];   /* fd -> SSL*, NULL = plaintext */
static SSL_CTX *sphttp_ssl_ctx = NULL;

static SSL *sphttp_ssl_for(int fd) {
    if (fd < 0 || fd >= SPHTTP_FD_MAX) return NULL;
    return sphttp_ssl_tab[fd];
}

/* Lazily build the shared client SSL_CTX: TLS 1.2+, peer verification
 * on, system CA bundle. NULL on failure (callers fall back to -1). */
static SSL_CTX *sphttp_ssl_ctx_get(void) {
    if (sphttp_ssl_ctx) return sphttp_ssl_ctx;
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return NULL;
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_default_verify_paths(ctx);
    sphttp_ssl_ctx = ctx;
    return ctx;
}

static char sphttp_req_buf[SPHTTP_BUFSIZE];
static int  sphttp_req_len = 0;

/* The POSIX TCP / poll / prefork / shell / signal primitives below now
 * live in spinel's sp_net (libspinel_rt.a, matz/spinel#1055). tep keeps
 * the sphttp_* names as thin delegating wrappers so lib/tep/net.rb and
 * every Sock.sphttp_* call site stay unchanged (tep#12). sp_net symbols
 * are auto-linked from libspinel_rt.a; we declare the surface we use
 * here rather than coupling to a shared header (same spirit as
 * sp_crypto, declared via ffi_func). HTTP framing, WebSocket accessors,
 * TLS, and the SSL-aware I/O all stay tep-side below. */
extern int sp_net_install_term_handlers(void);
extern int sp_net_shutdown_requested(void);
extern int sp_net_listen(int port, int reuseport);
extern int sp_net_accept(int sfd);
extern int sp_net_accept_nb(int sfd);
extern int sp_net_connect(const char *host, int port);
extern int sp_net_set_nonblock(int fd);
extern int sp_net_poll_reset(void);
extern int sp_net_poll_add(int fd, int mode_bits);
extern int sp_net_poll_run(int timeout_ms);
extern int sp_net_poll_ready(int slot);
extern int sp_net_fork(void);
extern int sp_net_exit(int status);
extern int sp_net_getpid(void);
extern int sp_net_wait_any(void);
extern const char *sp_net_shell_capture(const char *cmd, int max_bytes);

int sphttp_install_term_handlers(void) { return sp_net_install_term_handlers(); }
int sphttp_shutdown_requested(void)    { return sp_net_shutdown_requested(); }

/* Sub-second sleep, granular to a millisecond. spinel's Time / sleep
 * surface deals in integer epoch-seconds only; this helper exposes
 * usleep for callers that need finer-grained pacing (e.g. Tep::Proxy's
 * retry backoff loop). Returns 0 on success, -1 on EINTR (the caller
 * decides whether to retry). ms <= 0 returns immediately. */
int sphttp_sleep_ms(int ms) {
    if (ms <= 0) return 0;
    /* usleep accepts useconds_t but is deprecated on some BSDs; the
     * portable shape is nanosleep, which we use here. */
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    if (nanosleep(&ts, NULL) < 0) {
        return -1;
    }
    return 0;
}

/* Bind & listen on 0.0.0.0:port. If `reuseport` != 0 we set
 * SO_REUSEPORT so multiple worker processes can listen on the same
 * port and the kernel will load-balance accept() across them. */
/* All three delegate to sp_net (#12). sp_net_accept carries the same
 * term-flag-aware pre-check + EINTR handling as the old body; the
 * shutdown flag is now sp_net's (set via sp_net_install_term_handlers,
 * which sphttp_install_term_handlers delegates to). */
int sphttp_listen(int port, int reuseport) { return sp_net_listen(port, reuseport); }
int sphttp_accept(int sfd)                 { return sp_net_accept(sfd); }
int sphttp_accept_nb(int sfd)              { return sp_net_accept_nb(sfd); }

/* Read until end-of-headers ("\r\n\r\n") or the buffer fills. Subsequent
 * recv()s for the body are the caller's job (we expose a length helper).
 * Returns the parsed length (>0), 0 on clean EOF, -1 on error. */
int sphttp_read_request(int fd) {
    SSL *ssl = sphttp_ssl_for(fd);   /* inbound TLS: decrypt via SSL_read */
    sphttp_req_len = 0;
    sphttp_req_buf[0] = '\0';
    while (sphttp_req_len < SPHTTP_BUFSIZE - 1) {
        int want = SPHTTP_BUFSIZE - 1 - sphttp_req_len;
        ssize_t n = ssl
            ? (ssize_t)SSL_read(ssl, sphttp_req_buf + sphttp_req_len, want)
            : recv(fd, sphttp_req_buf + sphttp_req_len, (size_t)want, 0);
        if (n == 0) {
            if (sphttp_req_len == 0) return 0;
            break;
        }
        if (n < 0) {
            if (!ssl && errno == EINTR) continue;
            return -1;
        }
        sphttp_req_len += (int)n;
        sphttp_req_buf[sphttp_req_len] = '\0';
        if (strstr(sphttp_req_buf, "\r\n\r\n") != NULL) break;
    }
    return sphttp_req_len;
}

const char *sphttp_request_buf(void) {
    return sphttp_req_buf;
}

int sphttp_request_len(void) {
    return sphttp_req_len;
}

/* Drain the body bytes we still owe past the buffered chunk. Tep
 * computes remaining = content_length - already_in_buf; this gulps
 * those into a Ruby-visible string buffer. We round-trip via a
 * static buffer to avoid hand-rolling write_str FFI. */
static char sphttp_body_buf[SPHTTP_BUFSIZE];

const char *sphttp_drain_body(int fd, int total_len) {
    SSL *ssl = sphttp_ssl_for(fd);
    int n = total_len;
    if (n < 0) n = 0;
    if (n >= SPHTTP_BUFSIZE) n = SPHTTP_BUFSIZE - 1;
    int got = 0;
    while (got < n) {
        ssize_t r = ssl ? (ssize_t)SSL_read(ssl, sphttp_body_buf + got, n - got)
                        : recv(fd, sphttp_body_buf + got, n - got, 0);
        if (r <= 0) {
            if (!ssl && errno == EINTR) continue;
            break;
        }
        got += (int)r;
    }
    sphttp_body_buf[got] = '\0';
    return sphttp_body_buf;
}

int sphttp_write_str(int fd, const char *s) {
    SSL *ssl = sphttp_ssl_for(fd);
    size_t len = strlen(s);
    size_t off = 0;
    while (off < len) {
        if (ssl) {
            int w = SSL_write(ssl, s + off, (int)(len - off));
            if (w <= 0) return -1;
            off += (size_t)w;
        } else {
            ssize_t n = send(fd, s + off, len - off, 0);
            if (n <= 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            off += (size_t)n;
        }
    }
    return 0;
}

/* Binary write -- explicit length, no strlen. Required for any
 * caller that needs to send bytes that may contain 0x00 (WebSocket
 * frames, raw protocol bodies). Returns 0 on success, -1 on send
 * failure. */
int sphttp_write_bytes(int fd, const char *data, int n) {
    SSL *ssl = sphttp_ssl_for(fd);
    size_t total = (n < 0) ? 0 : (size_t)n;
    size_t off = 0;
    while (off < total) {
        if (ssl) {
            int w = SSL_write(ssl, data + off, (int)(total - off));
            if (w <= 0) return -1;
            off += (size_t)w;
        } else {
            ssize_t w = send(fd, data + off, total - off, 0);
            if (w <= 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            off += (size_t)w;
        }
    }
    return 0;
}

/* Binary recv accessor pair, mechanically identical to
 * sphttp_request_buf / _len above but on a separate static buffer
 * so callers that interleave HTTP request reads with arbitrary
 * frame reads don't trample each other. Use case: WebSocket frame
 * codec drives a `recv_into_frame -> _buf + _len` loop.
 *
 * The frame buffer is NOT NUL-terminated and may contain arbitrary
 * bytes including 0x00. Always read exactly `sphttp_recv_frame_len()`
 * bytes from the buffer; don't rely on strlen-style scanning. */
static char sphttp_frame_buf[SPHTTP_BUFSIZE];
static int  sphttp_frame_len = 0;

/* Single non-blocking recv into the frame buffer. Returns the
 * number of bytes received (also reflected in sphttp_recv_frame_len),
 * 0 on EOF, -1 on error. Calling this overwrites the prior buffer
 * contents. For EAGAIN-style "would block" the caller is expected
 * to have parked on a poll/io_wait beforehand -- this fn does NOT
 * retry. */
int sphttp_recv_into_frame(int fd) {
    SSL *ssl = sphttp_ssl_for(fd);
    sphttp_frame_len = 0;
    ssize_t n = ssl ? (ssize_t)SSL_read(ssl, sphttp_frame_buf, SPHTTP_BUFSIZE)
                    : recv(fd, sphttp_frame_buf, SPHTTP_BUFSIZE, 0);
    if (n < 0) {
        if (!ssl && errno == EINTR) {
            /* one retry on EINTR for ergonomics; further EINTRs surface */
            n = recv(fd, sphttp_frame_buf, SPHTTP_BUFSIZE, 0);
            if (n < 0) return -1;
        } else {
            return -1;
        }
    }
    sphttp_frame_len = (int)n;
    return (int)n;
}

const char *sphttp_recv_frame_buf(void) {
    return sphttp_frame_buf;
}

int sphttp_recv_frame_len(void) {
    return sphttp_frame_len;
}

/* Send a file's contents straight from disk -- used for static
 * file serving. Returns -1 on open/read failure (caller falls back
 * to 404), 0 on success. */
int sphttp_sendfile(int fd, const char *path) {
    int src = open(path, O_RDONLY);
    if (src < 0) return -1;
    char buf[16384];
    for (;;) {
        ssize_t r = read(src, buf, sizeof(buf));
        if (r <= 0) break;
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = send(fd, buf + off, r - off, 0);
            if (w <= 0) {
                if (errno == EINTR) continue;
                close(src);
                return -1;
            }
            off += w;
        }
    }
    close(src);
    return 0;
}

/* Returns the file size at `path`, or -1 if missing / not a regular file.
 * Used by static serving to compute Content-Length. */
int sphttp_filesize(const char *path) {
    struct stat st;
    if (stat(path, &st) < 0) return -1;
    if ((st.st_mode & S_IFMT) != S_IFREG) return -1;
    if (st.st_size > 0x7fffffff) return -1;
    return (int)st.st_size;
}

/* mtime (Unix epoch seconds) of a regular file, or -1 if it doesn't
 * stat / isn't a regular file. Used for send_file's Last-Modified +
 * the size-mtime ETag (cache revalidation, #152). */
int sphttp_file_mtime(const char *path) {
    struct stat st;
    if (stat(path, &st) < 0) return -1;
    if ((st.st_mode & S_IFMT) != S_IFREG) return -1;
    return (int)st.st_mtime;
}

int sphttp_close(int fd) {
    SSL *ssl = sphttp_ssl_for(fd);
    if (ssl) {
        SSL_shutdown(ssl);
        SSL_free(ssl);
        sphttp_ssl_tab[fd] = NULL;   /* fd < SPHTTP_FD_MAX guaranteed by sphttp_ssl_for */
    }
    return close(fd);
}

/* Chunked Transfer-Encoding frame: write `<hex-size>\r\n<bytes>\r\n`.
 * Returns 0 on success, -1 on partial write / EOF. */
int sphttp_write_chunk(int fd, const char *s) {
    size_t len = strlen(s);
    if (len == 0) return 0;
    char hdr[32];
    int n = snprintf(hdr, sizeof(hdr), "%zx\r\n", len);
    if (n <= 0) return -1;
    if (sphttp_write_str(fd, hdr) < 0) return -1;
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, s + off, len - off, 0);
        if (w <= 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)w;
    }
    return sphttp_write_str(fd, "\r\n");
}

/* End-of-chunked-stream marker. */
int sphttp_write_chunk_end(int fd) {
    return sphttp_write_str(fd, "0\r\n\r\n");
}

/* SHA-256 / HMAC / PBKDF2 / Base64URL / CSPRNG live in tep_crypto.c */

/* Pre-fork support. Returns child pid in parent, 0 in child, -1 on fail. */
/* Prefork primitives -- delegate to sp_net (#12). */
int sphttp_fork(void)       { return sp_net_fork(); }
int sphttp_exit(int status) { return sp_net_exit(status); }   /* never returns */
int sphttp_getpid(void)     { return sp_net_getpid(); }
int sphttp_wait_any(void)   { return sp_net_wait_any(); }

/* ---------- Non-blocking I/O + poll(2) plumbing ----------
 *
 * The scheduler parks a fiber on (fd, mode) via Sock.sphttp_poll_add;
 * tick() then calls sphttp_poll_run with a timeout and walks the
 * slots to see who got ready. Mode bits:  1=READ, 2=WRITE.
 *
 * Storage is process-static. The Ruby side owns the "reset between
 * tick rounds" discipline -- safe because the scheduler is single-
 * threaded inside one worker. */

/* poll(2) + set_nonblock delegate to sp_net (#12). The poll set is
 * now sp_net's process-static storage; all four functions route to it,
 * so the "reset between tick rounds" discipline still holds. */
int sphttp_poll_reset(void)                { return sp_net_poll_reset(); }
int sphttp_poll_add(int fd, int mode_bits) { return sp_net_poll_add(fd, mode_bits); }
int sphttp_poll_run(int timeout_ms)        { return sp_net_poll_run(timeout_ms); }
int sphttp_poll_ready(int slot)            { return sp_net_poll_ready(slot); }
int sphttp_set_nonblock(int fd)            { return sp_net_set_nonblock(fd); }

/* Bound a blocking recv with SO_RCVTIMEO (milliseconds; <=0 clears the
 * timeout). Used by the pooled outbound client (6.7b): a keep-alive
 * response with no Content-Length and no Connection: close (e.g. a
 * chunked upstream) would otherwise read-until-an-EOF-that-never-comes
 * and hang the worker. With a timeout the recv returns -1/EAGAIN and
 * the caller bails with what it has. Returns 0 on success, -1 on
 * setsockopt failure. */
int sphttp_set_recv_timeout(int fd, int ms) {
    struct timeval tv;
    if (ms <= 0) {
        tv.tv_sec = 0;
        tv.tv_usec = 0;
    } else {
        tv.tv_sec  = ms / 1000;
        tv.tv_usec = (long)(ms % 1000) * 1000L;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) return -1;
    return 0;
}

/* Outbound TCP connect. Resolves `host` via getaddrinfo (so both
 * IP literals and DNS names work). Returns the connected fd or -1.
 * Blocking connect for now -- a future variant can do non-blocking
 * connect + poll(POLLOUT) for fully-async outbound. */
/* Plaintext outbound connect -- delegate to sp_net (#12). sphttp_connect_tls
 * builds on this for the TLS path. */
int sphttp_connect(const char *host, int port) { return sp_net_connect(host, port); }

/* Outbound TLS connect: TCP connect to host:port, then a TLS 1.2+
 * handshake with SNI + peer-cert verification + hostname check.
 * Registers the SSL* against the returned fd so subsequent
 * write/recv/close route through it transparently. Returns the fd on
 * success, -1 on connect/handshake/verification failure. */
int sphttp_connect_tls(const char *host, int port) {
    int fd = sphttp_connect(host, port);
    if (fd < 0) return -1;
    if (fd >= SPHTTP_FD_MAX) { close(fd); return -1; }

    SSL_CTX *ctx = sphttp_ssl_ctx_get();
    if (!ctx) { close(fd); return -1; }
    SSL *ssl = SSL_new(ctx);
    if (!ssl) { close(fd); return -1; }

    SSL_set_fd(ssl, fd);
    /* SNI -- required by virtually every multi-tenant TLS endpoint. */
    SSL_set_tlsext_host_name(ssl, host);
    /* Verify the presented cert actually matches `host`. */
    SSL_set_hostflags(ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (SSL_set1_host(ssl, host) != 1) { SSL_free(ssl); close(fd); return -1; }

    if (SSL_connect(ssl) != 1) {
        /* Handshake or verification failed (incl. bad/expired cert,
         * hostname mismatch, untrusted CA). */
        SSL_free(ssl);
        close(fd);
        return -1;
    }
    sphttp_ssl_tab[fd] = ssl;
    return fd;
}

/* ---- inbound (server) TLS -- tep#148 phase 2 ----
 *
 * A separate server-side SSL_CTX (cert + key). sphttp_tls_server_init
 * loads them once (before the prefork, so workers inherit the CTX);
 * sphttp_accept_tls wraps an already-accepted plain-TCP fd in a TLS
 * handshake and registers the SSL* so read/write/close are transparent
 * (same fd->SSL* table as the client path). Blocking fd, so SSL_accept
 * completes or hard-errors. */
static SSL_CTX *sphttp_ssl_server_ctx = NULL;

/* Load cert chain + private key into the server CTX. Returns 0 on
 * success, -1 on any failure (missing/unreadable files, key mismatch). */
int sphttp_tls_server_init(const char *cert_path, const char *key_path) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) return -1;
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    if (SSL_CTX_use_certificate_chain_file(ctx, cert_path) != 1) { SSL_CTX_free(ctx); return -1; }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) { SSL_CTX_free(ctx); return -1; }
    if (SSL_CTX_check_private_key(ctx) != 1) { SSL_CTX_free(ctx); return -1; }
    sphttp_ssl_server_ctx = ctx;
    return 0;
}

/* Server-side TLS handshake over an accepted fd. Returns 0 on success
 * (SSL* registered for fd), -1 on failure -- the caller closes the fd. */
int sphttp_accept_tls(int fd) {
    if (!sphttp_ssl_server_ctx) return -1;
    if (fd < 0 || fd >= SPHTTP_FD_MAX) return -1;
    SSL *ssl = SSL_new(sphttp_ssl_server_ctx);
    if (!ssl) return -1;
    SSL_set_fd(ssl, fd);
    if (SSL_accept(ssl) != 1) {
        SSL_free(ssl);
        return -1;
    }
    sphttp_ssl_tab[fd] = ssl;
    return 0;
}

/* Best-effort recv() that returns the bytes as a static buffer.
 * Pairs with sphttp_set_nonblock + sphttp_poll_run for the scheduler
 * loop. Returns "" on EAGAIN/empty so callers can branch on
 * .length == 0; "<EOF>" sentinel is the empty-string + closed fd
 * pattern (use sphttp_close + state machine on the caller side). */
static char sphttp_recv_buf[SPHTTP_BUFSIZE];
const char *sphttp_recv_some(int fd, int maxlen) {
    if (maxlen <= 0 || maxlen >= SPHTTP_BUFSIZE) maxlen = SPHTTP_BUFSIZE - 1;
    SSL *ssl = sphttp_ssl_for(fd);
    ssize_t n = ssl ? (ssize_t)SSL_read(ssl, sphttp_recv_buf, maxlen)
                    : recv(fd, sphttp_recv_buf, (size_t)maxlen, 0);
    if (n <= 0) {
        sphttp_recv_buf[0] = '\0';
        return sphttp_recv_buf;
    }
    sphttp_recv_buf[n] = '\0';
    return sphttp_recv_buf;
}

/* Read from `fd` until EOF (peer close) or `max_bytes`, whichever
 * comes first. Used by Tep::Http for the HTTP/1.0 + Connection:
 * close response shape. Returns the bytes in a static buffer
 * (length encoded as the C strlen, which is fine because HTTP
 * responses don't carry NUL bytes in their headers/body for the
 * formats this client targets). */
static char sphttp_recv_all_buf[SPHTTP_BUFSIZE];
const char *sphttp_recv_all(int fd, int max_bytes) {
    if (max_bytes <= 0 || max_bytes >= SPHTTP_BUFSIZE) max_bytes = SPHTTP_BUFSIZE - 1;
    SSL *ssl = sphttp_ssl_for(fd);
    int total = 0;
    while (total < max_bytes) {
        ssize_t n = ssl
            ? (ssize_t)SSL_read(ssl, sphttp_recv_all_buf + total, max_bytes - total)
            : recv(fd, sphttp_recv_all_buf + total, (size_t)(max_bytes - total), 0);
        if (n <= 0) break;
        total += (int)n;
    }
    sphttp_recv_all_buf[total] = '\0';
    return sphttp_recv_all_buf;
}

/* popen-based shell-out. Captures stdout (up to SPHTTP_BUFSIZE-1)
 * into a static buffer and returns it. Stderr is left to the
 * inherited fd. WARNING: cmd is passed verbatim to /bin/sh -c, so
 * NEVER interpolate untrusted input.  The Ruby side (Tep::Shell)
 * enforces this discipline at the API level. */
/* Shell capture -- delegate to sp_net (#12). */
const char *sphttp_shell_capture(const char *cmd, int max_bytes) {
    return sp_net_shell_capture(cmd, max_bytes);
}

/* ISO-8601 UTC timestamp ("2026-05-27T13:40:01Z") for the given
 * Unix epoch seconds. Used by Tep::Events for the run_start /
 * run_end wall-clock fields -- spinel's Time.now only exposes
 * integer epoch seconds, and hand-rolling the calendar math (leap
 * years, etc.) in Ruby isn't worth it. gmtime_r + strftime do it
 * in one line. Returns a pointer to a static buffer (single-
 * threaded server model; copy on the Ruby side if retained). */
static char sphttp_iso8601_buf[32];
const char *sphttp_iso8601_utc(int epoch_secs) {
    time_t t = (time_t)epoch_secs;
    struct tm tmv;
    gmtime_r(&t, &tmv);
    strftime(sphttp_iso8601_buf, sizeof(sphttp_iso8601_buf),
             "%Y-%m-%dT%H:%M:%SZ", &tmv);
    return sphttp_iso8601_buf;
}

/* RFC 1123 GMT date ("Sun, 06 Nov 1994 08:49:37 GMT") for the given
 * Unix epoch seconds -- the format HTTP Date / Last-Modified / Expires
 * use. Static buffer; copy on the Ruby side if retained. The "C"
 * locale day/month abbreviations are what HTTP requires (strftime here
 * runs under the process default locale, which spinel programs don't
 * change). */
static char sphttp_http_date_buf[40];
const char *sphttp_http_date(int epoch_secs) {
    time_t t = (time_t)epoch_secs;
    struct tm tmv;
    gmtime_r(&t, &tmv);
    strftime(sphttp_http_date_buf, sizeof(sphttp_http_date_buf),
             "%a, %d %b %Y %H:%M:%S GMT", &tmv);
    return sphttp_http_date_buf;
}

/* Parse an RFC 1123 HTTP date back to epoch seconds, or -1 if it
 * doesn't parse. Only the modern fixed-length form is handled (what
 * browsers send in If-Modified-Since); the legacy RFC 850 / asctime
 * forms are intentionally not supported. timegm interprets the parsed
 * struct tm as UTC (HTTP dates are always GMT). */
int sphttp_parse_http_date(const char *s) {
    struct tm tmv;
    memset(&tmv, 0, sizeof(tmv));
    if (strptime(s, "%a, %d %b %Y %H:%M:%S GMT", &tmv) == NULL) return -1;
    time_t t = timegm(&tmv);
    if (t == (time_t)-1) return -1;
    return (int)t;
}

/* uname-based host introspection for toy/v1's host:{name,os,arch}
 * envelope (Tep::Events.run_start). One static buffer per field;
 * we lowercase the os field to match the schema's "linux"/"darwin"
 * convention (uname returns "Linux"/"Darwin" with leading caps).
 * arch is returned as-is ("aarch64", "x86_64", ...). On uname()
 * failure we return "unknown" so the field is always populated. */
#include <sys/utsname.h>
#include <ctype.h>
static char sphttp_os_buf[32];
static char sphttp_arch_buf[32];
const char *sphttp_os_kind(void) {
    struct utsname u;
    if (uname(&u) != 0) {
        return "unknown";
    }
    size_t i;
    for (i = 0; i < sizeof(sphttp_os_buf) - 1 && u.sysname[i]; i++) {
        sphttp_os_buf[i] = (char)tolower((unsigned char)u.sysname[i]);
    }
    sphttp_os_buf[i] = '\0';
    return sphttp_os_buf;
}
const char *sphttp_arch_kind(void) {
    struct utsname u;
    if (uname(&u) != 0) {
        return "unknown";
    }
    size_t i;
    for (i = 0; i < sizeof(sphttp_arch_buf) - 1 && u.machine[i]; i++) {
        sphttp_arch_buf[i] = u.machine[i];
    }
    sphttp_arch_buf[i] = '\0';
    return sphttp_arch_buf;
}

/* ---------- HTTP/1.1 outbound connection pool (chunk 6.7) ----------
 *
 * Per-process pool keyed by (host, port). Each slot caches one idle
 * keep-alive socket; checkout() removes the matching idle slot,
 * checkin() registers an idle slot, sweep() closes slots older than
 * an idle-timeout. Pure C state -- single-threaded server model
 * (each prefork worker has its own copy of these statics). The Ruby
 * wrapper (Tep::Http::Pool) provides the ergonomic API + ms-grained
 * stats.
 *
 * Fixed-size array with a basic LRU-by-last-used eviction when full.
 * 256 slots is enough for any realistic gateway shape (each slot
 * holds one host+port+fd triple), and the hot path is O(N) over
 * slots -- acceptable for N=256 with cache-line locality. */
#define SPHTTP_POOL_MAX  256
#define SPHTTP_POOL_HOST 96
struct sphttp_pool_slot {
    int  fd;                                 /* -1 = empty */
    int  port;
    long last_used_secs;                     /* epoch seconds */
    char host[SPHTTP_POOL_HOST];
};
static struct sphttp_pool_slot sphttp_pool[SPHTTP_POOL_MAX];
static int  sphttp_pool_inited = 0;
static long sphttp_pool_checkouts = 0;
static long sphttp_pool_checkins  = 0;
static long sphttp_pool_hits      = 0;
static long sphttp_pool_misses    = 0;

static void sphttp_pool_init_once(void) {
    if (sphttp_pool_inited) return;
    int i;
    for (i = 0; i < SPHTTP_POOL_MAX; i++) {
        sphttp_pool[i].fd   = -1;
        sphttp_pool[i].port = 0;
        sphttp_pool[i].last_used_secs = 0;
        sphttp_pool[i].host[0] = '\0';
    }
    sphttp_pool_inited = 1;
}

/* Try to claim an idle fd for (host, port). Returns the fd (>=0)
 * on hit, -1 on miss. Caller owns the fd on hit -- it's removed
 * from the pool atomically. checkouts + hits/misses are bumped for
 * observability. */
int sphttp_pool_checkout(const char *host, int port) {
    sphttp_pool_init_once();
    sphttp_pool_checkouts++;
    int i;
    for (i = 0; i < SPHTTP_POOL_MAX; i++) {
        if (sphttp_pool[i].fd >= 0 &&
            sphttp_pool[i].port == port &&
            strncmp(sphttp_pool[i].host, host, SPHTTP_POOL_HOST) == 0) {
            int fd = sphttp_pool[i].fd;
            sphttp_pool[i].fd = -1;
            sphttp_pool[i].host[0] = '\0';
            sphttp_pool_hits++;
            return fd;
        }
    }
    sphttp_pool_misses++;
    return -1;
}

/* Register `fd` as an idle keep-alive socket for (host, port).
 * Returns 0 on success, -1 on failure (pool full -- in that case
 * the caller should close the fd; we do NOT close it for them so
 * the call stays side-effect-light). LRU-evict the oldest entry
 * when full: sweep finds the slot with the smallest last_used,
 * closes its fd, reuses the slot. */
int sphttp_pool_checkin(int fd, const char *host, int port) {
    sphttp_pool_init_once();
    if (fd < 0) return -1;
    int i, free_slot = -1;
    long now = (long)time(NULL);
    /* First pass: find an empty slot. */
    for (i = 0; i < SPHTTP_POOL_MAX; i++) {
        if (sphttp_pool[i].fd < 0) {
            free_slot = i;
            break;
        }
    }
    /* Second pass: evict the LRU if no empty slot. Seed `oldest`
     * with slot 0 + scan from i=1 to avoid needing LONG_MAX (which
     * would pull in limits.h for a single sentinel). */
    if (free_slot < 0) {
        long oldest = sphttp_pool[0].last_used_secs;
        free_slot = 0;
        for (i = 1; i < SPHTTP_POOL_MAX; i++) {
            if (sphttp_pool[i].last_used_secs < oldest) {
                oldest = sphttp_pool[i].last_used_secs;
                free_slot = i;
            }
        }
        if (sphttp_pool[free_slot].fd >= 0) {
            close(sphttp_pool[free_slot].fd);
        }
    }
    if (free_slot < 0) return -1;
    sphttp_pool[free_slot].fd   = fd;
    sphttp_pool[free_slot].port = port;
    sphttp_pool[free_slot].last_used_secs = now;
    /* strncpy WITHOUT trailing NUL guarantee on overflow -- but
     * SPHTTP_POOL_HOST is bigger than any realistic hostname; we
     * NUL-terminate manually for safety. */
    strncpy(sphttp_pool[free_slot].host, host, SPHTTP_POOL_HOST - 1);
    sphttp_pool[free_slot].host[SPHTTP_POOL_HOST - 1] = '\0';
    sphttp_pool_checkins++;
    return 0;
}

/* Close any pooled idle fd whose last_used is older than now_secs
 * minus idle_seconds. Returns the count of slots closed. Callers
 * sweep periodically (e.g. the server's main loop) to bound the
 * idle-socket count under sustained low traffic. */
int sphttp_pool_close_idle(int idle_seconds) {
    sphttp_pool_init_once();
    long now = (long)time(NULL);
    long cutoff = now - (long)idle_seconds;
    int i, closed = 0;
    for (i = 0; i < SPHTTP_POOL_MAX; i++) {
        if (sphttp_pool[i].fd >= 0 &&
            sphttp_pool[i].last_used_secs < cutoff) {
            close(sphttp_pool[i].fd);
            sphttp_pool[i].fd = -1;
            sphttp_pool[i].host[0] = '\0';
            closed++;
        }
    }
    return closed;
}

/* Stats getters -- callers (Tep::Http::Pool.stats) read each one
 * via separate FFI calls to avoid a struct-return shape over FFI. */
int sphttp_pool_stat_checkouts(void) { return (int)sphttp_pool_checkouts; }
int sphttp_pool_stat_checkins(void)  { return (int)sphttp_pool_checkins; }
int sphttp_pool_stat_hits(void)      { return (int)sphttp_pool_hits; }
int sphttp_pool_stat_misses(void)    { return (int)sphttp_pool_misses; }

/* File read/write moved to spinel's built-in File.read / File.write */
