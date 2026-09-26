# frozen_string_literal: true

# Certificate login (wire mechanism EXTERNAL, PROTOCOL.md §2.4) end to end
# over real TLS: an in-process CA signs a server certificate (SAN skaidb)
# and a client certificate (CN app); the fake server demands the client
# certificate, checks the AuthStart bytes and answers AuthOutcome at once.
require "test_helper"
require "tmpdir"

class CertificateAuthTest < Minitest::Test
  # A CA, a server certificate and a client certificate, written as PEM files.
  class Pki
    attr_reader :dir, :ca, :ca_key, :server_cert, :server_key

    def initialize
      @dir = Dir.mktmpdir("skaidb-cert-test")
      @ca_key = OpenSSL::PKey::EC.generate("prime256v1")
      @ca = issue("CN=test ca", @ca_key, nil, nil, ca: true)
      @server_key = OpenSSL::PKey::EC.generate("prime256v1")
      @server_cert = issue("CN=skaidb", @server_key, @ca, @ca_key, san: "DNS:skaidb")
      write("ca.pem", @ca.to_pem)
    end

    # A client certificate for +cn+; returns [cert_path, key_path].
    def client(cn)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert = issue("CN=#{cn}", key, @ca, @ca_key)
      [write("#{cn}.crt", cert.to_pem), write("#{cn}.key", key.private_to_pem)]
    end

    def path(name)
      File.join(@dir, name)
    end

    def cleanup
      FileUtils.remove_entry(@dir)
    end

    private

    def write(name, pem)
      File.write(path(name), pem)
      path(name)
    end

    def issue(subject, key, issuer, issuer_key, ca: false, san: nil)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(64)
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = issuer ? issuer.subject : cert.subject
      cert.public_key = key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      ef = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
      cert.add_extension(ef.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
      cert.add_extension(ef.create_extension("subjectAltName", san)) if san
      cert.sign(issuer_key || key, OpenSSL::Digest.new("SHA256"))
      cert
    end
  end

  # A TLS listener that requires a client certificate, reads AuthStart and
  # answers per +outcome+ (:ok sends 32 ZERO signature bytes; :denied sends
  # the reason), then serves Hello and "SELECT whoami" (the certificate CN).
  class TlsServer
    attr_reader :port, :auth_starts, :peer_cns, :error

    def initialize(pki, outcome: :ok, reason: "certificate CN is not a role")
      @outcome = outcome
      @reason = reason
      @auth_starts = []
      @peer_cns = []
      @error = nil
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = pki.server_cert
      ctx.key = pki.server_key
      ctx.cert_store = OpenSSL::X509::Store.new.tap { |s| s.add_cert(pki.ca) }
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @thread = Thread.new do
        raw = @tcp.accept
        ssl = OpenSSL::SSL::SSLSocket.new(raw, ctx)
        ssl.sync_close = true
        begin
          ssl.accept
          serve(ssl)
        ensure
          ssl.close
        end
      rescue StandardError => e
        @error = "#{e.class}: #{e.message}"
      end
    end

    def join
      @thread.join(10)
      @tcp.close
    end

    private

    def read_frame(sock)
      head = sock.read(4)
      return nil if head.nil? || head.bytesize < 4

      n = head.unpack1("N")
      n.zero? ? "".b : sock.read(n)
    end

    def send_frame(sock, payload)
      sock.write([payload.bytesize].pack("N") + payload.b)
    end

    def serve(sock)
      cn = sock.peer_cert.subject.to_a.find { |(k, _v, _t)| k == "CN" }[1]
      @peer_cns << cn
      start = read_frame(sock) or return
      @auth_starts << start
      if @outcome == :denied
        send_frame(sock, [13, 0].pack("CC") + Skaidb.enc_str(@reason))
        return
      end
      send_frame(sock, [13, 1].pack("CC") + ("\0".b * 32))
      while (req = read_frame(sock))
        case req.getbyte(0)
        when 8 then send_frame(sock, [2].pack("C"))
        when 1 then send_frame(sock, FakeSkaidb::F.rows(["user"], [[cn]]))
        else send_frame(sock, FakeSkaidb::F.error("unexpected op #{req.getbyte(0)}"))
        end
      end
    end
  end

  def setup
    @pki = Pki.new
  end

  def teardown
    @pki.cleanup
  end

  def cert_connect(server, cn, **kw)
    cert, key = @pki.client(cn)
    Skaidb.connect(host: "127.0.0.1", port: server.port, tls_ca: @pki.path("ca.pem"),
                   tls_client_cert: cert, tls_client_key: key, auth_mechanism: :certificate,
                   timeout: 5, **kw)
  end

  # AuthStart for EXTERNAL: tag 10, username, EMPTY client nonce, mechanism 2.
  def auth_start_bytes(user)
    ([10].pack("C") + [user.bytesize].pack("V") + user + [0].pack("V") + [2].pack("C")).b
  end

  def test_certificate_login_without_a_user_sends_an_empty_name_and_accepts_the_zero_signature
    server = TlsServer.new(@pki)
    conn = cert_connect(server, "app")
    assert_equal "app", conn.exec("SELECT whoami")[0]["user"]
    conn.close
    server.join
    assert_nil server.error
    assert_equal ["app"], server.peer_cns # the client certificate was presented
    assert_equal [auth_start_bytes("")], server.auth_starts
  end

  def test_certificate_login_with_a_user_names_it_in_auth_start
    server = TlsServer.new(@pki)
    conn = cert_connect(server, "app", user: "app", auth_mechanism: "external") # an alias
    assert conn.usable?
    conn.close
    server.join
    assert_nil server.error
    assert_equal [auth_start_bytes("app")], server.auth_starts
  end

  def test_a_denied_certificate_login_fails_the_connect_with_the_reason
    server = TlsServer.new(@pki, outcome: :denied, reason: "certificate CN nobody is not a role")
    e = assert_raises(Skaidb::ConnectionError) { cert_connect(server, "nobody") }
    assert_includes e.message, "certificate CN nobody is not a role"
    server.join
    assert_nil server.error
  end

  def test_the_certificate_mechanism_needs_tls_and_a_client_certificate
    cert, key = @pki.client("app")
    e = assert_raises(Skaidb::Error) { Skaidb.connect(port: 1, auth_mechanism: :certificate) }
    assert_match(/needs TLS with a client certificate/, e.message)
    e = assert_raises(Skaidb::Error) { Skaidb.connect(port: 1, tls: true, auth_mechanism: :certificate) }
    assert_match(/needs TLS with a client certificate/, e.message)
    e = assert_raises(Skaidb::Error) { Skaidb.connect(port: 1, tls_client_cert: cert) }
    assert_match(/go together/, e.message)
    e = assert_raises(Skaidb::Error) { Skaidb.connect(port: 1, tls_client_key: key) }
    assert_match(/go together/, e.message)
    e = assert_raises(Skaidb::Error) { Skaidb.connect(port: 1, auth_mechanism: :kerberos) }
    assert_match(/unknown auth_mechanism/, e.message)
  end

  def test_frame_builder_and_outcome_parser
    assert_equal auth_start_bytes(""), Skaidb.certificate_auth_start(nil)
    assert_equal auth_start_bytes("app"), Skaidb.certificate_auth_start("app")
    assert_nil Skaidb.parse_certificate_outcome([13, 1].pack("CC") + ("\xFF".b * 32)) # never verified
    e = assert_raises(Skaidb::ConnectionError) do
      Skaidb.parse_certificate_outcome([13, 0].pack("CC") + Skaidb.enc_str("no role"))
    end
    assert_equal "authentication denied: no role", e.message
    assert_raises(Skaidb::ConnectionError) { Skaidb.parse_certificate_outcome([11].pack("C")) }
    assert_equal :certificate, Skaidb::AuthMechanism.resolve("X509")
    assert_equal :scram, Skaidb::AuthMechanism.resolve(:password)
  end
end
