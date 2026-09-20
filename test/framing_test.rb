# frozen_string_literal: true

# The frame layer (PROTOCOL.md §1) and the request encodings (§3): the length
# prefix is the one big-endian field, everything inside is little-endian.
require "test_helper"

class FramingTest < Minitest::Test
  include ServerHelpers

  def test_reader_is_little_endian_and_refuses_truncation
    r = Skaidb::Reader.new("\x01\x02\x00\x03\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00hi".b)
    assert_equal 1, r.u8
    assert_equal 2, r.u16
    assert_equal 3, r.u32
    assert_equal 4, r.i64
    assert_equal "hi", r.text
    assert_raises(Skaidb::ConnectionError) { r.u8 }
    assert_equal(-1, Skaidb::Reader.new("\xff" * 8).i64)
    assert_equal 2**64 - 1, Skaidb::Reader.new("\xff" * 8).u64
    assert_equal(-1, Skaidb::Reader.new("\xff" * 16).i128)
    assert_equal 2**64, Skaidb::Reader.new(("\x00" * 8) + "\x01" + ("\x00" * 7)).i128
  end

  def test_enc_str_is_u32_le_length_plus_utf8
    assert_equal "\x02\x00\x00\x00\xc3\xa9".b, Skaidb.enc_str("é")
    assert_equal "\x00\x00\x00\x00".b, Skaidb.enc_str("")
  end

  def test_frames_carry_a_big_endian_length_prefix
    raw = []
    with_server do |srv|
      srv.handler = ->(req, _c) { req.op == 1 ? FakeSkaidb::F.rows(["c"], [[1]]) : nil }
      c = connect(srv)
      c.exec("SELECT 1")
      c.close
      raw = srv.requests.map(&:raw)
    end
    # Hello then the query; each request payload arrived intact through the
    # length-prefixed framing (the fake server reads exactly `length` bytes).
    assert_equal [8, 1], raw.map { |p| p.getbyte(0) }
    hello = Skaidb::Reader.new(raw[0])
    hello.u8
    assert_equal "ruby", hello.text
    assert_equal Skaidb::VERSION, hello.text
    q = Skaidb::Reader.new(raw[1])
    assert_equal 1, q.u8
    assert_equal Skaidb::Consistency::QUORUM, q.u8
    assert_equal "SELECT 1", q.text
    assert_equal [8].pack("C") + Skaidb.enc_str("ruby") + Skaidb.enc_str(Skaidb::VERSION), raw[0]
    assert_equal FakeSkaidb.frame("abc").unpack1("N"), 3
  end

  def test_every_request_opcode_encodes_per_the_spec
    reqs = nil
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        { "SELECT 1" => FakeSkaidb::F.rows(["c"], [[1]]),
          "SELECT s" => [FakeSkaidb::F.header(["c"]), FakeSkaidb::F.rows_end] },
        prepared: { "INSERT INTO t VALUES (?, ?)" => 2 },
        on_execute: ->(_sql, _req) { FakeSkaidb::F.mutation(1) },
        on_batch: ->(_sql, req) { FakeSkaidb::F.mutation(req.rows.length) }
      )
      c = connect(srv, consistency: :all)
      c.exec("SELECT 1")
      c.exec_params("INSERT INTO t VALUES ($1, $2)", [1, "a"], consistency: :one)
      c.exec_batch("INSERT INTO t VALUES ($1, $2)", [[2, "b"], [3, "c"]])
      c.stream("SELECT s") { |_| nil }
      c.close
      reqs = srv.requests
    end
    assert_equal [8, 1, 2, 3, 7, 5], reqs.map(&:op)
    assert_equal [2, "SELECT 1"], [reqs[1].consistency, reqs[1].sql]
    assert_equal "INSERT INTO t VALUES (?, ?)", reqs[2].sql
    assert_equal [0, 100, [1, "a"]], [reqs[3].consistency, reqs[3].id, reqs[3].params]
    assert_equal [2, 100, [[2, "b"], [3, "c"]]], [reqs[4].consistency, reqs[4].id, reqs[4].rows]
    assert_equal [2, "SELECT s"], [reqs[5].consistency, reqs[5].sql]
    # OP_EXECUTE: u8 op, u8 consistency, u32 id, u16 nparams, then (u32 len + value)*
    ex = reqs[3].raw
    assert_equal [3, 0, 100, 2], ex.unpack("CCVv")
    assert_equal 9, ex.byteslice(8, 4).unpack1("V") # first value: Int is 1 + 8 bytes
    assert_equal Skaidb.encode_value(1), ex.byteslice(12, 9)
    # OP_EXECUTE_BATCH: u8 op, u8 consistency, u32 id, u32 nrows, rows of (u16 n + values)
    assert_equal [7, 2, 100, 2, 2], reqs[4].raw.unpack("CCVVv")
  end
end
