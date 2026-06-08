# Tep::AuthOAuth2 -- the OAuth2-style authorization-code issuance
# surface. tep here is the AUTHORIZATION SERVER (not the OAuth
# client) -- the entity that issues delegated-access tokens to
# bots / agents / automation clients on behalf of human users.
#
# Flow (apps wire their own /oauth/authorize + /oauth/token routes
# on top of these primitives):
#
#   1. Bot redirects the user to /oauth/authorize?client_id=summarizer-bot
#      &redirect_uri=...&caps=read,post_summary.
#   2. App's /authorize route looks up the client, checks the
#      caps subset against allowed_caps, renders a consent
#      screen ("summarizer-bot wants to act on your behalf...").
#   3. User clicks "Allow". App calls:
#        Tep::AuthOAuth2.issue_code(req.identity.principal_id,
#                                   client_id, caps_str, 600)
#      and redirects to the bot's redirect_uri with ?code=<code>.
#   4. Bot exchanges the code at /oauth/token:
#        Tep::AuthOAuth2.exchange_code(code, client_id)
#      which returns a JWT whose `delegate` field is populated
#      (acting_via on the resulting Tep::Identity).
#   5. Bot uses the JWT as a Bearer token. Tep::AuthBearerToken
#      parses it; req.identity is a delegated agent identity.
#
# The "agentic" framing: this is fundamentally OAuth2 with the
# semantic shift that the granted token represents an agent
# delegated by the user, not an "app" the user wants to share
# data with. The consent UI's wording (rendered by the app, not
# by tep) should make that clear to the user.
#
# Token issuance reuses Tep::Jwt + Tep::AuthBearerToken's wire
# format -- no new token schema. The downstream Identity surface
# is the same: `req.identity.agent?` is true, `acting_via.agent_id`
# is the client_id, `acting_via.origin` is :oauth_grant.
#
# Storage is per-process (Tep::APP attrs). High-fanout setups
# wanting cross-worker code redemption need a PG-backed extension;
# noted but not in scope for v1.
module Tep
  module AuthOAuth2
    # Default code TTL (seconds). Apps that need shorter / longer
    # pass an explicit ttl_seconds to issue_code.
    DEFAULT_CODE_TTL = 600

    # Default token TTL (seconds). The JWT exp claim is set to
    # `now + this`. Apps that need a different window pass an
    # explicit token_ttl_seconds to exchange_code.
    DEFAULT_TOKEN_TTL = 3600

    # Register a client (bot / agent / automation peer) with the
    # authorization server. Subsequent issue_code and exchange_code
    # calls reference it by client_id. Re-registering an existing
    # client_id replaces the prior entry.
    def self.register_client(client_id, name, redirect_uri, allowed_caps)
      Tep::AuthOAuth2.unregister_client(client_id)
      client = Tep::AuthOAuth2Client.new(
        client_id, name, redirect_uri, allowed_caps)
      Tep::APP.auth_oauth2_clients.push(client)
      0
    end

    def self.unregister_client(client_id)
      clients = Tep::APP.auth_oauth2_clients
      i = 0
      while i < clients.length
        if clients[i].client_id == client_id
          clients.delete_at(i)
          return 0
        end
        i += 1
      end
      0
    end

    def self.find_client(client_id)
      clients = Tep::APP.auth_oauth2_clients
      i = 0
      while i < clients.length
        if clients[i].client_id == client_id
          return clients[i]
        end
        i += 1
      end
      nil
    end

    # Mint a one-time code tied to (principal, client, granted_caps).
    # Caller (the app's /authorize handler) is responsible for
    # validating that granted_caps is a subset of the client's
    # allowed_caps before calling -- the issuance surface itself
    # trusts the caller.
    #
    # `caps_str` is comma-separated (matches Tep::AuthBearerToken's
    # wire format). `ttl_seconds` is the lifetime; pass 0 for
    # DEFAULT_CODE_TTL.
    #
    # Returns the opaque code string (base64url, ~32 chars).
    def self.issue_code(principal_id, client_id, caps_str, ttl_seconds)
      Tep::AuthOAuth2.sweep_expired_codes
      ttl = ttl_seconds
      if ttl <= 0
        ttl = DEFAULT_CODE_TTL
      end
      code = Crypto.sp_crypto_random_b64url(24)
      expires_at = Time.now.to_i + ttl
      rec = Tep::AuthOAuth2Code.new(
        code, principal_id, client_id, caps_str, expires_at)
      Tep::APP.auth_oauth2_codes.push(rec)
      code
    end

    # Redeem a code for a JWT. The code MUST have been issued for
    # this exact client_id (no cross-client redemption). Returns
    # the JWT string on success, "" on failure (unknown code,
    # client_id mismatch, expired, already-redeemed).
    #
    # The JWT is single-use against the registry: a successful
    # exchange_code removes the code from the registry.
    #
    # `token_ttl_seconds` is the JWT's exp lifetime; pass 0 for
    # DEFAULT_TOKEN_TTL.
    def self.exchange_code(code, client_id, token_ttl_seconds)
      Tep::AuthOAuth2.sweep_expired_codes
      codes = Tep::APP.auth_oauth2_codes
      idx = -1
      i = 0
      while i < codes.length
        if codes[i].code == code && codes[i].client_id == client_id
          idx = i
          i = codes.length
        else
          i += 1
        end
      end
      if idx < 0
        return ""
      end
      rec = codes[idx]
      codes.delete_at(idx)
      if rec.expired?(Time.now.to_i)
        return ""
      end
      Tep::AuthOAuth2.mint_jwt(rec, token_ttl_seconds)
    end

    # Build the JWT payload and sign it. Uses Tep::Jwt with the
    # same shared secret as Tep::AuthBearerToken, so apps don't
    # need to manage a second secret -- one HS256 secret signs all
    # tokens regardless of issuance path.
    def self.mint_jwt(rec, token_ttl_seconds)
      secret = Tep::APP.auth_bearer_secret
      if secret.length == 0
        return ""
      end
      ttl = token_ttl_seconds
      if ttl <= 0
        ttl = DEFAULT_TOKEN_TTL
      end
      now_ts = Time.now.to_i
      exp_ts = now_ts + ttl
      delegate_str = rec.client_id + "|" + now_ts.to_s + "|" +
                     exp_ts.to_s + "|oauth_grant"
      payload = "{" +
        SpinelKit::Json.encode_pair_str("sub", rec.principal_id) + "," +
        SpinelKit::Json.encode_pair_int("exp", exp_ts) + "," +
        SpinelKit::Json.encode_pair_str("caps", rec.caps_str) + "," +
        SpinelKit::Json.encode_pair_str("delegate", delegate_str) +
      "}"
      Tep::Jwt.encode_hs256(payload, secret)
    end

    # Walk the code registry, drop entries whose expires_at has
    # passed. Called on every issue / exchange so the registry
    # doesn't grow unboundedly even without explicit pruning.
    # Back-to-front so delete_at indices stay valid mid-loop.
    def self.sweep_expired_codes
      codes = Tep::APP.auth_oauth2_codes
      now_ts = Time.now.to_i
      i = codes.length - 1
      while i >= 0
        if codes[i].expired?(now_ts)
          codes.delete_at(i)
        end
        i -= 1
      end
      0
    end
  end
end
