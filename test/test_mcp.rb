require_relative "helper"

# Tep::MCP -- Battery 5 chunk 5.1. Tool DSL + JSON-RPC dispatcher
# + HTTP-direct route + llms.txt. The translator-emitted classes
# are exercised via real HTTP against the fixture app.
class TestMCP < TepTest
  app_source <<~RB
    require 'sinatra'

    # Grant capabilities via an X-Test-Cap header for the auth
    # gating tests. No real auth provider needed for the dispatch
    # paths -- we just override req.identity with a synthetic one
    # so req.identity.may?(:admin) returns true on demand.
    before do
      if req.req_headers["x-test-cap-admin"].length > 0
        req.identity = Tep::Identity.new(
          "user:42", nil, [:admin])
      end
    end

    mcp_tool 'greet', "Say hi to someone" do
      param :name, String, "person to greet"

      on_call do |name:|
        if name.length == 0
          Tep::MCP.error("name required")
        else
          Tep::MCP.text("hello " + name)
        end
      end
    end

    mcp_tool 'add', "Add two integers" do
      param :a, Integer, "left operand"
      param :b, Integer, "right operand"

      on_call do |a:, b:|
        Tep::MCP.text((a + b).to_s)
      end
    end

    # Capped tool -- requires :admin in the calling identity.
    mcp_tool 'wipe_db', "Drop everything (requires :admin)", caps: [:admin] do
      on_call do
        Tep::MCP.text("wiped")
      end
    end

    mcp_resource 'server/status', "Current server status" do
      on_read do
        Tep::MCP.resource_text("server/status", "uptime: 42")
      end
    end

    mcp_resource 'server/version', "Server build version" do
      on_read do
        Tep::MCP.resource_text("server/version", "1.0.0-test")
      end
    end
  RB

  # ---- HTTP-direct invocation ----

  def test_http_direct_tool_call_returns_text
    res = post("/tools/greet", "{\"name\":\"alice\"}",
               "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_equal "hello alice", res.body
  end

  def test_http_direct_tool_error_returns_400
    res = post("/tools/greet", "{\"name\":\"\"}",
               "Content-Type" => "application/json")
    assert_equal "400", res.code
    assert_equal "name required", res.body
  end

  def test_http_direct_integer_param_round_trip
    res = post("/tools/add", "{\"a\":2,\"b\":40}",
               "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_equal "42", res.body
  end

  # ---- JSON-RPC dispatch over /mcp ----

  def test_mcp_initialize_returns_server_info
    body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"jsonrpc\":\"2.0\""
    assert_includes res.body, "\"id\":1"
    assert_includes res.body, "\"serverInfo\""
    assert_includes res.body, "\"protocolVersion\""
  end

  def test_mcp_tools_list_returns_both_tools
    body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"name\":\"greet\""
    assert_includes res.body, "\"name\":\"add\""
    assert_includes res.body, "\"description\":\"Say hi to someone\""
    assert_includes res.body, "\"inputSchema\""
    # Schema should encode integer params as JSON Schema integer type.
    assert_includes res.body, "\"type\":\"integer\""
  end

  def test_mcp_tools_call_round_trips_text_content
    body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\"," +
           "\"params\":{\"name\":\"greet\",\"arguments\":{\"name\":\"bob\"}}}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"id\":3"
    assert_includes res.body, "\"text\":\"hello bob\""
    assert_includes res.body, "\"isError\":false"
  end

  def test_mcp_tools_call_propagates_is_error
    body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\"," +
           "\"params\":{\"name\":\"greet\",\"arguments\":{\"name\":\"\"}}}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"text\":\"name required\""
    assert_includes res.body, "\"isError\":true"
  end

  def test_mcp_tools_call_unknown_tool_returns_error_envelope
    body = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\"," +
           "\"params\":{\"name\":\"nope\",\"arguments\":{}}}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"error\""
    assert_includes res.body, "\"code\":-32602"
    assert_includes res.body, "unknown tool"
  end

  def test_mcp_unknown_method_returns_method_not_found
    body = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"notreal\"}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"code\":-32601"
    assert_includes res.body, "method not found"
  end

  # ---- caps gating (chunk 5.2) ----

  def test_capped_tool_denies_anonymous_caller
    res = post("/tools/wipe_db", "{}",
               "Content-Type" => "application/json")
    # Anonymous identity has empty caps, so :admin check fails.
    # The tool returns an error Result; HTTP-direct surfaces it
    # as 400 + the error text.
    assert_equal "400", res.code
    assert_includes res.body, "missing capability: admin"
  end

  def test_capped_tool_allows_caller_with_required_cap
    res = post("/tools/wipe_db", "{}",
               "Content-Type"   => "application/json",
               "X-Test-Cap-Admin" => "1")
    assert_equal "200", res.code
    assert_equal "wiped", res.body
  end

  def test_capped_tool_over_mcp_returns_isError
    # Same denial path through the JSON-RPC envelope: anonymous
    # caller -> wipe_db -> error Result -> isError:true.
    body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\"," +
           "\"params\":{\"name\":\"wipe_db\",\"arguments\":{}}}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"isError\":true"
    assert_includes res.body, "missing capability: admin"
  end

  # ---- notifications/initialized (chunk 5.2) ----

  def test_notifications_initialized_returns_204_no_body
    body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "204", res.code
    assert_equal "", res.body.to_s
  end

  # ---- mcp_resource (chunk 5.3) ----

  def test_http_direct_resource_read_returns_text
    res = get("/resources/server/status")
    assert_equal "200", res.code
    assert_includes res["content-type"].to_s, "text/plain"
    assert_equal "uptime: 42", res.body
  end

  def test_mcp_initialize_advertises_resources_capability
    body = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"initialize\"}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"resources\":{}"
  end

  def test_mcp_resources_list_returns_both_resources
    body = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"resources/list\"}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"uri\":\"server/status\""
    assert_includes res.body, "\"uri\":\"server/version\""
    assert_includes res.body, "\"description\":\"Current server status\""
    assert_includes res.body, "\"mimeType\":\"text/plain\""
  end

  def test_mcp_resources_read_round_trips_content
    body = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"resources/read\"," +
           "\"params\":{\"uri\":\"server/status\"}}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"uri\":\"server/status\""
    assert_includes res.body, "\"mimeType\":\"text/plain\""
    assert_includes res.body, "\"text\":\"uptime: 42\""
  end

  def test_mcp_resources_read_unknown_uri_errors
    body = "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"resources/read\"," +
           "\"params\":{\"uri\":\"nope\"}}"
    res = post("/mcp", body, "Content-Type" => "application/json")
    assert_equal "200", res.code
    assert_includes res.body, "\"code\":-32602"
    assert_includes res.body, "unknown resource"
  end

  # ---- llms.txt discovery ----

  def test_llms_txt_lists_tools_with_descriptions
    res = get("/llms.txt")
    assert_equal "200", res.code
    assert_includes res["content-type"].to_s, "text/markdown"
    assert_includes res.body, "MCP-endpoint: /mcp"
    assert_includes res.body, "## Tools"
    assert_includes res.body, "greet -- Say hi to someone"
    assert_includes res.body, "add -- Add two integers"
    assert_includes res.body, "## Resources"
    assert_includes res.body, "server/status -- Current server status"
  end
end
