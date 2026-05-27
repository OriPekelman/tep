require_relative "helper"
require "json"

# Tep::Llm::OpenAI::Server skeleton (chunk 7.1a): a Backend subclass
# wired via Server.use, served via Server.serve!, answering GET
# /v1/models. Proves the use/serve! DSL + that the route dispatches to
# the app's Backend *override* (APP.openai_backend slot, concrete
# instance flowed in via use -- the spiked dispatch path).
class TestOpenAIServer < TepTest
  app_source <<~RB
    require 'sinatra'

    class EchoBackend < Tep::Llm::OpenAI::Backend
      def list_models
        ["echo-1", "echo-2"]
      end
      def device_kind
        "cpu"
      end
      def generate_from_tokens(model, token_ids, sampling)
        c = Tep::Llm::OpenAI::Completion.new
        c.text              = "echoed " + token_ids.length.to_s + " tokens"
        c.prompt_tokens     = token_ids.length
        c.completion_tokens = sampling.max_tokens
        c
      end
    end

    Tep::Llm::OpenAI::Server.use(EchoBackend.new)
    Tep::Llm::OpenAI::Server.serve!
  RB

  def test_models_lists_backend_models
    res = get("/v1/models")
    assert_equal "200", res.code
    assert_match(%r{application/json}, res["content-type"])
    body = JSON.parse(res.body)
    assert_equal "list", body["object"]
    ids = body["data"].map { |m| m["id"] }
    assert_equal ["echo-1", "echo-2"], ids
    assert_equal "model", body["data"][0]["object"]
    assert_equal "tep",   body["data"][0]["owned_by"]
  end

  def test_models_dispatches_to_subclass_override
    # The base Backend#list_models returns []; getting echo-1/echo-2
    # back proves the EchoBackend override is what answered (backend
    # dispatch through the APP slot reaches the subclass).
    ids = JSON.parse(get("/v1/models").body)["data"].map { |m| m["id"] }
    refute_empty ids, "route hit the base Backend (empty), not the override"
    assert_includes ids, "echo-1"
  end

  def test_completions_returns_text_completion
    res = post("/v1/completions",
               "{\"model\":\"echo-1\",\"prompt\":[10,20,30],\"max_tokens\":5}")
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal "text_completion", body["object"]
    assert_equal "echo-1", body["model"]
    # generate_from_tokens saw the 3-token prompt + max_tokens=5.
    assert_equal "echoed 3 tokens", body["choices"][0]["text"]
    assert_equal "stop", body["choices"][0]["finish_reason"]
    assert_equal 3, body["usage"]["prompt_tokens"]
    assert_equal 5, body["usage"]["completion_tokens"]
    assert_equal 8, body["usage"]["total_tokens"]
  end
end
