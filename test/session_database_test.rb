# frozen_string_literal: true

# The session database across a re-dial: a connection that entered a
# database — with the database: option or with a USE statement — is put
# back in it on the new socket before anything else is sent, and a pool
# does not hand one borrower's USE to the next. Asserted by the statements
# the fake server received.
require "test_helper"

class SessionDatabaseTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  COUNT = "SELECT count(*) FROM notes"
  INSERT = "INSERT INTO notes (id) VALUES (1)"

  # Every USE acknowledged, the two statements answered; +overrides+ replace
  # or add statements.
  def handler(overrides = {})
    answers = { COUNT => F.rows(["count"], [[3]]), INSERT => F.mutation(1) }.merge(overrides)
    lambda do |req, _conn|
      next nil if req.op == 8
      next F.error("cannot prepare this statement") if req.op == 2

      a = answers[req.sql]
      a = a.call(req) if a.respond_to?(:call)
      a || (req.sql =~ /\A\s*(--[^\n]*\n\s*)*USE\b/i ? F.ddl : F.error("fake server: unknown statement #{req.sql}"))
    end
  end

  # The statements received since +mark+ (Hello left out).
  def since(srv, mark)
    srv.requests.drop(mark).reject { |q| q.op == 8 || q.op == 2 }.map(&:sql)
  end

  # Loses the idle connection, then runs the two statements: the first one
  # finds the connection gone and re-dials, and both run on the new one.
  def lose_and_run(srv, conn)
    restart(srv, conn)
    mark = srv.requests.length
    count = conn.exec(COUNT)[0]["count"]
    conn.exec(INSERT)
    [count, since(srv, mark)]
  end

  def test_the_database_option_is_re_entered_on_a_re_dial
    with_server do |srv|
      srv.handler = handler
      c = connect(srv, database: "app")
      count, sent = lose_and_run(srv, c)
      assert_equal 3, count
      assert_equal [%(USE "app"), COUNT, INSERT], sent
      c.close
    end
  end

  def test_a_use_statement_is_re_entered_on_a_re_dial_before_anything_else_is_sent
    forms = {
      "USE app" => "USE app",
      "use app;" => "USE app",
      "  USE DATABASE app  " => "USE app",
      %(USE "app") => %(USE "app"),
      %(USE DATABASE "we""ird name" ;) => %(USE "we""ird name"),
      "USE database" => "USE database", # a database called database
      "USE café_2" => "USE café_2",
      # the server skips -- comments, each to the end of its line; what is
      # sent again on a re-dial is the USE alone
      "USE app -- the app database" => "USE app",
      "USE app; -- then the reports" => "USE app",
      "USE app --" => "USE app",
      "-- to the archive\nUSE archive" => "USE archive",
      "USE DATABASE app -- one\n-- two\n;" => "USE app",
      %(USE "a--b") => %(USE "a--b"), # dashes inside a quoted name are the name
      %(USE "a--b" -- 'quoted' "words" in the comment) => %(USE "a--b")
    }
    senders = {
      "exec" => ->(c, sql) { c.exec(sql) },
      "query" => ->(c, sql) { c.query(sql) },
      "exec_params" => ->(c, sql) { c.exec_params(sql) },
      "stream" => ->(c, sql) { c.stream(sql) { |_row| flunk "no rows expected" } }
    }
    with_server do |srv|
      srv.handler = handler
      forms.each do |sent_by_the_caller, re_entered_with|
        senders.each do |how, send|
          what = "#{sent_by_the_caller.inspect} sent with #{how}"
          c = connect(srv)
          send.call(c, sent_by_the_caller)
          count, sent = lose_and_run(srv, c)
          assert_equal 3, count, what
          # on the new socket: the database first, then the statements
          assert_equal [re_entered_with, COUNT, INSERT], sent, what
          c.close
        end
      end
    end
  end

  def test_the_last_database_entered_wins_over_the_option_and_over_earlier_uses
    with_server do |srv|
      srv.handler = handler
      c = connect(srv, database: "app")
      c.exec("USE other")
      c.exec("USE third")
      _count, sent = lose_and_run(srv, c)
      assert_equal ["USE third", COUNT, INSERT], sent
      c.close
    end
  end

  def test_what_is_not_one_use_statement_the_server_accepted_is_left_alone
    with_server do |srv|
      srv.handler = handler(
        "USE nope" => F.error("database nope does not exist"), # refused: nothing was entered
        "USERS" => F.ddl, "SELECT 'USE x'" => F.rows(["c"], [["USE x"]]),
        "USE a; USE b" => F.ddl,
        # a comment is not a statement, and what follows USE here is one
        "-- USE archive" => F.ddl, "USE -- archive" => F.ddl, "SELECT '--' -- \nUSE archive" => F.ddl
      )
      c = connect(srv)
      c.exec("USE app")
      assert_raises(Skaidb::QueryError) { c.exec("USE nope") }
      ["USERS", "SELECT 'USE x'", "USE a; USE b", "-- USE archive", "USE -- archive",
       "SELECT '--' -- \nUSE archive"].each { |sql| c.exec(sql) }
      _count, sent = lose_and_run(srv, c)
      assert_equal ["USE app", COUNT, INSERT], sent
      c.close
    end
  end

  def test_a_database_that_cannot_be_re_entered_fails_the_statement_instead_of_running_it_elsewhere
    with_server do |srv|
      uses = 0
      # the database is gone when the connection comes back, then restored
      refused_twice = ->(_req) { (uses += 1).between?(2, 3) ? F.error("database app does not exist") : F.ddl }
      srv.handler = handler("USE app" => refused_twice)
      c = connect(srv)
      c.exec("USE app")
      restart(srv, c)
      mark = srv.requests.length
      2.times do
        e = assert_raises(Skaidb::QueryError) { c.exec(INSERT) }
        assert_equal "database app does not exist", e.message
        refute c.usable?
      end
      # neither attempt sent the INSERT to a session in another database
      assert_equal ["USE app", "USE app"], since(srv, mark)
      assert_equal 1, c.exec(INSERT).cmd_tuples
      assert_equal ["USE app", "USE app", "USE app", INSERT], since(srv, mark)
      assert_equal 4, srv.connections
      c.close
    end
  end

  # ---- a USE is not held hostage by the database it leaves -----------------
  #
  # The session's database is dropped, and the connection is lost. Every
  # statement then fails at the re-dial's USE — rightly: it must not run
  # elsewhere. A USE of another database is the way out, and must not fail
  # there too.

  GONE = %(database "app" does not exist)
  ALL = "SET CONSISTENCY ALL"
  BUDGET = "SET SCAN BUDGET ROWS 1"

  # What arrived on connection +number+ (Hello and prepares left out).
  def arrived(srv, number)
    srv.requests.select { |q| q.conn == number && ![8, 2].include?(q.op) }.map(&:sql)
  end

  # USE app is accepted once — then the database is dropped.
  def app_is_dropped(overrides = {})
    uses = 0
    handler({ "USE app" => ->(_req) { (uses += 1) == 1 ? F.ddl : F.error(GONE) }, ALL => F.ddl, BUDGET => F.ddl }
              .merge(overrides))
  end

  def test_a_use_is_sent_to_a_new_session_without_the_database_it_leaves_being_entered_first
    senders = {
      "exec" => ->(c, sql) { c.exec(sql) },
      "query" => ->(c, sql) { c.query(sql) },
      "exec_params" => ->(c, sql) { c.exec_params(sql) },
      "stream" => ->(c, sql) { c.stream(sql) { |_row| flunk "no rows expected" } }
    }
    senders.each do |how, send|
      with_server do |srv|
        srv.handler = app_is_dropped
        c = connect(srv)
        c.exec("USE app")
        c.exec(ALL)
        c.exec(BUDGET)
        restart(srv, c) # app was dropped from another connection; this one is lost
        # a statement fails with the USE's error — it must not run in another database
        2.times do
          e = assert_raises(Skaidb::QueryError, how) { c.exec(COUNT) }
          assert_equal GONE, e.message, how
        end
        assert_equal [["USE app"], ["USE app"]], [arrived(srv, 2), arrived(srv, 3)], how
        # the way out: a USE goes to a new session with the settings put
        # back — and without the database that is gone entered first
        send.call(c, "USE other -- the one that is left")
        assert_equal [ALL, BUDGET, "USE other -- the one that is left"], arrived(srv, 4), how
        assert c.usable?, how
        # its answer decides the session database as usual: the statement
        # after it runs there, and a later re-dial enters it
        assert_equal 3, c.exec(COUNT)[0]["count"], how
        assert_equal COUNT, arrived(srv, 4).last, how
        restart(srv, c)
        c.exec(INSERT)
        assert_equal ["USE other", ALL, BUDGET, INSERT], arrived(srv, 5), how
        c.close
      end
    end
  end

  def test_a_use_the_new_session_refuses_does_not_leave_the_connection_in_another_database
    with_server do |srv|
      srv.handler = app_is_dropped("USE nowhere" => F.error(%(database "nowhere" does not exist)))
      c = connect(srv)
      c.exec("USE app")
      restart(srv, c)
      # the USE reached a new session — which is in the default database —
      # and was refused there: that session is in no database the driver
      # knows the application chose
      e = assert_raises(Skaidb::QueryError) { c.exec("USE nowhere") }
      assert_equal %(database "nowhere" does not exist), e.message
      assert_equal ["USE nowhere"], arrived(srv, 2)
      refute c.usable?
      assert_hung_up srv, 1
      # so the statement after it does not run there: it fails as before
      e = assert_raises(Skaidb::QueryError) { c.exec(INSERT) }
      assert_equal GONE, e.message
      assert_equal ["USE app"], arrived(srv, 3)
      # and a USE that is accepted still gets the connection out
      c.exec("USE other")
      assert_equal 1, c.exec(INSERT).cmd_tuples
      assert_equal ["USE other", INSERT], arrived(srv, 4)
      c.close
    end
  end

  def test_a_use_cut_short_between_its_re_dial_and_its_request_leaves_no_session_in_the_wrong_database
    interrupt = Class.new(Exception) # rubocop:disable Lint/InheritException
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      c.exec("USE app")
      restart(srv, c)
      # the re-dial for the USE is done — the database it leaves not entered —
      # and the exception lands before the USE is written
      trace = TracePoint.new(:return) do |tp|
        next unless tp.method_id == :ensure_live! && tp.self.equal?(c)

        trace.disable
        raise interrupt
      end
      assert_raises(interrupt) { trace.enable { c.exec("USE other") } }
      assert_equal 2, srv.connections
      # that socket's session is in the default database, and nothing was
      # sent on it. Nothing but a USE ever is: the next statement dials
      # again, into the database the session is in
      c.exec(INSERT)
      assert_equal [], arrived(srv, 2)
      assert_equal ["USE app", INSERT], arrived(srv, 3)
      c.close
    end
  end

  def test_a_use_on_a_connection_that_is_alive_is_simply_sent
    with_server do |srv|
      srv.handler = handler
      c = connect(srv, database: "app")
      c.exec("USE other")
      c.exec(INSERT)
      assert_equal [%(USE "app"), "USE other", INSERT], arrived(srv, 1)
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_a_pooled_connection_gets_out_of_a_dropped_database_the_same_way
    with_server do |srv|
      srv.handler = handler(%(USE "app") => in_turn(F.ddl, F.error(GONE)))
      pool = pool_for(srv, database: "app")
      pool.with do |c|
        restart(srv, c)
        assert_equal GONE, assert_raises(Skaidb::QueryError) { c.exec(COUNT) }.message
        c.exec("USE other")
        assert_equal 3, c.exec(COUNT)[0]["count"]
        assert_equal ["USE other", COUNT], arrived(srv, 3)
      end
      pool.close
    end
  end

  # Answers a statement with each payload in turn, the last one from then on.
  def in_turn(*payloads)
    ->(_req) { payloads.length > 1 ? payloads.shift : payloads[0] }
  end

  # ---- the pool ------------------------------------------------------------

  def pool_for(srv, **kw)
    Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret", maxsize: 1, **kw)
  end

  def test_a_pooled_connection_that_re_dials_re_enters_its_database
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv, database: "app")
      pool.with { |c| c.exec(COUNT) }
      pool.with do |c|
        _count, sent = lose_and_run(srv, c)
        assert_equal [%(USE "app"), COUNT, INSERT], sent
        c.exec("USE other") # and one a borrower entered, for as long as it holds the connection
        _count, sent = lose_and_run(srv, c)
        assert_equal ["USE other", COUNT, INSERT], sent
      end
      pool.close
    end
  end

  def test_a_borrowers_use_does_not_reach_the_next_borrower_of_a_pool_with_a_database
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv, database: "app")
      first = nil
      pool.with do |c|
        first = c
        c.exec("USE other")
        c.exec(INSERT)
      end
      mark = srv.requests.length
      pool.with do |c|
        assert_same first, c # the same connection, handed out again
        c.exec(COUNT)
      end
      # put back in the pool's database before the borrower's first statement
      assert_equal [%(USE "app"), COUNT], since(srv, mark)
      mark = srv.requests.length
      pool.with { |c| c.exec(COUNT) } # nothing to put back: no extra round trip
      assert_equal [COUNT], since(srv, mark)
      assert_equal 1, srv.connections
      pool.close
    end
  end

  def test_a_connection_that_cannot_be_put_back_in_the_pools_database_is_not_handed_out
    with_server do |srv|
      uses = 0
      srv.handler = handler(%(USE "app") => ->(_req) { (uses += 1) == 2 ? F.error("database app is busy") : F.ddl })
      pool = pool_for(srv, database: "app")
      first = nil
      pool.with do |c|
        first = c
        c.exec("USE other")
      end
      pool.with do |c|
        refute_same first, c
        assert_equal 3, c.exec(COUNT)[0]["count"]
      end
      assert first.finished?
      assert_equal 2, srv.connections
      pool.close
    end
  end
end
