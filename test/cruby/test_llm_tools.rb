require_relative "helper"
require "socket"
require "json"
require "net/http"

# Tep::Llm tool use (tep#229), end to end against a fake OpenAI-compatible
# backend: the app sends tool schemas, gets tool_calls back, runs them,
# feeds the results in and continues the turn -- non-streaming (`chat`)
# and streaming (`chat_stream_response`).
class TestLlmTools < Minitest::Test
  APP = <<~'RB'
    require "sinatra"
    set :scheduler, :scheduled

    BACKEND = ENV.fetch("LLM_BACKEND", "http://127.0.0.1:1")
    TOOLS = '[{"type":"function","function":{"name":"add","description":"Add two integers",' +
            '"parameters":{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},' +
            '"required":["a","b"]}}}]'

    def run_tool(name, args)
      if name == "add"
        return (Tep::Json.get_int(args, "a") + Tep::Json.get_int(args, "b")).to_s
      end
      "unknown tool"
    end

    def new_client
      client = Tep::Llm.new(BACKEND)
      client.set_model("fake")
      client.set_tools(TOOLS)
      client.set_tool_choice("auto")
      client
    end

    get "/ask" do
      client = new_client
      msgs = [Tep::Llm::Message.new("user", "What is 2+3, and 10+20?")]
      reply = client.chat(msgs)
      rounds = 0
      while reply.tool_calls.length > 0 && rounds < 3
        msgs.push(reply.to_message)
        i = 0
        while i < reply.tool_calls.length
          call = reply.tool_calls[i]
          msgs.push(Tep::Llm::Message.tool(call.id, run_tool(call.name, call.arguments)))
          i += 1
        end
        reply = client.chat(msgs)
        rounds += 1
      end
      reply.content + "|" + reply.stop_reason + "|rounds=" + rounds.to_s
    end

    class ToolStreamer < Tep::Streamer
      def pump(out)
        client = new_client
        msgs = [Tep::Llm::Message.new("user", "What is 2+3, and 10+20?")]
        reply = client.chat_stream_response(msgs, out)
        rounds = 0
        while reply.tool_calls.length > 0 && rounds < 3
          msgs.push(reply.to_message)
          i = 0
          while i < reply.tool_calls.length
            call = reply.tool_calls[i]
            out.write("data: {" + Tep::Json.encode_pair_str("tool", call.name + call.arguments) + "}\n\n")
            msgs.push(Tep::Llm::Message.tool(call.id, run_tool(call.name, call.arguments)))
            i += 1
          end
          reply = client.chat_stream_response(msgs, out)
          rounds += 1
        end
        0
      end
    end

    get "/ask_stream" do
      res.headers["Content-Type"] = "text/event-stream"
      res.start_stream(ToolStreamer.new)
      ""
    end

    # No tools configured: the request body carries no tools field.
    get "/plain" do
      client = Tep::Llm.new(BACKEND)
      client.set_model("fake")
      client.chat([Tep::Llm::Message.new("user", "plain")]).content
    end

    # tool_choice as a raw JSON object.
    get "/splice_object_choice" do
      Tep::Llm.splice_tools('{"model":"m"}', "[]", '{"type":"function","function":{"name":"add"}}')
    end

    # `"content":null` must not swallow the next string in the body, and
    # object-shaped `arguments` (some backends) is taken as raw JSON.
    get "/parse_null_content" do
      fake = Tep::Http::Response.new
      fake.status = 200
      fake.body = '{"choices":[{"index":0,"message":{"role":"assistant","content":null,' +
                  '"tool_calls":[{"id":"c1","type":"function","function":{"name":"add","arguments":{"a":1,"b":2}}}]},' +
                  '"finish_reason":"tool_calls"}]}'
      out = Tep::Llm.parse_response(fake)
      "content=[" + out.content + "]|n=" + out.tool_calls.length.to_s + "|" +
        out.tool_calls[0].id + "|" + out.tool_calls[0].name + "|" + out.tool_calls[0].arguments +
        "|" + out.stop_reason
    end

    # A plain reply has no tool calls.
    get "/parse_no_tools" do
      fake = Tep::Http::Response.new
      fake.status = 200
      fake.body = '{"choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}'
      out = Tep::Llm.parse_response(fake)
      out.content + "|n=" + out.tool_calls.length.to_s
    end
  RB

  CALLS_JSON = '{"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[' \
               '{"id":"call_a","type":"function","function":{"name":"add","arguments":"{\"a\":2,\"b\":3}"}},' \
               '{"id":"call_b","type":"function","function":{"name":"add","arguments":"{\"a\":10,\"b\":20}"}}' \
               ']},"finish_reason":"tool_calls"}]}'.freeze
  FINAL_JSON = '{"choices":[{"index":0,"message":{"role":"assistant","content":"5 and 30"},"finish_reason":"stop"}]}'.freeze

  CALL_FRAMES = [
    '{"choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"add","arguments":""}}]},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":2,"}}]},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"b\":3}"}}]},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"add","arguments":"{\"a\":10,\"b\":20}"}}]},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
  ].freeze
  FINAL_FRAMES = [
    '{"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{"content":"5 and "},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{"content":"30"},"finish_reason":null}]}',
    '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
  ].freeze

  # Asks for two tool calls until the conversation contains a tool
  # result, then answers in text. Records every request body.
  def start_fake_backend
    @requests = Queue.new
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          head = +""
          head << c.readpartial(4096) until head.include?("\r\n\r\n")
          header, body = head.split("\r\n\r\n", 2)
          want = header[/content-length:\s*(\d+)/i, 1].to_i
          body << c.readpartial(4096) while body.bytesize < want
          @requests << body
          answered = body.include?('"role":"tool"') || !body.include?('"tools"')
          if body.include?('"stream":true')
            c.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
            (answered ? FINAL_FRAMES : CALL_FRAMES).each { |f| c.write("data: #{f}\n\n") }
            c.write("data: [DONE]\n\n")
          else
            json = answered ? FINAL_JSON : CALLS_JSON
            c.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
          end
        rescue StandardError
          nil
        ensure
          c.close rescue nil
        end
      end
    end
    [server, thread]
  end

  def setup
    @tmp = Dir.mktmpdir("tep-llm-tools")
    src = File.join(@tmp, "app.rb")
    File.write(src, APP)
    bin = File.join(@tmp, "app")
    TepHarness.build_with_retry("#{TepHarness::TEP_BIN} build #{src} -o #{bin}", "tep build llm tools app")
    @backend, @backend_thread = start_fake_backend
    @port = TepHarness.next_port
    env = { "LLM_BACKEND" => "http://127.0.0.1:#{@backend.addr[1]}" }
    @pid = Process.spawn(env, bin, "-p", @port.to_s, "-q",
                         out: File.join(@tmp, "app.log"), err: [:child, :out], pgroup: true)
    TepHarness.wait_for_port(@port, tmp: @tmp, pid: @pid)
  end

  def teardown
    TepHarness.reap(@pid) if @pid
    @backend_thread&.kill
    @backend&.close
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def get(path)
    Net::HTTP.start("127.0.0.1", @port, read_timeout: 20) { |h| h.get(path) }
  end

  def drain_requests
    out = []
    out << JSON.parse(@requests.pop) until @requests.empty?
    out
  end

  def assert_tool_round_trip(reqs)
    assert_equal 2, reqs.length
    first, second = reqs
    assert_equal "add", first["tools"][0]["function"]["name"]
    assert_equal "auto", first["tool_choice"]
    assert_equal ["user"], first["messages"].map { |m| m["role"] }

    assert_equal %w[user assistant tool tool], second["messages"].map { |m| m["role"] }
    assistant = second["messages"][1]
    assert_nil assistant["content"]
    assert_equal %w[call_a call_b], assistant["tool_calls"].map { |t| t["id"] }
    assert_equal "function", assistant["tool_calls"][0]["type"]
    assert_equal "add", assistant["tool_calls"][0]["function"]["name"]
    assert_equal({ "a" => 2, "b" => 3 }, JSON.parse(assistant["tool_calls"][0]["function"]["arguments"]))
    assert_equal({ "a" => 10, "b" => 20 }, JSON.parse(assistant["tool_calls"][1]["function"]["arguments"]))
    assert_equal({ "role" => "tool", "content" => "5", "tool_call_id" => "call_a" }, second["messages"][2])
    assert_equal({ "role" => "tool", "content" => "30", "tool_call_id" => "call_b" }, second["messages"][3])
    assert second.key?("tools"), "tools are resent on the follow-up request"
  end

  def test_chat_tool_loop
    res = get("/ask")
    assert_equal "5 and 30|stop|rounds=1", res.body
    assert_tool_round_trip(drain_requests)
  end

  def test_chat_stream_response_tool_loop
    res = get("/ask_stream")
    assert_equal "200", res.code
    lines = res.body.scan(/^data: (.+)$/).flatten
    assert_equal 1, lines.count("[DONE]"), "one [DONE], after the final answer: #{lines.inspect}"
    assert_equal "[DONE]", lines.last
    events = lines[0..-2].map { |l| JSON.parse(l) }
    assert_equal ['add{"a":2,"b":3}', 'add{"a":10,"b":20}'], events.filter_map { |e| e["tool"] }
    assert_equal "5 and 30", events.filter_map { |e| e["content"] }.join
    reqs = drain_requests
    assert(reqs.all? { |r| r["stream"] == true })
    assert_tool_round_trip(reqs)
  end

  def test_no_tools_field_without_set_tools
    assert_equal "5 and 30", get("/plain").body
    reqs = drain_requests
    assert_equal 1, reqs.length
    refute reqs[0].key?("tools")
    refute reqs[0].key?("tool_choice")
  end

  def test_tool_choice_object_is_spliced_verbatim
    body = JSON.parse(get("/splice_object_choice").body)
    assert_equal [], body["tools"]
    assert_equal "add", body["tool_choice"]["function"]["name"]
  end

  def test_null_content_and_object_arguments
    assert_equal 'content=[]|n=1|c1|add|{"a":1,"b":2}|tool_calls', get("/parse_null_content").body
  end

  # Object arrays declared in sig/ (Router @routes, the Llm @tool_calls)
  # must be used only in ways Spinel's unboxed object array supports;
  # otherwise every build -- of any app -- warns that the sig's
  # Array[Class] was not applied.
  def test_build_keeps_object_arrays_unboxed
    out = `#{TepHarness::TEP_BIN} build #{File.join(@tmp, "app.rb")} -o #{File.join(@tmp, "app2")} 2>&1`
    assert $?.success?, out
    refute_match(/stays a boxed array/, out)
  end

  def test_plain_reply_has_no_tool_calls
    assert_equal "hi|n=0", get("/parse_no_tools").body
  end
end
