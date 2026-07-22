# Tep::AuthOAuth2Client -- one entry in the OAuth2 client registry.
# Represents a "bot" / "agent" / "automation client" that can be
# delegated permissions to act on behalf of a human principal via
# the OAuth2-style authorization-code flow.
#
# Created by Tep::AuthOAuth2.register_client. Apps don't typically
# instantiate this directly -- the registry takes
# (client_id, name, redirect_uri, allowed_caps) and stores the
# resulting Client.
#
# `allowed_caps` is the MAXIMUM set of capabilities this client
# can ever be granted. At consent time the human grants a subset
# (or all) of these to the specific code being issued. The granted
# set on the eventual JWT is always a subset of allowed_caps.
module Tep
  class AuthOAuth2Client
    attr_reader :client_id        # String, opaque (e.g. "summarizer-bot")
    attr_reader :name             # Human-readable display name for consent UI
    attr_reader :redirect_uri     # Where to redirect with ?code=... after consent
    attr_reader :allowed_caps     # Array of symbols (ceiling on granted caps)

    def initialize(client_id, name, redirect_uri, allowed_caps)
      @client_id     = client_id
      @name          = name
      @redirect_uri  = redirect_uri
      @allowed_caps  = allowed_caps
    end
  end
end
