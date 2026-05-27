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
end
