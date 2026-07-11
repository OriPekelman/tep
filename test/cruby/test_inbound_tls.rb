require_relative "helper"
require "openssl"
require "socket"
require "timeout"

# Inbound server TLS (#148 phase 2): Tep::Server terminates HTTPS when
# Tep.tls_cert / Tep.tls_key are set. Boots a tep binary with a
# self-signed cert and drives it with a TLS client.
class TestInboundTls < TepTest
  # Per-process cert paths (unique under the parallel runner). Baked
  # into app_source at class load; generated before the binary boots.
  CERT = "/tmp/tep_tls_test_#{Process.pid}.crt"
  KEY  = "/tmp/tep_tls_test_#{Process.pid}.key"

  app_source <<~RB
    require 'sinatra'
    Tep.tls_cert = "#{CERT}"
    Tep.tls_key  = "#{KEY}"

    get '/hello' do
      "tls-ok"
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

  def tls_get(path)
    # Timeout-wrapped so a server-side handshake/read hang fails the
    # test fast instead of wedging forever.
    Timeout.timeout(15) do
      sock = TCPSocket.new("127.0.0.1", @port)
      ctx  = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE   # self-signed
      ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      ssl.connect
      ssl.write("GET #{path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      out = ssl.read.to_s
      ssl.close rescue nil
      sock.close rescue nil
      out
    end
  end

  def test_serves_a_request_over_tls
    resp = tls_get("/hello")
    assert_match(/200/, resp)
    assert_match(/tls-ok/, resp)
  end

  def test_presents_the_configured_certificate
    cn = Timeout.timeout(15) do
      sock = TCPSocket.new("127.0.0.1", @port)
      ctx  = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      ssl.connect
      subj = ssl.peer_cert.subject.to_s
      ssl.close rescue nil
      sock.close rescue nil
      subj
    end
    assert_match(/CN=localhost/, cn)
  end

  def test_plaintext_request_to_tls_port_is_dropped
    # A plain-HTTP request to the TLS port: SSL_accept fails on the
    # non-TLS bytes, the server drops the connection -> no HTTP reply.
    sock = TCPSocket.new("127.0.0.1", @port)
    sock.write("GET /hello HTTP/1.0\r\nConnection: close\r\n\r\n")
    data = ""
    begin
      data = sock.read_nonblock(64)
    rescue IO::WaitReadable
      IO.select([sock], nil, nil, 1.0)
      data = (sock.read_nonblock(64) rescue "")
    rescue
      data = ""
    end
    sock.close rescue nil
    refute_match(/HTTP\//, data.to_s)   # no plaintext HTTP response
  end
end
