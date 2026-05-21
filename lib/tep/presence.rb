# Tep::Presence -- topic-keyed who's-here registry.
#
# Battery 3 (Presence). Layers on req.identity (Battery 1) for
# the principal+delegate split and on the Broadcast pub-sub
# surface (Battery 2) for diff fan-out -- though in chunk 3.1
# diff broadcasting isn't wired yet; apps that want presence
# diffs build them on top of list() snapshots for now.
#
# Tracking model: one PresenceEntry per (principal, session,
# topic). `fd` doubles as the session-id surrogate, so a human
# with three browser tabs lands as three entries with kind=:human
# and three distinct fds. An agent acting on behalf of that
# human gets its own entry with kind=:agent_for and the agent_id
# populated -- four entries, one principal, one topic. This is
# the Phoenix.Presence shape extended with the agentic kind/
# agent_id pair.
#
# Storage scope is per-process (Tep::APP). Cross-worker
# visibility (PG-backed) lands in a follow-up chunk; v1 works
# best in single-worker prefork or app-internal contexts.
#
# Status handling: every entry carries a Tep::PresenceStatus
# inline (status_state / status_note / status_until on the
# entry). track() initializes status to :available; apps update
# via set_status / clear_status. Expiry (status_until) isn't
# auto-swept in chunk 3.1; the next chunk's diff loop will
# handle reset-on-expire alongside emit.
module Tep
  module Presence
    # Track a presence entry. principal_id comes off req.identity;
    # kind is :human or :agent_for depending on the identity's
    # delegation state. fd is the underlying connection's socket
    # (typically a WS-accepted fd). Returns 0 on success.
    #
    # Multiple track() calls for the same (principal, topic, fd)
    # are deduped: the existing entry stays, no second row is
    # created. Apps can call freely from before-filters /
    # reconnect paths without growing the registry.
    def self.track(req, topic, fd)
      ident = req.identity
      if Tep::Presence.find_entry(topic, fd) != nil
        return 0
      end
      kind = :human
      agent_id = ""
      if ident.agent?
        kind = :agent_for
        agent_id = ident.acting_via.agent_id
      end
      entry = Tep::PresenceEntry.new(
        topic, ident.principal_id, kind, agent_id, fd, Time.now.to_i)
      Tep::APP.presence_entries.push(entry)
      Tep::Presence.publish_diff("join", entry)
      0
    end

    # Drop the entry for (topic, fd). The fd is the unique key
    # within a topic; principal_id isn't needed. Returns 1 if an
    # entry was removed, 0 if none matched. Emits a "leave" diff
    # on the topic's presence channel when removal happens.
    def self.untrack(topic, fd)
      entries = Tep::APP.presence_entries
      i = 0
      while i < entries.length
        if entries[i].topic == topic && entries[i].fd == fd
          e = entries[i]
          entries.delete_at(i)
          Tep::Presence.publish_diff("leave", e)
          return 1
        end
        i += 1
      end
      0
    end

    # Drop every entry associated with `fd` (across all topics).
    # Used by the WS close hook to clean up everything a
    # connection had tracked. Returns the count dropped. Emits
    # one "leave" diff per dropped entry, on each entry's topic's
    # presence channel.
    def self.untrack_by_fd(fd)
      entries = Tep::APP.presence_entries
      dropped = 0
      i = entries.length - 1
      while i >= 0
        if entries[i].fd == fd
          e = entries[i]
          entries.delete_at(i)
          Tep::Presence.publish_diff("leave", e)
          dropped += 1
        end
        i -= 1
      end
      dropped
    end

    # All entries for `topic`. Caller groups by principal_id when
    # they want the Phoenix.Presence-style {principal => [metas]}
    # shape; tep doesn't pre-group because spinel's nested-hash
    # lowering is awkward.
    def self.list(topic)
      result = [Tep::PresenceEntry.new("", "", :human, "", -1, 0)]
      result.delete_at(0)
      entries = Tep::APP.presence_entries
      i = 0
      while i < entries.length
        if entries[i].topic == topic
          result.push(entries[i])
        end
        i += 1
      end
      result
    end

    # Total entries for `topic` (across all kinds).
    def self.count(topic)
      Tep::Presence.count_filtered(topic, :both)
    end

    def self.count_humans(topic)
      Tep::Presence.count_filtered(topic, :human)
    end

    def self.count_agents(topic)
      Tep::Presence.count_filtered(topic, :agent_for)
    end

    # Internal counting helper: `kind_filter` is :both for all
    # entries, otherwise :human or :agent_for to filter.
    def self.count_filtered(topic, kind_filter)
      entries = Tep::APP.presence_entries
      n = 0
      i = 0
      while i < entries.length
        if entries[i].topic == topic
          if kind_filter == :both
            n += 1
          elsif entries[i].kind == kind_filter
            n += 1
          end
        end
        i += 1
      end
      n
    end

    # Set the structured status on an existing entry. `state` ∈
    # {:available, :busy, :blocked}; `note` is free text (~140
    # char soft hint); `until_ts` is unix epoch seconds (0 = no
    # identity-level expiry). Returns 1 if the entry was found
    # and updated, 0 otherwise. Emits a "status" diff on the
    # topic's presence channel on update.
    def self.set_status(topic, fd, state, note, until_ts)
      entry = Tep::Presence.find_entry(topic, fd)
      if entry == nil
        return 0
      end
      entry.status_state = state
      entry.status_note  = note
      entry.status_until = until_ts
      Tep::Presence.publish_diff("status", entry)
      1
    end

    # Reset an entry's status back to :available / "" / 0.
    def self.clear_status(topic, fd)
      Tep::Presence.set_status(topic, fd, :available, "", 0)
    end

    # Internal: find the entry matching (topic, fd). Returns nil
    # if no match.
    def self.find_entry(topic, fd)
      entries = Tep::APP.presence_entries
      i = 0
      while i < entries.length
        if entries[i].topic == topic && entries[i].fd == fd
          return entries[i]
        end
        i += 1
      end
      nil
    end

    # Drop every entry. Used by tests between fixtures and
    # available to apps for graceful-shutdown cleanup. Returns
    # the count dropped. Does NOT emit leave diffs (it's a
    # registry-management op, not a per-connection event).
    def self.clear
      entries = Tep::APP.presence_entries
      n = entries.length
      while entries.length > 0
        entries.delete_at(0)
      end
      n
    end

    # ---- Diff broadcasting + auto-expiry ----

    # Compose the Broadcast topic for diff fan-out on a presence
    # topic. WS subscribers register via
    # Tep::Broadcast.subscribe_ws(diff_topic("room:lobby"), ws_fd).
    def self.diff_topic(topic)
      "presence:" + topic
    end

    # Flat-JSON wire format for a diff event. `kind` is one of
    # "join" / "leave" / "status". Tep::Json's flat-object
    # extractors handle this on the client side (or any
    # JSON-aware peer).
    def self.encode_diff(kind, entry)
      "{" +
        Tep::Json.encode_pair_str("kind", kind) + "," +
        Tep::Json.encode_pair_str("topic", entry.topic) + "," +
        Tep::Json.encode_pair_str("principal", entry.principal_id) + "," +
        Tep::Json.encode_pair_str("ekind", entry.kind.to_s) + "," +
        Tep::Json.encode_pair_str("agent_id", entry.agent_id) + "," +
        Tep::Json.encode_pair_int("fd", entry.fd) + "," +
        Tep::Json.encode_pair_int("since", entry.since) + "," +
        Tep::Json.encode_pair_str("state", entry.status_state.to_s) + "," +
        Tep::Json.encode_pair_str("note", entry.status_note) + "," +
        Tep::Json.encode_pair_int("until_ts", entry.status_until) +
      "}"
    end

    # Publish a diff via Tep::Broadcast. Subscribers to
    # diff_topic(entry.topic) -- typically WS connections via
    # subscribe_ws -- receive the encoded JSON payload as their
    # next message. Returns the local-match count from publish
    # (cross-worker delivery counts aren't tracked here, same
    # as Broadcast.publish's documented behavior).
    def self.publish_diff(kind, entry)
      payload = Tep::Presence.encode_diff(kind, entry)
      Tep::Broadcast.publish(
        Tep::Presence.diff_topic(entry.topic), payload)
    end

    # Sweep entries whose status_until has passed: reset to
    # :available / "" / 0 and emit a "status" diff for each.
    # Apps call this periodically (e.g. once per HTTP request,
    # or in a background fiber once Scheduled is reliable).
    # Returns the count of entries reset.
    def self.sweep_expired_status
      entries = Tep::APP.presence_entries
      now = Time.now.to_i
      swept = 0
      i = 0
      while i < entries.length
        e = entries[i]
        if e.status_until > 0 && e.status_until <= now && e.status_state != :available
          e.status_state = :available
          e.status_note  = ""
          e.status_until = 0
          Tep::Presence.publish_diff("status", e)
          swept += 1
        end
        i += 1
      end
      swept
    end
  end
end
