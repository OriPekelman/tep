# Tep::AgentDelegation -- the "on behalf of" half of a delegated
# identity. Carries the agent's own id (distinct from the human
# principal it acts for), the grant timestamps, and the origin
# label so audit logs can tell apart "issued via OAuth consent" vs
# "minted from a session handoff" vs "raw API token".
#
# Always paired with a Tep::Identity whose principal_id is the
# human being acted for. An Identity#human? has acting_via == nil;
# an Identity#agent? has acting_via populated with this struct.
#
# Lives in its own file so consumers that want the delegation
# vocabulary without the full Identity surface can require it
# narrowly.
module Tep
  class AgentDelegation
    attr_reader :agent_id     # String, e.g. "summarizer-bot"
    attr_reader :issued_at    # Integer (unix epoch seconds)
    attr_reader :expires_at   # Integer (unix epoch seconds)
    attr_reader :origin       # Symbol: :token, :oauth_grant, :session_handoff, ...

    def initialize(agent_id, issued_at, expires_at, origin)
      @agent_id   = agent_id
      @issued_at  = issued_at
      @expires_at = expires_at
      @origin     = origin
    end

    # `now` is unix epoch seconds (Time.now.to_i shape). Passed in
    # rather than read from Time.now so callers control the clock
    # source (and tests can fast-forward).
    def expired?(now)
      now >= @expires_at
    end
  end
end
