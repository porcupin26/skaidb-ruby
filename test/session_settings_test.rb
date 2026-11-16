# frozen_string_literal: true

# Session settings across a re-dial. SET CONSISTENCY and SET SCAN BUDGET
# are state of the server's session, like the database: a new connection
# starts without them. The driver notes the last one of each kind the
# server accepted and sends it again on every dial — after the database,
# before the statement — so a statement never runs under other settings
# than the application set. Asserted by the statements the fake server
# received.
require "test_helper"

class SessionSettingsTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  SCAN = "SELECT * FROM notes"
  INSERT = "INSERT INTO notes (id) VALUES (1)"
  BUDGET = "SET SCAN BUDGET ROWS 1"
  ALL = "SET CONSISTENCY ALL"

  # USE and SET acknowledged, the two statements answered; +overrides+
  # replace or add statements.
  def handler(overrides = {})
    answers = { SCAN => F.rows(["id"], [[1], [2]]), INSERT => F.mutation(1) }.merge(overrides)
    lambda do |req, _conn|
      next nil if req.op == 8
      next F.error("cannot prepare this statement") if req.op == 2

      a = answers[req.sql]
      a = a.call(req) if a.respond_to?(:call)
      a || (req.sql =~ /\A\s*(--[^\n]*\n\s*)*(USE|SET)\b/i ? F.ddl : F.error("fake server: unknown statement #{req.sql}"))
    end
  end

  # What arrived on connection +number+ (Hello and prepares left out).
  def arrived(srv, number)
    srv.requests.select { |q| q.conn == number && ![8, 2].include?(q.op) }.map(&:sql)
  end

  def test_settings_are_sent_again_on_a_re_dial_after_the_database_and_before_the_statement
    with_server do |srv|
      srv.handler = handler
      c = connect(srv, database: "app")
      c.exec(BUDGET)
      c.exec(ALL)
      restart(srv, c)
      assert_equal [[1], [2]], c.exec(SCAN).rows
      c.exec(INSERT)
      # the database, the consistency, the scan budget — then the statement
      assert_equal [%(USE "app"), ALL, BUDGET, SCAN, INSERT], arrived(srv, 2)
      # and again on the next one, also when the loss is met under a statement
      srv.handler = handler(SCAN => :close)
      assert_raises(Skaidb::ConnectionError) { c.exec(SCAN) }
      c.exec(INSERT)
      assert_equal [%(USE "app"), ALL, BUDGET, INSERT], arrived(srv, 3)
      c.close
    end
  end

  def test_only_what_was_set_is_sent
    with_server do |srv|
      srv.handler = handler
      one = connect(srv)
      one.exec(BUDGET)
      two = connect(srv)
      two.exec(ALL)
      three = connect(srv)
      restart(srv, one, two, three)
      [one, two, three].each { |c| c.exec(INSERT) }
      assert_equal [BUDGET, INSERT], arrived(srv, 4)
      assert_equal [ALL, INSERT], arrived(srv, 5)
      assert_equal [INSERT], arrived(srv, 6)
      [one, two, three].each(&:close)
    end
  end

  def test_a_setting_cleared_with_default_is_not_sent_again
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      c.exec(BUDGET)
      c.exec(ALL)
      c.exec("SET SCAN BUDGET DEFAULT")
      restart(srv, c)
      c.exec(INSERT)
      assert_equal [ALL, INSERT], arrived(srv, 2)
      c.exec("set consistency default ;")
      c.exec("SET SCAN BUDGET BYTES 4096 ROWS 2")
      restart(srv, c)
      c.exec(INSERT)
      assert_equal ["SET SCAN BUDGET BYTES 4096 ROWS 2", INSERT], arrived(srv, 3)
      c.exec("SET SCAN BUDGET default -- back to the node's")
      restart(srv, c)
      c.exec(INSERT)
      assert_equal [INSERT], arrived(srv, 4)
      c.close
    end
  end

  def test_the_last_setting_the_server_accepted_wins_one_note_per_kind
    with_server do |srv|
      srv.handler = handler("SET CONSISTENCY EVENTUAL" => F.error("parse error: SET CONSISTENCY takes ONE, QUORUM, ALL, or DEFAULT"),
                            "SET SCAN BUDGET ROWS 0" => F.error("parse error: a positive integer"))
      c = connect(srv)
      c.exec("SET CONSISTENCY ONE")
      c.exec("SET SCAN BUDGET ROWS 100")
      c.exec("SET CONSISTENCY QUORUM")
      c.exec("SET SCAN BUDGET ROWS 5 BYTES 1000")
      # refused: nothing was set, so nothing replaces the note
      assert_raises(Skaidb::QueryError) { c.exec("SET CONSISTENCY EVENTUAL") }
      assert_raises(Skaidb::QueryError) { c.exec("SET SCAN BUDGET ROWS 0") }
      restart(srv, c)
      c.exec(INSERT)
      assert_equal ["SET CONSISTENCY QUORUM", "SET SCAN BUDGET ROWS 5 BYTES 1000", INSERT], arrived(srv, 2)
      c.close
    end
  end

  def test_every_spelling_the_server_accepts_is_noted_and_sent_again_without_its_comments
    forms = {
      "SET CONSISTENCY ALL" => "SET CONSISTENCY ALL",
      "set consistency all;" => "set consistency all",
      "  Set   Consistency  One  ;  " => "Set   Consistency  One",
      "SET CONSISTENCY ALL -- every replica" => "SET CONSISTENCY ALL",
      "-- strict reads\nSET CONSISTENCY ALL" => "SET CONSISTENCY ALL",
      "SET SCAN BUDGET ROWS 1" => "SET SCAN BUDGET ROWS 1",
      "set scan budget rows 10 bytes 2000 ;" => "set scan budget rows 10 bytes 2000",
      "SET SCAN BUDGET BYTES 2000 ROWS 10" => "SET SCAN BUDGET BYTES 2000 ROWS 10",
      "SET SCAN BUDGET ROWS 1 -- small\n-- on purpose\n;" => "SET SCAN BUDGET ROWS 1"
    }
    senders = {
      "exec" => ->(c, sql) { c.exec(sql) },
      "query" => ->(c, sql) { c.query(sql) },
      "exec_params" => ->(c, sql) { c.exec_params(sql) },
      "stream" => ->(c, sql) { c.stream(sql) { |_row| flunk "no rows expected" } }
    }
    with_server do |srv|
      srv.handler = handler
      forms.each do |sent_by_the_caller, sent_again|
        senders.each do |how, send|
          what = "#{sent_by_the_caller.inspect} sent with #{how}"
          c = connect(srv)
          send.call(c, sent_by_the_caller)
          restart(srv, c)
          mark = srv.requests.length
          c.exec(INSERT)
          assert_equal [sent_again, INSERT], srv.requests.drop(mark).reject { |q| q.op == 8 }.map(&:sql), what
          c.close
        end
      end
    end
  end

  def test_what_is_not_one_such_statement_is_left_alone
    with_server do |srv|
      not_one = ["SET CONSISTENCY ALL; SET SCAN BUDGET ROWS 1", "-- SET CONSISTENCY ALL", "SELECT 'SET CONSISTENCY ALL'",
                 "SET CONSISTENCYX ALL", "SET SCAN BUDGETS ROWS 1", "SET SCAN ROWS 1", "SET CONFIG storage.x = 1",
                 "SET -- CONSISTENCY ALL"]
      srv.handler = handler(not_one.to_h { |sql| [sql, F.ddl] })
      c = connect(srv)
      not_one.each { |sql| c.exec(sql) }
      restart(srv, c)
      c.exec(INSERT)
      assert_equal [INSERT], arrived(srv, 2)
      c.close
    end
  end

  def test_a_setting_the_new_session_refuses_fails_the_statement_instead_of_running_it_without
    with_server do |srv|
      budgets = 0
      # the limit cannot be set when the connection comes back, twice; then it can
      refused_twice = ->(_req) { (budgets += 1).between?(2, 3) ? F.error("scan budget: not now") : F.ddl }
      srv.handler = handler(BUDGET => refused_twice)
      c = connect(srv)
      c.exec(ALL)
      c.exec(BUDGET)
      restart(srv, c)
      2.times do
        e = assert_raises(Skaidb::QueryError) { c.exec(SCAN) }
        assert_equal "scan budget: not now", e.message
        refute c.usable?
      end
      # neither attempt sent the scan to a session without the limit
      assert_equal [ALL, BUDGET], arrived(srv, 2)
      assert_equal [ALL, BUDGET], arrived(srv, 3)
      assert_equal [[1], [2]], c.exec(SCAN).rows
      assert_equal [ALL, BUDGET, SCAN], arrived(srv, 4)
      c.close
    end
  end

  def test_a_setting_cut_short_after_its_reply_is_not_left_on_a_session_the_driver_cannot_restore
    interrupt = Class.new(Exception) # rubocop:disable Lint/InheritException
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      c.exec("SET SCAN BUDGET ROWS 100")
      # the server took the new limit; the exception lands before the driver noted it
      assert_raises(interrupt) { cut_after_the_reply(c, interrupt) { c.exec(BUDGET) } }
      # the session and the note would disagree: the session goes, and the
      # next statement runs under what the driver knows was set
      refute c.usable?
      c.exec(INSERT)
      assert_equal ["SET SCAN BUDGET ROWS 100", INSERT], arrived(srv, 2)
      c.close
    end
  end

  def test_the_request_consistency_is_the_connections_own_and_is_sent_with_every_request
    with_server do |srv|
      srv.handler = handler("SELECT level" => ->(req) { F.rows(["c"], [[req.consistency]]) })
      c = connect(srv, consistency: :one)
      c.consistency = :all
      restart(srv, c)
      assert_equal 2, c.exec("SELECT level")[0]["c"]
      assert_equal ["SELECT level"], arrived(srv, 2) # no statement is needed to restore it
      c.close
    end
  end

  # ---- the pool ------------------------------------------------------------

  def test_a_pooled_connection_re_dialled_under_its_borrower_gets_the_borrowers_settings_back
    with_server do |srv|
      srv.handler = handler
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret", database: "app")
      pool.with do |c|
        c.exec(BUDGET)
        c.exec(ALL)
        restart(srv, c)
        assert_equal [[1], [2]], c.exec(SCAN).rows
        assert_equal [%(USE "app"), ALL, BUDGET, SCAN], arrived(srv, 2)
      end
      pool.close
    end
  end
end
