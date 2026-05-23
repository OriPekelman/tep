# Tep::Auth -- the entry point for the Auth battery.
#
# Sets `req.identity` (a Tep::Identity) on every request, populated
# by walking a fixed provider chain. Three providers ship:
# Tep::AuthBearerToken (JWT HS256), Tep::AuthSessionCookie
# (signed cookie), Tep::AuthOAuth2 (delegated-grant exchange).
# Each one extends the chain by editing Tep::Auth.identify
# (rather than via a runtime registry, because spinel's
# PtrArray<Base> dispatch can't carry cls_id across heterogeneous
# Provider subclasses -- see memory [[spinel_widening_dispatch]]).
# Once spinel resolves the cls_id story the design doc's
# Tep::Auth.providers.add(...) API will land; until then the
# fixed-chain shape stays.
#
# Install pattern:
#
#   require 'sinatra'
#   Tep::AuthBearerToken.set_secret(ENV["JWT_SECRET"])
#   Tep::Auth.install!
#
#   # In handlers, req.identity is always populated -- either with
#   # the bearer's identity or with Tep::Identity.anonymous.
#   get '/me' do
#     req.identity.subject
#   end
#
# The auth filter is a SEPARATE slot from the user-installed
# before-filter (see Tep::App#auth_filter). Both run, in order:
# auth-filter first (populates req.identity), then user
# before-filter (sees a fully-populated identity). This avoids the
# "one filter slot" composition tax tep otherwise imposes.
module Tep
  module Auth
    CORE_CAPABILITIES = [:read, :write, :authn, :authz]

    # Walk the provider chain. First provider that returns a non-nil
    # Identity wins. Returns nil if no provider matched -- caller is
    # responsible for substituting Tep::Identity.anonymous.
    #
    # Order: BearerToken first (an explicit Authorization header is
    # a stronger signal of caller intent than a passively-replayed
    # cookie), then SessionCookie. Apps that want cookie-wins-bearer
    # semantics can post-process req.identity in a before-filter.
    def self.identify(req)
      ident = Tep::AuthBearerToken.try(req)
      if ident != nil
        return ident
      end
      ident = Tep::AuthSessionCookie.try(req)
      if ident != nil
        return ident
      end
      nil
    end

    # Replaces the app's auth-filter slot with the real
    # populate-req.identity filter. Idempotent.
    def self.install!
      Tep::APP.set_auth_filter(Tep::AuthFilter.new)
      0
    end
  end

  # The before-filter that runs the provider chain and writes the
  # result to req.identity. Lives at top level (not Tep::Auth::Filter)
  # to keep dispatch simple under spinel.
  class AuthFilter < Tep::Filter
    def before(req, res)
      ident = Tep::Auth.identify(req)
      if ident == nil
        req.identity = Tep::Identity.anonymous
      else
        req.identity = ident
      end
      0
    end
  end
end
