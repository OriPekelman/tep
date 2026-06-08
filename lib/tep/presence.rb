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
# Local storage is per-process (Tep::APP) for the fast list /
# count read path. Cross-worker visibility goes through PG --
# Tep::Presence.enable_pg_mirror writes each track/untrack/
# set_status as an UPSERT/DELETE; list_global pulls the union.
# Apps that don't need cross-worker snapshots run single-worker
# or skip the mirror entirely.
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
      Tep::Presence.mirror_insert(entry)
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
          Tep::Presence.mirror_delete(topic, fd)
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
          Tep::Presence.mirror_delete(e.topic, fd)
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
      Tep::Presence.mirror_status(topic, fd, state, note, until_ts)
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
    # "join" / "leave" / "status". SpinelKit::Json's flat-object
    # extractors handle this on the client side (or any
    # JSON-aware peer).
    def self.encode_diff(kind, entry)
      "{" +
        SpinelKit::Json.encode_pair_str("kind", kind) + "," +
        SpinelKit::Json.encode_pair_str("topic", entry.topic) + "," +
        SpinelKit::Json.encode_pair_str("principal", entry.principal_id) + "," +
        SpinelKit::Json.encode_pair_str("ekind", entry.kind.to_s) + "," +
        SpinelKit::Json.encode_pair_str("agent_id", entry.agent_id) + "," +
        SpinelKit::Json.encode_pair_int("fd", entry.fd) + "," +
        SpinelKit::Json.encode_pair_int("since", entry.since) + "," +
        SpinelKit::Json.encode_pair_str("state", entry.status_state.to_s) + "," +
        SpinelKit::Json.encode_pair_str("note", entry.status_note) + "," +
        SpinelKit::Json.encode_pair_int("until_ts", entry.status_until) +
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

    # ---- PG mirror (cross-worker visibility) ----
    #
    # Opt-in mirror of the local presence registry to a shared PG
    # table. Each worker's track/untrack/set_status writes also
    # touch the table; list_global / count_global read across all
    # workers. The local registry stays the fast read path for
    # per-worker queries (list / count); list_global is for the
    # "who's globally in this room" snapshot that's typically a
    # one-shot UI render.
    #
    # Worker ID is PID + boot epoch second so a same-PID restart
    # doesn't alias a prior worker's stale rows. On
    # disable_pg_mirror (or clean shutdown), this worker's rows
    # get DELETE'd. Crashed workers leave stale rows; the
    # heartbeat + prune_stale_workers pair below handles the
    # garbage-collection.
    #
    # Returns 0 on success, -1 on connect / schema failure.
    def self.enable_pg_mirror(conninfo)
      conn = PG::Connection.new(conninfo)
      if conn.pgh < 0
        return -1
      end
      # exec raises PG::Error on failure now; degrade gracefully
      # (close + return -1) rather than letting it escape the worker.
      begin
        r = conn.exec(Tep::Presence.schema_sql)
        r.clear
        # Heartbeat table for the prune-stale-workers path (#47).
        r = conn.exec(Tep::Presence.worker_schema_sql)
        r.clear
      rescue PG::Error
        conn.finish
        return -1
      end
      Tep::APP.set_presence_pg_conn(conn)
      worker_id = Sock.sphttp_getpid.to_s + "-" + Time.now.to_i.to_s
      Tep::APP.set_presence_pg_worker_id(worker_id)
      Tep::APP.set_presence_pg_enabled(1)
      # Drop any rows from a prior worker that managed to leave
      # stale entries with this same worker_id (unlikely thanks
      # to the boot-epoch suffix, but defensive). Best-effort.
      Tep::Presence.mirror_exec(
        "DELETE FROM tep_presence WHERE worker_id = $1",
        [worker_id])
      # Register this worker's heartbeat row immediately. Apps
      # refresh it periodically via Tep::Presence.heartbeat;
      # prune_stale_workers deletes rows whose heartbeat is stale.
      Tep::Presence.heartbeat
      0
    end

    def self.disable_pg_mirror
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      # Best-effort cleanup -- swallow PG errors (we're tearing the
      # mirror down regardless) and still finish + disable below.
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "DELETE FROM tep_presence WHERE worker_id = $1",
          [Tep::APP.presence_pg_worker_id])
        r.clear
        # Remove the heartbeat row so prune_stale_workers doesn't
        # see this worker as live after we're gone.
        r = Tep::APP.presence_pg_conn.exec_params(
          "DELETE FROM tep_presence_worker WHERE worker_id = $1",
          [Tep::APP.presence_pg_worker_id])
        r.clear
      rescue PG::Error
        # swallow -- shutting the mirror down anyway
      end
      Tep::APP.presence_pg_conn.finish
      Tep::APP.set_presence_pg_enabled(0)
      0
    end

    # CREATE TABLE statement, kept here so apps that want to
    # provision the schema separately (migration runners, etc.)
    # can grab the canonical DDL. Idempotent via IF NOT EXISTS.
    def self.schema_sql
      "CREATE TABLE IF NOT EXISTS tep_presence (" +
        "worker_id    TEXT NOT NULL, " +
        "topic        TEXT NOT NULL, " +
        "fd           INTEGER NOT NULL, " +
        "principal_id TEXT NOT NULL, " +
        "kind         TEXT NOT NULL, " +
        "agent_id     TEXT NOT NULL, " +
        "since_ts     BIGINT NOT NULL, " +
        "status_state TEXT NOT NULL, " +
        "status_note  TEXT NOT NULL, " +
        "status_until BIGINT NOT NULL, " +
        "PRIMARY KEY (worker_id, topic, fd)" +
      ")"
    end

    # Heartbeat table -- one row per worker that's mirroring
    # presence right now. Used by prune_stale_workers to identify
    # crashed workers (no heartbeat updates in N seconds) and
    # garbage-collect their orphan tep_presence rows.
    def self.worker_schema_sql
      "CREATE TABLE IF NOT EXISTS tep_presence_worker (" +
        "worker_id    TEXT PRIMARY KEY, " +
        "last_seen_ts BIGINT NOT NULL" +
      ")"
    end

    # Refresh this worker's heartbeat row to the current Unix
    # timestamp. Apps call this periodically (typical: from a
    # before-filter, a Tep::Job tick, or an explicit timer fiber)
    # so prune_stale_workers can tell live workers from crashed
    # ones. No-op when the PG mirror isn't enabled, or when the
    # mirror was opened on a different process and we're the
    # post-fork child (worker_id is empty until enable_pg_mirror
    # runs locally).
    #
    # Returns 1 if the heartbeat row was upserted, 0 if the call
    # short-circuited (mirror disabled or no worker_id).
    def self.heartbeat
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      wid = Tep::APP.presence_pg_worker_id
      if wid.length == 0
        return 0
      end
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "INSERT INTO tep_presence_worker (worker_id, last_seen_ts) " +
          "VALUES ($1, $2) " +
          "ON CONFLICT (worker_id) DO UPDATE SET " +
          "  last_seen_ts = EXCLUDED.last_seen_ts",
          [wid, Time.now.to_i.to_s])
        r.clear
      rescue PG::Error
        return 0
      end
      1
    end

    # Prune crashed-worker rows. Deletes:
    #   1. tep_presence_worker rows whose last_seen_ts is older than
    #      ttl_seconds (the worker's heartbeat is stale).
    #   2. tep_presence rows whose worker_id has no surviving
    #      heartbeat (orphans left by the crashed worker).
    #
    # Apps call this periodically -- the canonical shape is a
    # before-filter on a "/health" route that internal monitoring
    # hits every 30s, or a Tep::Job that fires from a cron-like
    # tick. Returns the number of tep_presence rows deleted.
    #
    # ttl_seconds should be at least 3x the app's typical
    # heartbeat interval so a transient slow response doesn't
    # evict a live worker. Default callers pass 90 (assumes 30s
    # heartbeats).
    def self.prune_stale_workers(ttl_seconds)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      cutoff = Time.now.to_i - ttl_seconds
      conn = Tep::APP.presence_pg_conn
      begin
        # Drop dead heartbeats first; the second DELETE then walks
        # the worker_id space that's still alive.
        r1 = conn.exec_params(
          "DELETE FROM tep_presence_worker WHERE last_seen_ts < $1",
          [cutoff.to_s])
        r1.clear
        # Now drop presence rows whose worker_id isn't in the live
        # heartbeat table. NOT IN handles both crashed-and-pruned
        # workers and workers that never registered (legacy rows
        # from before this prune feature shipped).
        r2 = conn.exec(
          "DELETE FROM tep_presence " +
          "WHERE worker_id NOT IN (SELECT worker_id FROM tep_presence_worker)")
        n = r2.cmd_tuples
        r2.clear
      rescue PG::Error
        return 0
      end
      n
    end

    # Best-effort mirror write: run an exec_params on the mirror conn
    # and swallow any PG::Error. The PG mirror is advisory -- local
    # presence is authoritative -- so a transient mirror failure must
    # never propagate into the caller's request now that exec raises
    # (matz/spinel#627 + #1041). Always returns 0.
    def self.mirror_exec(sql, params)
      begin
        r = Tep::APP.presence_pg_conn.exec_params(sql, params)
        r.clear
      rescue PG::Error
        # swallow -- advisory mirror, local presence is authoritative
      end
      0
    end

    # Mirror a track to PG. Called from track() when the PG
    # mirror is enabled.
    def self.mirror_insert(entry)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      Tep::Presence.mirror_exec(
        "INSERT INTO tep_presence " +
        "(worker_id, topic, fd, principal_id, kind, agent_id, " +
        " since_ts, status_state, status_note, status_until) " +
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) " +
        "ON CONFLICT (worker_id, topic, fd) DO UPDATE SET " +
        "  principal_id = EXCLUDED.principal_id, " +
        "  kind         = EXCLUDED.kind, " +
        "  agent_id     = EXCLUDED.agent_id, " +
        "  since_ts     = EXCLUDED.since_ts, " +
        "  status_state = EXCLUDED.status_state, " +
        "  status_note  = EXCLUDED.status_note, " +
        "  status_until = EXCLUDED.status_until",
        [
          Tep::APP.presence_pg_worker_id,
          entry.topic,
          entry.fd.to_s,
          entry.principal_id,
          entry.kind.to_s,
          entry.agent_id,
          entry.since.to_s,
          entry.status_state.to_s,
          entry.status_note,
          entry.status_until.to_s
        ])
    end

    # Mirror an untrack to PG.
    def self.mirror_delete(topic, fd)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      Tep::Presence.mirror_exec(
        "DELETE FROM tep_presence " +
        "WHERE worker_id = $1 AND topic = $2 AND fd = $3",
        [Tep::APP.presence_pg_worker_id, topic, fd.to_s])
    end

    # Mirror a status update.
    def self.mirror_status(topic, fd, state, note, until_ts)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      Tep::Presence.mirror_exec(
        "UPDATE tep_presence " +
        "SET status_state = $4, status_note = $5, status_until = $6 " +
        "WHERE worker_id = $1 AND topic = $2 AND fd = $3",
        [Tep::APP.presence_pg_worker_id, topic, fd.to_s,
         state.to_s, note, until_ts.to_s])
    end

    # Cross-worker list: SELECT all entries on `topic` regardless
    # of which worker tracked them. Returns Array[PresenceEntry]
    # built from the PG rows. The returned entries are read-only
    # snapshots -- mutating them doesn't write back to PG.
    def self.list_global(topic)
      result = [Tep::PresenceEntry.new("", "", :human, "", -1, 0)]
      result.delete_at(0)
      if Tep::APP.presence_pg_enabled == 0
        return result
      end
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "SELECT principal_id, kind, agent_id, fd, since_ts, " +
          "       status_state, status_note, status_until " +
          "FROM tep_presence WHERE topic = $1 ORDER BY since_ts",
          [topic])
      rescue PG::Error
        return result
      end
      i = 0
      n = r.ntuples
      while i < n
        kind_sym = :human
        if r.getvalue(i, 1) == "agent_for"
          kind_sym = :agent_for
        end
        state_sym = :available
        sstr = r.getvalue(i, 5)
        if sstr == "busy"
          state_sym = :busy
        elsif sstr == "blocked"
          state_sym = :blocked
        end
        e = Tep::PresenceEntry.new(
          topic,
          r.getvalue(i, 0),
          kind_sym,
          r.getvalue(i, 2),
          r.getvalue(i, 3).to_i,
          r.getvalue(i, 4).to_i)
        e.status_state = state_sym
        e.status_note  = r.getvalue(i, 6)
        e.status_until = r.getvalue(i, 7).to_i
        result.push(e)
        i += 1
      end
      r.clear
      result
    end

    def self.count_global(topic)
      if Tep::APP.presence_pg_enabled == 0
        return 0
      end
      begin
        r = Tep::APP.presence_pg_conn.exec_params(
          "SELECT count(*) FROM tep_presence WHERE topic = $1",
          [topic])
      rescue PG::Error
        return 0
      end
      n = r.getvalue(0, 0).to_i
      r.clear
      n
    end
  end
end
