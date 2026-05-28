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
        # /v1/completions). `token_ids` is the encoded prompt
        # (Array[Integer]); `sampling` is a Tep::Llm::OpenAI::Sampling.
        # Returns a Tep::Llm::OpenAI::Completion (text + usage). This
        # 7.1b form is non-streaming -- it returns the full result;
        # the per-token block-yield variant for SSE lands in 7.2. The
        # base returns an empty completion so a bare backend compiles;
        # real backends override.
        def generate_from_tokens(model, token_ids, sampling)
          Tep::Llm::OpenAI::Completion.new
        end

        # Does this backend implement message-level (chat) generation?
        # When false, /v1/chat/completions returns 501. (The chat
        # template is per-model + an ML concern; tep doesn't ship one.)
        def supports_chat?
          false
        end

        # Backend's device, surfaced into the run_start event's
        # backend.kind at serve! time. Defaults to cpu.
        def device_kind
          "cpu"
        end

        # Backends that can embed override this -> true (gates
        # /v1/embeddings, chunk 7.3).
        def supports_embeddings?
          false
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
          Tep.get("/v1/models",       Tep::Llm::OpenAI::ModelsHandler.new)
          Tep.post("/v1/completions", Tep::Llm::OpenAI::CompletionsHandler.new)
          0
        end
      end

      # Sampling parameters handed to the backend. v1 carries max_tokens
      # (the int tep needs to bound generation); temperature / top_p are
      # JSON-number floats, which tep can't represent natively (no
      # Float) -- a float-capable chunk adds them. A backend that needs
      # them today reads the raw request body itself.
      class Sampling
        attr_accessor :max_tokens

        def initialize
          @max_tokens = 0
        end
      end

      # A backend's generation result: the decoded text + token usage.
      class Completion
        attr_accessor :text, :prompt_tokens, :completion_tokens

        def initialize
          @text              = ""
          @prompt_tokens     = 0
          @completion_tokens = 0
        end
      end

      # GET /v1/models -- the standard OpenAI list envelope, built from
      # backend.list_models. Dispatches through APP.openai_backend so
      # the app's subclass override is what answers.
      class ModelsHandler < Tep::Handler
        def handle(req, res)
          res.headers["Content-Type"] = "application/json"
          models = Tep::APP.openai_backend.list_models
          out = "{\"object\":\"list\",\"data\":["
          i = 0
          while i < models.length
            if i > 0
              out = out + ","
            end
            out = out + "{" +
              Tep::Json.encode_pair_str("id", models[i]) + "," +
              Tep::Json.encode_pair_str("object", "model") + "," +
              Tep::Json.encode_pair_str("owned_by", "tep") +
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
          res.headers["Content-Type"] = "application/json"
          body      = req.raw_body
          model     = Tep::Json.get_str(body, "model")
          token_ids = Tep::Json.get_int_array(body, "prompt")
          sampling  = Tep::Llm::OpenAI::Sampling.new
          sampling.max_tokens = Tep::Json.get_int(body, "max_tokens")

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

          "{" +
            Tep::Json.encode_pair_str("id", "cmpl-tep") + "," +
            Tep::Json.encode_pair_str("object", "text_completion") + "," +
            Tep::Json.encode_pair_int("created", Time.now.to_i) + "," +
            Tep::Json.encode_pair_str("model", model) + "," +
            "\"choices\":[{" +
              Tep::Json.encode_pair_int("index", 0) + "," +
              Tep::Json.encode_pair_str("text", comp.text) + "," +
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
    end
  end
end
