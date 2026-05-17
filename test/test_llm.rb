# Tests for Tep::Llm encode/parse via a live tep app. The app
# exposes one route per test that exercises the corresponding
# static method and returns the result as the body; the MRI test
# side GETs each route + asserts on the body.
#
# Integration coverage (Tep::Llm.chat() pointed at a live OpenAI-
# compatible backend) is the job of examples/chat/ once it lands
# per OriPekelman/tep#10 -- that demo exercises the network path.
require_relative "helper"

class TestLlm < TepTest
  # Single-quoted heredoc so the Phase B test bodies (which embed
  # `\r\n` chunked-transfer terminators) pass through literally
  # rather than getting interpreted as raw CR+LF at heredoc-parse
  # time.
  app_source <<~'RB'
    require "sinatra"

    get "/build_simple" do
      msg = Tep::Llm::Message.new("user", "Hello!")
      Tep::Llm.build_request_body("gpt-2", "", [msg])
    end

    get "/build_system" do
      msg = Tep::Llm::Message.new("user", "Hi")
      Tep::Llm.build_request_body("llama3", "You are concise.", [msg])
    end

    get "/build_multiturn" do
      msgs = [
        Tep::Llm::Message.new("user",      "What is 2+2?"),
        Tep::Llm::Message.new("assistant", "4"),
        Tep::Llm::Message.new("user",      "Now multiply by 3."),
      ]
      Tep::Llm.build_request_body("gpt-2", "", msgs)
    end

    get "/extract_simple" do
      Tep::Llm.extract_str_field('{"foo":"bar","baz":"qux"}', "foo", 0)
    end

    get "/extract_missing" do
      r = Tep::Llm.extract_str_field('{"foo":"bar"}', "missing", 0)
      # Distinguish empty-string-found from empty-string-default;
      # the empty-string-default case is what we want here.
      r.length == 0 ? "MISSING" : "FOUND:" + r
    end

    get "/parse_openai_happy" do
      fake = Tep::Http::Response.new
      fake.status = 200
      fake.body  = '{"choices":[{"index":0,' +
                   '"message":{"role":"assistant","content":"Hello!"},' +
                   '"finish_reason":"stop"}]}'
      out = Tep::Llm.parse_response(fake)
      out.content + "|" + out.role + "|" + out.stop_reason
    end

    get "/parse_transport_error" do
      fake = Tep::Http::Response.new
      fake.status = 0
      out = Tep::Llm.parse_response(fake)
      out.stop_reason
    end

    get "/parse_http_404" do
      fake = Tep::Http::Response.new
      fake.status = 404
      fake.body   = '{"error":"not found"}'
      out = Tep::Llm.parse_response(fake)
      out.stop_reason
    end

    get "/client_setters" do
      c = Tep::Llm.new("http://example.test")
      c.set_model("m")
      c.set_api_key("k")
      c.set_system_prompt("p")
      c.model + "|" + c.api_key + "|" + c.system_prompt
    end

    # --- Phase B: chunked decode + SSE event consume ---

    get "/hex_to_int_valid" do
      Tep::Llm.hex_to_int("ff").to_s + "|" +
      Tep::Llm.hex_to_int("a").to_s  + "|" +
      Tep::Llm.hex_to_int("100").to_s
    end

    get "/hex_to_int_invalid" do
      Tep::Llm.hex_to_int("zz").to_s + "|" +
      Tep::Llm.hex_to_int("").to_s
    end

    # One chunked body: 5 bytes "Hello", then last-chunk 0.
    get "/dechunk_complete" do
      s = "5\r\nHello\r\n0\r\n\r\n"
      Tep::Llm.dechunk_consume(s)
    end

    # Two chunks in one buffer.
    get "/dechunk_multiple" do
      s = "3\r\nfoo\r\n3\r\nbar\r\n0\r\n\r\n"
      Tep::Llm.dechunk_consume(s)
    end

    # Partial body: chunk header present, but body bytes not all there.
    # dechunk_consume returns the already-consumed portion ("");
    # dechunk_leftover returns the still-pending tail.
    get "/dechunk_partial" do
      s = "5\r\nHel"
      consumed = Tep::Llm.dechunk_consume(s)
      leftover = Tep::Llm.dechunk_leftover(s)
      "consumed=" + consumed.length.to_s + "|leftover=" + leftover
    end

    # consume_sse_events on a buffer with one delta + DONE marker.
    # The mock stream just counts writes and records the last write.
    get "/sse_one_delta_then_done" do
      state = Tep::Llm::StreamState.new
      state.leftover = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" +
                       "data: [DONE]\n\n"
      sink = Tep::Stream.new(0)   # write goes to fd 0 (stdout); we
                                   # only assert on state.acc + done
      Tep::Llm.consume_sse_events(sink, state)
      state.acc + "|done=" + (state.done ? "true" : "false")
    end

    # Partial: one full delta, then half of the next data: line.
    # consume_sse_events should drain the full one + leave the rest.
    get "/sse_partial_tail" do
      state = Tep::Llm::StreamState.new
      state.leftover = "data: {\"choices\":[{\"delta\":{\"content\":\"X\"}}]}\n\n" +
                       "data: {\"choices\":[{\"delta\":{\"content\""
      sink = Tep::Stream.new(0)
      Tep::Llm.consume_sse_events(sink, state)
      "acc=" + state.acc + "|done=" + (state.done ? "true" : "false") +
        "|leftover_len=" + state.leftover.length.to_s
    end

    # finish_reason in a data line should set state.done.
    get "/sse_finish_reason_ends" do
      state = Tep::Llm::StreamState.new
      state.leftover = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
      sink = Tep::Stream.new(0)
      Tep::Llm.consume_sse_events(sink, state)
      "done=" + (state.done ? "true" : "false")
    end
  RB

  def test_build_simple_user_message
    res = get("/build_simple")
    assert_equal "200", res.code
    assert_equal(
      '{"model":"gpt-2","messages":[{"role":"user","content":"Hello!"}]}',
      res.body
    )
  end

  def test_build_with_system_prompt
    res = get("/build_system")
    assert_equal(
      '{"model":"llama3","messages":[' \
      '{"role":"system","content":"You are concise."},' \
      '{"role":"user","content":"Hi"}' \
      ']}',
      res.body
    )
  end

  def test_build_multi_turn
    res = get("/build_multiturn")
    assert_match(/"role":"user","content":"What is 2\+2\?"/,    res.body)
    assert_match(/"role":"assistant","content":"4"/,             res.body)
    assert_match(/"role":"user","content":"Now multiply by 3\."/, res.body)
  end

  def test_extract_str_field_simple
    res = get("/extract_simple")
    assert_equal "bar", res.body
  end

  def test_extract_str_field_missing_returns_empty
    res = get("/extract_missing")
    assert_equal "MISSING", res.body
  end

  def test_parse_response_openai_happy_path
    res = get("/parse_openai_happy")
    assert_equal "Hello!|assistant|stop", res.body
  end

  def test_parse_response_transport_failure
    res = get("/parse_transport_error")
    assert_equal "error", res.body
  end

  def test_parse_response_http_404
    res = get("/parse_http_404")
    assert_equal "http_404", res.body
  end

  def test_client_setters_round_trip
    res = get("/client_setters")
    assert_equal "m|k|p", res.body
  end

  # --- Phase B: chunked + SSE primitives ---

  def test_hex_to_int_valid
    res = get("/hex_to_int_valid")
    assert_equal "255|10|256", res.body
  end

  def test_hex_to_int_malformed_returns_neg_one
    res = get("/hex_to_int_invalid")
    assert_equal "-1|-1", res.body
  end

  def test_dechunk_complete_single_chunk
    res = get("/dechunk_complete")
    assert_equal "Hello", res.body
  end

  def test_dechunk_complete_multiple_chunks
    res = get("/dechunk_multiple")
    assert_equal "foobar", res.body
  end

  def test_dechunk_partial_tail_left_for_next_recv
    res = get("/dechunk_partial")
    # No full chunk yet -- consumed empty, leftover holds the full tail.
    assert_equal "consumed=0|leftover=5\r\nHel", res.body
  end

  def test_sse_one_delta_then_done_sets_done
    res = get("/sse_one_delta_then_done")
    assert_equal "Hello|done=true", res.body
  end

  def test_sse_partial_tail_preserved_for_next_recv
    res = get("/sse_partial_tail")
    assert_match(/^acc=X\|done=false\|leftover_len=\d+/, res.body)
  end

  def test_sse_finish_reason_terminates_stream
    res = get("/sse_finish_reason_ends")
    assert_equal "done=true", res.body
  end
end
