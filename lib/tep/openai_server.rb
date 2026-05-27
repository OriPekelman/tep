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

        # Mount the standard OpenAI routes. 7.1a: GET /v1/models.
        # Later chunks add /v1/completions (+ events) and the
        # chat/embeddings routes.
        def self.serve!
          Tep.get("/v1/models", Tep::Llm::OpenAI::ModelsHandler.new)
          0
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
    end
  end
end
