# spinel repro: the const-char*/typed-slot-from-sp_RbVal family, third site.
# A String ivar (@path) read inside a method reached through a
# 'literal + method_call' concat chain arrives BOXED at sp_File_open's
# const char* arg (+ an int return slot gets sp_RbVal). LATENT: identical
# invalid C at fd87f45b (2026-07-12) and master ab7e0aaf (2026-07-25).
# Sibling shapes: matz/spinel#3256 (hash-set arg, fixed), #3330 (FFI :str
# arg, fixed); the maidenhead/geohash route-handler site is a fourth.
# Two-sided ddmin from the 10.4k-line maidenhead translation: candidate
# required to fail identically at BOTH engines; ruby -c clean; zero
# undefined-name/unresolved-constant artifacts. 331 lines, load-bearing.
module Tep
  module Multipart
    def self.parse(body, content_type)
      if bnd.length == 0
        if sep >= 0
          if name.length > 0 && !has_filename
          end
        end
      end
    end
    def self.extract_boundary(content_type)
      if at < 0
      end
    end
  end
end
module Sock
  ffi_func :sphttp_listen,        [:int, :int],     :int
  ffi_func :sphttp_recv_into_frame, [:int],         :int
  ffi_func :sphttp_tls_server_init, [:str, :str],   :int
  class Identity
    def self.anonymous
    end
  end
  class BroadcastSubscription
    def get(k)
    end
  end
  class Request
    def keep_alive?
    end
  end
  module Cache
    def self.not_modified?(req, res)
      if lm > 0
        if ims.length > 0
        end
      end
    end
  end
  class Streamer
    def pump(out)
    end
  end
  class App
    def initialize
    end
    def dispatch(req, res)
      if secret.length > 0
        while route != nil && !served
          if !try_static(req, res)
            if out.length > 0
            end
          end
        end
      end
    end
  end
  class AuthBearerToken
    def self.set_secret(s)
    end
  end
  class AuthSessionCookie
    def self.format_caps(caps)
    end
  end
  module AuthOAuth2
    def self.register_client(client_id, name, redirect_uri, allowed_caps)
      while i < subs.length
        if subs[i].topic == topic
        end
      end
    end
  end
  module Presence
    def self.track(req, topic, fd)
      while i < entries.length
        if entries[i].topic == topic && entries[i].fd == fd
        end
      end
end
  end
  class Server
    def initialize(app)
    end
    def run(port, workers, quiet)
      if Tep::APP.tls_cert.length > 0 && Tep::APP.tls_key.length > 0
        if Sock.sphttp_tls_server_init(Tep::APP.tls_cert, Tep::APP.tls_key) < 0
        end
      end
    end
    def handle_connection(client)
      while keep_going
      end
    end
    def write_response(client, req, res, keep_alive)
      if res.upgrading_ws
      end
    end
    class Scheduled
      def initialize(app)
      end
      def run(port, workers, quiet)
        sfd = Sock.sphttp_listen(port, workers > 1 ? 1 : 0)
        if sfd < 0
          i = 0
          while i < workers
            Tep.on_shutdown
          end
        end
      end
      def self.accept_loop(sfd)
        while true
        end
      end
    end
  end
  class SQLite
    def first_int(sql, p1)
    end
  end
  class Json
    def self.escape(s)
      while i < n
        if c == "\""
        end
      end
      h.each do |k, v|
        if !first
        end
      end
    end
    def self.skip_ws(s, pos)
    end
    def self.skip_str(s, pos)
      while pos < s.length
        if c == "\\"
        end
      end
      while pos < s.length
        if c == "\""
        end
      end
    end
    def self.find_value_start(s, target_key)
      pos = Json.skip_ws(s, 0)
      if pos >= s.length || s[pos] != "{"
      end
    end
    class ResourceContent
      def initialize
      end
    end
    def self.decode_payload(token)
      if d1 < 0
      end
    end
  end
end
module Tep
  class Password
    def self.verify(plain, stored)
      def before(req, res)
      end
    end
  end
end
module Tep
  class Scheduler
    def self.tick(poll_timeout_ms)
      while i < n
        if Tep::APP.sched_fibers[i].f.alive? &&
           Tep::APP.sched_io_ready[i] == 0
        end
      end
      while Time.now.to_i < deadline
        if !Scheduler.tick(0)
        end
      end
    end
  end
  class Shell
    def self.send_req(verb, url, body, headers)
      while attempt < 2
        if fd >= 0
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
            end
          end
        end
      end
    end
  end
  class Proxy < Tep::Handler
    class RetryPolicy
    end
    def run_stream(out, fd, leftover, is_chunked, is_sse, req)
      while !done
        if is_sse
        end
      end
      while true
        if ready == 0
        end
      end
      def fill_from(blob)
        while pos < blob.length
        end
      end
    end
  end
  class Events
    def run_end(reason)
    end
    def run_end_aggregated(reason)
      i = 0
      while i < lines.length
        line_s = lines[i]
        if Tep.str_find(line_s, "\"kind\":\"eval\"", 0) >= 0 &&
          extra_pos = Tep::Json.find_value_start(line_s, "extra")
          if extra_pos >= 0
          end
        end
      end
      out = "{" +
      append_line(out)
    end
    def append_line(line)
      File.open(@path, "a") do |f|
      end
    end
  end
end
module Tep
  class Llm
    def set_api_key(key)
      if key.length > 0
        if event.length >= 6 && event[0, 6] == "data: "
          if payload == "[DONE]"
          end
        end
      end
    end
    class Frame
      def initialize(fin, opcode, payload)
      end
      def self.parse_from_buf(start, avail)
        len7   = b1 & 0x7f
        if len7 < 126
          i = 0
          while i < 8
          end
        end
      end
    end
    class ParseResult
      attr_accessor :outcome, :frame, :consumed, :close_code
    end
  end
  module WebSocket
    class Handshake
      def self.downcase(s)
        while i < s.length
        end
      end
    end
  end
  module WebSocket
    class Driver
    end
  end
  module WebSocket
    class Connection
      def run
        while true
          n = Sock.sphttp_recv_into_frame(@fd)
          if n <= 0
            r = Tep::WebSocket::Frame.parse_from_buf(state.start, state.avail)
            if r.outcome == "need"
            end
          end
        end
      end
    end
  end
  class FiberSlot
    def initialize(f)
    end
  end
  def self.str_find(s, needle, start)
  end
  def self.h(s)
    while i < n
      if c == "&"
      end
    end
  end
  def self.run!(port, workers, quiet, scheduled = false)
    if scheduled
      Server.new(APP).run(port, workers, quiet)
    end
  end
  def self.on_shutdown
    if APP.openai_events.enabled?
      APP.openai_events.run_end_aggregated("completed")
    end
  end
end
__port = 4567
__workers = 1
__quiet = false
__scheduled = false
__i = 0
while __i < ARGV.length
  __a = ARGV[__i]
  if __a == "-p" && __i + 1 < ARGV.length
  end
end
Tep.run!(__port, __workers, __quiet, __scheduled)
