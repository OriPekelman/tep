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

# Tep::Llm::OpenAI::Server events emission (chunk 7.1c): with a
# non-empty events_jsonl path, serve! emits one run_start at boot and
# CompletionsHandler emits one inference per /v1/completions request.
# Disabled (empty path) leaves zero footprint -- exercised by the
# TestOpenAIServer class above, which doesn't pass an events arg.
class TestOpenAIServerEvents < TepTest
  EVENTS_PATH = "/tmp/tep_test_openai_events.jsonl"

  app_source <<~RB
    require 'sinatra'

    class EchoBackend < Tep::Llm::OpenAI::Backend
      def list_models
        ["echo-1"]
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
    Tep::Llm::OpenAI::Server.serve!("#{EVENTS_PATH}")
  RB

  # Wipe the events file ONCE, before the lazy boot. boot! is memoised
  # so serve!'s run_start only emits on the first setup call; deleting
  # the file after boot would lose the run_start the test asserts on.
  # A leftover file from a previous `make test` run would otherwise
  # poison the inference-count assertion.
  @@events_path_cleaned = false
  def setup
    unless @@events_path_cleaned
      File.delete(EVENTS_PATH) if File.exist?(EVENTS_PATH)
      @@events_path_cleaned = true
    end
    super
  end

  def test_events_jsonl_populated
    # serve! ran during binary boot -> a run_start should already be on
    # disk before we make any request. (The test harness boots the
    # compiled binary before this method runs.)
    assert File.exist?(EVENTS_PATH), "events file not created at serve!"
    lines = File.readlines(EVENTS_PATH).map { |l| JSON.parse(l) }
    rs = lines.find { |e| e["kind"] == "run_start" }
    refute_nil rs, "no run_start emitted"
    assert_equal "toy/v1", rs["schema"]
    assert_equal "cpu",    rs["backend"]["kind"]

    # POST /v1/completions -> exactly one inference event appended.
    res = post("/v1/completions",
               "{\"model\":\"echo-1\",\"prompt\":[1,2,3,4],\"max_tokens\":7}")
    assert_equal "200", res.code

    lines2 = File.readlines(EVENTS_PATH).map { |l| JSON.parse(l) }
    inferences = lines2.select { |e| e["kind"] == "inference" }
    assert_equal 1, inferences.length, "expected exactly one inference event"
    inf = inferences[0]
    assert_equal "serve",  inf["phase"]
    assert_equal "echo-1", inf["model"]
    assert_equal 4,        inf["prompt_tokens"]
    assert_equal 7,        inf["completion_tokens"]
    assert_kind_of Integer, inf["wall_us"]
    assert inf["wall_us"] >= 0
    extra = inf["extra"]
    assert_equal "cmpl-tep", extra["request_id"]
    assert_match(/\Auser:/, extra["principal_id"])
  end
end

# Tep::Llm::OpenAI::Server streaming completions (chunk 7.2): with
# "stream": true in the body, /v1/completions responds SSE-style. The
# backend writes tokens through a Tep::Llm::OpenAI::StreamSink (no
# block-yield -- spinel can't lower one across the backend boundary);
# the CompletionsStreamer terminates the stream with data: [DONE] and
# emits the toy/v1 inference event with sink.completion_count.
class TestOpenAIServerStreaming < TepTest
  EVENTS_PATH = "/tmp/tep_test_openai_stream_events.jsonl"

  app_source <<~RB
    require 'sinatra'

    class EchoStreamBackend < Tep::Llm::OpenAI::Backend
      def list_models
        ["echo-stream"]
      end
      def device_kind
        "cpu"
      end
      def generate_stream_from_tokens(model, token_ids, sampling, sink)
        # Emit one delta per prompt token -- simplest deterministic
        # shape the test can assert on.
        i = 0
        while i < token_ids.length
          sink.emit_token("t" + token_ids[i].to_s + " ")
          i += 1
        end
        0
      end
    end

    Tep::Llm::OpenAI::Server.use(EchoStreamBackend.new)
    Tep::Llm::OpenAI::Server.serve!("#{EVENTS_PATH}")
  RB

  @@events_path_cleaned = false
  def setup
    unless @@events_path_cleaned
      File.delete(EVENTS_PATH) if File.exist?(EVENTS_PATH)
      @@events_path_cleaned = true
    end
    super
  end

  def test_streaming_emits_sse_with_done_and_inference_event
    body = "{\"model\":\"echo-stream\",\"prompt\":[7,8,9],\"max_tokens\":5,\"stream\":true}"
    res  = post("/v1/completions", body)
    assert_equal "200", res.code
    assert_match(%r{text/event-stream}, res["content-type"])

    # Three token deltas + [DONE] sentinel.
    data_lines = res.body.scan(/^data: (.+)$/).flatten
    assert_equal 4, data_lines.length, "expected 3 token frames + 1 [DONE]"
    assert_equal "[DONE]", data_lines.last
    frames = data_lines[0..-2].map { |l| JSON.parse(l) }
    assert_equal ["t7 ", "t8 ", "t9 "], frames.map { |f| f["choices"][0]["text"] }
    assert_equal [nil, nil, nil],        frames.map { |f| f["choices"][0]["finish_reason"] }
    assert_equal ["echo-stream", "echo-stream", "echo-stream"],
                 frames.map { |f| f["model"] }

    # And the inference event landed in the JSONL with the right
    # completion_count (= 3, the number of emit_token calls).
    lines = File.readlines(EVENTS_PATH).map { |l| JSON.parse(l) }
    inferences = lines.select { |e| e["kind"] == "inference" }
    assert_equal 1, inferences.length
    inf = inferences[0]
    assert_equal "echo-stream", inf["model"]
    assert_equal 3,             inf["prompt_tokens"]
    assert_equal 3,             inf["completion_tokens"]
    assert_equal "cmpl-tep",    inf["extra"]["request_id"]
  end
end
