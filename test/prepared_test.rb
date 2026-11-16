# frozen_string_literal: true

# The server's prepared-statement table (256 statements per connection,
# PROTOCOL.md §3.3): the driver's cache stays under it and closes what it
# evicts, a refused prepare is a statement error, and an id never runs a
# statement on a connection that did not issue it.
require "test_helper"

class PreparedStatementsTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F
  LIMIT = 256

  # The real server's table, per connection: LIMIT slots, a new statement
  # takes the lowest free id (so an id that was closed, or that another
  # connection issued, names something else), OP_CLOSE frees one. Statements
  # sent as text are recorded apart: that is the literal fallback.
  class Table
    attr_reader :executed, :texts, :prepares, :closed, :refusals, :high_water

    def initialize
      @slots = Hash.new { |h, sock| h[sock] = {} }
      @executed = []
      @texts = []
      @prepares = []
      @closed = []
      @refusals = 0
      @high_water = 0
    end

    def call(req, conn)
      slots = @slots[conn[:sock]]
      case req.op
      when 1
        @texts << req.sql
        F.mutation(1)
      when 2
        if slots.length >= LIMIT
          @refusals += 1
          return F.error("too many prepared statements (max #{LIMIT}); close some first")
        end
        id = (0...LIMIT).find { |i| !slots.key?(i) }
        slots[id] = req.sql
        @prepares << req.sql
        @high_water = [@high_water, slots.length].max
        F.prepared(id, req.sql.count("?"))
      when 3, 7
        sql = slots[req.id]
        return F.error("unknown prepared statement id #{req.id}") if sql.nil?

        @executed << [sql, req.op == 3 ? req.params : req.rows]
        F.mutation(req.op == 3 ? 1 : req.rows.length)
      when 4
        sql = slots.delete(req.id)
        return F.error("unknown prepared statement id #{req.id}") if sql.nil?

        @closed << sql
        F.ddl
      end
    end
  end

  def with_table
    with_server do |srv|
      table = Table.new
      srv.handler = table.method(:call)
      yield srv, table
    end
  end

  def insert(n)
    "INSERT INTO t (id, a#{n}, v, ts, bin) VALUES ($1, $2, $3, $4, $5)"
  end

  def as_sent(sql)
    sql.gsub(/\$\d+/, "?")
  end

  # ---- the table never fills -----------------------------------------------

  def test_300_distinct_statements_on_one_connection_are_all_bound_typed
    ts = Time.utc(2026, 11, 16, 1, 2, 3, 456_000)
    bin = "\x00\x01\xfe\xff".b
    with_table do |srv, table|
      c = connect(srv)
      300.times { |n| assert_equal 1, c.exec_params(insert(n), [n, n, [1, "two", { "k" => n }], ts, bin]).cmd_tuples }
      # every one ran prepared, its values typed — the array an array, the
      # timestamp a timestamp, the bytes bytes
      assert_equal 300, table.executed.length
      table.executed.each_with_index do |(sql, params), n|
        assert_equal as_sent(insert(n)), sql
        assert_equal [n, n, [1, "two", { "k" => n }], ts, bin], params
        assert_equal Encoding::BINARY, params[4].encoding
      end
      assert_empty table.texts # none was sent as text with literals
      assert_equal 0, table.refusals # the server never had to refuse one
      assert_operator table.high_water, :<, LIMIT
      # what left the cache was closed on the server, oldest first
      assert_equal (0...table.closed.length).map { |n| as_sent(insert(n)) }, table.closed
      assert_equal 300 - table.high_water, table.closed.length
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_exec_batch_shares_the_cache
    with_table do |srv, table|
      c = connect(srv)
      300.times { |n| assert_equal 2, c.exec_batch("INSERT INTO t (id, b#{n}) VALUES ($1, $2)", [[n, 1], [n, 2]]) }
      assert_equal 300, table.executed.length
      assert_equal [0, 0], [table.refusals, table.texts.length]
      assert_operator table.high_water, :<, LIMIT
      c.close
    end
  end

  def test_a_statement_that_keeps_being_used_is_not_the_one_evicted
    hot = "UPDATE t SET v = $1 WHERE id = $2"
    with_table do |srv, table|
      c = connect(srv)
      c.exec_params(hot, [0, 0])
      300.times do |n|
        c.exec_params(insert(n), [n, n, [], Time.at(0), "".b])
        c.exec_params(hot, [n, n]) if (n % 50).zero?
      end
      assert_equal 1, table.prepares.count(as_sent(hot)) # prepared once, never again
      refute_includes table.closed, as_sent(hot)
      assert_equal 0, table.refusals
      c.close
    end
  end

  def test_a_statement_the_application_holds_is_never_closed
    held = "UPDATE t SET v = ? WHERE id = ?"
    with_table do |srv, table|
      c = connect(srv)
      id, nparams = c.prepare_server(held)
      assert_equal 2, nparams
      300.times { |n| c.exec_params(insert(n), [n, n, [], Time.at(0), "".b]) }
      refute_includes table.closed, held
      # the id still names it on the server
      assert_equal 1, c.exec_prepared(id, [7, 1], 1).cmd_tuples
      assert_equal [held, [7, 1]], table.executed.last
      # and exec_params with the same text uses it, without a second prepare
      c.exec_params("UPDATE t SET v = $1 WHERE id = $2", [8, 1])
      assert_equal 1, table.prepares.count(held)
      assert_equal 0, table.refusals
      c.close
    end
  end

  def test_a_prepare_refused_because_the_table_is_full_is_a_statement_error
    with_table do |srv, table|
      c = connect(srv)
      # the application holds every slot itself
      LIMIT.times { |n| c.prepare_server("SELECT #{n} FROM t WHERE id = ?") }
      calls = {
        "exec_params" => -> { c.exec_params("INSERT INTO t (id, ts) VALUES ($1, $2)", [1, Time.at(0)]) },
        "exec_batch" => -> { c.exec_batch("INSERT INTO t (id, ts) VALUES ($1, $2)", [[1, Time.at(0)]]) },
        "prepare_server" => -> { c.prepare_server("SELECT x FROM t WHERE id = ?") }
      }
      calls.each do |name, call|
        e = assert_raises(Skaidb::QueryError, name) { call.call }
        assert_match(/\Atoo many prepared statements/, e.message, name)
      end
      # it was not sent as text with the timestamp as a number instead
      assert_empty table.texts
      assert c.usable?
      assert_equal 1, srv.connections
      c.close
    end
  end

  # ---- an id belongs to the connection that issued it ----------------------

  A = "UPDATE t SET v = ? WHERE id = ?"
  B = "DELETE FROM t WHERE v = ? AND id = ?" # the same parameter count, another effect

  def test_after_a_re_dial_each_cached_statement_runs_as_itself
    with_table do |srv, table|
      c = connect(srv)
      c.exec_params("UPDATE t SET v = $1 WHERE id = $2", [1, 1]) # A takes the first id
      c.exec_params("DELETE FROM t WHERE v = $1 AND id = $2", [2, 2])
      srv.close_all # lost while idle
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") }
      # on the new connection B comes first, and takes the id A had on the old one
      c.exec_params("DELETE FROM t WHERE v = $1 AND id = $2", [3, 3])
      c.exec_params("UPDATE t SET v = $1 WHERE id = $2", [4, 4])
      assert_equal [[A, [1, 1]], [B, [2, 2]], [B, [3, 3]], [A, [4, 4]]], table.executed
      assert_equal [A, B, B, A], table.prepares # each prepared again on the new connection
      c.close
    end
  end

  def test_an_id_from_before_a_re_dial_runs_its_own_statement_not_the_one_that_took_its_number
    with_table do |srv, table|
      c = connect(srv)
      a, = c.prepare_server(A)
      b, = c.prepare_server(B)
      srv.close_all # lost while idle
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") }
      c.exec_params("DELETE FROM t WHERE v = $1 AND id = $2", [3, 3]) # B first on the new connection
      # A, by the id obtained before the loss: prepared on the new connection first
      assert_equal 1, c.exec_prepared(a, [4, 4], 1).cmd_tuples
      assert_equal 1, c.exec_prepared(b, [5, 5], 1).cmd_tuples
      assert_equal [[B, [3, 3]], [A, [4, 4]], [B, [5, 5]]], table.executed
      assert_equal [A, B, B, A], table.prepares
      # and again after another loss, met by exec_prepared itself
      srv.close_all
      assert_raises(Skaidb::ConnectionError) { c.exec_prepared(b, [6, 6], 1) }
      assert_equal 1, c.exec_prepared(a, [7, 7], 1).cmd_tuples
      assert_equal [A, [7, 7]], table.executed.last
      assert_equal 3, srv.connections
      c.close
    end
  end

  def test_an_id_another_connection_issued_is_refused
    with_table do |srv, table|
      one = connect(srv)
      two = connect(srv)
      a, = one.prepare_server(A)
      two.prepare_server(B) # the same number on its own connection
      e = assert_raises(Skaidb::QueryError) { two.exec_prepared(a, [1, 1], 1) }
      assert_match(/not issued by this connection/, e.message)
      assert_empty table.executed
      assert two.usable?
      # a pool is the same: an id stays with the connection that prepared it
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
      pool.with { |conn| assert_raises(Skaidb::QueryError) { conn.exec_prepared(a, [1, 1], 1) } }
      assert_empty table.executed
      pool.close
      [one, two].each(&:close)
    end
  end
end
