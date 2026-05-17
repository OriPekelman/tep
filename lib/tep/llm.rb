# Tep::Llm -- minimal OpenAI-compatible chat-completions client.
#
# Why this is a battery, not example code
# ---------------------------------------
# Every modern Sinatra-style app that talks to an LLM speaks the
# same wire shape -- POST /v1/chat/completions with
# {model, messages:[{role,content}...]} -- whether the backend is
# Ollama, OpenAI proper, vLLM, Anthropic-via-litellm, or tep's
# sibling project [toy](https://github.com/OriPekelman/toy)'s
# tep_demo/openai_api.rb. Hand-rolling that JSON + the parse for
# every app is twenty lines of awkward escape-handling each time.
# `Tep::Llm` is the Faraday-shape one-call client; backends are
# config, not code.
#
# Scope (v1)
# ----------
# * Synchronous `chat(messages)` only. Streaming (`chat_stream`)
#   waits for Tep::Server::Scheduled-driven non-blocking recv loops
#   to land in Tep::Http -- separate phase.
# * OpenAI wire protocol over HTTP/1.0. Connection: close.
# * Returns `Tep::Llm::Response` with `.content` (the assistant
#   reply string) and `.stop_reason`. Token usage stats omitted in
#   v1 to keep the parse minimal -- they're advisory, not load-bearing.
# * Single system prompt support via `set_system_prompt`. Multi-turn
#   conversation history is the caller's responsibility (build the
#   Array<Tep::Llm::Message> yourself, possibly from Tep::SQLite).
#
# API
# ---
#
#   client = Tep::Llm.new("http://localhost:11434")    # Ollama default
#   client.set_model("llama3")
#   client.set_api_key("")                              # empty = unset
#   client.set_system_prompt("You are helpful.")        # optional
#
#   msgs = [Tep::Llm::Message.new("user", "What is 2+2?")]
#   reply = client.chat(msgs)
#   puts reply.content        # => "4"
#
# Three backends interchangeable via base_url:
#   "http://localhost:11434" -- Ollama (default)
#   "http://localhost:8080"  -- toy/tep_demo/openai_api
#   "https://api.openai.com" -- OpenAI proper (needs api_key)
module Tep
  class Llm
    attr_accessor :base_url, :model, :api_key, :system_prompt

    def initialize(base_url)
      @base_url      = base_url
      @model         = ""
      @api_key       = ""
      @system_prompt = ""
      @http          = Tep::Http.new(base_url)
      @http.set_header("Content-Type", "application/json")
    end

    def set_model(name)
      @model = name
    end

    def set_api_key(key)
      @api_key = key
      if key.length > 0
        @http.set_header("Authorization", "Bearer " + key)
      end
    end

    def set_system_prompt(s)
      @system_prompt = s
    end

    # POST to <base_url>/v1/chat/completions with the messages array.
    # Returns a Tep::Llm::Response. On any transport / parse failure
    # `.content` is "" and `.stop_reason` is "error".
    def chat(messages)
      body = Llm.build_request_body(@model, @system_prompt, messages)
      res = @http.do_post("/v1/chat/completions", body)
      Llm.parse_response(res)
    end

    # Streaming variant. Opens a connection, sends the request with
    # `stream: true`, decodes the SSE response (handling either
    # close-delimited or HTTP/1.1 chunked-transfer-encoded bodies),
    # and writes each `{"content":"<delta>"}` event to `out_stream`
    # (anything with a `write(String) -> Integer` -- typically the
    # framework-provided Tep::Stream from a Tep::Streamer#pump).
    # Each SSE line is `data: {"content":"<delta>"}\n\n`. A final
    # `data: [DONE]\n\n` marks the end (after stop / disconnect).
    # Returns the accumulated assistant content as a String so the
    # caller can persist it.
    def chat_stream(messages, out_stream)
      body = Llm.build_request_body(@model, @system_prompt, messages)
      # Splice `,"stream":true` before the closing brace so the
      # backend opts into SSE. Inlined (rather than a separate
      # build_request_body_stream cmeth) to keep the messages-array
      # argument's typed-callsite to a single shape -- splitting
      # tripped spinel's cross-method param inference.
      body = body[0, body.length - 1] + ",\"stream\":true}"
      parts = Tep::Url.split_url(@base_url)
      host = parts["host"]
      port = parts["port"].to_i
      fd = Sock.sphttp_connect(host, port)
      if fd < 0
        return ""
      end
      Sock.sphttp_set_nonblock(fd)
      head = "POST /v1/chat/completions HTTP/1.1\r\n" +
             "Host: " + host + "\r\n" +
             "Content-Type: application/json\r\n" +
             "Accept: text/event-stream\r\n"
      if @api_key.length > 0
        head = head + "Authorization: Bearer " + @api_key + "\r\n"
      end
      head = head + "Content-Length: " + body.length.to_s + "\r\n" +
                    "Connection: close\r\n\r\n" + body
      if Sock.sphttp_write_str(fd, head) < 0
        Sock.sphttp_close(fd)
        return ""
      end
      out = Llm.read_sse_response(fd, out_stream)
      Sock.sphttp_close(fd)
      out_stream.write("data: [DONE]\n\n")
      out
    end

    # Hand-rolled JSON build. Tep::Json doesn't ship nested
    # array-of-hash support (its public encoders are flat); the
    # request body is a fixed shape so the inline assembly stays
    # bounded.
    def self.build_request_body(model, system_prompt, messages)
      out = "{\"model\":" + Json.quote(model) + ",\"messages\":["
      first = true
      if system_prompt.length > 0
        out = out + "{\"role\":\"system\",\"content\":" + Json.quote(system_prompt) + "}"
        first = false
      end
      i = 0
      while i < messages.length
        if !first
          out = out + ","
        end
        msg = messages[i]
        out = out + "{\"role\":" + Json.quote(msg.role) +
                    ",\"content\":" + Json.quote(msg.content) + "}"
        first = false
        i += 1
      end
      out = out + "]}"
      out
    end

    # OpenAI response shape:
    #   {"choices":[{"message":{"role":"assistant","content":"..."},
    #                "finish_reason":"stop"}], ...}
    # We extract two fields, both inside choices[0]. Tep::Json's
    # flat-key decoder doesn't dive that deep, so we hand-walk the
    # JSON looking for `"message":{...}` and pull "content" + (the
    # surrounding) "finish_reason" out of it.
    def self.parse_response(http_response)
      out = Tep::Llm::Response.new
      if http_response.status == 0
        out.stop_reason = "error"
        return out
      end
      if http_response.status >= 400
        out.stop_reason = "http_" + http_response.status.to_s
        return out
      end

      json = http_response.body
      # Find the assistant message block. The first `"message":{` in
      # the body is choices[0].message; subsequent ones would be
      # tool-call descriptors etc., which v1 doesn't surface.
      m_at = Tep.str_find(json, "\"message\"", 0)
      if m_at < 0
        out.stop_reason = "no_message"
        return out
      end
      out.content     = Llm.extract_str_field(json, "content", m_at)
      out.role        = Llm.extract_str_field(json, "role", m_at)
      out.stop_reason = Llm.extract_str_field(json, "finish_reason", m_at)
      out
    end

    # Extract `"key":"value"` from `json` starting the search at
    # `from`. Walks the post-key string honouring \" / \\ / \n / \t
    # escapes. Returns "" if the field isn't found.
    def self.extract_str_field(json, key, from)
      needle = "\"" + key + "\""
      k_at = Tep.str_find(json, needle, from)
      if k_at < 0
        return ""
      end
      # Skip past `"key"` to the colon, then the opening quote.
      pos = k_at + needle.length
      # Walk past whitespace + `:`.
      while pos < json.length && json[pos] != "\""
        pos += 1
      end
      if pos >= json.length
        return ""
      end
      pos += 1  # past opening quote
      out = ""
      while pos < json.length
        c = json[pos]
        if c == "\\"
          if pos + 1 < json.length
            nxt = json[pos + 1]
            if nxt == "n"
              out = out + "\n"
            elsif nxt == "t"
              out = out + "\t"
            elsif nxt == "\""
              out = out + "\""
            elsif nxt == "\\"
              out = out + "\\"
            elsif nxt == "/"
              out = out + "/"
            elsif nxt == "r"
              out = out + "\r"
            else
              out = out + nxt
            end
            pos += 2
          else
            pos += 1
          end
        elsif c == "\""
          return out
        else
          out = out + c
          pos += 1
        end
      end
      out
    end

    # Streaming SSE reader. Parks the fiber on Tep::Scheduler.io_wait
    # between recvs, decodes the response body (either raw bytes if
    # the server respected Connection: close, or HTTP/1.1 chunked
    # transfer encoding -- detected via the Transfer-Encoding
    # header), splits on the "\n\n" SSE event boundary, extracts
    # `choices[0].delta.content` from each `data: <json>` event,
    # and writes a `data: {"content":"<delta>"}\n\n` to `out_stream`
    # for each non-empty delta. Returns the accumulated content.
    #
    # Terminates on: SSE "[DONE]" event, EOF, finish_reason set,
    # or 60-second I/O-wait timeout.
    def self.read_sse_response(fd, out_stream)
      buf            = ""
      acc            = ""
      headers_done   = false
      is_chunked     = false
      body_buf       = ""

      while true
        ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, 60)
        if ready == 0
          return acc
        end
        chunk = Sock.sphttp_recv_some(fd, 4096)
        if chunk.length == 0
          # EOF -- flush whatever's in body_buf as a final SSE pass
          if headers_done
            acc = Llm.drain_sse_buf(body_buf, out_stream, acc)
          end
          return acc
        end
        buf = buf + chunk

        if !headers_done
          eoh = Tep.str_find(buf, "\r\n\r\n", 0)
          if eoh < 0
            next
          end
          headers_done = true
          header_blob = buf[0, eoh]
          # Case-fold-ish check for Transfer-Encoding: chunked.
          if Tep.str_find(header_blob, "Transfer-Encoding: chunked", 0) >= 0 ||
             Tep.str_find(header_blob, "transfer-encoding: chunked", 0) >= 0
            is_chunked = true
          end
          buf = buf[eoh + 4, buf.length - eoh - 4]
        end

        # Feed buf into the body. For chunked, dechunk first; for
        # raw, the body bytes ARE buf.
        if is_chunked
          decoded = Llm.dechunk_pass(buf)
          # decoded["payload"] = consumed bytes; decoded["rest"] =
          # leftover that's mid-chunk (no full chunk to extract yet).
          # Hand-rolled return: rebuild via str_find on a sentinel
          # to keep types simple.
          consumed = Llm.dechunk_consume(buf)
          rest     = Llm.dechunk_leftover(buf)
          buf      = rest
          body_buf = body_buf + consumed
        else
          body_buf = body_buf + buf
          buf      = ""
        end

        # Process complete SSE events. The state object carries
        # acc / leftover / done across the call (spinel's multi-
        # return-from-method support is uneven; one state class is
        # safer than three coordinated return values).
        state = Tep::Llm::StreamState.new
        state.acc      = acc
        state.leftover = body_buf
        Llm.consume_sse_events(out_stream, state)
        acc      = state.acc
        body_buf = state.leftover
        if state.done
          return acc
        end
      end
      acc
    end

    # Process every complete "\n\n"-terminated event in
    # `state.leftover`. Mutates state.acc / state.leftover / state.done.
    def self.consume_sse_events(out_stream, state)
      body_buf = state.leftover
      while true
        sep = Tep.str_find(body_buf, "\n\n", 0)
        if sep < 0
          state.leftover = body_buf
          return 0
        end
        event = body_buf[0, sep]
        body_buf = body_buf[sep + 2, body_buf.length - sep - 2]
        # Each event is "data: <json>" (or "data: [DONE]", or "" for
        # the SSE keepalive ": tick" / comment lines we ignore).
        if event.length >= 6 && event[0, 6] == "data: "
          payload = event[6, event.length - 6]
          if payload == "[DONE]"
            state.done = true
            state.leftover = body_buf
            return 0
          end
          # Extract choices[0].delta.content. Same shape Tep::Llm
          # already walks for non-streaming responses.
          delta = Llm.extract_str_field(payload, "content", 0)
          if delta.length > 0
            state.acc = state.acc + delta
            out_stream.write("data: {" + Json.encode_pair_str("content", delta) + "}\n\n")
          end
          # finish_reason on the last frame -- not load-bearing for
          # the accumulator but signals upstream end-of-stream.
          fr = Llm.extract_str_field(payload, "finish_reason", 0)
          if fr.length > 0
            state.done = true
            state.leftover = body_buf
            return 0
          end
        end
      end
      state.leftover = body_buf
      0
    end

    # Internal: walks the bytes-of-chunk-prefix-and-bytes form once
    # and returns the consumed dechunked bytes. Anything mid-chunk
    # (incomplete length or partial body) is dropped from the
    # consumed return and surfaces via dechunk_leftover.
    def self.dechunk_consume(s)
      out = ""
      i = 0
      while i < s.length
        # Find "\r\n" terminating the hex length line.
        eol = Tep.str_find(s, "\r\n", i)
        if eol < 0
          # No full chunk header yet.
          return out
        end
        hex = s[i, eol - i]
        n = Llm.hex_to_int(hex)
        if n < 0
          # Malformed length; bail.
          return out
        end
        if n == 0
          # Last chunk -- done.
          return out
        end
        if eol + 2 + n + 2 > s.length
          # Body bytes not all here yet.
          return out
        end
        out = out + s[eol + 2, n]
        i = eol + 2 + n + 2  # past chunk body + trailing \r\n
      end
      out
    end

    # Inverse of dechunk_consume: returns the bytes that weren't
    # consumed (the trailing partial chunk). Keep these for the
    # next recv loop. The two functions intentionally do the
    # parse twice rather than share state -- spinel's tuple/
    # multi-return support is uneven, simpler to pay the cost.
    def self.dechunk_leftover(s)
      i = 0
      while i < s.length
        eol = Tep.str_find(s, "\r\n", i)
        if eol < 0
          return s[i, s.length - i]
        end
        hex = s[i, eol - i]
        n = Llm.hex_to_int(hex)
        if n < 0
          return s[i, s.length - i]
        end
        if n == 0
          return ""
        end
        if eol + 2 + n + 2 > s.length
          return s[i, s.length - i]
        end
        i = eol + 2 + n + 2
      end
      ""
    end

    # Stub used by read_sse_response when dechunk_consume's split
    # logic gets hoisted. Left in place as a no-op return for the
    # str_find sentinel routing.
    def self.dechunk_pass(s)
      s
    end

    # On EOF: feed whatever's in body_buf to consume_sse_events
    # one last time (some servers omit the trailing \n\n on close).
    def self.drain_sse_buf(body_buf, out_stream, acc)
      if body_buf.length == 0
        return acc
      end
      # Append a synthetic \n\n so the splitter finishes the tail.
      state = Tep::Llm::StreamState.new
      state.acc      = acc
      state.leftover = body_buf + "\n\n"
      Llm.consume_sse_events(out_stream, state)
      state.acc
    end

    # Parse a (small) hex string to Integer; -1 on malformed.
    # Chunked sizes are at most 8 hex chars in practice (4 GB);
    # we cap at 16 for safety.
    def self.hex_to_int(s)
      if s.length == 0 || s.length > 16
        return -1
      end
      n = 0
      i = 0
      while i < s.length
        c = s[i]
        d = -1
        if c >= "0" && c <= "9"
          d = (c.ord - 48)
        elsif c >= "a" && c <= "f"
          d = (c.ord - 87)
        elsif c >= "A" && c <= "F"
          d = (c.ord - 55)
        end
        if d < 0
          return -1
        end
        n = n * 16 + d
        i += 1
      end
      n
    end

    # Per-stream state carried across consume_sse_events / read
    # loop iterations. See chat_stream + read_sse_response for use.
    class StreamState
      attr_accessor :acc, :leftover, :done

      def initialize
        @acc      = ""
        @leftover = ""
        @done     = false
      end
    end

    class Message
      attr_accessor :role, :content

      def initialize(role, content)
        @role = role
        @content = content
      end
    end

    class Response
      attr_accessor :content, :role, :stop_reason

      def initialize
        @content     = ""
        @role        = ""
        @stop_reason = ""
      end
    end
  end
end
