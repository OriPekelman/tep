# Tep::Llm -- minimal OpenAI-compatible chat-completions client.
#
# Why this is a battery, not example code
# ---------------------------------------
# Every modern Sinatra-style app that talks to an LLM speaks the
# same wire shape -- POST /v1/chat/completions with
# {model, messages:[{role,content}...]} -- whether the backend is
# Ollama, OpenAI proper, vLLM, Anthropic-via-litellm, or tep's
# sibling project [toy](https://github.com/OriPekelman/toy)'s
# `toy serve` (lib/toy/serve/openai/). Hand-rolling that JSON + the parse for
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
# Tool use (function calling), OpenAI-shaped (tep#229)
# ----------------------------------------------------
#
#   client.set_tools('[{"type":"function","function":{"name":"add",' +
#     '"parameters":{"type":"object","properties":{"a":{"type":"integer"}}}}}]')
#   client.set_tool_choice("auto")       # "auto" | "none" | "required" | raw JSON object
#
#   msgs  = [Tep::Llm::Message.new("user", "What is 2+3?")]
#   reply = client.chat(msgs)
#   while reply.tool_calls.length > 0
#     msgs.push(reply.to_message)                    # the assistant turn
#     i = 0
#     while i < reply.tool_calls.length
#       call = reply.tool_calls[i]                   # .id / .name / .arguments (JSON)
#       msgs.push(Tep::Llm::Message.tool(call.id, run_tool(call.name, call.arguments)))
#       i += 1
#     end
#     reply = client.chat(msgs)
#   end
#   puts reply.content
#
# `chat_stream_response` is the streaming counterpart: it returns the
# same Response (content + tool_calls + stop_reason) instead of a String.
#
# Three backends interchangeable via base_url:
#   "http://localhost:11434" -- Ollama (default)
#   "http://localhost:8080"  -- toy serve (toy's OpenAI server)
#   "https://api.openai.com" -- OpenAI proper (needs api_key)
module Tep
  class Llm
    attr_accessor :base_url, :model, :api_key, :system_prompt
    attr_accessor :tools, :tool_choice

    def initialize(base_url)
      @base_url      = base_url
      @model         = ""
      @api_key       = ""
      @system_prompt = ""
      @tools         = ""
      @tool_choice   = ""
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

    # Tool schemas for the request's `tools` field: a JSON array in the
    # OpenAI shape, passed through verbatim (the schemas are nested,
    # heterogeneous JSON; the app owns them as text). "" = no tools.
    def set_tools(json)
      @tools = json
    end

    # `tool_choice`: "auto", "none" or "required" are sent as JSON
    # strings; anything starting with `{` is sent verbatim (e.g.
    # {"type":"function","function":{"name":"add"}}). "" = omit.
    def set_tool_choice(choice)
      @tool_choice = choice
    end

    # POST to <base_url>/v1/chat/completions with the messages array.
    # Returns a Tep::Llm::Response. On any transport / parse failure
    # `.content` is "" and `.stop_reason` is "error".
    def chat(messages)
      body = Llm.build_request_body(@model, @system_prompt, messages)
      body = Llm.splice_tools(body, @tools, @tool_choice)
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
      chat_stream_response(messages, out_stream).content
    end

    # chat_stream, returning a Tep::Llm::Response: `.content` is the
    # accumulated text, `.tool_calls` the calls assembled from the
    # stream's deltas, `.stop_reason` the backend's finish_reason
    # ("error" if the connection failed). Tool-call deltas are not
    # forwarded to `out_stream`. `data: [DONE]` is written only when
    # the reply carries no tool calls, so a tool loop that calls this
    # several times ends the client's stream once.
    def chat_stream_response(messages, out_stream)
      out = Tep::Llm::Response.new
      body = Llm.build_request_body(@model, @system_prompt, messages)
      body = Llm.splice_tools(body, @tools, @tool_choice)
      # Splice `,"stream":true` before the closing brace so the
      # backend opts into SSE. Inlined (rather than a separate
      # build_request_body_stream cmeth) to keep the messages-array
      # argument's typed-callsite to a single shape -- splitting
      # tripped spinel's cross-method param inference.
      body = body[0, body.length - 1] + ",\"stream\":true}"
      parts = SpinelKit::Url.split_url(@base_url)
      host = parts["host"]
      port = parts["port"].to_i
      fd = Sock.sphttp_connect(host, port)
      if fd < 0
        out.stop_reason = "error"
        return out
      end
      Sock.sphttp_set_nonblock(fd)
      head = "POST /v1/chat/completions HTTP/1.1\r\n" +
             "Host: " + host + "\r\n" +
             "Content-Type: application/json\r\n" +
             "Accept: text/event-stream\r\n"
      if @api_key.length > 0
        head = head + "Authorization: Bearer " + @api_key + "\r\n"
      end
      head = head + "Content-Length: " + body.bytesize.to_s + "\r\n" +
                    "Connection: close\r\n\r\n" + body
      if Sock.sphttp_write_str(fd, head) < 0
        Sock.sphttp_close(fd)
        out.stop_reason = "error"
        return out
      end
      st = Tep::Llm::StreamState.new
      Llm.read_sse_into(fd, out_stream, st)
      Sock.sphttp_close(fd)
      out.content     = st.acc
      out.role        = "assistant"
      out.stop_reason = st.stop_reason
      out.tool_calls  = st.tool_calls
      if st.tool_calls.length == 0
        out_stream.write("data: [DONE]\n\n")
      end
      out
    end

    # Hand-rolled JSON build. Tep::Json doesn't ship nested
    # array-of-hash support (its public encoders are flat); the
    # request body is a fixed shape so the inline assembly stays
    # bounded.
    def self.build_request_body(model, system_prompt, messages)
      out = "{\"model\":" + Tep::Json.quote(model) + ",\"messages\":["
      first = true
      if system_prompt.length > 0
        out = out + "{\"role\":\"system\",\"content\":" + Tep::Json.quote(system_prompt) + "}"
        first = false
      end
      i = 0
      while i < messages.length
        if !first
          out = out + ","
        end
        msg = messages[i]
        out = out + "{\"role\":" + Tep::Json.quote(msg.role)
        if msg.tool_calls.length > 0 && msg.content.length == 0
          # An assistant turn that only calls tools has null content.
          out = out + ",\"content\":null"
        else
          out = out + ",\"content\":" + Tep::Json.quote(msg.content)
        end
        if msg.tool_calls.length > 0
          out = out + ",\"tool_calls\":["
          ti = 0
          while ti < msg.tool_calls.length
            tc = msg.tool_calls[ti]
            if ti > 0
              out = out + ","
            end
            out = out + "{\"id\":" + Tep::Json.quote(tc.id) +
                        ",\"type\":\"function\",\"function\":{\"name\":" +
                        Tep::Json.quote(tc.name) + ",\"arguments\":" +
                        Tep::Json.quote(tc.arguments) + "}}"
            ti += 1
          end
          out = out + "]"
        end
        if msg.tool_call_id.length > 0
          out = out + ",\"tool_call_id\":" + Tep::Json.quote(msg.tool_call_id)
        end
        out = out + "}"
        first = false
        i += 1
      end
      out = out + "]}"
      out
    end

    # Add `tools` / `tool_choice` to a built request body. String-only
    # (splices before the closing brace) so build_request_body keeps a
    # single typed call shape.
    def self.splice_tools(body, tools, tool_choice)
      if tools.length == 0
        return body
      end
      out = body[0, body.length - 1] + ",\"tools\":" + tools
      if tool_choice.length > 0
        if tool_choice[0] == "{"
          out = out + ",\"tool_choice\":" + tool_choice
        else
          out = out + ",\"tool_choice\":" + Tep::Json.quote(tool_choice)
        end
      end
      out + "}"
    end

    # Merge the `"tool_calls":[...]` array found at or after `from`
    # into `calls`. Serves both shapes:
    #   non-streaming  message.tool_calls: complete entries, in order;
    #   streaming      delta.tool_calls: fragments keyed by "index" --
    #                  the first carries id + function.name, the rest
    #                  append to function.arguments.
    # `arguments` is normally a JSON-encoded string; a backend that
    # sends an object instead has its raw JSON text taken.
    def self.merge_tool_calls(json, from, calls)
      k_at = Tep.str_find(json, "\"tool_calls\"", from)
      if k_at < 0
        return 0
      end
      pos = Tep::Json.skip_ws(json, k_at + 12)
      if pos >= json.length || json[pos] != ":"
        return 0
      end
      pos = Tep::Json.skip_ws(json, pos + 1)
      if pos >= json.length || json[pos] != "["
        return 0   # null / absent
      end
      arr_end = Tep::Json.skip_container(json, pos)
      pos += 1
      ordinal = 0
      while pos < arr_end
        c = json[pos]
        if c == "{"
          obj_end = Tep::Json.skip_container(json, pos)
          idx = ordinal
          i_at = Llm.obj_value_pos(json, pos, obj_end, "index")
          if i_at >= 0
            idx = Tep::Json.parse_int_value(json, i_at)
          end
          while calls.length <= idx
            calls.push(Tep::Llm::ToolCall.new("", "", ""))
          end
          call = calls[idx]
          id_at = Llm.obj_value_pos(json, pos, obj_end, "id")
          if id_at >= 0 && json[id_at] == "\""
            call.id = Tep::Json.parse_str_value(json, id_at)
          end
          n_at = Llm.obj_value_pos(json, pos, obj_end, "name")
          if n_at >= 0 && json[n_at] == "\""
            call.name = Tep::Json.parse_str_value(json, n_at)
          end
          a_at = Llm.obj_value_pos(json, pos, obj_end, "arguments")
          if a_at >= 0
            if json[a_at] == "\""
              call.arguments = call.arguments + Tep::Json.parse_str_value(json, a_at)
            elsif json[a_at] == "{"
              a_end = Tep::Json.skip_container(json, a_at)
              call.arguments = call.arguments + json[a_at, a_end - a_at]
            end
          end
          ordinal += 1
          pos = obj_end
        else
          pos += 1
        end
      end
      0
    end

    # Position of the value of `"key"` inside json[obj_start...obj_end),
    # or -1. Searches nested objects too (function.name sits one level
    # down from the tool-call entry).
    def self.obj_value_pos(json, obj_start, obj_end, key)
      needle = "\"" + key + "\""
      k_at = Tep.str_find(json, needle, obj_start)
      if k_at < 0 || k_at >= obj_end
        return -1
      end
      pos = Tep::Json.skip_ws(json, k_at + needle.length)
      if pos >= obj_end || json[pos] != ":"
        return -1
      end
      pos = Tep::Json.skip_ws(json, pos + 1)
      if pos >= obj_end
        return -1
      end
      pos
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
      # inside tool-call descriptors.
      m_at = Tep.str_find(json, "\"message\"", 0)
      if m_at < 0
        out.stop_reason = "no_message"
        return out
      end
      out.content     = Llm.extract_str_field(json, "content", m_at)
      out.role        = Llm.extract_str_field(json, "role", m_at)
      out.stop_reason = Llm.extract_str_field(json, "finish_reason", m_at)
      Llm.merge_tool_calls(json, m_at, out.tool_calls)
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
      # Skip past `"key"`, whitespace and the colon. The value must be
      # a string: `"content":null` (an assistant turn that only calls
      # tools, or `"finish_reason":null` on a stream frame) is "", not
      # whatever string happens to follow.
      pos = k_at + needle.length
      while pos < json.length && (json[pos] == " " || json[pos] == ":" || json[pos] == "\n" || json[pos] == "\t" || json[pos] == "\r")
        pos += 1
      end
      if pos >= json.length || json[pos] != "\""
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
      st = Tep::Llm::StreamState.new
      Llm.read_sse_into(fd, out_stream, st)
      st.acc
    end

    # read_sse_response, filling `st` (acc / tool_calls / stop_reason)
    # instead of returning the content alone.
    def self.read_sse_into(fd, out_stream, st)
      buf          = ""
      headers_done = false
      is_chunked   = false

      while true
        ready = Tep::Scheduler.io_wait(fd, Tep::Scheduler::READ, 60)
        if ready == 0
          return 0
        end
        chunk = Sock.sphttp_recv_some(fd, 4096)
        if chunk.length == 0
          # EOF -- run the splitter over the tail once more (some
          # servers omit the trailing \n\n on close).
          if headers_done && st.leftover.length > 0
            st.leftover = st.leftover + "\n\n"
            Llm.consume_sse_events(out_stream, st)
          end
          return 0
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

        # Feed buf into the body. For chunked, dechunk first (the two
        # helpers parse twice rather than share state); for raw, the
        # body bytes ARE buf.
        if is_chunked
          consumed    = Llm.dechunk_consume(buf)
          rest        = Llm.dechunk_leftover(buf)
          buf         = rest
          st.leftover = st.leftover + consumed
        else
          st.leftover = st.leftover + buf
          buf         = ""
        end

        Llm.consume_sse_events(out_stream, st)
        if st.done
          return 0
        end
      end
      0
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
            out_stream.write("data: {" + Tep::Json.encode_pair_str("content", delta) + "}\n\n")
          end
          # Tool-call fragments accumulate by index; they are not
          # forwarded to out_stream.
          Llm.merge_tool_calls(payload, 0, state.tool_calls)
          # finish_reason on the last frame ends the stream.
          fr = Llm.extract_str_field(payload, "finish_reason", 0)
          if fr.length > 0
            state.stop_reason = fr
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
        # to_int parses the leading hex (so a `size;ext` chunk-extension
        # yields the size, not a parse error) and is >= 0, so 0 -- empty or
        # no leading hex -- is the terminating chunk / give-up point.
        n = SpinelKit::Hex.to_int(hex)
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
        n = SpinelKit::Hex.to_int(hex)   # leading-hex, >= 0 (see dechunk_consume)
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

    # Per-stream state carried across consume_sse_events / read
    # loop iterations. See chat_stream + read_sse_response for use.
    class StreamState
      attr_accessor :acc, :leftover, :done
      attr_accessor :tool_calls, :stop_reason

      def initialize
        @acc         = ""
        @leftover    = ""
        @done        = false
        @stop_reason = ""
        # Typed-empty Array[ToolCall] (seed + delete_at, as elsewhere).
        @tool_calls  = [Tep::Llm::ToolCall.new("", "", "")]
        @tool_calls.delete_at(0)
      end
    end

    # One function call requested by the model. `arguments` is the
    # JSON text of the arguments object, as the model produced it.
    class ToolCall
      attr_accessor :id, :name, :arguments

      def initialize(id, name, arguments)
        @id        = id
        @name      = name
        @arguments = arguments
      end
    end

    class Message
      attr_accessor :role, :content
      # tool_calls: set on an assistant turn that called tools (see
      # Response#to_message). tool_call_id: set on a role "tool"
      # message, naming the call it answers (see Message.tool).
      attr_accessor :tool_calls, :tool_call_id

      def initialize(role, content)
        @role = role
        @content = content
        @tool_call_id = ""
        @tool_calls = [Tep::Llm::ToolCall.new("", "", "")]
        @tool_calls.delete_at(0)
      end

      # The result of one tool call, to send back to the model.
      def self.tool(tool_call_id, content)
        m = Tep::Llm::Message.new("tool", content)
        m.tool_call_id = tool_call_id
        m
      end
    end

    class Response
      attr_accessor :content, :role, :stop_reason
      # Function calls the model asked for; empty when it answered in
      # text. stop_reason is "tool_calls" when non-empty.
      attr_accessor :tool_calls

      def initialize
        @content     = ""
        @role        = ""
        @stop_reason = ""
        @tool_calls  = [Tep::Llm::ToolCall.new("", "", "")]
        @tool_calls.delete_at(0)
      end

      # This reply as the assistant Message to append to the
      # conversation before the tool results.
      def to_message
        m = Tep::Llm::Message.new("assistant", @content)
        m.tool_calls = @tool_calls
        m
      end
    end
  end
end
