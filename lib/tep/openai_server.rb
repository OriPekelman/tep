# Tep::Llm::OpenAI::Server -- serve OpenAI-compatible HTTP from local
# compute (Battery 7). Unlike Tep::Proxy there's no upstream: the route
# + events shell is tep, the actual inference is a pluggable Backend an
# app supplies. See docs/OPENAI-SERVER-BATTERY.md.
#
# Chunk 7.1a (this file): the Backend interface apps subclass, the
# Server.use / .serve! DSL, and GET /v1/models. Token-level completions
# (/v1/completions), events emission, and streaming land in later
# chunks (7.1b / 7.2).
#
#   class ToyBackend < Tep::Llm::OpenAI::Backend
#     def list_models; ["smollm2-135m"]; end
#     # generate_from_tokens / device_kind / ... overridden as needed
#   end
#   Tep::Llm::OpenAI::Server.use(ToyBackend.new)
#   Tep::Llm::OpenAI::Server.serve!
#
# Why subclass-and-override + `use(ConcreteBackend.new)`: the concrete
# instance flows into the APP.openai_backend slot from the user's
# `.new`, so spinel's observed-class set includes it and the route's
# `APP.openai_backend.list_models` dispatches to the override (verified
# spike). Same shape Tep::LiveView uses for its view instances.
module Tep
  class Llm
    module OpenAI
      # The interface an app's backend implements. Defaults make a
      # bare backend safe to compile + serve (empty model list, chat
      # unsupported, cpu device). Subclasses override what they offer.
      class Backend
        # Available model names -> [String]. /v1/models wraps these.
        def list_models
          empty = [""]
          empty.delete_at(0)
          empty
        end

        # PRIMARY shape: token-level generation (maps to
        # /v1/completions, non-streaming). `token_ids` is the encoded
        # prompt (Array[Integer]); `sampling` is a
        # Tep::Llm::OpenAI::Sampling. Returns a
        # Tep::Llm::OpenAI::Completion (text + usage). The base returns
        # an empty completion so a bare backend compiles; real backends
        # override.
        def generate_from_tokens(model, token_ids, sampling)
          Tep::Llm::OpenAI::Completion.new
        end

        # STREAMING shape (7.2): the per-token variant for SSE
        # /v1/completions when the request carries "stream": true.
        # The backend writes each token to `sink` via
        # sink.emit_token(piece); the sink (Tep::Llm::OpenAI::StreamSink)
        # formats it as an OpenAI SSE frame and writes to the
        # outbound chunked stream. Blocks/yields don't lower across the
        # spinel boundary, so a typed sink replaces the block --
        # backends never see SSE wire format or the client fd.
        # Base no-op (subclasses override).
        def generate_stream_from_tokens(model, token_ids, sampling, sink)
          0
        end

        # Does this backend implement message-level (chat) generation?
        # When false, /v1/chat/completions returns 501. (The chat
        # template is per-model + an ML concern; tep doesn't ship one.)
        def supports_chat?
          false
        end

        # Message-level (chat) generation. Mirrors generate_from_tokens
        # but receives the raw req so the backend can parse the
        # messages array itself + apply its own chat template. Tep
        # doesn't pre-build a Message[] because templating + role
        # ordering is per-model; the JSON tools live in Tep::Json. The
        # return is reused from the token path (text becomes the
        # assistant message's content). Base no-op; subclasses override.
        # Only reached when supports_chat? returns true -- the handler
        # gates with a 501 otherwise.
        def chat_completion(req)
          Tep::Llm::OpenAI::Completion.new
        end

        # Streaming chat (#127). Per-token variant for SSE
        # /v1/chat/completions when the request carries "stream":true.
        # Backend writes each token to `sink` via sink.emit_token(piece);
        # the sink formats it as the OpenAI chat-streaming delta frame
        # and writes one chunked frame. Same subclass-override-sink
        # pattern as 7.2 (generate_stream_from_tokens). Base no-op.
        def chat_completion_stream(req, sink)
          0
        end

        # Backend's device, surfaced into the run_start event's
        # backend.kind at serve! time. Defaults to cpu.
        def device_kind
          "cpu"
        end

        # owned_by value for each entry in the /v1/models list. Defaults
        # to "tep"; a backend overrides to attribute models to its own
        # project (e.g. toy returns "toy").
        def model_owner
          "tep"
        end

        # Backends that can embed override this -> true (gates
        # /v1/embeddings, chunk 7.3).
        def supports_embeddings?
          false
        end

        # Embedding generation for /v1/embeddings. `token_ids` is the
        # encoded input (Array[Integer]; this server speaks IDs only,
        # tokenize client-side, same policy as generate_from_tokens).
        # Returns the pooled embedding as an Array[Float] of length
        # d_model -- the backend owns the lookup + pooling strategy
        # (toy mean-pools per-token embeddings). Base returns an empty
        # vector so a bare backend compiles; only reached when
        # supports_embeddings? is true (EmbeddingsHandler gates 501).
        def generate_embeddings(model, token_ids)
          empty = [0.0]
          empty.delete_at(0)
          empty
        end
      end

      # The mountable server. Class methods because an app wires one
      # backend per process at boot (`use`) then mounts the standard
      # routes (`serve!`).
      class Server
        # Register the app's backend. Pass a concrete Backend subclass
        # instance; it's stored on Tep::APP and dispatched per request.
        def self.use(backend)
          Tep::APP.set_openai_backend(backend)
          0
        end

        # Mount the standard OpenAI routes + (optionally) start the
        # toy/v1 events stream. `events_jsonl` is a JSONL path the
        # per-request inference event + the run_start at boot append
        # to; an empty path (the default) disables emission with zero
        # overhead. Backwards-compatible with the 7.1a/b no-arg form.
        def self.serve!(events_jsonl = "")
          events = Tep::Events.new(events_jsonl)
          Tep::APP.set_openai_events(events)
          host = ENV["HOSTNAME"]
          if host.length == 0
            host = "tep"
          end
          # backend.device_kind => the run_start's `backend.kind`; reads
          # the backend via APP.openai_backend so a `use`d subclass's
          # override answers (e.g. ToyBackend returning "cuda").
          backend_kind = Tep::APP.openai_backend.device_kind
          config_json = "{" +
            Tep::Json.encode_pair_str("server", "tep-llm-openai") + "," +
            Tep::Json.encode_pair_str("events_jsonl", events_jsonl) +
          "}"
          events.run_start(host, backend_kind, "", "", config_json)
          Tep.get("/v1/models",            Tep::Llm::OpenAI::ModelsHandler.new)
          Tep.post("/v1/completions",      Tep::Llm::OpenAI::CompletionsHandler.new)
          Tep.post("/v1/chat/completions", Tep::Llm::OpenAI::ChatCompletionsHandler.new)
          # Always mounted; the handler 501s when supports_embeddings?
          # is false (same gate shape as chat completions).
          Tep.post("/v1/embeddings",       Tep::Llm::OpenAI::EmbeddingsHandler.new)
          0
        end
      end

      # Parse the `messages` array from an OpenAI chat request body.
      # Returns [Tep::Llm::Message, ...] (one per `{role, content}`
      # object); empty if the key is missing or the value isn't an
      # array.
      #
      # Helper for `chat_completion(req)` overrides — backends that
      # need the parsed messages array (most do, for applying their
      # chat template) can call this instead of writing their own
      # JSON walker:
      #
      #   def chat_completion(req)
      #     messages = Tep::Llm::OpenAI.parse_messages(req.raw_body)
      #     # ...apply template, tokenize, generate...
      #   end
      #
      # Honors only `role` + `content` (the v1 fields). Other fields
      # in the message object (e.g. `name`, `tool_calls`) are ignored
      # for now; future chunks may extend the shape.
      def self.parse_messages(body)
        out = [Tep::Llm::Message.new("", "")]
        out.delete_at(0)
        pos = Tep::Json.find_value_start(body, "messages")
        if pos < 0
          return out
        end
        pos = Tep::Json.skip_ws(body, pos)
        if pos >= body.length || body[pos] != "["
          return out
        end
        pos += 1
        while pos < body.length
          pos = Tep::Json.skip_ws(body, pos)
          if pos >= body.length
            return out
          end
          c = body[pos]
          if c == "]"
            return out
          end
          if c == ","
            pos += 1
            next
          end
          if c == "{"
            obj_end = Tep::Json.skip_container(body, pos)
            # Parse role + content within this object range. Run two
            # passes scoped via Tep::Json's existing key search: the
            # body-wide find could match a key in a sibling object so
            # we instead walk the bytes between `pos` and `obj_end`
            # manually, looking only for `"role"` / `"content"`.
            role = Tep::Llm::OpenAI.find_obj_key_str(body, pos, obj_end, "role")
            cont = Tep::Llm::OpenAI.find_obj_key_str(body, pos, obj_end, "content")
            out.push(Tep::Llm::Message.new(role, cont))
            pos = obj_end
          else
            pos = Tep::Json.skip_value(body, pos)
          end
        end
        out
      end

      # Scan body[obj_start..obj_end) for `"key":"<value>"` and return
      # the unescaped value. Returns "" if the key isn't present. Used
      # by parse_messages above to extract per-message fields without
      # crossing into adjacent message objects.
      def self.find_obj_key_str(body, obj_start, obj_end, key)
        needle = "\"" + key + "\""
        pos = Tep.str_find(body, needle, obj_start)
        if pos < 0 || pos >= obj_end
          return ""
        end
        pos = pos + needle.length
        pos = Tep::Json.skip_ws(body, pos)
        if pos >= obj_end || body[pos] != ":"
          return ""
        end
        pos += 1
        pos = Tep::Json.skip_ws(body, pos)
        if pos >= obj_end
          return ""
        end
        Tep::Json.parse_str_value(body, pos)
      end

      # Sampling parameters handed to the backend. v1 carries
      # max_tokens + temperature + top_p (the three OpenAI completion
      # knobs every client sets). Floats parsed via Tep::Json.get_float.
      # Defaults match OpenAI's API defaults so a backend that ignores
      # sampling gets pass-through behavior.
      class Sampling
        attr_accessor :max_tokens, :temperature, :top_p

        def initialize
          @max_tokens  = 0
          @temperature = 1.0
          @top_p       = 1.0
        end
      end

      # A backend's generation result: the decoded text + token usage.
      #
      # token_ids carries the GENERATED token IDs for an IDs-only backend
      # (no detokenizer): when non-empty, CompletionsHandler emits them as
      # choices[0].ids alongside text (which such a backend leaves ""),
      # matching the "tokenize/detokenize client-side" serving contract.
      # Text backends leave token_ids empty and the ids field is omitted.
      # finish_reason defaults to "stop"; a fixed-length greedy backend
      # sets "length".
      class Completion
        attr_accessor :text, :prompt_tokens, :completion_tokens
        attr_accessor :token_ids, :finish_reason

        def initialize
          @text              = ""
          @prompt_tokens     = 0
          @completion_tokens = 0
          # Typed-empty Array[Integer] seed (the [0]; delete_at(0) landmine
          # pattern) so Spinel emits an IntArray slot, not poly.
          @token_ids         = [0]
          @token_ids.delete_at(0)
          @finish_reason     = "stop"
        end
      end

      # The per-token write surface a streaming backend uses (7.2). One
      # method: `emit_token(piece)`. The sink formats `piece` as an
      # OpenAI text-completion SSE frame and writes one chunked frame
      # to the outbound stream. Counts emitted tokens for the
      # inference event's completion_tokens.
      #
      # Why a sink object instead of a block: spinel can't lower a
      # block parameter across the backend call boundary; a typed
      # object with one method does the same job through ordinary
      # virtual dispatch.
      class StreamSink
        attr_accessor :out, :model, :completion_count

        def initialize
          @model            = ""
          @completion_count = 0
        end

        # Write one SSE event carrying a single text delta. Matches
        # OpenAI's text_completion streaming shape: one choices[].text
        # per event, finish_reason: null until the streamer sends
        # [DONE]. created uses Time.now.to_i (epoch seconds).
        def emit_token(piece)
          @completion_count = @completion_count + 1
          frame = "{" +
            Tep::Json.encode_pair_str("id", "cmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "text_completion") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              Tep::Json.encode_pair_str("text", piece) + "," +
              "\"finish_reason\":null" +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end
      end

      # Runs one streaming completion. Subclass of Tep::Streamer so the
      # server pumps `pump(out)` cooperatively; we own the SSE shape
      # end-to-end: drive the backend through StreamSink, write the
      # terminating data:[DONE], then emit the toy/v1 serving event
      # (kind:eval, phase:serve, name:request) via Events#inference.
      class CompletionsStreamer < Tep::Streamer
        attr_accessor :model, :token_ids, :sampling
        attr_accessor :prompt_tokens, :t0, :request_id, :principal_id

        def initialize
          @model         = ""
          @token_ids     = [0]
          @token_ids.delete_at(0)
          @sampling      = Tep::Llm::OpenAI::Sampling.new
          @prompt_tokens = 0
          @t0            = 0
          @request_id    = ""
          @principal_id  = ""
        end

        def pump(out)
          sink = Tep::Llm::OpenAI::StreamSink.new
          sink.out   = out
          sink.model = @model
          Tep::APP.openai_backend.generate_stream_from_tokens(
            @model, @token_ids, @sampling, sink)
          # Terminating sentinel + inference event. wall_us is
          # second-resolution for the same reason as the non-streaming
          # path (spinel Time.now exposes epoch-int only); LLM is
          # seconds-scale, populated wall_us is enough signal.
          out.write("data: [DONE]\n\n")
          wall_us = (Time.now.to_i - @t0) * 1_000_000
          extra = "{" +
            Tep::Json.encode_pair_str("request_id", @request_id) + "," +
            Tep::Json.encode_pair_str("principal_id", @principal_id) +
          "}"
          Tep::APP.openai_events.inference(
            @model, @prompt_tokens, sink.completion_count, wall_us, extra)
          0
        end
      end

      # Chat-streaming write surface (#127). Three emit_* methods
      # cover the OpenAI chat-streaming wire shape:
      #
      #   1. emit_role_prelude("assistant") -> first frame carries
      #      `delta:{role:"assistant"}` (no content).
      #   2. emit_token(piece) -> N content frames, each
      #      `delta:{content:<piece>}` with finish_reason:null.
      #   3. emit_finish("stop") -> last frame carries an empty
      #      `delta:{}` with finish_reason set; the streamer then
      #      writes the terminating data:[DONE].
      #
      # Backends typically: sink.emit_role_prelude("assistant"); then
      # call sink.emit_token(piece) per generated token. emit_finish
      # is invoked by the streamer after the backend returns -- not
      # the backend's responsibility.
      class ChatStreamSink
        attr_accessor :out, :model, :completion_count

        def initialize
          @model            = ""
          @completion_count = 0
        end

        # First frame: role-only delta, no content. Per OpenAI's
        # wire shape, sent once before content frames.
        def emit_role_prelude(role)
          frame = "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion.chunk") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"delta\":{" +
                Tep::Json.encode_pair_str("role", role) +
              "}," +
              "\"finish_reason\":null" +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end

        # Content delta. One per generated token.
        def emit_token(piece)
          @completion_count = @completion_count + 1
          frame = "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion.chunk") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"delta\":{" +
                Tep::Json.encode_pair_str("content", piece) +
              "}," +
              "\"finish_reason\":null" +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end

        # Final frame: empty delta + populated finish_reason. The
        # streamer writes data:[DONE] after this.
        def emit_finish(reason)
          frame = "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion.chunk") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", @model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"delta\":{}," +
              Tep::Json.encode_pair_str("finish_reason", reason) +
            "}]" +
          "}"
          @out.write("data: " + frame + "\n\n")
          0
        end
      end

      # Runs one streaming chat completion. Subclass of Tep::Streamer.
      # Drives backend.chat_completion_stream through ChatStreamSink,
      # writes the terminating data:[DONE], then emits the toy/v1
      # serving event (kind:eval, phase:serve, name:request) with
      # sink.completion_count (mirrors CompletionsStreamer's #128 shape).
      class ChatCompletionsStreamer < Tep::Streamer
        attr_accessor :req_ref, :model, :prompt_tokens
        attr_accessor :t0, :request_id, :principal_id

        def initialize
          @req_ref       = Tep::Request.new
          @model         = ""
          @prompt_tokens = 0
          @t0            = 0
          @request_id    = ""
          @principal_id  = ""
        end

        def pump(out)
          sink = Tep::Llm::OpenAI::ChatStreamSink.new
          sink.out   = out
          sink.model = @model
          sink.emit_role_prelude("assistant")
          Tep::APP.openai_backend.chat_completion_stream(@req_ref, sink)
          sink.emit_finish("stop")
          out.write("data: [DONE]\n\n")
          wall_us = (Time.now.to_i - @t0) * 1_000_000
          extra = "{" +
            Tep::Json.encode_pair_str("request_id", @request_id) + "," +
            Tep::Json.encode_pair_str("principal_id", @principal_id) +
          "}"
          Tep::APP.openai_events.inference(
            @model, @prompt_tokens, sink.completion_count, wall_us, extra)
          0
        end
      end

      # GET /v1/models -- the standard OpenAI list envelope, built from
      # backend.list_models. Dispatches through APP.openai_backend so
      # the app's subclass override is what answers.
      class ModelsHandler < Tep::Handler
        def handle(req, res)
          res.headers["Content-Type"] = "application/json"
          models  = Tep::APP.openai_backend.list_models
          owner   = Tep::APP.openai_backend.model_owner
          created = Time.now.to_i
          out = "{\"object\":\"list\",\"data\":["
          i = 0
          while i < models.length
            if i > 0
              out = out + ","
            end
            out = out + "{" +
              Tep::Json.encode_pair_str("id", models[i]) + "," +
              Tep::Json.encode_pair_str("object", "model") + "," +
              Tep::Json.encode_pair_int("created", created) + "," +
              Tep::Json.encode_pair_str("owned_by", owner) +
            "}"
            i += 1
          end
          out = out + "]}"
          out
        end
      end

      # POST /v1/completions -- token-level OpenAI shape (the primary
      # completion route). Parses model / prompt (token ids) /
      # max_tokens, calls backend.generate_from_tokens, and formats the
      # standard text_completion response. Dispatches through
      # APP.openai_backend (the app's subclass override answers).
      class CompletionsHandler < Tep::Handler
        def handle(req, res)
          body      = req.raw_body
          model     = Tep::Json.get_str(body, "model")
          token_ids = Tep::Json.get_int_array(body, "prompt")
          sampling  = Tep::Llm::OpenAI::Sampling.new
          sampling.max_tokens = Tep::Json.get_int(body, "max_tokens")
          # Floats from the JSON body; defaults stay at 1.0 if the
          # key is absent (Tep::Json.get_float returns 0.0 for
          # missing, but we only overwrite when present).
          if Tep::Json.has_key?(body, "temperature")
            sampling.temperature = Tep::Json.get_float(body, "temperature")
          end
          if Tep::Json.has_key?(body, "top_p")
            sampling.top_p = Tep::Json.get_float(body, "top_p")
          end

          # OpenAI signals streaming with "stream": true in the JSON
          # body; Tep::Json has no bool getter, so we sniff the literal
          # (same shape as examples/llm_gateway/app.rb). When set, the
          # response is SSE: a CompletionsStreamer pumps per-token
          # frames + the [DONE] sentinel, then emits the inference
          # event with sink.completion_count.
          wants_stream = Tep.str_find(body, "\"stream\":true", 0) >= 0 ||
                         Tep.str_find(body, "\"stream\": true", 0) >= 0
          if wants_stream
            res.headers["Content-Type"]  = "text/event-stream"
            res.headers["Cache-Control"] = "no-cache"
            streamer = Tep::Llm::OpenAI::CompletionsStreamer.new
            streamer.model         = model
            streamer.token_ids     = token_ids
            streamer.sampling      = sampling
            streamer.prompt_tokens = token_ids.length
            streamer.t0            = Time.now.to_i
            streamer.request_id    = "cmpl-tep"
            streamer.principal_id  = req.identity.subject
            res.start_stream(streamer)
            return ""
          end

          res.headers["Content-Type"] = "application/json"

          # Stamp t0 for the inference event's wall_us. Time.now exposes
          # only integer epoch seconds under spinel, so wall_us is at
          # second-resolution (latency * 1_000_000) -- coarse, but LLM
          # serving is seconds-scale, fine for the run-level analytics.
          # A µs clock helper lands later; until then this is the right
          # placeholder shape so consumers see populated wall_us.
          t0 = Time.now.to_i

          comp = Tep::APP.openai_backend.generate_from_tokens(model, token_ids, sampling)
          total = comp.prompt_tokens + comp.completion_tokens

          # Emit one inference event per request. Skipped when events
          # are disabled via path-length short-circuit inside #inference.
          # request_id matches the JSON response's id; principal_id is
          # the auth-filter populated identity (anonymous if none).
          wall_us = (Time.now.to_i - t0) * 1_000_000
          extra = "{" +
            Tep::Json.encode_pair_str("request_id", "cmpl-tep") + "," +
            Tep::Json.encode_pair_str("principal_id", req.identity.subject) +
          "}"
          Tep::APP.openai_events.inference(
            model, comp.prompt_tokens, comp.completion_tokens, wall_us, extra
          )

          # IDs-only backends (no detokenizer) carry the generated token
          # IDs; emit them as choices[0].ids. Text backends leave token_ids
          # empty and the field is omitted (standard OpenAI shape).
          ids_frag = ""
          if comp.token_ids.length > 0
            ids_frag = "\"ids\":" + Tep::Json.from_int_array(comp.token_ids) + ","
          end

          "{" +
            Tep::Json.encode_pair_str("id", "cmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "text_completion") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              Tep::Json.encode_pair_str("text", comp.text) + "," +
              ids_frag +
              Tep::Json.encode_pair_str("finish_reason", comp.finish_reason) +
            "}]," +
            "\"usage\":{" +
              Tep::Json.encode_pair_int("prompt_tokens", comp.prompt_tokens) + "," +
              Tep::Json.encode_pair_int("completion_tokens", comp.completion_tokens) + "," +
              Tep::Json.encode_pair_int("total_tokens", total) +
            "}" +
          "}"
        end
      end

      # POST /v1/chat/completions -- message-level OpenAI shape. Skeleton
      # for now: gated 501 when backend.supports_chat? is false (the
      # default; chat templating is per-model + an ML concern tep
      # doesn't ship). When a backend opts in (overrides supports_chat?
      # to true + chat_completion), this dispatches to it and formats
      # the standard chat.completion envelope around the returned
      # Completion (the text field becomes the assistant message's
      # content). Streaming chat lands later.
      class ChatCompletionsHandler < Tep::Handler
        def handle(req, res)
          res.headers["Content-Type"] = "application/json"
          if !Tep::APP.openai_backend.supports_chat?
            res.set_status(501)
            return "{" +
              "\"error\":{" +
                Tep::Json.encode_pair_str("message",
                  "chat completions not supported by this backend") + "," +
                Tep::Json.encode_pair_str("type", "not_implemented") +
              "}" +
            "}"
          end
          body  = req.raw_body
          model = Tep::Json.get_str(body, "model")

          # Streaming branch (#127): same "stream":true sniff as
          # CompletionsHandler. Sends an SSE response driven by
          # ChatCompletionsStreamer -- which calls into
          # backend.chat_completion_stream via a ChatStreamSink.
          wants_stream = Tep.str_find(body, "\"stream\":true", 0) >= 0 ||
                         Tep.str_find(body, "\"stream\": true", 0) >= 0
          if wants_stream
            res.headers["Content-Type"]  = "text/event-stream"
            res.headers["Cache-Control"] = "no-cache"
            streamer = Tep::Llm::OpenAI::ChatCompletionsStreamer.new
            streamer.req_ref       = req
            streamer.model         = model
            # No `prompt` token-id array on chat requests; pass 0 so
            # the inference event has a deterministic value. A future
            # refinement can derive prompt_tokens from the messages
            # array's byte length / tokenizer estimate.
            streamer.prompt_tokens = 0
            streamer.t0            = Time.now.to_i
            streamer.request_id    = "chatcmpl-tep"
            streamer.principal_id  = req.identity.subject
            res.start_stream(streamer)
            return ""
          end

          comp  = Tep::APP.openai_backend.chat_completion(req)
          total = comp.prompt_tokens + comp.completion_tokens
          "{" +
            Tep::Json.encode_pair_str("id", "chatcmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "chat.completion") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"message\":{" +
                Tep::Json.encode_pair_str("role", "assistant") + "," +
                Tep::Json.encode_pair_str("content", comp.text) +
              "}," +
              Tep::Json.encode_pair_str("finish_reason", "stop") +
            "}]," +
            "\"usage\":{" +
              Tep::Json.encode_pair_int("prompt_tokens", comp.prompt_tokens) + "," +
              Tep::Json.encode_pair_int("completion_tokens", comp.completion_tokens) + "," +
              Tep::Json.encode_pair_int("total_tokens", total) +
            "}" +
          "}"
        end
      end

      # POST /v1/embeddings -- OpenAI embeddings shape. Gated 501 when
      # backend.supports_embeddings? is false (the default). When a
      # backend opts in, parses the IDs-only `input` array, asks the
      # backend for the pooled vector, and formats the standard
      # embeddings envelope. Mirrors toy's mean-pooled handler -- the
      # pooling strategy lives in the backend, not here.
      class EmbeddingsHandler < Tep::Handler
        def handle(req, res)
          res.headers["Content-Type"] = "application/json"
          if !Tep::APP.openai_backend.supports_embeddings?
            res.set_status(501)
            return "{" +
              "\"error\":{" +
                Tep::Json.encode_pair_str("message",
                  "embeddings not supported by this backend") + "," +
                Tep::Json.encode_pair_str("type", "not_implemented") +
              "}" +
            "}"
          end
          body  = req.raw_body
          model = Tep::Json.get_str(body, "model")
          ids   = Tep::Json.get_int_array(body, "input")
          if ids.length == 0
            res.set_status(400)
            return "{" +
              "\"error\":{" +
                Tep::Json.encode_pair_str("message",
                  "input must be a non-empty integer array " +
                  "(this server speaks token IDs only; tokenize client-side)") + "," +
                Tep::Json.encode_pair_str("type", "invalid_request_error") +
              "}" +
            "}"
          end

          vec = Tep::APP.openai_backend.generate_embeddings(model, ids)

          # Build the embedding float array by hand: Tep::Json has no
          # float-array encoder, and Float#to_s yields a JSON number.
          emb = "["
          k = 0
          while k < vec.length
            if k > 0
              emb = emb + ","
            end
            emb = emb + vec[k].to_s
            k = k + 1
          end
          emb = emb + "]"

          n = ids.length
          "{" +
            Tep::Json.encode_pair_str("object", "list") + "," +
            "\"data\":[{" +
              Tep::Json.encode_pair_str("object", "embedding") + "," +
              Tep::Json.encode_pair_int("index", 0) + "," +
              "\"embedding\":" + emb +
            "}]," +
            Tep::Json.encode_pair_str("model", model) + "," +
            "\"usage\":{" +
              Tep::Json.encode_pair_int("prompt_tokens", n) + "," +
              Tep::Json.encode_pair_int("total_tokens", n) +
            "}" +
          "}"
        end
      end
    end
  end
end
