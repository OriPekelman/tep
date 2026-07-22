# Tep::AuthOAuth2Code -- one entry in the short-lived
# authorization-code registry. Created by
# Tep::AuthOAuth2.issue_code at the moment a human consents to a
# specific (client, caps) grant; consumed by
# Tep::AuthOAuth2.exchange_code when the client redeems the code
# for a JWT.
#
# Codes are single-use and short-lived (typically 5-10 minutes).
# The registry sweeps expired entries on every lookup so
# memory doesn't accumulate even without explicit pruning.
#
# Storage scope is per-process: the registry lives on Tep::APP,
# which is per-worker under prefork. A bot redeeming a code MUST
# do so against the same worker that issued it. For most apps
# that's invisible (one human, one worker handling both the
# consent submission and the immediate redirect-then-redeem
# sequence), but high-fanout production setups will want
# cross-worker code storage (PG-backed) -- a future battery
# extension.
module Tep
  class AuthOAuth2Code
    attr_reader :code             # opaque base64url string
    attr_reader :principal_id     # the human granting access
    attr_reader :client_id        # which client this code was issued for
    attr_reader :caps_str         # comma-separated symbols (granted subset)
    attr_reader :expires_at       # unix epoch seconds; >= now means alive

    def initialize(code, principal_id, client_id, caps_str, expires_at)
      @code         = code
      @principal_id = principal_id
      @client_id    = client_id
      @caps_str     = caps_str
      @expires_at   = expires_at
    end

    def expired?(now)
      now >= @expires_at
    end
  end
end
