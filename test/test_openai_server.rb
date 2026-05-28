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
        # Echo back the sampling knobs so the test can assert they
        # reached the backend with the values the client requested.
        c.text              = "echoed " + token_ids.length.to_s +
                              " tokens t=" + sampling.temperature.to_s +
                              " p=" + sampling.top_p.to_s
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

  def test_chat_completions_returns_501_when_unsupported
    # Default backend.supports_chat? is false (EchoBackend doesn't
    # override it) -> the route returns 501 with an OpenAI-shape
    # error JSON, not a 200 / not a 404. Closes the gap that
    # /v1/chat/completions doesn't exist as a route until a backend
    # opts in.
    res = post("/v1/chat/completions",
               "{\"model\":\"echo-1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
    assert_equal "501", res.code
    assert_match(%r{application/json}, res["content-type"])
    body = JSON.parse(res.body)
    assert_equal "not_implemented", body["error"]["type"]
    assert_match(/chat completions not supported/, body["error"]["message"])
  end

  def test_completions_returns_text_completion
    # No temperature / top_p sent -> defaults of 1.0 reach the backend.
    res = post("/v1/completions",
               "{\"model\":\"echo-1\",\"prompt\":[10,20,30],\"max_tokens\":5}")
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal "text_completion", body["object"]
    assert_equal "echo-1", body["model"]
    assert_equal "echoed 3 tokens t=1.0 p=1.0", body["choices"][0]["text"]
    assert_equal "stop", body["choices"][0]["finish_reason"]
    assert_equal 3, body["usage"]["prompt_tokens"]
    assert_equal 5, body["usage"]["completion_tokens"]
    assert_equal 8, body["usage"]["total_tokens"]
  end

  def test_completions_threads_temperature_and_top_p
    # Explicit floats in the body -> Sampling.temperature/top_p set.
    res = post("/v1/completions",
               "{\"model\":\"echo-1\",\"prompt\":[1,2]," +
               "\"max_tokens\":1,\"temperature\":0.7,\"top_p\":0.9}")
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal "echoed 2 tokens t=0.7 p=0.9", body["choices"][0]["text"]
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
    # #136: inference events are kind:"eval"+name:"request"; per-request
    # fields nested under extra.
    inferences = lines2.select { |e| e["kind"] == "eval" && e["name"] == "request" }
    assert_equal 1, inferences.length, "expected exactly one inference event"
    inf = inferences[0]
    assert_equal "serve", inf["phase"]
    extra = inf["extra"]
    assert_equal "echo-1", extra["model"]
    assert_equal 4,        extra["prompt_tokens"]
    assert_equal 7,        extra["completion_tokens"]
    assert_kind_of Integer, extra["latency_us"]
    assert extra["latency_us"] >= 0
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
    # #136 spec shape: kind:"eval"+name:"request", per-request fields
    # nested under extra.
    inferences = lines.select { |e| e["kind"] == "eval" && e["name"] == "request" }
    assert_equal 1, inferences.length
    inf = inferences[0]
    assert_equal "echo-stream", inf["extra"]["model"]
    assert_equal 3,             inf["extra"]["prompt_tokens"]
    assert_equal 3,             inf["extra"]["completion_tokens"]
    assert_equal "cmpl-tep",    inf["extra"]["request_id"]
  end
end

# Tep::Llm::OpenAI::Server shutdown hook (SIGTERM/SIGINT -> run_end).
# Boots the binary normally, hits one /v1/completions to advance the
# stats, then SIGTERMs the spawned pid and asserts the events JSONL
# acquired a `run_end` line with the expected stats.
class TestOpenAIServerShutdown < TepTest
  EVENTS_PATH = "/tmp/tep_test_openai_shutdown.jsonl"

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
        c.text              = "ok"
        c.prompt_tokens     = token_ids.length
        c.completion_tokens = 1
        c
      end
    end

    Tep::Llm::OpenAI::Server.use(EchoBackend.new)
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

  def test_sigterm_emits_run_end
    # One request bumps requests=1, tokens_out=1.
    res = post("/v1/completions",
               "{\"model\":\"echo-1\",\"prompt\":[10,20,30],\"max_tokens\":1}")
    assert_equal "200", res.code

    # SIGTERM the server. accept(2) returns -1 with the term flag set;
    # the worker loop runs Tep.on_shutdown -> Tep::Events#run_end.
    TepHarness.terminate(@port)

    lines = File.readlines(EVENTS_PATH).map { |l| JSON.parse(l) }
    re = lines.find { |e| e["kind"] == "run_end" }
    refute_nil re, "expected a run_end event after SIGTERM"
    # reason: "completed" harmonised with toy/v1 vocabulary in #115.
    assert_equal "completed", re["reason"]
    assert_equal 1,    re["stats"]["requests"]
    assert_equal 1,    re["stats"]["tokens_out"]
    assert_equal 0,    re["stats"]["errors"]
  end
end

# Tep::Llm::OpenAI::Server cross-worker run_end aggregation (#128).
# Spawns the binary in prefork mode (workers=2); fires two /v1/completions
# requests so each worker most-likely handles one (SO_REUSEPORT
# load-balances); SIGTERMs the parent; asserts exactly ONE run_end
# in the JSONL with stats.requests=2 (aggregated across workers).
#
# The pre-#128 behaviour was N run_ends per N workers, each with that
# worker's local stats.
class TestOpenAIServerRunEndMultiWorker < TepTest
  EVENTS_PATH = "/tmp/tep_test_openai_runend_multi.jsonl"

  workers 2

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
        c.text              = "ok"
        c.prompt_tokens     = token_ids.length
        c.completion_tokens = 2   # contributes 2 to aggregated tokens_out
        c
      end
    end

    Tep::Llm::OpenAI::Server.use(EchoBackend.new)
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

  def test_parent_only_run_end_with_aggregated_stats
    # 4 sequential requests; SO_REUSEPORT load-balances across workers.
    # The test is shape-only on which worker handled which; we just
    # need the AGGREGATED count to be 4 in the single run_end below.
    4.times do |i|
      res = post("/v1/completions",
                 "{\"model\":\"echo-1\",\"prompt\":[#{i}],\"max_tokens\":1}")
      assert_equal "200", res.code, "request #{i}"
    end

    TepHarness.terminate(@port)

    lines = File.readlines(EVENTS_PATH).map { |l| JSON.parse(l) }
    run_ends = lines.select { |e| e["kind"] == "run_end" }
    assert_equal 1, run_ends.length,
      "expected exactly one run_end across workers (was #{run_ends.length})"
    re = run_ends[0]
    assert_equal "completed", re["reason"]
    # 4 requests across the workers, each with completion_tokens=2.
    assert_equal 4, re["stats"]["requests"]
    assert_equal 8, re["stats"]["tokens_out"]
    assert_equal 0, re["stats"]["errors"]
  end
end

# Tep::Llm::OpenAI::Server chat completions when a backend opts in.
# Default backend.supports_chat? is false (TestOpenAIServer covers the
# 501 gate); here ChatBackend overrides supports_chat? + chat_completion
# to prove the 200 path -- chat.completion envelope around the
# assistant message.
class TestOpenAIServerChat < TepTest
  app_source <<~RB
    require 'sinatra'

    class ChatBackend < Tep::Llm::OpenAI::Backend
      def list_models
        ["chat-1"]
      end
      def supports_chat?
        true
      end
      def chat_completion(req)
        # Demonstrates Tep::Llm::OpenAI.parse_messages: pull the
        # roles+contents out of the request body and echo the LAST
        # user content back as the assistant reply. A real backend
        # would tokenize + run inference + decode here.
        msgs = Tep::Llm::OpenAI.parse_messages(req.raw_body)
        last_user_content = ""
        i = 0
        while i < msgs.length
          if msgs[i].role == "user"
            last_user_content = msgs[i].content
          end
          i += 1
        end
        c = Tep::Llm::OpenAI::Completion.new
        c.text              = "echo: " + last_user_content
        c.prompt_tokens     = msgs.length * 4   # synthetic
        c.completion_tokens = 1
        c
      end
    end

    Tep::Llm::OpenAI::Server.use(ChatBackend.new)
    Tep::Llm::OpenAI::Server.serve!
  RB

  def test_chat_completion_envelope_when_supported
    res = post("/v1/chat/completions",
               "{\"model\":\"chat-1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal "chat.completion", body["object"]
    assert_equal "chat-1",          body["model"]
    assert_equal "assistant", body["choices"][0]["message"]["role"]
    # parse_messages saw one user message with content "hi";
    # the backend echoes that as the assistant reply.
    assert_equal "echo: hi",  body["choices"][0]["message"]["content"]
    assert_equal "stop",      body["choices"][0]["finish_reason"]
    # prompt_tokens = msgs.length * 4 = 4 (one message).
    assert_equal 4, body["usage"]["prompt_tokens"]
    assert_equal 1, body["usage"]["completion_tokens"]
    assert_equal 5, body["usage"]["total_tokens"]
  end

  def test_chat_parse_messages_multi_turn
    # Multiple turns + interleaved roles. parse_messages should walk
    # them in order; the backend echoes the LAST user content.
    body_json = "{\"model\":\"chat-1\",\"messages\":[" +
                "{\"role\":\"system\",\"content\":\"you are helpful\"}," +
                "{\"role\":\"user\",\"content\":\"first\"}," +
                "{\"role\":\"assistant\",\"content\":\"...\"}," +
                "{\"role\":\"user\",\"content\":\"second\"}]}"
    res = post("/v1/chat/completions", body_json)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal "echo: second", body["choices"][0]["message"]["content"]
    # 4 messages -> prompt_tokens = 4 * 4 = 16.
    assert_equal 16, body["usage"]["prompt_tokens"]
  end
end
