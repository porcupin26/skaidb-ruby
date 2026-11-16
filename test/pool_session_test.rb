# frozen_string_literal: true

# A pooled connection reaches each borrower in the pool's own session state:
# in the pool's database (its database: option, or `default`, where every
# new connection starts), with no transaction open and with no consistency
# override or scan budget of an earlier borrower. What a borrower changed,
# the pool puts back when the connection is returned — only that, so a
# borrower that changed nothing costs no round trip — and a connection it
# cannot put back is closed. Asserted by the statements the fake server
# received.
require "test_helper"

class PoolSessionTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  COUNT = "SELECT count(*) FROM notes"
  INSERT = "INSERT INTO notes (id) VALUES (1)"
  BUDGET = "SET SCAN BUDGET ROWS 1"
  ALL = "SET CONSISTENCY ALL"
  BACK = ["SET SCAN BUDGET DEFAULT", "SET CONSISTENCY DEFAULT"].freeze

  # USE, SET, BEGIN, COMMIT and ROLLBACK acknowledged, the two statements
  # answered; +overrides+ replace or add statements.
  def handler(overrides = {})
    answers = { COUNT => F.rows(["count"], [[3]]), INSERT => F.mutation(1) }.merge(overrides)
    lambda do |req, _conn|
      next nil if req.op == 8
      next F.error("cannot prepare this statement") if req.op == 2

      a = answers[req.sql]
      a = a.call(req) if a.respond_to?(:call)
      next a if a

      req.sql =~ /\A(USE|SET|BEGIN|COMMIT|ROLLBACK)\b/i ? F.ddl : F.error("fake server: unknown statement #{req.sql}")
    end
  end

  # What arrived on connection +number+ (Hello and prepares left out).
  def arrived(srv, number)
    srv.requests.select { |q| q.conn == number && ![8, 2].include?(q.op) }.map(&:sql)
  end

  # A pool of size 1: both borrowers get the same connection.
  def pool_for(srv, **kw)
    Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret", maxsize: 1, **kw)
  end

  # Borrower 1 moves the connection every way a session can be moved.
  def first_borrower(pool)
    pool.with do |c|
      c.exec("USE other")
      c.exec(BUDGET)
      c.exec(ALL)
      c
    end
  end

  def test_the_next_borrower_gets_the_pools_state_not_the_last_borrowers
    { nil => "USE default", "app" => %(USE "app") }.each do |database, home|
      what = database ? "a pool with database: #{database}" : "a pool without a database"
      with_server do |srv|
        srv.handler = handler
        pool = pool_for(srv, **(database ? { database: database } : {}))
        first = first_borrower(pool)
        opened = database ? [home] : []
        # put back when the connection came back: the database, then the
        # scan budget, then the consistency
        assert_equal opened + ["USE other", BUDGET, ALL, home, *BACK], arrived(srv, 1), what
        pool.with do |c|
          assert_same first, c, what # the same connection, handed out again
          assert_equal 3, c.exec(COUNT)[0]["count"], what
        end
        # ... so the second borrower's statement ran in the pool's
        # database, under no borrower's settings — and with nothing to put
        # back after it, at no round trip more
        assert_equal opened + ["USE other", BUDGET, ALL, home, *BACK, COUNT], arrived(srv, 1), what
        assert_equal 1, srv.connections, what
        pool.close
      end
    end
  end

  def test_only_what_a_borrower_changed_is_put_back
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv, database: "app")
      pool.with { |c| c.exec(COUNT) }
      assert_equal [%(USE "app"), COUNT], arrived(srv, 1) # nothing changed: nothing sent
      pool.with { |c| c.exec(BUDGET) }
      pool.with { |c| c.exec(ALL) }
      pool.with { |c| c.exec("USE other") }
      assert_equal [BUDGET, "SET SCAN BUDGET DEFAULT", ALL, "SET CONSISTENCY DEFAULT", "USE other", %(USE "app")],
                   arrived(srv, 1).drop(2)
      # a borrower that puts its own changes back leaves nothing to do
      mark = arrived(srv, 1).length
      pool.with do |c|
        c.exec(BUDGET)
        c.exec(ALL)
        c.exec("USE other")
        c.exec("SET SCAN BUDGET DEFAULT")
        c.exec("SET CONSISTENCY DEFAULT")
        c.exec(%(USE "app"))
      end
      assert_equal 6, arrived(srv, 1).length - mark
      assert_equal 1, srv.connections
      pool.close
    end
  end

  def test_a_connection_that_cannot_be_put_back_is_closed_and_the_next_borrower_gets_a_new_one
    refusals = {
      # an older server has no SET CONSISTENCY DEFAULT
      "SET CONSISTENCY DEFAULT" => F.error("parse error: SET CONSISTENCY takes ONE, QUORUM, or ALL"),
      "SET SCAN BUDGET DEFAULT" => F.error("not now"),
      "USE default" => F.error(%(database "default" is not available))
    }
    refusals.each do |statement, refusal|
      with_server do |srv|
        srv.handler = handler(statement => refusal)
        pool = pool_for(srv)
        first = first_borrower(pool)
        assert first.finished?, statement
        assert_equal statement, arrived(srv, 1).last, statement # nothing is sent after the refusal
        assert_equal [0, 0], pool.members[0].values_at(:in_use, :idle), statement
        pool.with do |c|
          refute_same first, c, statement
          assert_equal 3, c.exec(COUNT)[0]["count"], statement
        end
        assert_equal [COUNT], arrived(srv, 2), statement # a new session: in the pool's state as it is
        assert_equal 2, srv.connections, statement
        pool.close
      end
    end
  end

  def test_a_re_dial_under_the_next_borrower_restores_the_pools_state
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv, database: "app")
      first_borrower(pool)
      pool.with do |c|
        restart(srv, c)
        assert_equal 3, c.exec(COUNT)[0]["count"]
      end
      # the notes went with the borrower that made them
      assert_equal [%(USE "app"), COUNT], arrived(srv, 2)
      pool.close
    end
  end

  # ---- a transaction a borrower left open ----------------------------------

  def test_a_transaction_a_borrower_left_open_is_rolled_back_before_anything_else
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv)
      pool.with do |c|
        c.exec("BEGIN")
        c.exec(INSERT)
        c.exec("USE other")
      end
      assert_equal ["BEGIN", INSERT, "USE other", "ROLLBACK", "USE default"], arrived(srv, 1)
      pool.with { |c| c.exec(INSERT) } # in autocommit, not inside the first borrower's transaction
      assert_equal INSERT, arrived(srv, 1).last
      assert_equal 1, srv.connections
      pool.close
    end
  end

  def test_a_transaction_that_cannot_be_rolled_back_costs_the_connection
    with_server do |srv|
      srv.handler = handler("ROLLBACK" => F.error("rollback failed"))
      pool = pool_for(srv)
      first = pool.with { |c| c.exec("BEGIN") && c }
      assert first.finished?
      assert_equal %w[BEGIN ROLLBACK], arrived(srv, 1)
      pool.with { |c| c.exec(INSERT) }
      assert_equal [INSERT], arrived(srv, 2)
      pool.close
    end
  end

  def test_a_transaction_that_was_ended_costs_no_rollback
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv)
      pool.with { |c| c.exec("BEGIN") && c.exec(INSERT) && c.exec("COMMIT") }
      pool.transaction { |c| c.exec(INSERT) }
      assert_raises(RuntimeError) { pool.transaction { |_c| raise "boom" } }
      assert_equal ["BEGIN", INSERT, "COMMIT", "BEGIN", INSERT, "COMMIT", "BEGIN", "ROLLBACK"], arrived(srv, 1)
      assert_equal [0, 1], pool.members[0].values_at(:in_use, :idle)
      pool.close
    end
  end

  # ---- connections the pool does not keep ----------------------------------

  def test_a_connection_the_pool_will_not_keep_is_closed_without_a_word
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv) # keeps one idle connection
      a = pool.checkout
      b = pool.checkout
      [a, b].each { |c| c.exec(BUDGET) }
      pool.checkin(a)
      pool.checkin(b) # one too many: closed, with nothing to put back first
      assert_equal [BUDGET, "SET SCAN BUDGET DEFAULT"], arrived(srv, 1)
      assert_equal [BUDGET], arrived(srv, 2)
      assert b.finished?
      # and so is one returned to a pool that is closed
      c = pool.checkout
      c.exec(ALL)
      pool.close
      pool.checkin(c)
      assert c.finished?
      assert_equal [BUDGET, "SET SCAN BUDGET DEFAULT", ALL], arrived(srv, 1) # no SET CONSISTENCY DEFAULT after it
    end
  end

  def test_a_connection_lost_before_it_came_back_is_closed_and_nothing_is_written_to_it
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv)
      first = pool.with do |c|
        c.exec(BUDGET)
        srv.half_close_all # gone while the borrower held it; a write would still succeed
        let_the_loss_arrive(c)
        c
      end
      assert first.finished?
      assert_equal [BUDGET], arrived(srv, 1)
      assert_equal 1, srv.connections # and no new connection was dialled to put a dead one's state back
      pool.with { |c| c.exec(COUNT) }
      assert_equal [COUNT], arrived(srv, 2)
      pool.close
    end
  end
end
