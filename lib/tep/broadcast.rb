# Tep::Broadcast -- in-process pub-sub topic broker.
#
# Foundation of the Broadcast battery (Battery 2 in
# docs/BATTERIES-DESIGN.md). Apps + later batteries (Presence,
# LiveView) layer on top: WebSocket connections subscribe to
# topics; publish(topic, payload) writes payload to every
# subscribed fd.
#
# Public API:
#
#   sub_id = Tep::Broadcast.subscribe(topic, fd)
#   Tep::Broadcast.publish(topic, payload)
#   Tep::Broadcast.unsubscribe(sub_id)
#   Tep::Broadcast.unsubscribe_fd(fd)    # drop ALL subs for an fd
#
# Subscription model is fd-based rather than block/callback-based
# (spinel can't reliably round-trip blocks-as-values across module
# boundaries, see memory [[spinel_widening_dispatch]]). The
# concrete v1 use case is "deliver to a WS connection" -- the WS
# layer keeps its accepted-socket fd, calls subscribe, and
# Tep::Broadcast.publish writes the payload bytes to that fd.
# Apps that need a different delivery surface (HTTP SSE, log
# fan-out) use the same subscribe-fd shape with a different fd.
#
# Storage scope is per-process: subscriptions live on Tep::APP,
# which under prefork is per-worker. Cross-worker pub-sub (via PG
# LISTEN/NOTIFY) is a follow-up chunk -- subscribers will still
# register fd-local, but publish() will route through the database
# so other workers see the message too.
#
# `subscribe` returns an opaque subscription id (the registry
# index at insertion time). Callers can pass it back to
# `unsubscribe` for a single-sub drop. For WS connections that
# subscribe to multiple topics, `unsubscribe_fd(fd)` drops every
# subscription tied to that fd in one call -- the right shape for
# the WS on-close hook.
module Tep
  module Broadcast
    # Register a subscription for `fd` on `topic`. Returns an
    # opaque sub_id for later unsubscribe.
    def self.subscribe(topic, fd)
      subs = Tep::APP.broadcast_subs
      sub = Tep::BroadcastSubscription.new(topic, fd)
      subs.push(sub)
      subs.length - 1
    end

    # Drop the subscription at `sub_id`. Note that ids are
    # registry indexes; subsequent drops shift everything past it
    # downward. For multi-sub drop, prefer `unsubscribe_fd`.
    def self.unsubscribe(sub_id)
      subs = Tep::APP.broadcast_subs
      if sub_id < 0 || sub_id >= subs.length
        return 0
      end
      subs.delete_at(sub_id)
      0
    end

    # Drop every subscription whose fd matches. Returns the count
    # dropped. Used by WS on-close to clean up everything a closing
    # connection had subscribed to. Back-to-front so delete_at
    # indices stay valid mid-loop.
    def self.unsubscribe_fd(fd)
      subs = Tep::APP.broadcast_subs
      dropped = 0
      i = subs.length - 1
      while i >= 0
        if subs[i].fd == fd
          subs.delete_at(i)
          dropped += 1
        end
        i -= 1
      end
      dropped
    end

    # Write `payload` to every subscribed fd for `topic`. Returns
    # the number of subscriptions matched (NOT the number of
    # successful writes -- a closed / bad fd still counts as
    # matched; the underlying sphttp_write_str returns -1 silently
    # on that fd). Apps that need delivery confirmation should
    # track their own ack channel.
    #
    # When the PG backend is enabled (Tep::Broadcast.enable_pg_backend),
    # publish ALSO NOTIFY's the configured channel so other workers
    # subscribed via poll_pg_once can deliver to their local
    # subscribers. Match count returned is the LOCAL match count;
    # remote deliveries are best-effort and not counted here.
    def self.publish(topic, payload)
      matched = Tep::Broadcast.publish_local_only(topic, payload)
      if Tep::APP.broadcast_pg_enabled != 0
        wire = Tep::Broadcast.encode_wire(topic, payload)
        Tep::APP.broadcast_pg_conn.notify(
          Tep::APP.broadcast_pg_channel, wire)
      end
      matched
    end

    # Total subscription count across all topics. Useful for
    # diagnostics and the v1 test surface.
    def self.subscriber_count
      Tep::APP.broadcast_subs.length
    end

    # Count of subscribers for one topic. O(n) over the registry;
    # acceptable for v1 (n is typically small per worker).
    def self.subscribers_for(topic)
      subs = Tep::APP.broadcast_subs
      n = 0
      i = 0
      while i < subs.length
        if subs[i].topic == topic
          n += 1
        end
        i += 1
      end
      n
    end

    # Drop every subscription. Used by tests between fixtures, and
    # available to apps that need to fully reset (e.g. during
    # graceful shutdown). Returns the count dropped.
    def self.clear
      subs = Tep::APP.broadcast_subs
      n = subs.length
      while subs.length > 0
        subs.delete_at(0)
      end
      n
    end

    # ---- PG backend (cross-worker pub/sub) ----
    #
    # Opens a dedicated PG connection and issues `LISTEN <channel>`.
    # Subsequent publishes NOTIFY this channel too -- other workers
    # subscribed to the same channel can receive the message via
    # poll_pg_once.
    #
    # `conninfo` is the libpq connect string. `channel` must be a
    # safe SQL identifier (e.g. "tep_broadcast") since it lands
    # inside a LISTEN / NOTIFY command unescaped.
    #
    # Returns 0 on success, -1 on connection or LISTEN failure.
    def self.enable_pg_backend(conninfo, channel)
      conn = PG::Connection.new(conninfo)
      if conn.pgh < 0
        return -1
      end
      if conn.listen(channel) < 0
        return -1
      end
      Tep::APP.set_broadcast_pg_conn(conn)
      Tep::APP.set_broadcast_pg_channel(channel)
      Tep::APP.set_broadcast_pg_enabled(1)
      0
    end

    def self.disable_pg_backend
      if Tep::APP.broadcast_pg_enabled == 0
        return 0
      end
      Tep::APP.broadcast_pg_conn.unlisten(Tep::APP.broadcast_pg_channel)
      Tep::APP.broadcast_pg_conn.finish
      Tep::APP.set_broadcast_pg_enabled(0)
      0
    end

    # Process one notification from the PG channel: parse the wire
    # format, dispatch to local subscribers as if `publish` had
    # been called locally (but WITHOUT re-NOTIFYing -- that would
    # loop). Returns 1 if a notification was processed, 0 on
    # timeout, -1 on connection error or unenabled backend.
    def self.poll_pg_once(timeout_ms)
      if Tep::APP.broadcast_pg_enabled == 0
        return -1
      end
      r = Tep::APP.broadcast_pg_conn.poll_notification(timeout_ms)
      if r != 1
        return r
      end
      wire = Tep::APP.broadcast_pg_conn.last_notify_payload
      Tep::Broadcast.deliver_wire_local(wire)
      1
    end

    # Wire format: "<topic_byte_length>:<topic><payload>".
    # Length-prefixed so topics and payloads with arbitrary chars
    # (commas, colons, embedded quotes, newlines) round-trip
    # unambiguously. Encoded by `publish` when the PG backend is
    # enabled; decoded by `deliver_wire_local`.
    def self.encode_wire(topic, payload)
      topic.length.to_s + ":" + topic + payload
    end

    def self.deliver_wire_local(wire)
      colon = Tep.str_find(wire, ":", 0)
      if colon <= 0
        return -1
      end
      len_str = wire[0, colon]
      tlen    = len_str.to_i
      if tlen < 0 || colon + 1 + tlen > wire.length
        return -1
      end
      topic   = wire[colon + 1, tlen]
      payload = wire[colon + 1 + tlen, wire.length - colon - 1 - tlen]
      Tep::Broadcast.publish_local_only(topic, payload)
    end

    # Same fan-out as #publish but skips the PG NOTIFY step. Used
    # internally by poll_pg_once when delivering a cross-worker
    # message that already came in via PG -- re-NOTIFY would cause
    # an infinite loop.
    def self.publish_local_only(topic, payload)
      subs = Tep::APP.broadcast_subs
      matched = 0
      i = 0
      while i < subs.length
        if subs[i].topic == topic
          Sock.sphttp_write_str(subs[i].fd, payload)
          matched += 1
        end
        i += 1
      end
      matched
    end
  end
end
