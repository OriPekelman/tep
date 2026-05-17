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
