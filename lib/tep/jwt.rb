# Tep::Jwt -- HS256 JWT encode + decode + verify.
#
# Why bundle one? CRuby's `jwt` gem dispatches algorithms via
# runtime class registration (`JWT::Algos.find`) and uses
# `OpenSSL::HMAC` (a CRuby C extension). We can't load it through
# spinel.
#
# Tep already ships HMAC-SHA256 in tep_crypto.c (the session-cookie
# store uses it). The JWT spec on top of that is short:
# base64url-encoded JSON for header + payload, base64url-encoded
# 32-byte HMAC for the signature, joined by `.`.
#
# Surface
# -------
#
#   payload_json = "{" + Tep::Json.encode_pair_str("sub", user_id) + "," +
#                        Tep::Json.encode_pair_int("exp", exp_unix) + "}"
#   token = Tep::Jwt.encode_hs256(payload_json, secret)
#
#   # On the receiving side:
#   if Tep::Jwt.verify_hs256(token, secret)
#     payload = Tep::Jwt.decode_payload(token)   # the JSON string
#     sub = Tep::Json.get_str(payload, "sub")
#   end
#
# Scope
# -----
# **Algorithm:** HS256 only. ES256 / RS256 need RSA / ECDSA from
# OpenSSL; deferred until callers explicitly need asymmetric
# verification. The spec's `none` algorithm is intentionally not
# supported (forbidden in RFC 8725 §3.1).
#
# **Claims validation:** the `verify_hs256` only checks the
# signature. `exp` / `nbf` / `iss` / `aud` claim checks are left
# to caller code -- pull them with `Tep::Json.get_int(payload, "exp")`
# and compare against `Time.now.to_i`. This keeps the surface
# small and lets the app's policy decide what's required (some
# apps want skew tolerance, some want strict expiry).
#
# Constraints
# -----------
# **Constant header.** We always emit `{"alg":"HS256","typ":"JWT"}`
# (precomputed base64url constant). On decode we don't validate
# the header's alg, only the signature -- which is a deliberate
# choice that prevents algorithm-confusion attacks (no path that
# trusts the token's claimed alg).
module Tep
  class Jwt
    # base64url-encoded `{"alg":"HS256","typ":"JWT"}`.
    HEADER_B64U = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

    # Build a token from a JSON-encoded payload string and the
    # signing secret. Returns the three-segment `header.payload.sig`
    # string.
    def self.encode_hs256(payload_json, secret)
      payload_b64 = Crypto.sp_crypto_b64url_encode(payload_json)
      signing_input = HEADER_B64U + "." + payload_b64
      sig = Crypto.sp_crypto_hmac_sha256_b64url(secret, signing_input)
      signing_input + "." + sig
    end

    # Verify the signature on a token. Returns true / false. Does
    # NOT check claim semantics (exp / nbf / iss / aud).
    def self.verify_hs256(token, secret)
      d1 = token.index(".")
      if d1 < 0
        return false
      end
      d2 = token.index(".", d1 + 1)
      if d2 < 0
        return false
      end
      signing_input = token[0, d2]
      provided_sig = token[d2 + 1, token.length - d2 - 1]
      expected_sig = Crypto.sp_crypto_hmac_sha256_b64url(secret, signing_input)
      Jwt.timing_safe_eq(provided_sig, expected_sig)
    end

    # Pull the JSON-encoded payload back out of a token. No
    # signature verification -- call `verify_hs256` first if you
    # haven't, OR use the wrapped `verify_and_decode` form.
    def self.decode_payload(token)
      d1 = token.index(".")
      if d1 < 0
        return ""
      end
      d2 = token.index(".", d1 + 1)
      if d2 < 0
        return ""
      end
      payload_b64 = token[d1 + 1, d2 - d1 - 1]
      Crypto.sp_crypto_b64url_decode(payload_b64)
    end

    # One-shot: verify, then decode. Returns the JSON payload on
    # success, "" on bad signature / malformed token. Saves callers
    # an explicit early-return check.
    def self.verify_and_decode(token, secret)
      if !Jwt.verify_hs256(token, secret)
        return ""
      end
      Jwt.decode_payload(token)
    end

    # Constant-time string compare. Returns true iff strings are
    # byte-identical. Used so a token-signature mismatch leaks no
    # timing info about how many leading bytes matched.
    def self.timing_safe_eq(a, b)
      if a.length != b.length
        return false
      end
      diff = 0
      i = 0
      n = a.length
      while i < n
        diff = diff | (a.bytes[i] ^ b.bytes[i])
        i += 1
      end
      diff == 0
    end
  end
end
