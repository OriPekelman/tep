# Tep::Password -- password hashing for spinel-AOT'd apps.
#
# Uses PBKDF2-HMAC-SHA256 with a 16-byte CSPRNG salt and a default
# of 200,000 iterations -- sits in the OWASP-recommended ballpark
# (200k for SHA256 as of 2023). Backed by a small C helper in
# sphttp.c; no libcrypt / OpenSSL / bcrypt-gem dependency.
#
# Why PBKDF2 instead of bcrypt?
# -----------------------------
# Bcrypt is the textbook choice but its canonical impls are either
# the system `crypt(3)` (not portable: macOS doesn't ship $2b$, Linux
# needs libxcrypt) or the bcrypt-ruby gem (a CRuby C extension that
# spinel can't load). PBKDF2-SHA256 is in NIST SP 800-132 and OWASP
# acceptable, builds on the HMAC-SHA256 we already ship for the
# session store, and adds zero new system dependencies.
#
# scrypt / argon2 would be stronger but require linking libsodium or
# vendoring ~2k lines of C. Defer until callers need them.
#
# Format
# ------
# Stored hash is `pbkdf2-sha256$<iters>$<salt_b64>$<derived_b64>`.
# All segments are base64url, no padding. Self-describing so a
# future rotation to higher iter counts (or a different scheme) can
# coexist with old hashes -- `verify` honours the embedded iter
# count.
#
# Usage
# -----
#
#   stored = Tep::Password.create("user-input")
#   # store `stored` in the DB
#
#   # On login:
#   if Tep::Password.verify("user-input", stored)
#     # session.set("uid", row_id)
#   end
module Tep
  class Password
    DEFAULT_ITERS = 200000
    SALT_BYTES    = 16

    # Derive a stored hash from a plain password. Generates a
    # fresh CSPRNG salt and runs PBKDF2-SHA256 at the default
    # iter count. Returns the self-describing storage string.
    #
    # Named `create` (and not `hash`) because `Object#hash` is the
    # Ruby hash-code method returning Integer. Spinel's per-method
    # type inference unifies same-named methods, so a `Password.hash`
    # signature would widen to `int`-returning everywhere via the
    # cross-class `.hash` dispatch.
    def self.create(plain)
      salt = Sock.sphttp_random_b64url(SALT_BYTES)
      derived = Sock.sphttp_pbkdf2_sha256_b64url(plain, salt, DEFAULT_ITERS)
      "pbkdf2-sha256$" + DEFAULT_ITERS.to_s + "$" + salt + "$" + derived
    end

    # Verify `plain` against a stored hash. Re-runs PBKDF2 with the
    # same salt + iter count embedded in the stored string and
    # constant-time compares. Rejects malformed stored hashes by
    # returning false.
    def self.verify(plain, stored)
      parts = Password.split4(stored)
      if parts[0] != "pbkdf2-sha256"
        return false
      end
      iters_s = parts[1]
      salt    = parts[2]
      derived = parts[3]
      if iters_s.length == 0 || salt.length == 0 || derived.length == 0
        return false
      end
      iters = iters_s.to_i
      if iters < 1
        return false
      end
      candidate = Sock.sphttp_pbkdf2_sha256_b64url(plain, salt, iters)
      Tep::Jwt.timing_safe_eq(candidate, derived)
    end

    # Split a 4-segment "$"-delimited stored hash into its four
    # parts. spinel's `String#split` exists but its behaviour on
    # complex inputs has tripped us before; the explicit walker
    # is small and obviously correct.
    def self.split4(s)
      out = ["", "", "", ""]
      n = s.length
      seg = 0
      start = 0
      i = 0
      while i < n
        if s[i] == "$"
          if seg < 4
            out[seg] = s[start, i - start]
          end
          seg += 1
          start = i + 1
        end
        i += 1
      end
      if seg < 4
        out[seg] = s[start, n - start]
      end
      out
    end
  end
end
