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
  app_source <<~RB
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
end
