# spinel repro: whole-program compile-time BLOWUP at 2026.09.12 (tep#258).
# This 77-line reduction compiles in 74s at 2026.09.12 vs 0.35s at
# 85abddd2 (~200x). ddmin'd from tep's 10.5K-line translated hello via
# spinel-reduce (oracle: compile > 60s); the full program is
# NON-TERMINATING at the release (>20min, 100% CPU) vs ~1min before.
# The reducer left skeleton artifacts (undefined locals, unresolved
# Tep::Json) — but the OLD engine compiles this SAME file in 0.35s, so
# the artifacts are incidental, not the cause. Compile with -I <spinel_kit>.
#
module Tep
  class Session
  end
end
module Tep
  module Cache
    def self.not_modified?(req, res)
      if etag.length > 0
        if inm.length > 0
          if inm == "*"
          end
        end
      end
    end
  end
end
module Tep
  class Route
    def self.exchange_code(code, client_id, token_ttl_seconds)
      if idx < 0
      end
    end
    def self.mint_jwt(rec, token_ttl_seconds)
      if secret.length == 0
      end
      while i >= 0
        if entries[i].fd == fd
        end
      end
    end
    def self.encode_diff(kind, entry)
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
def self.mirror_status(topic, fd, state, note, until_ts)
      if !quiet
      end
      loop do
        if gone < 0
        end
      end
    end
  end
end
module Tep
  class SQLite
    def self.skip_str(s, pos)
      if pos >= s.length || s[pos] != "\""
        if c == "\\"
        end
      end
    end
    def self.skip_value(s, pos)
      if c == "\""
      end
    end
  end
end
module Tep
  module MCP
    class Result
    end
    def self.decode_payload(token)
      if d2 < 0
      end
    end
  end
end
