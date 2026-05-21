# Tep::PresenceEntry -- one row in the Tep::Presence registry.
#
# Represents one (principal, session, topic) tracking, plus the
# optional structured-status + agent-delegation metadata that
# makes Presence agent-aware. Multiple entries with the same
# principal_id under one topic are normal: a human in three
# browser tabs (kind=:human, three different fds), plus their
# delegated summarizer-bot (kind=:agent_for, agent_id set,
# separate fd) -- five entries, one principal.
#
# fd is the underlying socket file descriptor (typically the
# accepted WS socket). It's the session-id surrogate: each WS
# connection has its own fd, so fd uniquely identifies a session
# within a worker. The framework's WS close hook calls
# Tep::Presence.untrack_by_fd(fd) to clear all entries when the
# connection closes.
#
# `since` is unix epoch seconds at track time. Useful for "online
# for N minutes" UI labels.
#
# Status fields encode Tep::PresenceStatus inline (a separate
# wrapper class would force a nested struct and complicate
# spinel's PtrArray<PresenceEntry> dispatch). Status defaults to
# (:available, "", 0) at track time; apps update via
# Tep::Presence.set_status.
module Tep
  class PresenceEntry
    attr_reader :topic         # String
    attr_reader :principal_id  # String, opaque
    attr_reader :kind          # Symbol: :human | :agent_for
    attr_reader :agent_id      # String, empty when kind == :human
    attr_reader :fd            # Integer, session-id surrogate
    attr_reader :since         # Integer unix epoch seconds
    # Structured-status fields (see docs/BATTERIES-DESIGN.md +
    # memory presence_status). state ∈ :available | :busy | :blocked.
    attr_accessor :status_state
    attr_accessor :status_note
    attr_accessor :status_until

    def initialize(topic, principal_id, kind, agent_id, fd, since)
      @topic         = topic
      @principal_id  = principal_id
      @kind          = kind
      @agent_id      = agent_id
      @fd            = fd
      @since         = since
      @status_state  = :available
      @status_note   = ""
      @status_until  = 0
    end
  end
end
