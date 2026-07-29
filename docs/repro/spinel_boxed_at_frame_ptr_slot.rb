# spinel repro (boxed-into-typed-slot family, site five — found while
# reducing site four under a loose 'any sp_RbVal type error' oracle):
# a boxed value is assigned into an sp_Frame* OBJECT-POINTER slot — the
# family is not confined to const char* string slots. LATENT: identical
# at fd87f45b and master 0ccc3ceb; zero artifacts; two-sided-reduced.
module Tep
  module Multipart
    def self.parse(body, content_type)
      while i < parts.length
        if part.length >= 2 && part[0, 2] == "--"
        end
      end
      if rest.length > 0 && rest[0, 1] == "\""
        if end_q < 0
        end
      end
    end
    def self.extract_field_name(headers)
      if at < 0
      end
    end
  end
end
module Sock
  class AgentDelegation
    def initialize(agent_id, issued_at, expires_at, origin)
    end
  end
end
module Tep
  class Identity
    def expired?(now)
    end
  end
  class BroadcastSubscription
    def get(k)
      if !Tep.timing_safe_eq(sig, expect)
        if !first
        end
      end
    end
  end
  def self.timing_safe_eq(a, b)
    if a.length != b.length
      while i < @routes.length
        if @routes[i] == route
        end
      end
    end
    def self.try(req)
      if sub.length == 0
      end
    end
    def self.format_caps(caps)
      caps.each do |c|
      end
    end
    def self.format_delegate(deleg)
    end
  end
end
module Tep
  module AuthOAuth2
    def self.issue_code(principal_id, client_id, caps_str, ttl_seconds)
      rec = Tep::AuthOAuth2Code.new(
        code, principal_id, client_id, caps_str, expires_at)
    end
    def self.exchange_code(code, client_id, token_ttl_seconds)
      while i < codes.length
        if codes[i].code == code && codes[i].client_id == client_id
        end
      end
      if idx < 0
      end
    end
    def self.mint_jwt(rec, token_ttl_seconds)
      while i >= 0
        if codes[i].expired?(now_ts)
        end
      end
    end
    def self.track(req, topic, fd)
      if ident.agent?
      end
    end
    def self.untrack(topic, fd)
      while i < entries.length
      end
    end
    def self.list(topic)
      while i < entries.length
      end
    end
    def topic
    end
    def self.from_int_array(a)
      while i < a.length
      end
    end
    def self.get_str(s, key)
      if pos < 0
      end
    end
    def self.get_int(s, key)
      if pos < 0
      end
    end
    def self.skip_ws(s, pos)
      while pos < s.length
        if c == " " || c == "\t" || c == "\n" || c == "\r"
        end
      end
      while pos < s.length
      end
    end
    def self.skip_container(s, pos)
      while pos < s.length && depth > 0
        if c == "\""
          if npos < 0
          end
        end
      end
    end
  end
end
module Tep
  module MCP
    class Result
      def initialize
      end
    end
    def self.text(s)
      def initialize
      end
    end
    def self.nested_extract(json, key)
      if pos < 0
      end
    end
  end
  class Jwt
    def self.encode_hs256(payload_json, secret)
    end
  end
end
module Tep
  class Password
    def self.verify(plain, stored)
      while i < n
        if s[i] == "$"
          if seg < 4
          end
        end
      end
    end
    def self.any_io_waiter
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? &&
           Tep::APP.sched_io_ready[i] == 0
        end
      end
    end
  end
end
module Tep
  class Shell
    def self.read(path)
      begin
      end
    end
    def self.send_req(verb, url, body, headers)
      if Tep::Scheduler.scheduled_context?
        if wrote < 0
          if fr.raw.length == 0 && from_pool == 1
          end
        end
      end
      if scheme == "https"
        while hs == 1 || hs == 2
        end
      end
      while raw.length < COOP_RESPONSE_MAX
      end
      while true
        if chunk.length == 0
        end
      end
    end
    class ProxyStreamer < Tep::Streamer
      def initialize
      end
      def pump(out)
      end
    end
  end
  class Events
    def initialize(path)
    end
    def run_start(host, backend_kind, model_name, model_path, config_json)
      if @path.length == 0
      end
    end
    def run_end_aggregated(reason)
      if @path.length == 0
      end
      while i < lines.length
        if Tep.str_find(line_s, "\"kind\":\"eval\"", 0) >= 0 &&
          if extra_pos >= 0
          end
        end
      end
    end
    class Frame
      def encode_unmasked
        if plen <= 125
        end
      end
      def self.parse_from_buf(start, avail)
        if avail - start < 2
          if !fin
          end
        end
        if len7 < 126
          if avail - pos < 2
          end
        end
        while i < plen
          if (i & 3) == 0
          end
        end
      end
      def self.reserved_opcode?(op)
        if op == Tep::WebSocket::OPCODE_CONTINUATION
        end
      end
    end
    class ParseResult
      attr_accessor :outcome, :frame, :consumed, :close_code
      def initialize
        @frame      = Tep::WebSocket::Frame.new(true, 0, "")
      end
    end
  end
end
module Tep
  module WebSocket
    class Handshake
      def self.check(req)
      end
      def self.icontains(hay, needle)
        if hay.length == 0 || needle.length == 0
        end
      end
      def self.downcase(s)
        while pos < s.length
        end
      end
      def self.trim(s)
        while i < s.length && (s[i] == " " || s[i] == "\t")
        end
      end
    end
  end
end
module Tep
  module WebSocket
    class Driver
      def close(code, reason)
      end
    end
    class Handler
      def handle_event(event)
        while true
          if ready == 0
            if frame.payload.length > 2
            end
          end
        end
      end
    end
    class ConnectionState
      def initialize
      end
    end
  end
  class FiberSlot
    def initialize(f)
    end
  end
  def self.seed_fiber_noop
    while pos <= slen - nlen
      if s[pos, nlen] == needle
      end
    end
  end
  def self.h(s)
    while i < n
    end
  end
  _tep_seed_ws_pr = Tep::WebSocket::ParseResult.new
  _tep_seed_ws_pr.frame      = _tep_seed_ws_frame
  def self.on_shutdown
    if APP.openai_events.enabled?
    end
  end
end
