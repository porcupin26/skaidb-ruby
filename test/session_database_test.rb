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

  # Loses the idle connection, then runs the two statements: the first call
  # meets the loss, the ones after it run on the re-dialled connection.
  def lose_and_run(srv, conn)
    srv.close_all
    mark = srv.requests.length
    assert_raises(Skaidb::ConnectionError) { conn.exec(COUNT) }
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
      srv.close_all
      mark = srv.requests.length
      assert_raises(Skaidb::ConnectionError) { c.exec(COUNT) }
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
