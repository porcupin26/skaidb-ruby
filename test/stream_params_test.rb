# frozen_string_literal: true

# Parameterised streaming (OP_QUERY_STREAM_PARAMS, PROTOCOL.md §3.4, server
# >= 0.330): the exact request bytes, the parameterless form that keeps the
# original OP_QUERY_STREAM byte for byte, the call forms that predate
# parameters, the checks that refuse a parameter before anything is sent,
# and what an older server's "unknown opcode" becomes.
require "test_helper"

class StreamParamsTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  # What a server before 0.330 answers opcode 9 with.
  OLD_SERVER = "protocol error: malformed message: unknown opcode"

  # The stream requests the fake server saw, in order.
  def streams(srv)
    srv.requests.select { |q| [5, 9].include?(q.op) }
  end

  def test_parameters_travel_in_op_query_stream_params_byte_for_byte
    qsql = "SELECT id FROM t WHERE id > ? AND tag = ?"
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        { qsql => [F.header(["id"]), F.chunk([[8], [9]]), F.chunk([[10]]), F.rows_end],
          "SELECT 1" => F.rows(["c"], [[1]]) }
      )
      c = connect(srv)
      seen = []
      res = c.stream("SELECT id FROM t WHERE id > $1 AND tag = $2", [7, "a"]) { |row| seen << row["id"] }
      assert_equal [8, 9, 10], seen
      assert_equal [:stream, ["id"], []], [res.kind, res.fields, res.rows]
      want = [9, 1].pack("CC") +                                    # OP_QUERY_STREAM_PARAMS, QUORUM
             [qsql.bytesize].pack("V") + qsql +                      # the SQL, $N rewritten to ?
             [2].pack("v") +                                         # u16 parameter count
             [9].pack("V") + "\x02\x07\x00\x00\x00\x00\x00\x00\x00".b + # u32 length + Int 7
             [6].pack("V") + "\x05\x01\x00\x00\x00a".b               # u32 length + String "a"
      assert_equal want.b, streams(srv).last.raw
      assert_equal 9, streams(srv).last.op
      assert c.usable?
      # leaving early drains the tail of a parameterised stream too
      assert_equal [8], c.stream("SELECT id FROM t WHERE id > $1 AND tag = $2", [7, "a"]).first(1).map { |r| r["id"] }
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      c.close
    end
  end

  def test_the_values_are_the_parameter_vector_op_execute_carries
    t = Time.utc(2026, 10, 29, 12, 0, 0, 123_000)
    u = Skaidb::Uuid.random
    params = [t, [1, "two", nil], { "city" => "London", "n" => nil }, BigDecimal("1.25"), u, "\x00\xff".b,
              2.5, false, :sym, 2**62]
    sql = "SELECT id FROM t WHERE ts >= $1 AND a = $2 AND d = $3 AND m = $4 AND u = $5 AND b = $6 " \
          "AND f = $7 AND x = $8 AND s = $9 AND i = $10 AND ts < $1"
    qsql, order = Skaidb.to_qmark(sql, params)
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        { qsql => [F.header(["id"]), F.rows_end] },
        prepared: { qsql => order.length }, on_execute: ->(_s, _req) { F.rows(["id"], []) }
      )
      c = connect(srv)
      c.stream(sql, params) { |_| flunk "no rows expected" }
      c.exec_params(sql, params)
      stream_req = srv.requests.find { |q| q.op == 9 }
      exec_req = srv.requests.find { |q| q.op == 3 }
      # typed, in ? order: $1 is referenced twice, so it is sent twice
      assert_equal [t, [1, "two", nil], { "city" => "London", "n" => nil }, BigDecimal("1.25"), u.to_s,
                    "\x00\xff".b, 2.5, false, "sym", 2**62, t], stream_req.params
      assert_equal qsql, stream_req.sql
      # byte for byte the vector after OP_EXECUTE's u8 op, u8 consistency, u32 id
      assert_equal exec_req.raw.byteslice(6..), stream_req.raw.byteslice((6 + qsql.bytesize)..)
      c.close
    end
  end

  def test_no_parameters_keep_the_original_op_query_stream_byte_for_byte
    sql = "SELECT id FROM t WHERE note = 'costs $1'"
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(sql => [F.header(["id"]), F.chunk([[1]]), F.rows_end],
                                        "SELECT $1" => [F.header(["c"]), F.rows_end])
      c = connect(srv)
      c.stream(sql) { |_| nil }
      c.stream(sql, []) { |_| nil }
      c.stream(sql, nil) { |_| nil }
      assert_equal [{ "id" => 1 }], c.stream(sql, []).to_a
      # without parameters the SQL goes out untouched, $N and all
      c.stream("SELECT $1") { |_| nil }
      want = [5, 1].pack("CC") + Skaidb.enc_str(sql)
      assert_equal [want] * 4, streams(srv).first(4).map(&:raw)
      assert_equal [5, 1].pack("CC") + Skaidb.enc_str("SELECT $1"), streams(srv).last.raw
      assert_equal [5] * 5, streams(srv).map(&:op)
      c.close
    end
  end

  def test_the_call_forms_that_predate_parameters_still_work
    with_server do |srv|
      level = ->(req, _c) { [F.header(["level"]), F.chunk([[req.consistency]]), F.rows_end] }
      srv.handler = FakeSkaidb.scripted(
        "SELECT level" => level, "SELECT level WHERE id = ?" => level,
        "DELETE FROM t WHERE id = ?" => F.mutation(2)
      )
      c = connect(srv, consistency: :quorum)
      got = []
      res = c.stream("SELECT level") { |row| got << row["level"] }
      c.stream("SELECT level", consistency: :one) { |row| got << row["level"] }
      c.stream("SELECT level", consistency: "ALL") { |row| got << row["level"] }
      got.concat(c.stream("SELECT level").map { |row| row["level"] })
      got.concat(c.stream("SELECT level", consistency: 0).first(1).map { |row| row["level"] })
      assert_equal [1, 0, 2, 1, 0], got
      assert_equal [:stream, ["level"]], [res.kind, res.fields]
      assert_equal [5] * 5, streams(srv).map(&:op)

      # the parameterised form takes the same keyword, block and Enumerator forms
      got = []
      c.stream("SELECT level WHERE id = $1", [1], consistency: :all) { |row| got << row["level"] }
      got.concat(c.stream("SELECT level WHERE id = $1", [1]).map { |row| row["level"] })
      got.concat(c.stream("SELECT level WHERE id = $1", [1], consistency: :one).first(1).map { |row| row["level"] })
      assert_equal [2, 1, 0], got
      assert_equal [9] * 3, streams(srv).last(3).map(&:op)
      assert_equal [[1]] * 3, streams(srv).last(3).map(&:params)

      # a statement without rows answers its ordinary result over opcode 9
      del = c.stream("DELETE FROM t WHERE id = $1", [5]) { |_| flunk "no rows expected" }
      assert_equal [:mutation, 2], [del.kind, del.cmd_tuples]
      assert_equal [9, [5]], [streams(srv).last.op, streams(srv).last.params]
      assert c.usable?
      c.close
    end
  end

  def test_an_old_server_refusing_the_opcode_says_so_and_the_connection_survives
    with_server do |srv|
      srv.handler = lambda do |req, _c|
        case req.op
        when 9 then F.error(OLD_SERVER)
        when 5 then [F.header(["id"]), F.chunk([[1]]), F.rows_end]
        when 1 then F.rows(["c"], [[1]])
        end
      end
      c = connect(srv)
      e = assert_raises(Skaidb::QueryError) do
        c.stream("SELECT id FROM t WHERE id > $1", [0]) { |_| flunk "no rows expected" }
      end
      assert_equal "server does not support parameterised streaming (skaidb >= 0.330): #{OLD_SERVER}", e.message
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT id FROM t WHERE id > $1", [0]).first(1) }
      assert_match(/parameterised streaming \(skaidb >= 0\.330\)/, e.message)
      # one ordinary Error frame: the connection sits at a request boundary
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal [{ "id" => 1 }], c.stream("SELECT id FROM t").to_a # a parameterless stream still works
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_other_refusals_keep_their_messages
    with_server do |srv|
      srv.handler = lambda do |req, _c|
        case req.op
        when 9 then F.error("statement expects 2 parameters, got 1")
        when 5 then F.error(OLD_SERVER)
        end
      end
      c = connect(srv)
      # an error that is not "unknown opcode" is the server's, unchanged
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT $1", [1]) { |_| nil } }
      assert_equal "statement expects 2 parameters, got 1", e.message
      # a server without any streaming still says just that
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT 1") { |_| nil } }
      assert_equal "server does not support streaming: #{OLD_SERVER}", e.message
      assert c.usable?
      c.close
    end
  end

  def test_a_parameter_that_cannot_be_bound_is_refused_before_anything_is_sent
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("SELECT 1" => F.rows(["c"], [[1]]))
      c = connect(srv)
      sent = srv.requests.length
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT id FROM t WHERE id = $2", [1]) { |_| nil } }
      assert_equal "placeholder $2 has no parameter", e.message
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT id FROM t WHERE id = $1", [1, "EXTRA"]) { |_| nil } }
      assert_equal "more parameters (2) than placeholders ($1)", e.message
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT id FROM t WHERE id = ?", [1]) { |_| nil } }
      assert_match(/this driver uses \$1, \$2, \.\.\. placeholders/, e.message)
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT id FROM t WHERE id = $1", [2**63]) { |_| nil } }
      assert_match(/64-bit/, e.message)
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT id FROM t WHERE id = $1", [Object.new]) { |_| nil } }
      assert_match(/cannot bind value of type Object/, e.message)
      # the count is a u16 on the wire: refused rather than wrapped
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT #{(['$1'] * 65_536).join(', ')}", [1]) { |_| nil } }
      assert_equal "a statement takes at most 65535 parameters, got 65536", e.message
      # params is an Array; anything else is most likely a positional consistency
      e = assert_raises(ArgumentError) { c.stream("SELECT 1", :one) { |_| nil } }
      assert_match(/stream params must be an Array, got Symbol .*consistency: :one/, e.message)
      assert_raises(ArgumentError) { c.stream("SELECT 1", "ONE").to_a }
      assert_equal sent, srv.requests.length
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      c.close
    end
  end
end
