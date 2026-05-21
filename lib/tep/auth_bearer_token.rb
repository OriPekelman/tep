# Tep::AuthBearerToken -- JWT-HS256 bearer-token provider for the
# Auth battery. Sniffs `Authorization: Bearer <token>`, verifies
# the signature with the app's configured secret, decodes the
# flat-JSON payload, and builds a Tep::Identity (with optional
# Tep::AgentDelegation when the token represents an agent).
#
# Configuration:
#
#   Tep::AuthBearerToken.set_secret(ENV["JWT_SECRET"])
#
# Token payload schema (flat JSON, single level -- matches
# Tep::Json's flat-object extraction surface):
#
#   {
#     "sub":      "user:42",                    # principal_id (required)
#     "exp":      1716396000,                   # unix epoch seconds
#     "caps":     "read,write,post_summary",    # comma-separated symbols
#     "delegate": "summarizer-bot|1716392400|1716396000|token"
#                                               # optional; presence flips
#                                               # the identity to an agent.
#                                               # Format:
#                                               # agent_id|issued_at|expires_at|origin
#   }
#
# Why flat (not nested `acting_via: { ... }`): Tep::Json today
# extracts flat keys only. A nested-object getter is a separate
# tiny battery; for v1 of Auth the flat pipe-encoded delegate
# string is the smallest thing that ships and round-trips
# cleanly. The Identity / AgentDelegation Ruby surface stays
# nested -- the encoding is only on the wire.
#
# Why a flat top-level class name (not Tep::Auth::BearerToken):
# two-level namespacing on classes carries spinel cls_id risk
# (see memory note [[spinel_widening_dispatch]]). The Tep::Auth
# module owns the conceptual grouping; the class itself lives at
# Tep:: level so dispatch is shallow.
module Tep
  class AuthBearerToken
    # Set the shared HMAC secret. Apps call once at boot.
    def self.set_secret(s)
      Tep::APP.set_auth_bearer_secret(s)
      0
    end

    # Attempt to identify the request. Returns a Tep::Identity on
    # successful verification, nil if no Bearer header / bad
    # signature / expired / malformed payload.
    def self.try(req)
      header = req.req_headers["authorization"]
      if header.length < 8 || header[0, 7] != "Bearer "
        return nil
      end
      token = header[7, header.length - 7]

      secret = Tep::APP.auth_bearer_secret
      if secret.length == 0
        return nil
      end

      payload = Tep::Jwt.verify_and_decode(token, secret)
      if payload.length == 0
        return nil
      end

      # Check expiry first -- a token whose exp passed gets rejected
      # even if the signature still verifies. exp is unix epoch sec.
      exp = Tep::Json.get_int(payload, "exp")
      if exp > 0 && Time.now.to_i >= exp
        return nil
      end

      sub = Tep::Json.get_str(payload, "sub")
      if sub.length == 0
        return nil
      end

      caps_str = Tep::Json.get_str(payload, "caps")
      caps = Tep::AuthBearerToken.parse_caps(caps_str)

      delegate_str = Tep::Json.get_str(payload, "delegate")
      delegation = Tep::AuthBearerToken.parse_delegate(delegate_str)

      Tep::Identity.new(sub, delegation, caps)
    end

    # "read,write,post_summary" -> [:read, :write, :post_summary]
    def self.parse_caps(s)
      caps = [:_seed]
      caps.delete_at(0)
      if s.length == 0
        return caps
      end
      s.split(",").each do |name|
        if name.length > 0
          caps.push(name.to_sym)
        end
      end
      caps
    end

    # "agent_id|issued_at|expires_at|origin" -> AgentDelegation, or
    # nil for empty / malformed. The four-segment pipe encoding
    # avoids the nested-JSON limitation; pipes don't appear in
    # agent ids (we constrain the issuance side).
    #
    # `.to_s` on parts[0] is a no-op type-witness for spinel:
    # without it the inference for the first AgentDelegation arg
    # widens to mrb_int in some larger-codebase compile paths (no
    # other call site constrains agent_id to a String), and the
    # generated C compares pointer-to-int.
    def self.parse_delegate(s)
      if s.length == 0
        return nil
      end
      parts = s.split("|")
      if parts.length < 4
        return nil
      end
      agent_id   = parts[0].to_s
      issued_at  = parts[1].to_i
      expires_at = parts[2].to_i
      origin     = parts[3].to_sym
      Tep::AgentDelegation.new(agent_id, issued_at, expires_at, origin)
    end
  end
end
