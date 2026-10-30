# frozen_string_literal: true

# The shared skaidb wire-protocol conformance suite.
#
# conformance/vectors.json is generated from the server's reference encoders
# (https://skaidb.org/conformance/vectors.json; the contract is
# conformance/README.md). This harness runs it against the driver's PUBLIC
# API through a fake server that sends the reference bytes — never bytes this
# driver encoded — and checks the exact bytes the driver sends. The fake
# server verifies the SCRAM client proof with its own OpenSSL calls, not the
# driver's SCRAM code.
require "test_helper"
require "json"

module Conformance
  VECTORS = JSON.parse(File.read(File.expand_path("../conformance/vectors.json", __dir__)))

  # The call methods this harness has no public API for (printed, and listed
  # in the README's Conformance section). Every method is covered today.
  SKIPPED_METHODS = [].freeze

  module_function

  def unhex(s)
    [s].pack("H*")
  end

  def hex(b)
    b.unpack1("H*")
  end

  # ---- tagged JSON <-> Ruby ------------------------------------------------

  # A value the driver surfaced, in the vectors' tagged form.
  def tagged(v)
    case v
    when nil then { "null" => true }
    when true, false then { "bool" => v }
    when Integer then { "int" => v.to_s }
    when Float then { "float" => v, "float_bits" => [v].pack("G").unpack1("H*") }
    when BigDecimal
      sign, digits, _base, exponent = v.split
      mantissa = digits.to_i
      mantissa = -mantissa if sign.negative?
      scale = mantissa.zero? ? 0 : digits.length - exponent
      if scale.negative?
        mantissa *= 10**-scale
        scale = 0
      end
      { "decimal" => { "mantissa" => mantissa.to_s, "scale" => scale } }
    when String
      v.encoding == Encoding::BINARY ? { "bytes" => hex(v) } : { "string" => v }
    when Skaidb::Uuid then { "string" => v.to_s }
    when Time then { "timestamp_ms" => ((v.to_i * 1000) + (v.nsec / 1_000_000)).to_s }
    when Array then { "array" => v.map { |x| tagged(x) } }
    when Hash then { "document" => v.map { |k, x| { "key" => k, "value" => tagged(x) } } }
    else raise "unmapped driver value #{v.inspect}"
    end
  end

  # The driver surfaces a Uuid cell as its canonical String (docs/types.md),
  # so an expected Uuid is compared in that form.
  def driver_form(t)
    case t
    when Hash
      return { "string" => t["uuid"] } if t.keys == ["uuid"]

      t.transform_values { |x| driver_form(x) }
    when Array then t.map { |x| driver_form(x) }
    else t
    end
  end

  # A tagged value as the Ruby value the driver binds.
  def native(t)
    if t.key?("null") then nil
    elsif t.key?("bool") then t["bool"]
    elsif t.key?("int") then Integer(t["int"], 10)
    elsif t.key?("float_bits") then unhex(t["float_bits"]).unpack1("G")
    elsif t.key?("decimal") then BigDecimal("#{t['decimal']['mantissa']}e-#{t['decimal']['scale']}")
    elsif t.key?("string") then t["string"]
    elsif t.key?("bytes") then unhex(t["bytes"])
    elsif t.key?("uuid") then Skaidb::Uuid.new(t["uuid"])
    elsif t.key?("timestamp_ms") then Time.at(Rational(Integer(t["timestamp_ms"], 10), 1000)).utc
    elsif t.key?("array") then t["array"].map { |x| native(x) }
    elsif t.key?("document") then t["document"].to_h { |e| [e["key"], native(e["value"])] }
    else raise "unknown tagged value #{t}"
    end
  end

  def rows_json(columns, rows)
    { "columns" => columns.to_a, "rows" => rows.map { |r| r.map { |v| tagged(v) } } }
  end

  # The vectors' SQL uses the server's positional `?`; this driver's syntax
  # is $1, $2, ... (rewritten back to `?` on the wire, which the byte check
  # on the request proves).
  def dollar_placeholders(sql)
    n = 0
    in_str = false
    sql.each_char.map do |ch|
      in_str = !in_str if ch == "'"
      next ch if in_str || ch != "?"

      n += 1
      "$#{n}"
    end.join
  end

  # ---- the scripted fake server -------------------------------------------

  # One connection: the handshake per +outcome+, then +exchanges+ (a list of
  # [request bytes, [response bytes...]]). A mismatch is kept in +error+.
  class FakeServer
    attr_reader :port, :error, :requests

    def initialize(outcome: "ok", exchanges: [])
      @outcome = outcome
      @pending = exchanges.dup
      @requests = []
      @error = nil
      @listener = TCPServer.new("127.0.0.1", 0)
      @port = @listener.addr[1]
      @thread = Thread.new do
        sock = @listener.accept
        @listener.close
        begin
          serve(sock)
        ensure
          sock.close
        end
      rescue StandardError => e
        @error ||= "#{e.class}: #{e.message}"
      end
    end

    def join
      @thread.join(10) or @error ||= "fake server did not finish"
      @listener.close unless @listener.closed?
    end

    private

    def read_frame(sock)
      head = sock.read(4)
      return nil if head.nil? || head.bytesize < 4

      n = head.unpack1("N")
      body = n.zero? ? "".b : sock.read(n)
      return nil if body.nil? || body.bytesize < n

      body
    end

    def send_frame(sock, payload)
      sock.write([payload.bytesize].pack("N") + payload.b)
    end

    def str_at(buf, pos)
      n = buf.byteslice(pos, 4).unpack1("V")
      [buf.byteslice(pos + 4, n), pos + 4 + n]
    end

    def hmac(key, msg)
      OpenSSL::HMAC.digest("SHA256", key, msg)
    end

    def serve(sock)
      auth = VECTORS["auth"]
      start = read_frame(sock) or raise "no AuthStart"
      raise "expected AuthStart, got tag #{start.getbyte(0)}" unless start.getbyte(0) == 10

      user, pos = str_at(start, 1)
      client_nonce, pos = str_at(start, pos)
      raise "AuthStart has trailing bytes #{Conformance.hex(start.byteslice(pos..))}" unless pos == start.bytesize

      salt = Conformance.unhex(auth["challenge"]["salt"])
      iterations = auth["challenge"]["iterations"]
      server_nonce = client_nonce + auth["challenge"]["server_nonce_suffix"].b
      send_frame(sock, [11].pack("C") + [salt.bytesize].pack("V") + salt + [iterations].pack("V") +
                       [server_nonce.bytesize].pack("V") + server_nonce)

      finish = read_frame(sock) or raise "no AuthFinish"
      raise "expected AuthFinish" unless finish.getbyte(0) == 12 && finish.bytesize == 33

      am = [user, client_nonce, server_nonce, Conformance.hex(salt).b, iterations.to_s.b].join("\0".b)
      salted = OpenSSL::KDF.pbkdf2_hmac(auth["password"].b, salt: salt, iterations: iterations,
                                                            length: 32, hash: "sha256")
      client_key = hmac(salted, "Client Key")
      client_sig = hmac(OpenSSL::Digest::SHA256.digest(client_key), am)
      proof = client_key.bytes.zip(client_sig.bytes).map { |a, b| a ^ b }.pack("C*")
      raise "client proof did not verify" unless finish.byteslice(1, 32) == proof

      server_sig = hmac(hmac(salted, "Server Key"), am)
      case @outcome
      when "ok"
        send_frame(sock, [13, 1].pack("CC") + server_sig)
      when "bad_server_signature"
        send_frame(sock, [13, 1].pack("CC") + ("\xAA".b * 32))
        return
      else
        denied = auth["outcomes"].find { |o| o["name"] == "denied" }
        send_frame(sock, Conformance.unhex(denied["payload"]))
        return
      end

      ddl = Conformance.unhex(VECTORS["ignorable_requests"]["ddl_payload"])
      loop do
        req = read_frame(sock)
        if req.nil?
          @error ||= "never received request #{Conformance.hex(@pending.first[0])}" unless @pending.empty?
          return
        end
        if [4, 8].include?(req.getbyte(0))
          send_frame(sock, ddl)
          next
        end
        @requests << req
        if @pending.empty?
          @error = "unexpected extra request #{Conformance.hex(req)}"
          return
        end
        want, responses = @pending.shift
        if req != want
          @error = "request mismatch:\n  got  #{Conformance.hex(req)}\n  want #{Conformance.hex(want)}"
          return
        end
        responses.each { |r| send_frame(sock, r) }
      end
    end
  end

  def connect(server)
    Skaidb.connect(host: "127.0.0.1", port: server.port, user: VECTORS["auth"]["username"],
                   password: VECTORS["auth"]["password"], timeout: 5)
  end

  # ---- running a case's call through the public API -----------------------

  def outcome
    yield
  rescue Skaidb::QueryError => e
    { "error" => e.message }
  end

  def result_json(res)
    case res.kind
    when :ddl then { "ddl" => true }
    when :mutation then { "affected" => res.cmd_tuples.to_s }
    when :rows
      if res.result_sets.length > 1
        { "result_sets" => res.result_sets.map { |s| rows_json(s.fields, s.rows) } }
      else
        { "rows" => rows_json(res.fields, res.rows) }
      end
    else raise "unexpected result kind #{res.kind.inspect}"
    end
  end

  def run_call(conn, call)
    case call["method"]
    when "sequence"
      { "sequence" => call["calls"].map { |c| run_call(conn, c) } }
    when "query"
      outcome do
        conn.consistency = call["consistency"]
        result_json(conn.exec(call["sql"]))
      end
    when "query_stream"
      outcome do
        rows = []
        columns = nil
        # With call.params, the parameterised form: the vector's `?` become
        # $1, $2, ... and go back to `?` on the wire (OP_QUERY_STREAM_PARAMS).
        params = Array(call["params"]).map { |p| native(p) }
        args = params.empty? ? [call["sql"]] : [dollar_placeholders(call["sql"]), params]
        begin
          res = conn.stream(*args) do |row|
            columns ||= row.keys
            rows << row.values
          end
        rescue Skaidb::QueryError => e
          raise if rows.empty? # an error before any row: a plain statement error

          next { "rows_then_error" => { "rows" => rows_json(columns, rows), "error" => e.message } }
        end
        # A row stream is compared by the rows the block saw. Anything else is
        # the Result stream returned: a non-row statement's, or a CALL that
        # EMITs — its :rows Result (the block got the last set) carries every
        # set in order, and result_json reports them all as result_sets.
        res.kind == :stream ? { "rows" => rows_json(res.fields, rows) } : result_json(res)
      end
    when "execute_prepared"
      outcome do
        result_json(conn.exec_params(dollar_placeholders(call["sql"]), call["params"].map { |p| native(p) },
                                     consistency: call["consistency"]))
      end
    when "execute_batch"
      outcome do
        n = conn.exec_batch(dollar_placeholders(call["sql"]),
                            call["rows"].map { |r| r.map { |p| native(p) } },
                            consistency: call["consistency"])
        { "affected" => n.to_s }
      end
    else
      raise "unknown call.method #{call['method']}"
    end
  end

  def matches?(expect, got)
    if expect.key?("error")
      got.key?("error") && got["error"].include?(expect["error"])
    elsif expect.key?("sequence")
      got.key?("sequence") && expect["sequence"].length == got["sequence"].length &&
        expect["sequence"].zip(got["sequence"]).all? { |e, g| matches?(e, g) }
    elsif expect.key?("rows_then_error")
      e = expect["rows_then_error"]
      g = got["rows_then_error"]
      !g.nil? && e["rows"] == g["rows"] && g["error"].include?(e["error"])
    else
      expect == got
    end
  end
end

class ConformanceTest < Minitest::Test
  V = Conformance::VECTORS
  C = Conformance

  def test_format_version_is_understood
    assert_equal 1, V["format_version"]
  end

  def test_every_value_decodes_and_encodes
    refute_empty V["values"]
    V["values"].each do |entry|
      encoded = C.unhex(entry["encoded"])
      decoded = Skaidb.decode_value(Skaidb::Reader.new(encoded))
      assert_equal C.driver_form(entry["value"]), C.tagged(decoded), "decode #{entry['name']}"
      assert_equal entry["encoded"], C.hex(Skaidb.encode_value(C.native(entry["value"]))), "encode #{entry['name']}"
    end
  end

  def test_scram_computations
    refute_empty V["scram"]
    V["scram"].each do |s|
      salt = C.unhex(s["salt"])
      am = Skaidb.auth_message(s["username"], s["client_nonce"], s["server_nonce"], salt, s["iterations"])
      assert_equal s["auth_message"], C.hex(am.b), "auth_message #{s['username']}"
      assert_equal s["salted_password"], C.hex(Skaidb.salted_password(s["password"], salt, s["iterations"]))
      proof, sig = Skaidb.scram(s["password"], salt, s["iterations"], am)
      assert_equal s["client_proof"], C.hex(proof), "client_proof #{s['username']}"
      assert_equal s["server_signature"], C.hex(sig), "server_signature #{s['username']}"
    end
  end

  def test_auth_outcomes
    V["auth"]["outcomes"].each do |o|
      server = C::FakeServer.new(outcome: o["name"])
      if o["expect"] == "connected"
        conn = C.connect(server)
        assert conn.usable?, o["name"]
        conn.close
      else
        e = assert_raises(Skaidb::ConnectionError, o["name"]) { C.connect(server) }
        assert_includes e.message, o["reason"], o["name"] if o["reason"]
      end
      server.join
      assert_nil server.error, o["name"]
    end
  end

  def test_cases
    ran = []
    skipped = []
    V["cases"].each do |kase|
      methods = [kase["call"]["method"]] + Array(kase["call"]["calls"]).map { |c| c["method"] }
      if (methods & C::SKIPPED_METHODS).any?
        skipped << kase["name"]
        next
      end
      exchanges = kase["exchanges"].map { |e| [C.unhex(e["request"]), e["responses"].map { |r| C.unhex(r) }] }
      server = C::FakeServer.new(exchanges: exchanges)
      conn = C.connect(server)
      got = begin
        C.run_call(conn, kase["call"])
      ensure
        conn.close
      end
      server.join
      assert_nil server.error, kase["name"]
      expect = C.driver_form(kase["expect"])
      assert C.matches?(expect, got), "#{kase['name']}:\n  expected #{expect}\n  got      #{got}"
      ran << kase["name"]
    end
    skipped_methods = C::SKIPPED_METHODS.empty? ? "none" : C::SKIPPED_METHODS.join(", ")
    puts "\nconformance: #{ran.length} cases ran, #{skipped.length} skipped; skipped call methods: #{skipped_methods}"
    refute_empty ran
  end
end
