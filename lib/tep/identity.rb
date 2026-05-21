# Tep::Identity -- principal + delegate identity. Identifies who
# made a request and, optionally, the agent acting on their behalf.
#
# Set on `req.identity` by the Tep::Auth provider chain (see
# docs/BATTERIES-DESIGN.md for the full Auth surface). Consumers
# (Broadcast, Presence, LiveView) read req.identity and key authz
# decisions off #may?(cap) plus the human?/agent? split.
#
# Agentic shape: a "delegated" identity is one where a non-human
# agent (LLM-driven bot, scheduled worker, automation client)
# acts on behalf of a human principal. Both layers are visible:
#   - principal_id is the human (e.g. "user:42").
#   - acting_via.agent_id is the agent ("summarizer-bot").
# Authz checks via #may? gate on the granted capability set, which
# the issuer is expected to keep as a subset of the principal's
# own caps -- never a superset. The split lets app code branch
# tighter on req.identity (e.g. "only humans may revoke other
# agents") rather than treating every authenticated caller alike.
module Tep
  class Identity
    attr_reader :principal_id   # String, opaque to tep (apps own the format)
    attr_reader :acting_via     # Tep::AgentDelegation or nil
    attr_reader :capabilities   # Array of symbols

    def initialize(principal_id, acting_via, capabilities)
      @principal_id = principal_id
      @acting_via   = acting_via
      @capabilities = capabilities
    end

    # The unauthenticated identity. Used by the Tep::Auth before-
    # filter when no provider sniffed a credential off the request.
    # Apps that gate routes on identity check the principal_id ==
    # "" shape; #may? returns false for everything since the cap
    # array is empty.
    def self.anonymous
      seed = [:_seed]
      seed.delete_at(0)
      Identity.new("", nil, seed)
    end

    def human?
      @acting_via == nil
    end

    def agent?
      @acting_via != nil
    end

    def may?(cap)
      @capabilities.include?(cap)
    end

    # Audit-friendly string. Humans render as "user:<principal>";
    # agents render as "agent:<agent_id>/<principal>" -- the slash
    # makes the principal-of-record visible at a glance and is the
    # standard shape every log line and Broadcast `from` field
    # should carry.
    def subject
      if @acting_via == nil
        "user:" + @principal_id
      else
        "agent:" + @acting_via.agent_id + "/" + @principal_id
      end
    end
  end
end
