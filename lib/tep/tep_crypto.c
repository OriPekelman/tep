/* tep_crypto.c -- SHA-256 / HMAC-SHA256 / PBKDF2 / Base64URL / CSPRNG.
 *
 * Lifted out of sphttp.c so the FFI surface separates "POSIX HTTP
 * plumbing" from "small in-tree crypto". Pure C, no spinel-runtime
 * dependency -- consumed by spinel via ffi_func bindings in the
 * Crypto module (see lib/tep/net.rb).
 *
 * Naming
 * ------
 * Public exports use the `tep_crypto_` prefix (matches the
 * `tep_sqlite_` convention next door in tep_sqlite.c). Internal
 * helpers and state buffers reuse the same prefix to keep the C
 * symbol table tidy.
 *
 * State buffers
 * -------------
 * Each public function returns a pointer into a per-function static
 * buffer that the next call to the same function clobbers. Spinel
 * receives the pointer as :str -- copy on the Ruby side (`+ ""`) if
 * the value needs to outlive the next FFI call. This matches the
 * convention already in use across sphttp.c.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#  include <stdlib.h>  /* arc4random_buf */
#endif

/* ---------- SHA-256 ----------
 * Compact public-domain SHA-256 implementation.
 */

static const uint32_t tep_crypto_sha256_k[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define TEPC_ROTR(x,n)    (((x) >> (n)) | ((x) << (32 - (n))))
#define TEPC_S0(x)  (TEPC_ROTR(x, 2) ^ TEPC_ROTR(x,13) ^ TEPC_ROTR(x,22))
#define TEPC_S1(x)  (TEPC_ROTR(x, 6) ^ TEPC_ROTR(x,11) ^ TEPC_ROTR(x,25))
#define TEPC_s0(x)  (TEPC_ROTR(x, 7) ^ TEPC_ROTR(x,18) ^ ((x) >> 3))
#define TEPC_s1(x)  (TEPC_ROTR(x,17) ^ TEPC_ROTR(x,19) ^ ((x) >> 10))
#define TEPC_CH(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
#define TEPC_MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

static void tep_crypto_sha256_block(uint32_t H[8], const uint8_t b[64]) {
    uint32_t w[64], sa, sb, sc, sd, se, sf, sg, sh, t1, t2;
    int i;
    for (i = 0; i < 16; i++) {
        w[i] = ((uint32_t)b[i*4] << 24) | ((uint32_t)b[i*4+1] << 16) |
               ((uint32_t)b[i*4+2] << 8) |  (uint32_t)b[i*4+3];
    }
    for (i = 16; i < 64; i++) {
        w[i] = TEPC_s1(w[i-2]) + w[i-7] + TEPC_s0(w[i-15]) + w[i-16];
    }
    sa=H[0]; sb=H[1]; sc=H[2]; sd=H[3]; se=H[4]; sf=H[5]; sg=H[6]; sh=H[7];
    for (i = 0; i < 64; i++) {
        t1 = sh + TEPC_S1(se) + TEPC_CH(se,sf,sg) + tep_crypto_sha256_k[i] + w[i];
        t2 = TEPC_S0(sa) + TEPC_MAJ(sa,sb,sc);
        sh = sg; sg = sf; sf = se; se = sd + t1;
        sd = sc; sc = sb; sb = sa; sa = t1 + t2;
    }
    H[0]+=sa; H[1]+=sb; H[2]+=sc; H[3]+=sd;
    H[4]+=se; H[5]+=sf; H[6]+=sg; H[7]+=sh;
}

static void tep_crypto_sha256(const uint8_t *msg, size_t len, uint8_t out[32]) {
    uint32_t H[8] = {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
        0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };
    uint8_t buf[64];
    size_t i, full = len & ~((size_t)63);
    for (i = 0; i < full; i += 64) tep_crypto_sha256_block(H, msg + i);
    size_t rem = len - full;
    for (i = 0; i < rem; i++) buf[i] = msg[full + i];
    buf[rem] = 0x80;
    if (rem >= 56) {
        for (i = rem + 1; i < 64; i++) buf[i] = 0;
        tep_crypto_sha256_block(H, buf);
        for (i = 0; i < 56; i++) buf[i] = 0;
    } else {
        for (i = rem + 1; i < 56; i++) buf[i] = 0;
    }
    uint64_t bits = (uint64_t)len * 8;
    for (i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bits >> (56 - 8*i));
    tep_crypto_sha256_block(H, buf);
    for (i = 0; i < 8; i++) {
        out[i*4]   = (uint8_t)(H[i] >> 24);
        out[i*4+1] = (uint8_t)(H[i] >> 16);
        out[i*4+2] = (uint8_t)(H[i] >> 8);
        out[i*4+3] = (uint8_t)(H[i]);
    }
}

/* ---------- HMAC-SHA256 ---------- */

static void tep_crypto_hmac_sha256(const uint8_t *key, size_t klen,
                                   const uint8_t *msg, size_t mlen,
                                   uint8_t out[32]) {
    uint8_t kpad[64], ipad[64], opad[64], inner[32];
    size_t i;
    if (klen > 64) {
        tep_crypto_sha256(key, klen, kpad);
        for (i = 32; i < 64; i++) kpad[i] = 0;
    } else {
        for (i = 0; i < klen; i++) kpad[i] = key[i];
        for (i = klen; i < 64; i++) kpad[i] = 0;
    }
    for (i = 0; i < 64; i++) {
        ipad[i] = kpad[i] ^ 0x36;
        opad[i] = kpad[i] ^ 0x5c;
    }
    /* inner = SHA256(ipad || msg) -- stream the two segments so we
     * avoid a second heap alloc. */
    {
        uint32_t H[8] = {
            0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
            0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
        };
        tep_crypto_sha256_block(H, ipad);
        uint8_t buf[64];
        size_t full = mlen & ~((size_t)63);
        for (i = 0; i < full; i += 64) tep_crypto_sha256_block(H, msg + i);
        size_t rem = mlen - full;
        for (i = 0; i < rem; i++) buf[i] = msg[full + i];
        buf[rem] = 0x80;
        if (rem >= 56) {
            for (i = rem + 1; i < 64; i++) buf[i] = 0;
            tep_crypto_sha256_block(H, buf);
            for (i = 0; i < 56; i++) buf[i] = 0;
        } else {
            for (i = rem + 1; i < 56; i++) buf[i] = 0;
        }
        uint64_t bits = (uint64_t)(64 + mlen) * 8;
        for (i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bits >> (56 - 8*i));
        tep_crypto_sha256_block(H, buf);
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
        tep_crypto_sha256_block(H, opad);
        uint8_t buf[64];
        for (i = 0; i < 32; i++) buf[i] = inner[i];
        buf[32] = 0x80;
        for (i = 33; i < 56; i++) buf[i] = 0;
        uint64_t bits = (uint64_t)(64 + 32) * 8;
        for (i = 0; i < 8; i++) buf[56 + i] = (uint8_t)(bits >> (56 - 8*i));
        tep_crypto_sha256_block(H, buf);
        for (i = 0; i < 8; i++) {
            out[i*4]   = (uint8_t)(H[i] >> 24);
            out[i*4+1] = (uint8_t)(H[i] >> 16);
            out[i*4+2] = (uint8_t)(H[i] >> 8);
            out[i*4+3] = (uint8_t)(H[i]);
        }
    }
}

/* Public FFI: HMAC-SHA256, hex-encoded result in a static buffer.
 * Both key and msg are NUL-terminated (spinel passes :str without a
 * separate length) -- adequate for cookie use where the secret has
 * no NULs and the message is URL-encoded. */
static char tep_crypto_hmac_hex_buf[65];

const char *tep_crypto_hmac_sha256_hex(const char *key, const char *msg) {
    uint8_t out[32];
    tep_crypto_hmac_sha256((const uint8_t *)key, strlen(key),
                           (const uint8_t *)msg, strlen(msg),
                           out);
    static const char H[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; i++) {
        tep_crypto_hmac_hex_buf[i*2]   = H[(out[i] >> 4) & 0xf];
        tep_crypto_hmac_hex_buf[i*2+1] = H[out[i] & 0xf];
    }
    tep_crypto_hmac_hex_buf[64] = '\0';
    return tep_crypto_hmac_hex_buf;
}

/* ---------- Base64URL (RFC 4648 §5) ----------
 * + and / replaced by - and _. No padding -- JWT and most modern
 * callers strip '=' on emit and accept it missing on decode.
 */

static const char TEPC_B64U[64] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/* HMAC-SHA256 -> 43-char unpadded b64url. JWT JOSE encoding wants
 * the binary HMAC digest base64url'd directly, never hex. */
static char tep_crypto_hmac_b64url_buf[44];

const char *tep_crypto_hmac_sha256_b64url(const char *key, const char *msg) {
    uint8_t out[32];
    tep_crypto_hmac_sha256((const uint8_t *)key, strlen(key),
                           (const uint8_t *)msg, strlen(msg),
                           out);
    int i, j = 0;
    for (i = 0; i + 3 <= 32; i += 3) {
        uint32_t v = ((uint32_t)out[i] << 16)
                   | ((uint32_t)out[i+1] << 8)
                   | (uint32_t)out[i+2];
        tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[(v >> 6)  & 0x3f];
        tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[v & 0x3f];
    }
    if (i < 32) {
        uint32_t v = ((uint32_t)out[i] << 16)
                   | (i + 1 < 32 ? ((uint32_t)out[i+1] << 8) : 0);
        tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        if (i + 1 < 32) {
            tep_crypto_hmac_b64url_buf[j++] = TEPC_B64U[(v >> 6) & 0x3f];
        }
    }
    tep_crypto_hmac_b64url_buf[j] = '\0';
    return tep_crypto_hmac_b64url_buf;
}

/* base64url-encode an arbitrary NUL-terminated input. The cap below
 * covers JWT-payload-sized inputs comfortably (a 4 KiB token's
 * payload after JSON serialisation is well under 3 KiB). For larger
 * payloads bump TEPC_B64U_BUFSIZE. */
#define TEPC_B64U_BUFSIZE (16 * 1024)
static char tep_crypto_b64url_buf[TEPC_B64U_BUFSIZE];

const char *tep_crypto_b64url_encode(const char *src) {
    size_t n = strlen(src);
    size_t i = 0, j = 0;
    if (4 * ((n + 2) / 3) + 1 > TEPC_B64U_BUFSIZE) {
        tep_crypto_b64url_buf[0] = '\0';
        return tep_crypto_b64url_buf;
    }
    while (i + 3 <= n) {
        uint32_t v = ((uint32_t)(uint8_t)src[i]   << 16)
                   | ((uint32_t)(uint8_t)src[i+1] << 8)
                   |  (uint32_t)(uint8_t)src[i+2];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >>  6) & 0x3f];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[ v        & 0x3f];
        i += 3;
    }
    size_t rem = n - i;
    if (rem == 1) {
        uint32_t v = (uint32_t)(uint8_t)src[i] << 16;
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
    } else if (rem == 2) {
        uint32_t v = ((uint32_t)(uint8_t)src[i]   << 16)
                   | ((uint32_t)(uint8_t)src[i+1] << 8);
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        tep_crypto_b64url_buf[j++] = TEPC_B64U[(v >>  6) & 0x3f];
    }
    tep_crypto_b64url_buf[j] = '\0';
    return tep_crypto_b64url_buf;
}

/* base64url-decode, NUL-terminated. Decoded NUL bytes truncate the
 * C-string view -- fine for JWT JSON payloads (no NULs by
 * construction). */
static char tep_crypto_b64u_dec_buf[TEPC_B64U_BUFSIZE];

static int tep_crypto_b64u_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

const char *tep_crypto_b64url_decode(const char *src) {
    size_t n = strlen(src);
    /* Strip optional padding so callers can pass either RFC-7515
     * unpadded JWT segments or the rarer padded form. */
    while (n > 0 && src[n - 1] == '=') n--;
    size_t i = 0, j = 0;
    if (n / 4 * 3 + 3 > TEPC_B64U_BUFSIZE) {
        tep_crypto_b64u_dec_buf[0] = '\0';
        return tep_crypto_b64u_dec_buf;
    }
    while (i + 4 <= n) {
        int a = tep_crypto_b64u_val(src[i]);
        int b = tep_crypto_b64u_val(src[i+1]);
        int c = tep_crypto_b64u_val(src[i+2]);
        int d = tep_crypto_b64u_val(src[i+3]);
        if (a < 0 || b < 0 || c < 0 || d < 0) {
            tep_crypto_b64u_dec_buf[0] = '\0';
            return tep_crypto_b64u_dec_buf;
        }
        uint32_t v = (uint32_t)a << 18 | (uint32_t)b << 12
                   | (uint32_t)c <<  6 | (uint32_t)d;
        tep_crypto_b64u_dec_buf[j++] = (v >> 16) & 0xff;
        tep_crypto_b64u_dec_buf[j++] = (v >>  8) & 0xff;
        tep_crypto_b64u_dec_buf[j++] =  v        & 0xff;
        i += 4;
    }
    size_t rem = n - i;
    if (rem == 2) {
        int a = tep_crypto_b64u_val(src[i]);
        int b = tep_crypto_b64u_val(src[i+1]);
        if (a < 0 || b < 0) { tep_crypto_b64u_dec_buf[0] = '\0'; return tep_crypto_b64u_dec_buf; }
        tep_crypto_b64u_dec_buf[j++] = (a << 2) | (b >> 4);
    } else if (rem == 3) {
        int a = tep_crypto_b64u_val(src[i]);
        int b = tep_crypto_b64u_val(src[i+1]);
        int c = tep_crypto_b64u_val(src[i+2]);
        if (a < 0 || b < 0 || c < 0) { tep_crypto_b64u_dec_buf[0] = '\0'; return tep_crypto_b64u_dec_buf; }
        tep_crypto_b64u_dec_buf[j++] = (a << 2) | (b >> 4);
        tep_crypto_b64u_dec_buf[j++] = ((b & 0xf) << 4) | (c >> 2);
    }
    tep_crypto_b64u_dec_buf[j] = '\0';
    return tep_crypto_b64u_dec_buf;
}

/* ---------- PBKDF2-HMAC-SHA256 ----------
 * Derives 32 bytes (one SHA256 block) and base64url-encodes them
 * into a 43-char unpadded string. dkLen > 32 isn't supported here
 * (Tep::Password always derives 32).
 */
static char tep_crypto_pbkdf2_b64url_buf[44];

const char *tep_crypto_pbkdf2_sha256_b64url(const char *password, const char *salt, int iters) {
    if (iters < 1) iters = 1;
    size_t plen = strlen(password);
    size_t slen = strlen(salt);
    /* salt || INT(1) -- single block. */
    uint8_t salted[256];
    if (slen + 4 > sizeof(salted)) {
        tep_crypto_pbkdf2_b64url_buf[0] = '\0';
        return tep_crypto_pbkdf2_b64url_buf;
    }
    memcpy(salted, salt, slen);
    salted[slen+0] = 0;
    salted[slen+1] = 0;
    salted[slen+2] = 0;
    salted[slen+3] = 1;
    uint8_t U[32], T[32];
    tep_crypto_hmac_sha256((const uint8_t *)password, plen, salted, slen + 4, U);
    memcpy(T, U, 32);
    int it;
    for (it = 1; it < iters; it++) {
        tep_crypto_hmac_sha256((const uint8_t *)password, plen, U, 32, U);
        int b;
        for (b = 0; b < 32; b++) T[b] ^= U[b];
    }
    int i, j = 0;
    for (i = 0; i + 3 <= 32; i += 3) {
        uint32_t v = ((uint32_t)T[i] << 16)
                   | ((uint32_t)T[i+1] << 8)
                   | (uint32_t)T[i+2];
        tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[(v >> 6)  & 0x3f];
        tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[v & 0x3f];
    }
    if (i < 32) {
        uint32_t v = ((uint32_t)T[i] << 16)
                   | (i + 1 < 32 ? ((uint32_t)T[i+1] << 8) : 0);
        tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        if (i + 1 < 32) {
            tep_crypto_pbkdf2_b64url_buf[j++] = TEPC_B64U[(v >> 6) & 0x3f];
        }
    }
    tep_crypto_pbkdf2_b64url_buf[j] = '\0';
    return tep_crypto_pbkdf2_b64url_buf;
}

/* ---------- CSPRNG ----------
 * Random bytes, base64url-encoded. Used for password salts and
 * other unpredictable tokens. `nbytes` clamped to 64 (88 chars
 * b64url -- enough for a 512-bit secret).
 */
static char tep_crypto_random_b64url_buf[90];

const char *tep_crypto_random_b64url(int nbytes) {
    if (nbytes < 1) nbytes = 16;
    if (nbytes > 64) nbytes = 64;
    uint8_t r[64];
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    arc4random_buf(r, nbytes);
#else
    /* /dev/urandom is universal; getrandom() would need extra
     * feature-test dance for an identical guarantee. */
    FILE *f = fopen("/dev/urandom", "rb");
    if (f) {
        fread(r, 1, nbytes, f);
        fclose(f);
    } else {
        /* Last-ditch: time-mixed -- not cryptographically secure
         * but better than zeros. Modern systems never reach this. */
        time_t t = time(NULL);
        for (int k = 0; k < nbytes; k++) r[k] = (uint8_t)(t >> (k * 7));
    }
#endif
    int i, j = 0;
    for (i = 0; i + 3 <= nbytes; i += 3) {
        uint32_t v = ((uint32_t)r[i] << 16)
                   | ((uint32_t)r[i+1] << 8)
                   | (uint32_t)r[i+2];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 6)  & 0x3f];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[v & 0x3f];
    }
    int rem = nbytes - i;
    if (rem == 1) {
        uint32_t v = (uint32_t)r[i] << 16;
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
    } else if (rem == 2) {
        uint32_t v = ((uint32_t)r[i] << 16)
                   | ((uint32_t)r[i+1] << 8);
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 18) & 0x3f];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 12) & 0x3f];
        tep_crypto_random_b64url_buf[j++] = TEPC_B64U[(v >> 6) & 0x3f];
    }
    tep_crypto_random_b64url_buf[j] = '\0';
    return tep_crypto_random_b64url_buf;
}
