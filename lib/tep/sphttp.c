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
    do {
        fd = accept(sfd, (struct sockaddr *)&caddr, &clen);
    } while (fd < 0 && errno == EINTR);
    return fd;
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

/* Byte-level accessor. Workaround for the spinel `:str` FFI return
 * shape being NUL-bound (the Ruby-side String stops at the first
 * 0x00 byte regardless of the buffer's actual length). Callers that
 * need to walk arbitrary bytes -- WebSocket frame codec, file uploads
 * with embedded NULs, anything binary -- use this fn in a loop:
 *
 *   n = Sock.sphttp_recv_into_frame(fd)
 *   i = 0
 *   while i < n
 *     byte = Sock.sphttp_recv_frame_byte_at(i)
 *     ...
 *     i += 1
 *   end
 *
 * Returns the unsigned byte value (0..255), or -1 if `i` is out of
 * bounds. Slow but correct; replace with a bulk-read variant when
 * spinel grows a binary-safe FFI return shape. */
int sphttp_recv_frame_byte_at(int i) {
    if (i < 0 || i >= sphttp_frame_len) return -1;
    return (int)(unsigned char)sphttp_frame_buf[i];
}

/* Binary send accumulator -- mirror of the recv side.
 *
 * Ruby Strings in spinel are NUL-bound at the value level: `0.chr`
 * is an empty String, and `"abc" + 0.chr + "def"` truncates at the
 * NUL (filed as matz/spinel#593). That makes WebSocket frame headers
 * -- which routinely contain 0x00 bytes for 16-bit and 64-bit length
 * encodings -- impossible to build via Ruby String concatenation.
 *
 * The fix is to build the bytes into a C-side static buffer one byte
 * at a time via sphttp_send_append_byte, then flush via send(). The
 * read-back accessor sphttp_send_byte_at exists for tests; the live
 * flush path is sphttp_send_flush(fd) which writes len bytes via the
 * full sphttp_write_bytes retry-on-EINTR loop.
 *
 * Single-buffer / per-fork: WS encoding is cooperative within one
 * fiber-per-connection worker, so cross-frame interleaving doesn't
 * happen. Multi-fiber concurrency (Phase 3+) would route each fiber's
 * encode through Fiber.storage (matz/spinel#578).
 *
 * For payloads that contain NUL (binary frames), Ruby String concat
 * is still the bottleneck on the caller side; tep currently ships
 * server-side TEXT/PING/PONG/CLOSE with payloads that don't embed
 * 0x00. Binary frame payloads are a Phase 3 deliverable. */
static unsigned char sphttp_send_buf[SPHTTP_BUFSIZE];
static int  sphttp_send_len = 0;

void sphttp_send_clear(void) { sphttp_send_len = 0; }

int sphttp_send_append_byte(int b) {
    if (sphttp_send_len >= SPHTTP_BUFSIZE) return -1;
    sphttp_send_buf[sphttp_send_len] = (unsigned char)(b & 0xff);
    sphttp_send_len++;
    return sphttp_send_len;
}

/* Append a Ruby String (NUL-bound) up to `n` bytes. Suitable for
 * text payloads only; binary payloads (which may contain 0x00) must
 * be appended via sphttp_send_append_byte in a byte-by-byte loop. */
int sphttp_send_append_bytes(const char *data, int n) {
    if (n < 0) n = 0;
    if (sphttp_send_len + n > SPHTTP_BUFSIZE) return -1;
    for (int i = 0; i < n; i++) {
        sphttp_send_buf[sphttp_send_len + i] = (unsigned char)data[i];
    }
    sphttp_send_len += n;
    return sphttp_send_len;
}

int sphttp_send_byte_at(int i) {
    if (i < 0 || i >= sphttp_send_len) return -1;
    return (int)sphttp_send_buf[i];
}

int sphttp_send_len_get(void) { return sphttp_send_len; }

/* Flush the entire send buffer to fd via the standard retry-on-EINTR
 * send() loop. Resets sphttp_send_len to 0 on success. Returns 0 on
 * success, -1 on send failure (buffer length is NOT reset on failure
 * so caller can inspect it). */
int sphttp_send_flush(int fd) {
    size_t total = (size_t)sphttp_send_len;
    size_t off = 0;
    while (off < total) {
        ssize_t w = send(fd, sphttp_send_buf + off, total - off, 0);
        if (w <= 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)w;
    }
    sphttp_send_len = 0;
    return 0;
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

/* File read/write moved to spinel's built-in File.read / File.write */
