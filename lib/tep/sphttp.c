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

/* ---------- SHA-256 + HMAC for the cookie session store ---------- */
/* Compact public-domain SHA-256 implementation, then HMAC on top. */

static const uint32_t sphttp_sha256_k[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define SPHTTP_ROTR(x,n)    (((x) >> (n)) | ((x) << (32 - (n))))
#define SPHTTP_S0(x)  (SPHTTP_ROTR(x, 2) ^ SPHTTP_ROTR(x,13) ^ SPHTTP_ROTR(x,22))
#define SPHTTP_S1(x)  (SPHTTP_ROTR(x, 6) ^ SPHTTP_ROTR(x,11) ^ SPHTTP_ROTR(x,25))
#define SPHTTP_s0(x)  (SPHTTP_ROTR(x, 7) ^ SPHTTP_ROTR(x,18) ^ ((x) >> 3))
#define SPHTTP_s1(x)  (SPHTTP_ROTR(x,17) ^ SPHTTP_ROTR(x,19) ^ ((x) >> 10))
#define SPHTTP_CH(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
#define SPHTTP_MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

static void sphttp_sha256_block(uint32_t H[8], const uint8_t b[64]) {
    uint32_t w[64], a, sa, sb, sc, sd, se, sf, sg, sh, t1, t2;
    int i;
    for (i = 0; i < 16; i++) {
        w[i] = ((uint32_t)b[i*4] << 24) | ((uint32_t)b[i*4+1] << 16) |
               ((uint32_t)b[i*4+2] << 8) |  (uint32_t)b[i*4+3];
    }
    for (i = 16; i < 64; i++) {
        w[i] = SPHTTP_s1(w[i-2]) + w[i-7] + SPHTTP_s0(w[i-15]) + w[i-16];
    }
    sa=H[0]; sb=H[1]; sc=H[2]; sd=H[3]; se=H[4]; sf=H[5]; sg=H[6]; sh=H[7];
    for (i = 0; i < 64; i++) {
        t1 = sh + SPHTTP_S1(se) + SPHTTP_CH(se,sf,sg) + sphttp_sha256_k[i] + w[i];
        t2 = SPHTTP_S0(sa) + SPHTTP_MAJ(sa,sb,sc);
        sh = sg; sg = sf; sf = se; se = sd + t1;
        sd = sc; sc = sb; sb = sa; sa = t1 + t2;
    }
    H[0]+=sa; H[1]+=sb; H[2]+=sc; H[3]+=sd;
    H[4]+=se; H[5]+=sf; H[6]+=sg; H[7]+=sh;
    a = a;  /* silence unused-var if compiler is pedantic */
}

static void sphttp_sha256(const uint8_t *msg, size_t len, uint8_t out[32]) {
    uint32_t H[8] = {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
        0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };
    uint8_t buf[64];
    size_t i, full = len & ~((size_t)63);
    for (i = 0; i < full; i += 64) sphttp_sha256_block(H, msg + i);
    size_t rem = len - full;
    for (i = 0; i < rem; i++) buf[i] = msg[full + i];
    buf[rem] = 0x80;
    if (rem >= 56) {
        for (i = rem + 1; i < 64; i++) buf[i] = 0;
        sphttp_sha256_block(H, buf);
        for (i = 0; i < 56; i++) buf[i] = 0;
    } else {
        for (i = rem + 1; i < 56; i++) buf[i] = 0;
    }
    uint64_t bits = (uint64_t)len * 8;
    for (i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bits >> (56 - 8*i));
    sphttp_sha256_block(H, buf);
    for (i = 0; i < 8; i++) {
        out[i*4]   = (uint8_t)(H[i] >> 24);
        out[i*4+1] = (uint8_t)(H[i] >> 16);
        out[i*4+2] = (uint8_t)(H[i] >> 8);
        out[i*4+3] = (uint8_t)(H[i]);
    }
}

static void sphttp_hmac_sha256(const uint8_t *key, size_t klen,
                               const uint8_t *msg, size_t mlen,
                               uint8_t out[32]) {
    uint8_t kpad[64], ipad[64], opad[64], inner[32];
    size_t i;
    if (klen > 64) {
        sphttp_sha256(key, klen, kpad);
        for (i = 32; i < 64; i++) kpad[i] = 0;
    } else {
        for (i = 0; i < klen; i++) kpad[i] = key[i];
        for (i = klen; i < 64; i++) kpad[i] = 0;
    }
    for (i = 0; i < 64; i++) {
        ipad[i] = kpad[i] ^ 0x36;
        opad[i] = kpad[i] ^ 0x5c;
    }
    /* inner = SHA256(ipad || msg) */
    /* Avoid an extra heap alloc by streaming the two segments. */
    {
        uint32_t H[8] = {
            0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
            0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
        };
        sphttp_sha256_block(H, ipad);
        /* Now hash msg with the carry state. Total length = 64 + mlen. */
        uint8_t buf[64];
        size_t full = mlen & ~((size_t)63);
        for (i = 0; i < full; i += 64) sphttp_sha256_block(H, msg + i);
        size_t rem = mlen - full;
        for (i = 0; i < rem; i++) buf[i] = msg[full + i];
        buf[rem] = 0x80;
        if (rem >= 56) {
            for (i = rem + 1; i < 64; i++) buf[i] = 0;
            sphttp_sha256_block(H, buf);
            for (i = 0; i < 56; i++) buf[i] = 0;
        } else {
            for (i = rem + 1; i < 56; i++) buf[i] = 0;
        }
        uint64_t bits = (uint64_t)(64 + mlen) * 8;
        for (i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bits >> (56 - 8*i));
        sphttp_sha256_block(H, buf);
        for (i = 0; i < 8; i++) {
            inner[i*4]   = (uint8_t)(H[i] >> 24);
            inner[i*4+1] = (uint8_t)(H[i] >> 16);
            inner[i*4+2] = (uint8_t)(H[i] >> 8);
            inner[i*4+3] = (uint8_t)(H[i]);
        }
    }
    /* outer = SHA256(opad || inner) */
    {
        uint32_t H[8] = {
            0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
            0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
        };
        sphttp_sha256_block(H, opad);
        uint8_t buf[64];
        for (i = 0; i < 32; i++) buf[i] = inner[i];
        buf[32] = 0x80;
        for (i = 33; i < 56; i++) buf[i] = 0;
        uint64_t bits = (uint64_t)(64 + 32) * 8;
        for (i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bits >> (56 - 8*i));
        sphttp_sha256_block(H, buf);
        for (i = 0; i < 8; i++) {
            out[i*4]   = (uint8_t)(H[i] >> 24);
            out[i*4+1] = (uint8_t)(H[i] >> 16);
            out[i*4+2] = (uint8_t)(H[i] >> 8);
            out[i*4+3] = (uint8_t)(H[i]);
        }
    }
}

/* Public FFI: HMAC-SHA256 with the result returned as a 64-char hex
 * string in a static buffer. Both key and msg are NUL-terminated
 * (Spinel doesn't pass length alongside :str) -- adequate for our
 * cookie use, where the secret has no embedded NULs and the message
 * is URL-encoded (also NUL-free). The next call clobbers the buffer. */
static char sphttp_hmac_hex_buf[65];

const char *sphttp_hmac_sha256_hex(const char *key, const char *msg) {
    uint8_t out[32];
    sphttp_hmac_sha256((const uint8_t *)key, strlen(key),
                       (const uint8_t *)msg, strlen(msg),
                       out);
    static const char H[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; i++) {
        sphttp_hmac_hex_buf[i*2]   = H[(out[i] >> 4) & 0xf];
        sphttp_hmac_hex_buf[i*2+1] = H[out[i] & 0xf];
    }
    sphttp_hmac_hex_buf[64] = '\0';
    return sphttp_hmac_hex_buf;
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
