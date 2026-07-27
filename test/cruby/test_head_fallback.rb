require_relative "helper"

# HEAD -> GET fallback (tep#246, mirror condition 1): a HEAD request
# with no explicit `head` route serves the matching GET route with the
# body suppressed and the Content-Length the body would have had --
# sinatra semantics. An explicit `head` route still wins.
class TestHeadFallback < TepTest
  app_source <<~RB
    get '/' do
      "hello head fallback"
    end

    get '/typed' do
      response.headers["Content-Type"] = "application/json"
      "{\\"k\\":\\"v\\"}"
    end

    head '/explicit' do
      response.headers["X-Explicit-Head"] = "yes"
      ""
    end

    get '/explicit' do
      "get body for explicit"
    end
  RB

  def test_head_serves_get_route_headers_no_body
    g = get("/")
    h = head("/")
    assert_equal "200", h.code
    assert_equal g.body.length.to_s, h["content-length"]
    assert_equal g["content-type"], h["content-type"]
    # Net::HTTP::Head never reads a body; the empty-vs-nil detail is
    # client-side. The real body-suppression proof is the raw socket
    # test below.
  end

  def test_head_raw_socket_no_body_bytes
    body_len = get("/").body.length
    raw = raw_roundtrip("HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    head, _, tail = raw.partition("\r\n\r\n")
    assert_match(/^HTTP\/1\.1 200 /, head)
    assert_match(/^Content-Length: #{body_len}$/i, head.split("\r\n").grep(/Content-Length/i).first)
    assert_equal "", tail, "HEAD response carried body bytes"
  end

  def test_head_preserves_handler_content_type
    h = head("/typed")
    assert_equal "200", h.code
    assert_equal "application/json", h["content-type"]
  end

  def test_explicit_head_route_wins
    h = head("/explicit")
    assert_equal "200", h.code
    assert_equal "yes", h["x-explicit-head"]
  end

  def test_head_missing_404_no_body
    raw = raw_roundtrip("HEAD /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    head, _, tail = raw.partition("\r\n\r\n")
    assert_match(/^HTTP\/1\.1 404 /, head)
    assert_equal "", tail, "HEAD 404 carried body bytes"
  end

  def test_get_unaffected
    g = get("/")
    assert_equal "hello head fallback", g.body
  end

  private

  # Raw-socket round trip: Net::HTTP hides HEAD body bytes, so prove
  # suppression on the wire.
  def raw_roundtrip(request)
    s = TCPSocket.new("127.0.0.1", @port)
    s.write(request)
    out = +""
    while (chunk = s.read(4096))
      out << chunk
    end
    out
  ensure
    s&.close
  end
end
