# Tep::AuthSessionCookie -- the SessionCookie provider for the Auth
# battery. Reads identity fields off the signed session cookie that
# Tep::Session already round-trips through Tep::App#dispatch.
#
# Configuration:
#
#   Tep.session_secret = ENV["TEP_SESSION_SECRET"]
#   Tep::Auth.install!     # enables both Bearer + SessionCookie
#
# Identity in the session is stored as four keys (identity_sub /
# identity_caps / identity_delegate / identity_exp). The whole
# cookie is HMAC-signed (Tep::Session's existing payload+sig
# format), so forgery requires the secret. The identity payload IS
# visible to the client -- the cookie is signed, not encrypted --
# so don't put secrets in caps or in the delegate fields. Standard
# session-cookie tradeoff.
#
# Login / logout:
#
#   post '/login' do
#     # ... verify the user's password / OAuth handshake / etc ...
#     ident = Tep::Identity.new("user:42", nil, [:read, :write])
#     Tep::AuthSessionCookie.set(req, ident)
#     # The session will be re-signed + emitted via Set-Cookie by
#     # tep's normal session lifecycle (App#dispatch end).
#     ""
#   end
#
#   post '/logout' do
#     Tep::AuthSessionCookie.clear(req)
#     ""
#   end
#
# Provider-chain order: tried AFTER Tep::AuthBearerToken in
# Tep::Auth.identify. Bearer wins if both present, on the
# principle that an explicit Authorization header is a stronger
# signal of caller intent than a passively-replayed cookie.
#
# Flat namespacing (Tep::AuthSessionCookie, not
# Tep::Auth::SessionCookie) mirrors Tep::AuthBearerToken for the
# same spinel cls_id reasons -- see memory note
# [[spinel_widening_dispatch]].
module Tep
  class AuthSessionCookie
    # Write an Identity into req.session. Caller is responsible for
    # ensuring Tep.session_secret is configured -- otherwise the
    # response cookie won't get signed and the next request can't
    # round-trip the identity back.
    #
    # `exp` is unix epoch seconds; nil disables expiry (the cookie
    # itself still expires per its own Max-Age / Expires headers
    # or browser session lifetime).
    def self.set(req, identity, exp)
      req.session.set("identity_sub", identity.principal_id)
      req.session.set("identity_caps",
        Tep::AuthSessionCookie.format_caps(identity.capabilities))
      delegate = identity.acting_via
      if delegate == nil
        req.session.set("identity_delegate", "")
      else
        req.session.set("identity_delegate",
          Tep::AuthSessionCookie.format_delegate(delegate))
      end
      if exp > 0
        req.session.set("identity_exp", exp.to_s)
      else
        req.session.set("identity_exp", "")
      end
      0
    end

    # Drop the identity fields from req.session. The session itself
    # stays valid (signed cookie continues to round-trip), but any
    # subsequent try() returns nil because identity_sub is empty.
    def self.clear(req)
      req.session.set("identity_sub", "")
      req.session.set("identity_caps", "")
      req.session.set("identity_delegate", "")
      req.session.set("identity_exp", "")
      0
    end

    # Attempt to recover an Identity from req.session. Returns nil
    # if the session has no identity (no prior #set call, or after
    # #clear) or the stored identity is expired.
    def self.try(req)
      # Session#get on a missing key reads as nil (sinatra-parity Hash
      # semantics; same class as tep#235) -- guard before String calls.
      sub = req.session.get("identity_sub")
      sub = "" if sub.nil?
      if sub.length == 0
        return nil
      end

      exp_str = req.session.get("identity_exp")
      exp_str = "" if exp_str.nil?
      if exp_str.length > 0
        exp = exp_str.to_i
        if exp > 0 && Time.now.to_i >= exp
          return nil
        end
      end

      caps_str = req.session.get("identity_caps")
      caps_str = "" if caps_str.nil?
      caps = Tep::AuthBearerToken.parse_caps(caps_str)

      delegate_str = req.session.get("identity_delegate")
      delegate_str = "" if delegate_str.nil?
      delegation = Tep::AuthBearerToken.parse_delegate(delegate_str)

      Tep::Identity.new(sub, delegation, caps)
    end

    # [:read, :write, :post_summary] -> "read,write,post_summary"
    def self.format_caps(caps)
      out = ""
      first = true
      caps.each do |c|
        if !first
          out = out + ","
        end
        out = out + c.to_s
        first = false
      end
      out
    end

    # AgentDelegation -> "agent_id|issued_at|expires_at|origin".
    # Inverse of Tep::AuthBearerToken.parse_delegate.
    def self.format_delegate(deleg)
      deleg.agent_id + "|" +
        deleg.issued_at.to_s + "|" +
        deleg.expires_at.to_s + "|" +
        deleg.origin.to_s
    end
  end
end
