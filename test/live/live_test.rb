# frozen_string_literal: true

# End-to-end test against a REAL skaidb server. Opt-in: it runs only when
# SKAIDB_LIVE=1 is set (CI has no server, so there it is skipped, not failed).
#
#   SKAIDB_LIVE=1 SKAIDB_HOST=127.0.0.1 SKAIDB_PORT=7000 \
#   SKAIDB_USER=admin SKAIDB_PASSWORD=secret SKAIDB_DATABASE=default \
#   ruby -Ilib test/live/live_test.rb
#
# Every table it creates is prefixed ruby_live_ and dropped afterwards.
require "minitest/autorun"
require "skaidb"

class LiveTest < Minitest::Test
  HOST = ENV.fetch("SKAIDB_HOST", "127.0.0.1")
  PORT = ENV.fetch("SKAIDB_PORT", "7000").to_i
  USER = ENV.fetch("SKAIDB_USER", "anonymous")
  PASSWORD = ENV.fetch("SKAIDB_PASSWORD", "")
  DATABASE = ENV["SKAIDB_DATABASE"]
  TABLE = "ruby_live_#{Process.pid}"

  def setup
    skip "set SKAIDB_LIVE=1 (and SKAIDB_HOST/PORT/USER/PASSWORD) to run against a server" unless ENV["SKAIDB_LIVE"]
    @conn = Skaidb.connect(host: HOST, port: PORT, user: USER, password: PASSWORD,
                           database: DATABASE, consistency: :quorum)
    @conn.exec("DROP TABLE IF EXISTS #{TABLE}")
    @conn.exec("DROP TABLE IF EXISTS #{TABLE}_big")
  end

  def teardown
    return unless @conn

    @conn.exec("DROP TABLE IF EXISTS #{TABLE}")
    @conn.exec("DROP TABLE IF EXISTS #{TABLE}_big")
    @conn.close
  end

  def test_end_to_end
    conn = @conn
    assert conn.usable?

    # CREATE TABLE (DDL cannot be prepared: goes over OP_QUERY)
    ddl = conn.exec("CREATE TABLE #{TABLE} (PRIMARY KEY (id))")
    assert_equal 0, ddl.cmd_tuples

    # prepared INSERT with every type
    uuid = Skaidb::Uuid.new("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    ts = Time.utc(2024, 2, 29, 12, 34, 56, 789_000)
    row = [1, "O'Brien", 2.5, true, nil, [1, "two", 3.0], { "city" => "London", "tags" => %w[a b] },
           BigDecimal("123.45"), uuid, ts, "\x00\x01\xfe\xff".b]
    res = conn.exec_params(
      "INSERT INTO #{TABLE} (id, s, f, b, n, arr, doc, dec, u, ts, bin) " \
      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)", row
    )
    assert_equal 1, res.cmd_tuples
    conn.exec_params(
      "INSERT INTO #{TABLE} (id, s, f, b, n, arr, doc, dec, u, ts, bin) " \
      "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
      [2, "second", -0.25, false, nil, [], {}, BigDecimal("-0.005"), Skaidb::Uuid.random, Time.at(0).utc, "".b]
    )

    # SELECT with a bound WHERE and ORDER BY, reading every type back
    res = conn.exec_params(
      "SELECT id, s, f, b, n, arr, doc, dec, u, ts, bin FROM #{TABLE} WHERE id >= $1 ORDER BY id", [1]
    )
    assert_equal %w[id s f b n arr doc dec u ts bin], res.fields
    assert_equal 2, res.ntuples
    r = res[0]
    assert_equal 1, r["id"]
    assert_equal "O'Brien", r["s"]
    assert_equal 2.5, r["f"]
    assert_equal true, r["b"]
    assert_nil r["n"]
    assert_equal [1, "two", 3.0], r["arr"]
    assert_equal({ "city" => "London", "tags" => %w[a b] }, r["doc"])
    assert_kind_of BigDecimal, r["dec"]
    assert_equal BigDecimal("123.45"), r["dec"]
    assert_equal "6ba7b810-9dad-11d1-80b4-00c04fd430c8", r["u"]
    assert_equal uuid, r["u"]
    assert_kind_of Time, r["ts"]
    assert_equal ts, r["ts"]
    assert_equal "\x00\x01\xfe\xff".b, r["bin"]
    assert_equal Encoding::BINARY, r["bin"].encoding
    assert_equal [2, "second", false], res.rows[1][0..1] + [res.rows[1][3]]
    assert_equal BigDecimal("-0.005"), res[1]["dec"]

    # UPDATE row count
    up = conn.exec_params("UPDATE #{TABLE} SET s = $1 WHERE id = $2", ["updated", 1])
    assert_equal 1, up.cmd_tuples
    assert_equal "updated", conn.exec_params("SELECT s FROM #{TABLE} WHERE id = $1", [1])[0]["s"]

    # batch insert in one round-trip
    n = conn.exec_batch("INSERT INTO #{TABLE} (id, s) VALUES ($1, $2)", (10..19).map { |i| [i, "b#{i}"] })
    assert_equal 10, n
    assert_equal 12, conn.exec("SELECT id FROM #{TABLE}").ntuples

    # a streamed large result
    conn.exec("CREATE TABLE #{TABLE}_big (PRIMARY KEY (id))")
    rows = (1..2500).map { |i| [i, "pad-#{i}" * 4] }
    inserted = rows.each_slice(500).sum { |chunk| conn.exec_batch("INSERT INTO #{TABLE}_big (id, pad) VALUES ($1, $2)", chunk) }
    assert_equal 2500, inserted
    seen = 0
    last = 0
    conn.stream("SELECT id, pad FROM #{TABLE}_big ORDER BY id") do |r2|
      seen += 1
      assert_equal last + 1, r2["id"]
      last = r2["id"]
      assert_equal "pad-#{last}" * 4, r2["pad"]
    end
    assert_equal 2500, seen
    assert conn.usable?
    # abandoning a stream early drains it and leaves the connection usable
    first = conn.stream("SELECT id FROM #{TABLE}_big ORDER BY id").first(3)
    assert_equal [1, 2, 3], first.map { |r3| r3["id"] }
    assert conn.usable?
    # a stream with bound parameters (server >= 0.330), typed as exec_params binds them
    begin
      bound = []
      conn.stream("SELECT id, pad FROM #{TABLE}_big WHERE id > $1 AND id <= $2 AND pad = $3 ORDER BY id",
                  [2490, 2495, "pad-2493" * 4]) { |r4| bound << r4["id"] }
      assert_equal [2493], bound
      first_two = conn.stream("SELECT id FROM #{TABLE}_big WHERE id > $1 ORDER BY id", [2490]).first(2)
      assert_equal [2491, 2492], first_two.map { |r5| r5["id"] }
    rescue Skaidb::QueryError => e
      raise unless e.message.include?("does not support parameterised streaming")

      warn "server predates parameterised streaming, skipped: #{e.message}"
    end
    assert conn.usable?
    assert_equal 2500, conn.exec("SELECT count(*) AS c FROM #{TABLE}_big")[0]["c"]

    # an error surfaces as QueryError and keeps the connection usable
    err = assert_raises(Skaidb::QueryError) { conn.exec("SELECT nope FROM #{TABLE}_does_not_exist") }
    assert_match(/does not exist/, err.message)
    assert conn.usable?
    assert_equal 1, conn.exec("SELECT 1 AS one")[0]["one"]

    # the drivers table shows this driver's name and package version
    sleep 1
    drivers = conn.exec("SELECT client_name, client_version FROM drivers").to_a
    assert_includes drivers, { "client_name" => "ruby", "client_version" => Skaidb::VERSION }
    warn "drivers table: #{drivers.inspect}"
  end

  # Transactions and session state: the helper, a transaction written by
  # hand, a conflict run again, a session setting, and a pool that hands
  # each borrower its own session state. Needs a server that takes a plain
  # BEGIN (a standalone one, >= 0.346 for the conflict).
  def test_transactions_and_session_state
    conn = @conn
    conn.exec("CREATE TABLE #{TABLE} (PRIMARY KEY (id))")
    ids = -> { conn.exec("SELECT id FROM #{TABLE} ORDER BY id").rows.flatten }
    begin
      conn.exec("BEGIN")
    rescue Skaidb::QueryError => e
      skip "this server takes no plain BEGIN: #{e.message}"
    end
    # written by hand: rolled back, then committed
    conn.exec_params("INSERT INTO #{TABLE} (id, n) VALUES ($1, $2)", [1, 0])
    conn.exec("ROLLBACK")
    assert_empty ids.call
    conn.exec("BEGIN")
    conn.exec_params("INSERT INTO #{TABLE} (id, n) VALUES ($1, $2)", [1, 0])
    conn.exec("COMMIT")
    assert_equal [1], ids.call

    # the helper: the block's value on COMMIT, a ROLLBACK when the block raises
    value = conn.transaction do |tx|
      tx.exec_params("INSERT INTO #{TABLE} (id, n) VALUES ($1, $2)", [2, 0])
      :committed
    end
    assert_equal :committed, value
    assert_raises(RuntimeError) do
      conn.transaction do |tx|
        tx.exec_params("INSERT INTO #{TABLE} (id, n) VALUES ($1, $2)", [3, 0])
        raise "boom"
      end
    end
    assert_equal [1, 2], ids.call
    assert conn.usable?

    # a COMMIT refused as a conflict is run again from BEGIN
    other = Skaidb.connect(host: HOST, port: PORT, user: USER, password: PASSWORD, database: DATABASE)
    runs = 0
    conn.transaction do |tx|
      runs += 1
      tx.exec_params("UPDATE #{TABLE} SET n = $1 WHERE id = $2", [runs * 10, 1])
      # another writer changes the row the transaction writes — the first time only
      other.exec_params("UPDATE #{TABLE} SET n = $1 WHERE id = $2", [5, 1]) if runs == 1
    end
    assert_equal 2, runs
    assert_equal 20, conn.exec_params("SELECT n FROM #{TABLE} WHERE id = $1", [1])[0]["n"]
    e = assert_raises(Skaidb::TransactionConflict) do
      conn.transaction(attempts: 1) do |tx|
        tx.exec_params("UPDATE #{TABLE} SET n = $1 WHERE id = $2", [30, 1])
        other.exec_params("UPDATE #{TABLE} SET n = $1 WHERE id = $2", [6, 1])
      end
    end
    assert e.message.start_with?(Skaidb::TransactionConflict::PREFIX)
    assert conn.usable?
    other.close

    # a session setting: a scan budget refuses a scan, DEFAULT clears it
    conn.exec("SET SCAN BUDGET ROWS 1")
    e = assert_raises(Skaidb::QueryError) { conn.exec("SELECT * FROM #{TABLE}") }
    assert_match(/scan budget exceeded/, e.message)
    conn.exec("SET SCAN BUDGET DEFAULT")
    assert_equal 2, conn.exec("SELECT * FROM #{TABLE}").ntuples

    # a pool of one connection: the second borrower does not get the first
    # one's scan budget, nor a transaction it left open
    pool = Skaidb::Pool.new(host: HOST, port: PORT, user: USER, password: PASSWORD, database: DATABASE, maxsize: 1)
    begin
      pool.with do |c|
        c.exec("SET SCAN BUDGET ROWS 1")
        c.exec("BEGIN")
        c.exec_params("INSERT INTO #{TABLE} (id, n) VALUES ($1, $2)", [9, 0])
      end
      pool.with do |c|
        assert_equal [1, 2], c.exec("SELECT id FROM #{TABLE} ORDER BY id").rows.flatten
        c.exec_params("INSERT INTO #{TABLE} (id, n) VALUES ($1, $2)", [4, 0])
      end
      assert_equal [1, 2, 4], ids.call # committed on its own, outside any transaction
    ensure
      pool.close
    end
  end
end
