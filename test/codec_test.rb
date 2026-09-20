# frozen_string_literal: true

# The value codec (PROTOCOL.md §4), client-side quoting (§5) and the $N -> ?
# placeholder rewrite. No sockets.
require "test_helper"

class CodecTest < Minitest::Test
  def roundtrip(v)
    Skaidb.decode_value(Skaidb::Reader.new(Skaidb.encode_value(v)))
  end

  def test_null_bool_int_float
    assert_equal "\x00".b, Skaidb.encode_value(nil)
    assert_nil roundtrip(nil)
    assert_equal "\x01\x01".b, Skaidb.encode_value(true)
    assert_equal "\x01\x00".b, Skaidb.encode_value(false)
    assert_equal true, roundtrip(true)
    assert_equal false, roundtrip(false)
    assert_equal "\x02\x2a\x00\x00\x00\x00\x00\x00\x00".b, Skaidb.encode_value(42) # i64 LE
    assert_equal(-1, roundtrip(-1))
    assert_equal 2**63 - 1, roundtrip(2**63 - 1)
    assert_equal(-(2**63), roundtrip(-(2**63)))
    assert_equal 1.5, roundtrip(1.5)
    assert_equal "\x03\x00\x00\x00\x00\x00\x00\xf8\x3f".b, Skaidb.encode_value(1.5) # f64 LE
    assert_equal(-0.0, roundtrip(-0.0))
  end

  def test_int_out_of_range_and_non_finite_float_are_refused
    e = assert_raises(Skaidb::QueryError) { Skaidb.encode_value(2**63) }
    assert_match(/64-bit/, e.message)
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(-(2**63) - 1) }
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(Float::NAN) }
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(Float::INFINITY) }
    assert_raises(Skaidb::QueryError) { Skaidb.quote(Float::NAN) }
  end

  def test_decimal
    b = Skaidb.encode_value(BigDecimal("123.45"))
    assert_equal 4, b.getbyte(0)
    assert_equal 12_345, b.byteslice(1, 16).unpack("Q<Q<").then { |lo, hi| (hi << 64) | lo }
    assert_equal 2, b.byteslice(17, 4).unpack1("V")
    assert_equal BigDecimal("123.45"), roundtrip(BigDecimal("123.45"))
    assert_equal BigDecimal("-0.005"), roundtrip(BigDecimal("-0.005"))
    assert_equal BigDecimal("0"), roundtrip(BigDecimal("0"))
    assert_equal BigDecimal("100000"), roundtrip(BigDecimal("1e5"))
    assert_equal [100_000, 0], Skaidb.decimal_parts(BigDecimal("1e5")) # positive exponent folded
    assert_equal [-123, 1], Skaidb.decimal_parts(BigDecimal("-12.300")) # trailing zeros dropped
    assert_equal BigDecimal("-170141183460469231731687303715884105728"), roundtrip(BigDecimal("-170141183460469231731687303715884105728"))
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(BigDecimal("170141183460469231731687303715884105728")) }
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(BigDecimal("NaN")) }
    # decoding a negative mantissa
    neg = [4].pack("C") + [-5 & (2**64 - 1), 2**64 - 1].pack("Q<Q<") + [3].pack("V")
    assert_equal BigDecimal("-0.005"), Skaidb.decode_value(Skaidb::Reader.new(neg))
  end

  def test_string_and_bytes
    b = Skaidb.encode_value("héllo")
    assert_equal 5, b.getbyte(0)
    assert_equal 6, b.byteslice(1, 4).unpack1("V")
    assert_equal "héllo", roundtrip("héllo")
    assert_equal Encoding::UTF_8, roundtrip("héllo").encoding
    assert_equal "sym", roundtrip(:sym)
    raw = "\x00\x01\xfe\xff".b
    bb = Skaidb.encode_value(raw)
    assert_equal 6, bb.getbyte(0)
    assert_equal raw, roundtrip(raw)
    assert_equal Encoding::BINARY, roundtrip(raw).encoding
    assert_equal "".b, roundtrip("".b)
  end

  def test_uuid
    u = Skaidb::Uuid.new("6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
    assert_equal "6ba7b810-9dad-11d1-80b4-00c04fd430c8", u.to_s
    b = Skaidb.encode_value(u)
    assert_equal 17, b.bytesize
    assert_equal 7, b.getbyte(0)
    assert_equal "6ba7b8109dad11d180b400c04fd430c8", b.byteslice(1, 16).unpack1("H*")
    assert_equal "6ba7b810-9dad-11d1-80b4-00c04fd430c8", roundtrip(u) # results are canonical Strings
    assert_equal u, roundtrip(u)
    assert_equal u, Skaidb::Uuid.new("6ba7b8109dad11d180b400c04fd430c8")
    assert_equal u, Skaidb::Uuid.from_bytes(u.bytes)
    assert_equal u.hash, Skaidb::Uuid.new(u.to_s).hash
    refute_equal u, "not-a-uuid"
    assert_raises(ArgumentError) { Skaidb::Uuid.new("nope") }
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, Skaidb::Uuid.random.to_s)
    assert_equal "'6ba7b810-9dad-11d1-80b4-00c04fd430c8'", Skaidb.quote(u)
  end

  def test_timestamp
    t = Time.utc(2024, 2, 29, 12, 34, 56, 789_000)
    b = Skaidb.encode_value(t)
    assert_equal 8, b.getbyte(0)
    assert_equal 1_709_210_096_789, b.byteslice(1, 8).unpack1("q<")
    r = roundtrip(t)
    assert_kind_of Time, r
    assert_equal t, r
    assert r.utc?
    # sub-millisecond precision is truncated, exactly (no float rounding)
    assert_equal 1_709_210_096_789, Skaidb.time_ms(Time.utc(2024, 2, 29, 12, 34, 56, 789_999))
    # pre-1970 values, and a local-zone Time, round-trip to the same instant
    pre = Time.at(-1, 500_000, :usec).utc
    assert_equal(-500, Skaidb.time_ms(pre))
    assert_equal pre, roundtrip(pre)
    local = Time.at(1_700_000_000, 250_000, :usec).localtime("+05:30")
    assert_equal local, roundtrip(local)
    assert_equal "1700000000250", Skaidb.quote(local)
  end

  def test_array_and_document
    v = [1, "two", 3.0, nil, true, [BigDecimal("1.5")], { "k" => "v" }]
    b = Skaidb.encode_value(v)
    assert_equal 9, b.getbyte(0)
    assert_equal 7, b.byteslice(1, 4).unpack1("V")
    assert_equal v, roundtrip(v)
    doc = { "city" => "London", "tags" => %w[a b], "n" => nil, "sym" => 1 }
    d = Skaidb.encode_value(doc)
    assert_equal 10, d.getbyte(0)
    assert_equal 4, d.byteslice(1, 4).unpack1("V")
    assert_equal doc, roundtrip(doc)
    assert_equal %w[city tags n sym], roundtrip(doc).keys # insertion order kept
    assert_equal({ "sym" => 1 }, roundtrip({ sym: 1 })) # symbol keys become strings
    assert_equal [], roundtrip([])
    assert_equal({}, roundtrip({}))
  end

  def test_unknown_types_and_tags
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(Object.new) }
    assert_raises(Skaidb::QueryError) { Skaidb.encode_value(1..2) }
    assert_raises(Skaidb::ConnectionError) { Skaidb.decode_value(Skaidb::Reader.new("\x0b".b)) }
    assert_raises(Skaidb::ConnectionError) { Skaidb.decode_value(Skaidb::Reader.new("\x02\x01".b)) } # truncated
  end

  def test_quote_client_side_fallback
    assert_equal "NULL", Skaidb.quote(nil)
    assert_equal "TRUE", Skaidb.quote(true)
    assert_equal "FALSE", Skaidb.quote(false)
    assert_equal "42", Skaidb.quote(42)
    assert_equal "1.5", Skaidb.quote(1.5)
    assert_equal "123.45", Skaidb.quote(BigDecimal("123.45"))
    assert_equal "'O''Brien'", Skaidb.quote("O'Brien")
    assert_equal "'sym'", Skaidb.quote(:sym)
    assert_equal "'00ff'", Skaidb.quote("\x00\xff".b)
    assert_raises(Skaidb::QueryError) { Skaidb.quote([1]) }
    assert_raises(Skaidb::QueryError) { Skaidb.quote({}) }
  end

  def test_bind_interpolates_outside_string_literals
    assert_equal "SELECT * FROM t WHERE a = 'x''y' AND b = 2 AND c = '$1'",
                 Skaidb.bind("SELECT * FROM t WHERE a = $1 AND b = $2 AND c = '$1'", ["x'y", 2])
    assert_equal "SELECT 1 WHERE a = 1 AND b = 1", Skaidb.bind("SELECT 1 WHERE a = $1 AND b = $1", [1])
    assert_equal "SELECT 11", Skaidb.bind("SELECT $11", (1..11).to_a)
    assert_raises(Skaidb::QueryError) { Skaidb.bind("SELECT $0", [1]) }
    assert_raises(Skaidb::QueryError) { Skaidb.bind("SELECT $2", [1]) }
    assert_raises(Skaidb::QueryError) { Skaidb.bind("SELECT $1", [1, 2]) } # more params than placeholders
    assert_equal "SELECT 1", Skaidb.bind("SELECT 1", nil)
  end

  def test_to_qmark_rewrites_placeholders_in_wire_order
    sql, order = Skaidb.to_qmark("UPDATE t SET a = $2, b = $1 WHERE a = $2 AND s = '$1'", ["one", "two"])
    assert_equal "UPDATE t SET a = ?, b = ? WHERE a = ? AND s = '$1'", sql
    assert_equal %w[two one two], order
    sql, order = Skaidb.to_qmark("SELECT 'it''s $1'", [])
    assert_equal "SELECT 'it''s $1'", sql
    assert_equal [], order
    assert_raises(Skaidb::QueryError) { Skaidb.to_qmark("SELECT $3", [1, 2]) }
    assert_raises(Skaidb::QueryError) { Skaidb.to_qmark("SELECT $0", [1]) }
  end

  def test_a_bare_question_mark_is_not_a_placeholder
    e = assert_raises(Skaidb::QueryError) { Skaidb.to_qmark("SELECT * FROM t WHERE id = ?", [1]) }
    assert_match(/\$1, \$2/, e.message)
    # inside a string literal, or with no parameters at all, it is just text
    assert_equal ["SELECT '?'", []], Skaidb.to_qmark("SELECT '?'", [])
    assert_equal ["SELECT * FROM t WHERE q = '?' AND id = ?", [1]],
                 Skaidb.to_qmark("SELECT * FROM t WHERE q = '?' AND id = $1", [1])
  end

  def test_consistency_resolve
    assert_equal 0, Skaidb::Consistency.resolve(:one)
    assert_equal 1, Skaidb::Consistency.resolve("QUORUM")
    assert_equal 2, Skaidb::Consistency.resolve(2)
    assert_raises(Skaidb::Error) { Skaidb::Consistency.resolve(3) }
    assert_raises(Skaidb::Error) { Skaidb::Consistency.resolve(:nope) }
    assert_raises(Skaidb::Error) { Skaidb::Consistency.resolve(nil) }
  end
end
