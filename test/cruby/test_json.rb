require_relative "helper"

# Tep::Json -- pure-Ruby JSON encode primitives + flat-key decode.
class TestJson < TepTest
  app_source <<~RB
    require 'sinatra'

    # ---- encode side ----
    get '/escape' do
      res.headers["Content-Type"] = "application/json"
      Tep::Json.quote("a\\"b\\nc")
    end

    get '/object' do
      res.headers["Content-Type"] = "application/json"
      "{" + Tep::Json.encode_pair_str("name", "alice") + "," +
            Tep::Json.encode_pair_int("age", 30) + "}"
    end

    get '/array' do
      res.headers["Content-Type"] = "application/json"
      Tep::Json.from_str_array(["a", "b", "c"])
    end

    get '/int_array' do
      res.headers["Content-Type"] = "application/json"
      Tep::Json.from_int_array([1, 2, 3])
    end

    get '/echo_html' do
      res.headers["Content-Type"] = "application/json"
      "{" + Tep::Json.encode_pair_str("payload", "<script>alert(1)</script>") + "}"
    end

    # ---- decode side ----
    post '/parse_str' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Json.get_str(req.raw_body, "name")
    end

    post '/parse_int' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Json.get_int(req.raw_body, "n").to_s
    end

    post '/has_key' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Json.has_key?(req.raw_body, "x") ? "yes" : "no"
    end

    post '/skip_nested' do
      # Read a top-level key past a nested object (skip_value should
      # walk the nested object correctly).
      res.headers["Content-Type"] = "text/plain"
      Tep::Json.get_str(req.raw_body, "after")
    end

    post '/parse_float' do
      res.headers["Content-Type"] = "text/plain"
      Tep::Json.get_float(req.raw_body, "x").to_s
    end
  RB

  def test_quote_escapes
    res = get("/escape")
    # The route quoted the string `a"b\nc`; the escape should turn
    # the quote and newline into \" and \n. The HTTP body is JSON,
    # so the client sees: "a\"b\nc"
    assert_match(/"a\\"b\\nc"/, res.body)
  end

  def test_encode_pair_str_and_int
    res = get("/object")
    assert_equal '{"name":"alice","age":30}', res.body.strip
  end

  def test_from_str_array
    res = get("/array")
    assert_equal '["a","b","c"]', res.body.strip
  end

  def test_from_int_array
    res = get("/int_array")
    assert_equal "[1,2,3]", res.body.strip
  end

  def test_html_chars_are_escaped_in_strings
    # JSON escape includes backslash + quote; tag chars (< > /) pass
    # through as-is (legal JSON, the client does its own HTML escape
    # if it embeds the value).
    res = get("/echo_html")
    assert_match(/"payload":"<script>alert\(1\)<\\\/script>"|"payload":"<script>alert\(1\)<\/script>"/, res.body)
  end

  def test_get_str
    res = post("/parse_str", '{"name":"alice","age":30}')
    assert_equal "alice", res.body.strip
  end

  def test_get_str_missing_returns_empty
    res = post("/parse_str", '{"other":"value"}')
    assert_equal "", res.body.strip
  end

  def test_get_int
    res = post("/parse_int", '{"n":42}')
    assert_equal "42", res.body.strip
  end

  def test_get_int_negative
    res = post("/parse_int", '{"n":-7}')
    assert_equal "-7", res.body.strip
  end

  def test_has_key
    res = post("/has_key", '{"x":1}')
    assert_equal "yes", res.body.strip
    res = post("/has_key", '{"y":1}')
    assert_equal "no", res.body.strip
  end

  def test_skips_nested_objects
    body = '{"first":{"a":1,"b":{"c":2}},"after":"target"}'
    res = post("/skip_nested", body)
    assert_equal "target", res.body.strip
  end

  def test_skips_strings_with_braces
    # The skip-string walker should ignore { / } inside string values.
    body = '{"first":"has{}braces","after":"target"}'
    res = post("/skip_nested", body)
    assert_equal "target", res.body.strip
  end

  def test_handles_escaped_quote_in_string
    # \" inside a value-string must not terminate the string and
    # corrupt the walk.
    body = '{"first":"has \\"quote\\" inside","after":"target"}'
    res = post("/skip_nested", body)
    assert_equal "target", res.body.strip
  end

  def test_get_float_decimal
    res = post("/parse_float", '{"x":3.14}')
    assert_equal "3.14", res.body.strip
  end

  def test_get_float_negative
    res = post("/parse_float", '{"x":-0.5}')
    assert_equal "-0.5", res.body.strip
  end

  def test_get_float_integer_literal
    # JSON integer 42 read as float -> 42.0
    res = post("/parse_float", '{"x":42}')
    assert_equal "42.0", res.body.strip
  end

  def test_get_float_exponent
    res = post("/parse_float", '{"x":1.5e2}')
    assert_equal "150.0", res.body.strip
  end

  def test_get_float_missing_key_returns_zero
    res = post("/parse_float", '{"other":42}')
    assert_equal "0.0", res.body.strip
  end
end
