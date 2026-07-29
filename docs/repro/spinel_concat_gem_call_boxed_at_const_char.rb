# spinel repro (#3385 site four): route-handler 'literal + gem-call' concat —
# String result of an inlined vendored-gem module function, with fully typed
# args (param reads .to_f/.to_i), lands boxed (sp_RbVal) in a const char*
# local init. LATENT: identical at fd87f45b and master 0ccc3ceb. This is
# the site that keeps tep's examples/maidenhead + examples/geohash red.
# Two-phase ddmin, oracle pinned to the exact error text + artifact guard;
# the lat/lon/prec assignments were hand-restored and re-verified (the
# reducer had dropped them; failure does NOT depend on their absence).
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
  end
end
module Tep
  class AuthOAuth2Code
    def initialize(code, principal_id, client_id, caps_str, expires_at)
    end
  end
end
module Tep
  class BroadcastSubscription
    def load_from(cookie_value, secret)
      if cookie_value.length == 0 || secret.length == 0
      end
    end
  end
  def self.timing_safe_eq(a, b)
  end
end
module Tep
  class Request
    def index_of(route)
      while i < @routes.length
        if @routes[i] == route
        end
      end
    end
    def self.try(req)
      if header.length < 8 || header[0, 7] != "Bearer "
      end
    end
  end
end
module Tep
  class AuthSessionCookie
    def self.try(req)
      caps.each do |c|
        if !first
        end
      end
    end
  end
end
module Tep
  module AuthOAuth2
    def self.issue_code(principal_id, client_id, caps_str, ttl_seconds)
      while i < codes.length
        if codes[i].code == code && codes[i].client_id == client_id
        end
      end
      while i >= 0
        if codes[i].expired?(now_ts)
        end
      end
    end
  end
end
module Tep
  module Presence
    def self.track(req, topic, fd)
      if Tep::Presence.find_entry(topic, fd) != nil
      end
      entry = Tep::PresenceEntry.new(
        topic, ident.principal_id, kind, agent_id, fd, Time.now.to_i)
      while i < entries.length
        if entries[i].topic == topic && entries[i].fd == fd
        end
      end
    end
    def self.list(topic)
      while i < entries.length
        if entries[i].topic == topic
        end
      end
      while i < entries.length
        if entries[i].topic == topic && entries[i].fd == fd
        end
      end
    end
  end
end
module Tep
  class LiveView
    def run(port, workers, quiet)
      if Tep::APP.tls_cert.length > 0 && Tep::APP.tls_key.length > 0
        if Sock.sphttp_tls_server_init(Tep::APP.tls_cert, Tep::APP.tls_key) < 0
        end
      end
      if workers <= 1
        while buf.length < MAX_REQUEST_BYTES
          if remaining <= 0
          end
        end
        if res.upgrading_ws
          head = Tep::WebSocket::Handshake.build_response(
            res.ws_accept_key, res.ws_driver.subprotocol)
          if res.body.length > 0 && !res.head_only
          end
        end
      end
    end
  end
end
module Tep
  class Json
    def self.escape(s)
      while i < n
      end
    end
    def self.quote(s)
    end
    def self.encode_pair_str(k, v)
    end
    def self.encode_pair_int(k, v)
      h.each do |k, v|
      end
    end
    def self.from_int_hash(h)
      while i < a.length
        if i > 0
        end
      end
    end
  end
end
module Tep
  class Json
    def self.get_str(s, key)
    end
    def self.skip_ws(s, pos)
      while pos < s.length
        if c == "\\"
        end
      end
      while pos < s.length
        if c == "," || c == "}" || c == "]" ||
           c == " " || c == "\t" || c == "\n" || c == "\r"
        end
      end
    end
    def self.skip_container(s, pos)
      while pos < s.length && depth > 0
      end
    end
    def self.parse_str_value(s, pos)
      if pos >= s.length || s[pos] != "\""
        if c == "\""
        end
      end
      while pos < s.length
        if c >= "0" && c <= "9"
        end
      end
      if !saw_digit
      end
    end
    def self.find_value_start(s, target_key)
      if pos >= s.length || s[pos] != "{"
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
    def self.nested_extract(json, key)
    end
  end
end
module Tep
  class Jwt
    def self.verify_hs256(token, secret)
      if d1 < 0
      end
    end
    def self.timing_safe_eq(a, b)
      if a.length != b.length
      end
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
  end
end
module Tep
  module Security
    class Cors < Tep::Filter
      def initialize
      end
    end
  end
end
module Tep
  class Scheduler
    def self.spawn_fiber(f)
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? && Tep::APP.sched_wake_at[i] <= now
          if best < 0 || Tep::APP.sched_wake_at[i] < Tep::APP.sched_wake_at[best]
          end
        end
      end
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? &&
          if next_at >= 0
            if tgap < gap
            end
          end
          if best < 0 || Tep::APP.sched_wake_at[i] < Tep::APP.sched_wake_at[best]
          end
        end
      end
    end
    def self.any_io_waiter
      while i < n
      end
    end
    def self.clear
      while Tep::APP.sched_fibers.length > 0
        if Tep::APP.sched_fibers[i].f.alive?
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
          if from_pool == 0
          end
        end
      end
      if scheme == "https"
        if fd < 0
        end
      end
      while raw.length < COOP_RESPONSE_MAX
        if ready == 0
        end
      end
      while pos < raw.length
        if next_eol < 0
        end
      end
      while buf.length < 4194304
        if hdr_end < 0
          if idx >= 0
            if ci >= 0
              if Tep.str_find(kline, "close", 0) >= 0
              end
            end
          end
        end
        if hdr_end >= 0 && clen >= 0 && (buf.length - hdr_end) >= clen
        end
      end
      def initialize
      end
    end
    class Pool
      def self.release(fd, host, port)
      end
    end
  end
end
module Tep
  class Proxy < Tep::Handler
    class RetryPolicy
      def backoff_for(attempt)
        if @base_backoff_ms <= 0
        end
      end
      def retriable?(status)
        if status == 0
        end
        while i < @retry_on_status.length
          if @retry_on_status[i] == status
          end
        end
      end
    end
  end
  class Proxy
    def on_stream_end(req, out, stats)
      if @max_request_body_bytes > 0 && req.raw_body.length > @max_request_body_bytes
          Tep::Json.encode_pair_str("message",
            @max_request_body_bytes.to_s + " bytes") + "," +
        if attempt < policy.max_attempts
          if backoff > 0
          end
        end
      end
      if parts["scheme"] != "http"
        if Sock.sphttp_write_str(fd, ureq.body) < 0
        end
      end
    end
    def run_stream(out, fd, leftover, is_chunked, is_sse, req)
      while !done
        if is_chunked
          if consumed.length > 0
          end
        end
        if ready == 0
        end
      end
      while true
        if ready == 0
        end
      end
    end
    def self.hop_by_hop?(name)
      def initialize
      end
      def fill_from(blob)
        if sp1 >= 0
          if neol < 0
          end
        end
      end
    end
    class ProxyStreamer < Tep::Streamer
    end
  end
end
module Tep
  class Events
    def initialize(path)
    end
    def run_end_aggregated(reason)
      while i < lines.length
        if Tep.str_find(line_s, "\"kind\":\"eval\"", 0) >= 0 &&
           Tep.str_find(line_s, "\"name\":\"request\"", 0) >= 0
        end
      end
    end
    def append_line(line)
      File.open(@path, "a") do |f|
      end
    end
  end
end
module Tep
  class Llm
    def initialize(base_url)
    end
    def chat(messages)
      while true
        if chunk.length == 0
          if headers_done
          end
        end
        if is_chunked
          if delta.length > 0
          end
        end
      end
    end
    def self.dechunk_consume(s)
      while i < s.length
      end
    end
    class StreamState
      def initialize
      end
    end
    class Message
      def initialize(role, content)
      end
    end
    class Response
      def initialize
      end
    end
    module OpenAI
      class Backend
      end
      def self.parse_messages(body)
        while pos < body.length
          if pos >= body.length
          end
        end
        def initialize
          Tep::APP.openai_events.inference(
          )
        end
      end
      class ChatCompletionsHandler < Tep::Handler
        def handle(req, res)
          wants_stream = Tep.str_find(body, "\"stream\":true", 0) >= 0 ||
          if wants_stream
                Tep::Json.encode_pair_str("message",
                  "embedding generation failed (backend returned an empty vector)") + "," +
            "}"
          end
        end
      end
    end
  end
end
module Tep
  module WebSocket
    class Frame
      def encode_unmasked
        if plen <= 125
        end
      end
      def self.parse_from_buf(start, avail)
        if Frame.control_opcode?(opcode)
          if !fin
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
      def self.control_opcode?(op)
      end
    end
    class ParseResult
      def self.check(req)
        if req.verb != "GET"
        end
      end
      def self.trim(s)
        while j >= i && (s[j] == " " || s[j] == "\t")
        end
        if j < i
        end
      end
    end
  end
end
module Tep
  module WebSocket
    class Driver
      def close(code, reason)
        if reason.length > 123
        end
      end
    end
    class Handler
      def initialize
      end
      def run
        while true
          if ready == 0
          end
        end
      end
    end
    class ConnectionState
      def initialize
      end
    end
  end
end
module Tep
  class FiberSlot
    def initialize(f)
    end
  end
  def self.seed_fiber_noop
  end
  def self.str_find(s, needle, start)
    slen = s.length
    pos = start
    while pos <= slen - nlen
    end
  end
  def self.h(s)
    while i < n
    end
  end
  _tep_seed_oai_chat.handle(_tep_seed_proxy_req, _tep_seed_proxy_res)
  def self.on_shutdown
    if APP.openai_events.enabled?
    end
  end
end
class TepRoute_2 < Tep::Handler
  def handle(req, res)
      lat  = Tep.param(req, "lat").to_f
      lon  = Tep.param(req, "lon").to_f
      prec = Tep.param(req, "precision").to_i
      if prec <= 0
        prec = 5
      end
      "" + (Maidenhead.to_maidenhead(lat, lon, prec))
  end
end
