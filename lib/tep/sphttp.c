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

static char sphttp_req_buf[SPHTTP_BUFSIZE];
static int  sphttp_req_len = 0;

/* Shutdown-on-signal plumbing. SIGTERM/SIGINT set the flag; the
 * server's accept loop checks it after accept() returns from EINTR
 * and breaks out cleanly so Ruby-level run_end hooks can fire before
 * the process exits. SA_RESETHAND restores the default handler after
 * the first delivery so a second signal kills the process immediately
 * if shutdown stalls (a non-cooperative second Ctrl-C). */
static volatile sig_atomic_t sphttp_term_flag = 0;
static void sphttp_term_signal(int sig) {
    (void)sig;
    sphttp_term_flag = 1;
}
int sphttp_install_term_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sphttp_term_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;       /* second signal -> default action */
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    return 0;
}
int sphttp_shutdown_requested(void) {
    return (int)sphttp_term_flag;
}

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
int sphttp_listen(int port, int reuseport) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_REUSEPORT
    if (reuseport) {
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    }
#endif
    /* Disable Nagle for small response latency. */
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    /* Don't die on broken-pipe sends. */
    signal(SIGPIPE, SIG_IGN);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 1024) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int sphttp_accept(int sfd) {
    struct sockaddr_in caddr;
    socklen_t clen = sizeof(caddr);
    int fd;
    for (;;) {
        fd = accept(sfd, (struct sockaddr *)&caddr, &clen);
        if (fd >= 0) return fd;
        if (errno == EINTR) {
            /* SIGTERM/SIGINT raises sphttp_term_flag; surface as a -1
             * return so the Ruby accept loop can run shutdown hooks
             * and exit. Unrelated signals (SIGCHLD, ...) just retry. */
            if (sphttp_term_flag) return -1;
            continue;
        }
        return -1;
    }
}

/* Non-blocking accept. Returns the new fd on success, -1 with errno
 * EAGAIN/EWOULDBLOCK if no pending connection, -1 with other errno
 * on real error. Caller (Tep::Server::Scheduled) parks the accept
 * fiber on Tep::Scheduler.io_wait(sfd, READ) before retrying.
 * Requires the listen fd to already be in non-blocking mode -- call
 * sphttp_set_nonblock(sfd) once after sphttp_listen. */
int sphttp_accept_nb(int sfd) {
    struct sockaddr_in caddr;
    socklen_t clen = sizeof(caddr);
    int fd;
    do {
        fd = accept(sfd, (struct sockaddr *)&caddr, &clen);
    } while (fd < 0 && errno == EINTR);
    return fd;
}

/* Read until end-of-headers ("\r\n\r\n") or the buffer fills. Subsequent
 * recv()s for the body are the caller's job (we expose a length helper).
 * Returns the parsed length (>0), 0 on clean EOF, -1 on error. */
int sphttp_read_request(int fd) {
    sphttp_req_len = 0;
    sphttp_req_buf[0] = '\0';
    while (sphttp_req_len < SPHTTP_BUFSIZE - 1) {
        ssize_t n = recv(fd, sphttp_req_buf + sphttp_req_len,
                         SPHTTP_BUFSIZE - 1 - sphttp_req_len, 0);
        if (n == 0) {
            if (sphttp_req_len == 0) return 0;
            break;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
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
    int n = total_len;
    if (n < 0) n = 0;
    if (n >= SPHTTP_BUFSIZE) n = SPHTTP_BUFSIZE - 1;
    int got = 0;
    while (got < n) {
        ssize_t r = recv(fd, sphttp_body_buf + got, n - got, 0);
        if (r <= 0) {
            if (errno == EINTR) continue;
            break;
        }
        got += (int)r;
    }
    sphttp_body_buf[got] = '\0';
    return sphttp_body_buf;
}

int sphttp_write_str(int fd, const char *s) {
    size_t len = strlen(s);
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, s + off, len - off, 0);
        if (n <= 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/* Binary write -- explicit length, no strlen. Required for any
 * caller that needs to send bytes that may contain 0x00 (WebSocket
 * frames, raw protocol bodies). Returns 0 on success, -1 on send
 * failure. */
int sphttp_write_bytes(int fd, const char *data, int n) {
    size_t total = (n < 0) ? 0 : (size_t)n;
    size_t off = 0;
    while (off < total) {
        ssize_t w = send(fd, data + off, total - off, 0);
        if (w <= 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)w;
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
    sphttp_frame_len = 0;
    ssize_t n = recv(fd, sphttp_frame_buf, SPHTTP_BUFSIZE, 0);
    if (n < 0) {
        if (errno == EINTR) {
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

int sphttp_close(int fd) {
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
int sphttp_fork(void) {
    return (int)fork();
}

/* Hard exit -- bypasses spinel's Ruby-level `exit(0)` (which was
 * observed to not actually terminate child processes in some
 * codegen shapes). Used by Tep::Parallel children after they've
 * written their result file. Returns int for FFI symmetry; the
 * function actually never returns. */
int sphttp_exit(int status) {
    _exit(status);
    return 0;
}

int sphttp_getpid(void) {
    return (int)getpid();
}

/* Block until any child exits; reap it. Returns the pid that exited
 * or -1 if there are no children. */
int sphttp_wait_any(void) {
    int status = 0;
    pid_t p = wait(&status);
    return (int)p;
}

/* ---------- Non-blocking I/O + poll(2) plumbing ----------
 *
 * The scheduler parks a fiber on (fd, mode) via Sock.sphttp_poll_add;
 * tick() then calls sphttp_poll_run with a timeout and walks the
 * slots to see who got ready. Mode bits:  1=READ, 2=WRITE.
 *
 * Storage is process-static. The Ruby side owns the "reset between
 * tick rounds" discipline -- safe because the scheduler is single-
 * threaded inside one worker. */

#define SPHTTP_POLL_MAX 256
static struct pollfd sphttp_poll_set[SPHTTP_POLL_MAX];
static int           sphttp_poll_n = 0;

int sphttp_poll_reset(void) {
    sphttp_poll_n = 0;
    return 0;
}

/* Add (fd, mode_bits) to the poll set. Returns the slot index for
 * later sphttp_poll_ready(slot), or -1 if the set is full. */
int sphttp_poll_add(int fd, int mode_bits) {
    if (sphttp_poll_n >= SPHTTP_POLL_MAX) return -1;
    short ev = 0;
    if (mode_bits & 1) ev |= POLLIN;
    if (mode_bits & 2) ev |= POLLOUT;
    sphttp_poll_set[sphttp_poll_n].fd      = fd;
    sphttp_poll_set[sphttp_poll_n].events  = ev;
    sphttp_poll_set[sphttp_poll_n].revents = 0;
    return sphttp_poll_n++;
}

/* Run poll() with a millisecond timeout. -1 blocks forever, 0 is a
 * non-blocking peek. Returns the count of ready slots (>=0) or -1. */
int sphttp_poll_run(int timeout_ms) {
    int r;
    do {
        r = poll(sphttp_poll_set, sphttp_poll_n, timeout_ms);
    } while (r < 0 && errno == EINTR);
    return r;
}

/* Read the ready-mode bits for a slot. POLLHUP/POLLERR fold into the
 * READ bit so a fiber waiting on read sees the hangup and can call
 * recv() to get the 0-byte EOF / errno. */
int sphttp_poll_ready(int slot) {
    if (slot < 0 || slot >= sphttp_poll_n) return 0;
    short rev = sphttp_poll_set[slot].revents;
    int out = 0;
    if (rev & (POLLIN | POLLHUP | POLLERR)) out |= 1;
    if (rev & POLLOUT)                       out |= 2;
    return out;
}

/* Flip O_NONBLOCK on. Used by the scheduler to make handler-owned
 * sockets play nicely with poll-based parking. */
int sphttp_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Outbound TCP connect. Resolves `host` via getaddrinfo (so both
 * IP literals and DNS names work). Returns the connected fd or -1.
 * Blocking connect for now -- a future variant can do non-blocking
 * connect + poll(POLLOUT) for fully-async outbound. */
int sphttp_connect(const char *host, int port) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char portbuf[16];
    snprintf(portbuf, sizeof(portbuf), "%d", port);

    if (getaddrinfo(host, portbuf, &hints, &res) != 0) return -1;

    int fd = -1;
    struct addrinfo *ai;
    for (ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

/* Best-effort recv() that returns the bytes as a static buffer.
 * Pairs with sphttp_set_nonblock + sphttp_poll_run for the scheduler
 * loop. Returns "" on EAGAIN/empty so callers can branch on
 * .length == 0; "<EOF>" sentinel is the empty-string + closed fd
 * pattern (use sphttp_close + state machine on the caller side). */
static char sphttp_recv_buf[SPHTTP_BUFSIZE];
const char *sphttp_recv_some(int fd, int maxlen) {
    if (maxlen <= 0 || maxlen >= SPHTTP_BUFSIZE) maxlen = SPHTTP_BUFSIZE - 1;
    ssize_t n = recv(fd, sphttp_recv_buf, (size_t)maxlen, 0);
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
    int total = 0;
    while (total < max_bytes) {
        ssize_t n = recv(fd, sphttp_recv_all_buf + total, (size_t)(max_bytes - total), 0);
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
static char sphttp_shell_buf[SPHTTP_BUFSIZE];
const char *sphttp_shell_capture(const char *cmd, int max_bytes) {
    if (max_bytes <= 0 || max_bytes >= SPHTTP_BUFSIZE) max_bytes = SPHTTP_BUFSIZE - 1;
    sphttp_shell_buf[0] = '\0';
    FILE *fp = popen(cmd, "r");
    if (!fp) return sphttp_shell_buf;
    size_t total = 0;
    while (total < (size_t)max_bytes) {
        size_t n = fread(sphttp_shell_buf + total, 1, (size_t)max_bytes - total, fp);
        if (n == 0) break;
        total += n;
    }
    sphttp_shell_buf[total] = '\0';
    pclose(fp);
    return sphttp_shell_buf;
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
