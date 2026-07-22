require_relative "helper"
require "openssl"
require "socket"
require "timeout"

# Scheduled-server inbound TLS (#148 phase 2, scheduled variant):
# Tep::Server::Scheduled terminates HTTPS with a NON-BLOCKING SSL_accept
# (sphttp_tls_accept_start + handshake_step parked on the scheduler).
# Mirrors test_inbound_tls.rb but with `set :scheduler, :scheduled`, so
# it exercises the cooperative handshake + want-aware recv path.
class TestInboundTlsScheduled < TepTest
  CERT = "/tmp/tep_tls_sched_test_#{Process.pid}.crt"
  KEY  = "/tmp/tep_tls_sched_test_#{Process.pid}.key"

  app_source <<~RB
    require 'sinatra'
    set :scheduler, :scheduled
    Tep.tls_cert = "#{CERT}"
    Tep.tls_key  = "#{KEY}"

    get '/hello' do
      "tls-sched-ok"
    end

    post '/echo' do
      "echo:" + request.body.read
    end
  RB

  def self.gen_cert
    return if File.exist?(CERT) && File.exist?(KEY)
    key  = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version    = 2
    cert.serial     = 1
    cert.subject    = OpenSSL::X509::Name.parse("/CN=localhost")
    cert.issuer     = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after  = Time.now + 3600
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    File.write(CERT, cert.to_pem)
    File.write(KEY,  key.to_pem)
  end

  def setup
    self.class.gen_cert    # must exist before the spawned binary boots
    super
  end

  def tls_socket
    sock = TCPSocket.new("127.0.0.1", @port)
    ctx  = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE   # self-signed
    ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
    ssl.connect
    [ssl, sock]
  end

  def tls_get(path)
    Timeout.timeout(15) do
      ssl, sock = tls_socket
      ssl.write("GET #{path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      out = ssl.read.to_s
      ssl.close rescue nil
      sock.close rescue nil
      out
    end
  end

  def test_serves_a_request_over_tls_under_scheduler
    resp = tls_get("/hello")
    assert_match(/200/, resp)
    assert_match(/tls-sched-ok/, resp)
  end

  def test_post_body_over_tls_under_scheduler
    # Drives the want-aware body drain (consume_body_via_scheduler) over
    # TLS -- a partial SSL record must not truncate the body.
    resp = Timeout.timeout(15) do
      ssl, sock = tls_socket
      body = "hello-tls-body"
      ssl.write("POST /echo HTTP/1.0\r\nHost: localhost\r\n" \
                "Content-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n" \
                "Connection: close\r\n\r\n#{body}")
      out = ssl.read.to_s
      ssl.close rescue nil
      sock.close rescue nil
      out
    end
    assert_match(/200/, resp)
    assert_match(/echo:hello-tls-body/, resp)
  end

  def test_two_sequential_tls_connections
    # A second connection must hand-shake cleanly after the first closed
    # (server CTX reused across connections / fibers).
    assert_match(/tls-sched-ok/, tls_get("/hello"))
    assert_match(/tls-sched-ok/, tls_get("/hello"))
  end
end
