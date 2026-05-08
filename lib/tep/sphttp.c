/* sphttp.c - POSIX HTTP plumbing for Tep, called from Spinel via FFI.
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
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <signal.h>

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

/* Pre-fork support. Returns child pid in parent, 0 in child, -1 on fail. */
int sphttp_fork(void) {
    return (int)fork();
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
