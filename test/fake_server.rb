# frozen_string_literal: true

# An in-process skaidb server for the driver's unit tests: it speaks the
# frame layer and the SCRAM-SHA-256 handshake for real, and answers every
# post-handshake request with whatever the test scripts. No skaidb binary is
# involved. Pure stdlib (socket + openssl), like the driver.
require "socket"
require "openssl"
require "securerandom"
require "skaidb"

module FakeSkaidb
  # ---- frame builders (server -> client payloads, PROTOCOL.md §3.2) --------
  module F
    module_function

    def str(s)
      Skaidb.enc_str(s)
    end

    def rows_block(columns, rows)
      out = String.new
      out << [columns.length].pack("V")
      columns.each { |c| out << str(c) }
      out << [rows.length].pack("V")
      rows.each do |row|
        out << [row.length].pack("V")
        row.each do |v|
          b = Skaidb.encode_value(v)
          out << [b.bytesize].pack("V") << b
        end
      end
      out
    end

    def rows(columns, rows)
      [0].pack("C") + rows_block(columns, rows)
    end

    def mutation(n)
      [1].pack("C") + [n].pack("Q<")
    end

    def ddl
      [2].pack("C")
    end

    def error(msg)
      [3].pack("C") + str(msg)
    end

    def prepared(id, nparams)
      [4].pack("C") + [id].pack("V") + [nparams].pack("v")
    end

    def header(columns)
      out = String.new([5].pack("C") + [columns.length].pack("V"))
      columns.each { |c| out << str(c) }
      out
    end

    def chunk(rows)
      out = String.new([6].pack("C") + [rows.length].pack("V"))
      rows.each do |row|
        out << [row.length].pack("V")
        row.each do |v|
          b = Skaidb.encode_value(v)
          out << [b.bytesize].pack("V") << b
        end
      end
      out
    end

    def rows_end
      [7].pack("C")
    end

    def result_sets(sets)
      out = String.new([8].pack("C") + [sets.length].pack("V"))
      sets.each { |(columns, rows)| out << rows_block(columns, rows) }
      out
    end
  end

  # One frame: u32 BE length + payload.
  def self.frame(payload)
    payload = payload.b
    [payload.bytesize].pack("N") + payload
  end

  # ---- request parsers (client -> server payloads, §3) ---------------------
  Request = Struct.new(:op, :consistency, :sql, :id, :params, :rows, :name, :version, :raw, keyword_init: true)

  def self.parse_request(payload)
    r = Skaidb::Reader.new(payload)
    op = r.u8
    case op
    when 1, 5
      Request.new(op: op, consistency: r.u8, sql: r.text, raw: payload)
    when 2
      Request.new(op: op, sql: r.text, raw: payload)
    when 3
      consistency = r.u8
      id = r.u32
      n = r.u16
      params = Array.new(n) { Skaidb.decode_value(Skaidb::Reader.new(r.blob)) }
      Request.new(op: op, consistency: consistency, id: id, params: params, raw: payload)
    when 4
      Request.new(op: op, id: r.u32, raw: payload)
    when 7
      consistency = r.u8
      id = r.u32
      nrows = r.u32
      rows = Array.new(nrows) do
        n = r.u16
        Array.new(n) { Skaidb.decode_value(Skaidb::Reader.new(r.blob)) }
      end
      Request.new(op: op, consistency: consistency, id: id, rows: rows, raw: payload)
    when 8
      Request.new(op: op, name: r.text, version: r.text, raw: payload)
    else
      Request.new(op: op, raw: payload)
    end
  end

  # ---- the server ----------------------------------------------------------
  class Server
    ITERATIONS = 1000

    attr_reader :port, :requests, :hellos, :connections
    attr_accessor :corrupt_server_signature, :handler

    # password: the one password every user has.
    # handler: ->(req, conn) { payload | [payloads] | :close | nil } for every
    #   post-handshake request; Hello is answered with Ddl unless the handler
    #   returns something; nil for anything else answers Error.
    def initialize(password: "secret", &handler)
      @password = password
      @handler = handler || ->(_req, _conn) { nil }
      @requests = []
      @hellos = []
      @connections = 0
      @sockets = []
      @threads = []
      @mutex = Mutex.new
      @corrupt_server_signature = false
    end

    def start
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @acceptor = Thread.new do
        loop do
          sock = begin
            @server.accept
          rescue StandardError
            break
          end
          @mutex.synchronize do
            @connections += 1
            @sockets << sock
          end
          @threads << Thread.new(sock) { |s| serve(s) }
        end
      end
      self
    end

    # Kill every live connection, as a node restart would.
    def close_all
      socks = @mutex.synchronize { s = @sockets.dup; @sockets.clear; s }
      socks.each { |s| s.close rescue nil }
    end

    def stop
      @server&.close
      close_all
      @acceptor&.join(2)
      @threads.each { |t| t.join(2) }
      nil
    end

    private

    def read_frame(sock)
      head = sock.read(4)
      return nil if head.nil? || head.bytesize < 4

      len = head.unpack1("N")
      body = len.zero? ? "".b : sock.read(len)
      return nil if body.nil? || body.bytesize < len

      body
    end

    def send(sock, payload)
      sock.write(FakeSkaidb.frame(payload))
    end

    def serve(sock)
      conn = { sock: sock, user: nil }
      return unless handshake(sock, conn)

      while (payload = read_frame(sock))
        req = FakeSkaidb.parse_request(payload)
        @mutex.synchronize do
          @requests << req
          @hellos << req if req.op == 8
        end
        out = @handler.call(req, conn)
        if out == :close
          sock.close
          break
        end
        out = (req.op == 8 ? F.ddl : F.error("fake server: unhandled op #{req.op}")) if out.nil?
        Array(out).each { |p| send(sock, p) }
      end
    rescue IOError, SystemCallError
      nil
    ensure
      sock.close rescue nil
    end

    def handshake(sock, conn)
      payload = read_frame(sock) or return false
      r = Skaidb::Reader.new(payload)
      raise "expected AuthStart" unless r.u8 == 10

      user = r.text
      client_nonce = r.text
      salt = SecureRandom.random_bytes(16)
      server_nonce = "s#{SecureRandom.hex(6)}"
      conn[:user] = user
      auth_message = [user, client_nonce, server_nonce, salt.unpack1("H*"), ITERATIONS.to_s].join("\0")
      salted = OpenSSL::KDF.pbkdf2_hmac(@password, salt: salt, iterations: ITERATIONS, length: 32, hash: "sha256")
      send(sock, [11].pack("C") + [salt.bytesize].pack("V") + salt + [ITERATIONS].pack("V") + Skaidb.enc_str(server_nonce))

      payload = read_frame(sock) or return false
      r = Skaidb::Reader.new(payload)
      raise "expected AuthFinish" unless r.u8 == 12

      proof = r.take(32)
      client_key = hmac(salted, "Client Key")
      stored_key = OpenSSL::Digest::SHA256.digest(client_key)
      client_sig = hmac(stored_key, auth_message)
      recovered = Skaidb.xor_bytes(proof, client_sig)
      unless Skaidb.secure_compare(OpenSSL::Digest::SHA256.digest(recovered), stored_key)
        send(sock, [13, 0].pack("CC") + Skaidb.enc_str("bad password"))
        sock.close
        return false
      end
      server_key = hmac(salted, "Server Key")
      server_sig = hmac(server_key, auth_message)
      server_sig = ("\x07" * 32).b if @corrupt_server_signature
      send(sock, [13, 1].pack("CC") + server_sig)
      true
    end

    def hmac(key, msg)
      OpenSSL::HMAC.digest(OpenSSL::Digest::SHA256.new, key, msg)
    end
  end

  # A scripted handler: `script[sql]` answers OP_QUERY / OP_QUERY_STREAM text
  # (a payload, an Array of payloads, or a Proc taking the request),
  # `prepared[sql]` makes OP_PREPARE succeed with that arity, executes are
  # answered by `on_execute.(sql, req)` and batches by `on_batch.(sql, req)`.
  def self.scripted(script = nil, prepared: {}, on_execute: nil, on_batch: nil, **inline)
    script ||= inline
    ids = {}
    next_id = 100
    lambda do |req, conn|
      case req.op
      when 1, 5
        a = script[req.sql]
        return F.error("fake server: unknown statement #{req.sql}") if a.nil?

        a.respond_to?(:call) ? a.call(req, conn) : a
      when 2
        return F.error("cannot prepare this statement") unless prepared.key?(req.sql)

        id = next_id
        next_id += 1
        ids[id] = req.sql
        F.prepared(id, prepared[req.sql])
      when 3
        on_execute ? on_execute.call(ids[req.id], req) : F.error("fake server: no on_execute")
      when 7
        on_batch ? on_batch.call(ids[req.id], req) : F.mutation(req.rows.length)
      end
    end
  end
end
