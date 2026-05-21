# Tep::BroadcastSubscription -- one entry in the Tep::Broadcast
# subscriber registry. Pairs a topic name with an output fd. When a
# publish matches the topic, the fd gets the payload bytes via
# Sock.sphttp_write_str.
#
# fd is just an integer file descriptor: typically a WebSocket
# connection's accepted socket fd, but the registry doesn't care
# about the protocol on top -- it'll write to any open fd. Apps
# integrating with WS (via Tep::WebSocket) subscribe their
# connection fds; non-WS use cases (server-sent events, log
# fan-out, etc.) work the same way.
#
# Single-process registry only in v1; cross-worker pub-sub
# (PG LISTEN/NOTIFY) lands in a follow-up chunk. See
# docs/BATTERIES-DESIGN.md for the broader Broadcast battery
# design.
module Tep
  class BroadcastSubscription
    attr_reader :topic   # String
    attr_reader :fd      # Integer file descriptor

    def initialize(topic, fd)
      @topic = topic
      @fd    = fd
    end
  end
end
