# Tep::MCP -- runtime helpers for the MCP battery (chunk 5.1).
#
# Most of the action happens in the bin/tep translator: each
# `mcp_tool` declaration generates a per-tool dispatch cmeth + a
# direct HTTP route, and the translator-emitted dispatcher class
# at POST /mcp routes JSON-RPC 2.0 messages to those cmeths by
# name. This file holds the runtime helpers the generated code
# leans on -- nested-key JSON extraction, result builders, and
# JSON-RPC envelope formatters.
#
# Public surface (chunk 5.1):
#
#   Tep::MCP.text(s)              -> Result with text content
#   Tep::MCP.error(s)             -> Result marked isError = true
#   Tep::MCP.nested_extract(j, k) -> sub-JSON string for a nested key
#   Tep::MCP.initialize_envelope(id, name, version)
#   Tep::MCP.tools_list_envelope(id, tools_json)
#   Tep::MCP.tools_call_envelope(id, result)
#   Tep::MCP.unknown_tool_envelope(id, name)
#   Tep::MCP.method_not_found_envelope(id, method)
#
# Apps wire the battery via `mcp_tool '...' do ... end` blocks at
# the top level; bin/tep does the rest. The runtime here stays
# small + spinel-friendly (no class-hierarchy dispatch, no
# heterogeneous arrays). See docs/MCP-BATTERY.md for the design.
module Tep
  module MCP
    # MCP protocol version this server claims to speak. Tracks the
    # 2025-03 ("Streamable HTTP") revision of the spec.
    PROTOCOL_VERSION = "2025-03-26"

    # Tool result -- carries either a text content block (the only
    # content type supported in chunk 5.1) or an error marker.
    class Result
      attr_accessor :text, :is_error

      def initialize
        @text     = ""
        @is_error = 0
      end
    end

    def self.text(s)
      r = Tep::MCP::Result.new
      r.text     = s
      r.is_error = 0
      r
    end

    def self.error(s)
      r = Tep::MCP::Result.new
      r.text     = s
      r.is_error = 1
      r
    end

    # Resource read outcome -- a (uri, mime, text) triple wrapped
    # in the resources/read response envelope. Kept as a simple
    # value class (parallel to Result) so spinel tracks the slot
    # types cleanly across module boundaries.
    class ResourceContent
      attr_accessor :uri, :mime, :text

      def initialize
        @uri  = ""
        @mime = "text/plain"
        @text = ""
      end
    end

    # Build a text-mime resource content block. URI is the
    # resource's identifier (echoed back to the client so clients
    # can correlate the response with the request).
    def self.resource_text(uri, text)
      c = Tep::MCP::ResourceContent.new
      c.uri  = uri
      c.mime = "text/plain"
      c.text = text
      c
    end

    # JSON-quote a String for embedding in our envelope output.
    # The escape body is inlined (vs split into a separate
    # json_escape helper) because the helper-shape param kept
    # widening to poly through spinel's iterative inference even
    # with a concrete seed -- single-function scope keeps the type
    # signal tight. Names live in Tep::MCP (not Tep::Json) to
    # keep the param-type inference isolated from Tep::Json.quote's
    # wider caller graph.
    def self.json_quote(s)
      out = "\""
      i = 0
      n = s.length
      while i < n
        c = s[i]
        if c == "\""
          out = out + "\\\""
        elsif c == "\\"
          out = out + "\\\\"
        elsif c == "\n"
          out = out + "\\n"
        elsif c == "\r"
          out = out + "\\r"
        elsif c == "\t"
          out = out + "\\t"
        else
          out = out + c
        end
        i += 1
      end
      out + "\""
    end

    # Pull a nested JSON value out of `json` by top-level key,
    # returning the value's JSON-string form. Used by the
    # translator-emitted dispatcher to dig `params` out of the
    # JSON-RPC envelope, then `arguments` out of params, before
    # handing the arguments sub-object to the per-tool cmeth.
    #
    # Returns "{}" when the key isn't present (so downstream
    # Tep::Json.get_str / get_int calls see an empty object that
    # returns their zero-default cleanly).
    def self.nested_extract(json, key)
      pos = Tep::Json.find_value_start(json, key)
      if pos < 0
        return "{}"
      end
      end_pos = Tep::Json.skip_value(json, pos)
      if end_pos <= pos
        return "{}"
      end
      json[pos, end_pos - pos]
    end

    # JSON-RPC 2.0 response envelope for `initialize`. The MCP
    # client expects serverInfo + capabilities + protocolVersion.
    # capabilities lists which method groups this server speaks.
    def self.initialize_envelope(req_id, server_name, server_version)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"result\":{" +
          "\"protocolVersion\":\"" + Tep::MCP::PROTOCOL_VERSION + "\"," +
          "\"capabilities\":{\"tools\":{},\"resources\":{}}," +
          "\"serverInfo\":{" +
            "\"name\":"    + Tep::MCP.json_quote(server_name)    + "," +
            "\"version\":" + Tep::MCP.json_quote(server_version) +
          "}" +
        "}" +
      "}"
    end

    # Wrap a pre-built tools-array JSON string into the tools/list
    # response envelope. tools_array_json is the literal `[{...},
    # {...}]` the translator emits at compile time.
    def self.tools_list_envelope(req_id, tools_array_json)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"result\":{\"tools\":" + tools_array_json + "}" +
      "}"
    end

    # Wrap a tool's text + error-flag into the tools/call response
    # envelope. content is a one-element array with a text block.
    # Takes scalars rather than the Result struct directly so spinel
    # tracks the String param locally through json_quote without
    # going through attr_accessor return-type inference.
    def self.tools_call_envelope(req_id, text, is_error)
      is_err_str = "false"
      if is_error == 1
        is_err_str = "true"
      end
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"result\":{" +
          "\"content\":[" +
            "{\"type\":\"text\",\"text\":" + Tep::MCP.json_quote(text) + "}" +
          "]," +
          "\"isError\":" + is_err_str +
        "}" +
      "}"
    end

    # Wrap a pre-built resources-array JSON string into the
    # resources/list response envelope. Same shape as
    # tools_list_envelope -- translator emits the array literally
    # at compile time so spinel doesn't need to walk it at runtime.
    def self.resources_list_envelope(req_id, resources_array_json)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"result\":{\"resources\":" + resources_array_json + "}" +
      "}"
    end

    # Wrap a ResourceContent into a resources/read response
    # envelope. contents is a one-element array per MCP spec; the
    # uri / mimeType / text fields are read off as scalars (same
    # spinel-friendly pattern as tools_call_envelope) before being
    # spliced into the JSON.
    def self.resources_read_envelope(req_id, uri, mime, text)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"result\":{\"contents\":[" +
          "{\"uri\":" + Tep::MCP.json_quote(uri) + "," +
           "\"mimeType\":" + Tep::MCP.json_quote(mime) + "," +
           "\"text\":" + Tep::MCP.json_quote(text) + "}" +
        "]}" +
      "}"
    end

    # Error envelope for resources/read on an unknown URI. Same
    # JSON-RPC code as unknown_tool (-32602 invalid params).
    def self.unknown_resource_envelope(req_id, uri)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"error\":{\"code\":-32602," +
          "\"message\":" + Tep::MCP.json_quote("unknown resource: " + uri) +
        "}" +
      "}"
    end

    # Error envelope for tools/call on an unknown tool name. Sent
    # as a JSON-RPC error (-32602 invalid params) per the spec.
    def self.unknown_tool_envelope(req_id, tool_name)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"error\":{\"code\":-32602," +
          "\"message\":" + Tep::MCP.json_quote("unknown tool: " + tool_name) +
        "}" +
      "}"
    end

    # Error envelope for an unrecognized JSON-RPC method. Spec
    # code -32601 (method not found).
    def self.method_not_found_envelope(req_id, method_name)
      "{\"jsonrpc\":\"2.0\",\"id\":" + req_id.to_s + "," +
        "\"error\":{\"code\":-32601," +
          "\"message\":" + Tep::MCP.json_quote("method not found: " + method_name) +
        "}" +
      "}"
    end
  end
end
