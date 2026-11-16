# frozen_string_literal: true

# A transaction the application writes itself — BEGIN, statements, COMMIT or
# ROLLBACK sent with exec — is a transaction to the driver too (PROTOCOL.md
# §6 rule 7): it notes the BEGIN the server accepted, and until COMMIT or
# ROLLBACK ends it a lost connection is not replaced. A new session has no
# transaction open: the rest of the statements, and the COMMIT, would each
# autocommit on it. Asserted by the statements the fake server received.
require "test_helper"

class HandWrittenTransactionTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  ONE = "SELECT 1"
  WRITE = "UPDATE t SET v = $1 WHERE id = $2"
  QWRITE = "UPDATE t SET v = ? WHERE id = ?"
  BIG = "SELECT id FROM big"

  def insert(row)
    "INSERT INTO notes (id) VALUES (#{row})"
  end

  # BEGIN, COMMIT and ROLLBACK in every spelling acknowledged, INSERTs
  # counted, a SELECT answered; +overrides+ replace or add statements.
  def handler(overrides = {})
    answers = { ONE => F.rows(["c"], [[1]]), BIG => [F.header(["id"]), F.chunk([[1]]), F.rows_end] }.merge(overrides)
    prepared = FakeSkaidb.scripted({}, prepared: { QWRITE => 2 }, on_execute: ->(_sql, _req) { F.mutation(1) })
    lambda do |req, conn|
      next nil if req.op == 8
      next prepared.call(req, conn) unless [1, 5].include?(req.op)

      a = answers[req.sql]
      a = a.call(req, conn) if a.respond_to?(:call)
      next a if a

      case req.sql
      when /\A\s*(--[^\n]*\n\s*)*(BEGIN|COMMIT|ROLLBACK)\b/i then F.ddl
      when /\AINSERT/ then F.mutation(1)
      else F.error("fake server: unknown statement #{req.sql}")
      end
    end
  end

  # Answers a statement with each payload in turn, the last one from then on.
  def in_turn(*payloads)
    ->(_req, _conn) { payloads.length > 1 ? payloads.shift : payloads[0] }
  end

  # What arrived on connection +number+ (Hello left out).
  def arrived(srv, number)
    srv.requests.select { |q| q.conn == number && q.op != 8 }.map(&:sql)
  end

  # Every call that runs a statement, each a write.
  def writes(conn, id)
    {
      "exec" => -> { conn.exec(insert(3)) },
      "exec_params" => -> { conn.exec_params(insert(3)) },
      "exec_params, prepared before the loss" => -> { conn.exec_params(WRITE, [3, 4]) },
      "exec_params, not prepared yet" => -> { conn.exec_params("UPDATE u SET v = $1", [5]) },
      "exec_batch" => -> { conn.exec_batch(WRITE, [[5, 6], [7, 8]]) },
      "exec_prepared" => -> { conn.exec_prepared(id, [9, 10], 1) },
      "stream" => -> { conn.stream(BIG) { |_row| flunk "no rows expected" } },
      "stream, as an Enumerator" => -> { conn.stream(BIG).to_a },
      "stream with parameters" => -> { conn.stream("SELECT $1", [1]) { |_row| flunk "no rows expected" } },
      "the transaction helper" => -> { conn.transaction { |_tx| flunk "the block must not run" } }
    }
  end

  # ---- no loss: exactly as before ------------------------------------------

  def test_without_a_loss_a_hand_written_transaction_is_sent_as_written
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      assert_equal :ddl, c.exec("BEGIN").kind
      assert_equal 1, c.exec(insert(1)).cmd_tuples
      assert_equal :ddl, c.exec("COMMIT").kind
      c.exec("BEGIN")
      c.exec(insert(2))
      assert_equal :ddl, c.exec("ROLLBACK").kind
      assert_equal 1, c.exec(ONE)[0]["c"]
      assert_equal ["BEGIN", insert(1), "COMMIT", "BEGIN", insert(2), "ROLLBACK", ONE], arrived(srv, 1)
      assert_equal 1, srv.connections
      assert c.usable?
      c.close
    end
  end

  # ---- the connection is lost inside it ------------------------------------

  def test_a_connection_lost_inside_a_hand_written_transaction_is_not_replaced_until_the_transaction_ends
    losses = {
      "closed while idle" => ->(srv, c) { restart(srv, c) },
      "half-closed while idle (the write would still succeed)" => ->(srv, c) { srv.half_close_all && let_the_loss_arrive(c) },
      "reset while idle" => ->(srv, c) { srv.reset_all && let_the_loss_arrive(c) }
    }
    endings = {
      # COMMIT fails: the connection was lost and nothing was committed
      "COMMIT" => lambda do |c, what|
        e = assert_raises(Skaidb::ConnectionError, what) { c.exec("COMMIT") }
        assert_match(/lost inside a transaction/, e.message, what)
        assert_match(/nothing was committed/, e.message, what)
      end,
      # ROLLBACK succeeds without being sent: the server discarded the
      # transaction with the connection
      "ROLLBACK" => ->(c, what) { assert_equal :ddl, c.exec("ROLLBACK").kind, what }
    }
    losses.to_a.product(endings.to_a).each do |(loss_name, lose), (ending_name, ending)|
      what = "#{loss_name}, ended with #{ending_name}"
      with_server do |srv|
        srv.handler = handler
        c = connect(srv)
        c.exec_params(WRITE, [1, 2]) # prepared, and cached, before the transaction
        id, = c.prepare_server(QWRITE)
        c.exec("BEGIN")
        c.exec(insert(1))
        before = arrived(srv, 1)
        lose.call(srv, c)
        # row 2 fails: the connection was lost — found before anything is written
        e = assert_raises(Skaidb::ConnectionError, what) { c.exec(insert(2)) }
        assert_match(/lost inside a transaction/, e.message, what)
        refute c.usable?, what
        # row 3 fails too, by every call that could send it
        writes(c, id).each do |call_name, call|
          e = assert_raises(Skaidb::ConnectionError, "#{what}: #{call_name}") { call.call }
          assert_match(/lost inside a transaction/, e.message, "#{what}: #{call_name}")
        end
        ending.call(c, what)
        # nothing of all that was sent: not on the dead socket, and not on a new session
        assert_equal before, arrived(srv, 1), what
        assert_equal 1, srv.connections, what
        # the transaction is over for the driver too: the next statement
        # re-dials as after any lost connection
        assert_equal 1, c.exec(ONE)[0]["c"], what
        assert_equal [ONE], arrived(srv, 2), what
        assert_equal 2, srv.connections, what
        assert c.usable?, what
        c.close
      end
    end
  end

  def test_a_connection_lost_under_a_statement_of_the_transaction_is_not_replaced_either
    with_server do |srv|
      srv.handler = handler(insert(2) => :close) # the server takes row 2 and goes away
      c = connect(srv)
      c.exec("BEGIN")
      c.exec(insert(1))
      assert_raises(Skaidb::ConnectionError) { c.exec(insert(2)) } # the loss, under it
      e = assert_raises(Skaidb::ConnectionError) { c.exec(insert(3)) }
      assert_match(/lost inside a transaction/, e.message)
      e = assert_raises(Skaidb::ConnectionError) { c.exec("COMMIT") }
      assert_match(/nothing was committed/, e.message)
      assert_equal ["BEGIN", insert(1), insert(2)], arrived(srv, 1)
      assert_equal 1, srv.connections
      assert_equal 1, c.exec(ONE)[0]["c"]
      assert_equal [ONE], arrived(srv, 2)
      c.close
    end
  end

  def test_a_connection_lost_under_the_commit_itself_leaves_the_outcome_unknown_and_says_so
    with_server do |srv|
      srv.handler = handler("COMMIT" => :close)
      c = connect(srv)
      c.exec("BEGIN")
      c.exec(insert(1))
      e = assert_raises(Skaidb::ConnectionError) { c.exec("COMMIT") }
      # the server may have applied it before its reply went missing
      assert_match(/not known/, e.message)
      refute_match(/nothing was committed/, e.message)
      # the COMMIT has ended the transaction for the driver: the next statement re-dials
      assert_equal 1, c.exec(ONE)[0]["c"]
      assert_equal ["BEGIN", insert(1), "COMMIT"], arrived(srv, 1)
      assert_equal [ONE], arrived(srv, 2)
      c.close
    end
  end

  def test_a_connection_lost_under_the_rollback_itself_has_ended_the_transaction
    with_server do |srv|
      srv.handler = handler("ROLLBACK" => :close)
      c = connect(srv)
      c.exec("BEGIN")
      c.exec(insert(1))
      assert_raises(Skaidb::ConnectionError) { c.exec("ROLLBACK") }
      assert_equal 1, c.exec(ONE)[0]["c"]
      assert_equal [ONE], arrived(srv, 2)
      c.close
    end
  end

  # ---- what opens a noted transaction, and what ends it --------------------

  def test_every_spelling_of_begin_commit_and_rollback_is_followed
    openings = ["BEGIN", "begin", "BEGIN TRANSACTION", "  Begin ;", "BEGIN ATOMIC",
                "BEGIN ATOMIC PARTITION (tenant = 'a--b')", "BEGIN -- the nightly batch", "-- nightly\nBEGIN"]
    endings = ["COMMIT", "commit", "COMMIT TRANSACTION", "  Commit ; ", "ROLLBACK", "rollback transaction;",
               "ROLLBACK -- give up", "-- done\nCOMMIT"]
    senders = {
      "exec" => ->(c, sql) { c.exec(sql) },
      "query" => ->(c, sql) { c.query(sql) },
      "exec_params" => ->(c, sql) { c.exec_params(sql) },
      "stream" => ->(c, sql) { c.stream(sql) { |_row| flunk "no rows expected" } }
    }
    with_server do |srv|
      srv.handler = handler(openings.to_h { |sql| [sql, F.ddl] }.merge(endings.to_h { |sql| [sql, F.ddl] }))
      senders.each do |how, send|
        openings.each do |opening|
          what = "#{opening.inspect} sent with #{how}"
          c = connect(srv)
          send.call(c, opening)
          restart(srv, c)
          # it opened a transaction: the lost connection is not replaced
          e = assert_raises(Skaidb::ConnectionError, what) { c.exec(insert(1)) }
          assert_match(/lost inside a transaction/, e.message, what)
          c.close
        end
        endings.each do |ending|
          what = "#{ending.inspect} sent with #{how}"
          c = connect(srv)
          c.exec("BEGIN")
          send.call(c, ending)
          restart(srv, c)
          # it ended the transaction: the lost connection is replaced as always
          assert_equal 1, c.exec(insert(1)).cmd_tuples, what
          c.close
        end
      end
    end
  end

  def test_what_does_not_open_a_transaction_is_not_taken_for_one
    with_server do |srv|
      not_one = ["SELECT 'BEGIN'", "BEGINNING", "-- BEGIN", "CREATE PROCEDURE p() BEGIN SELECT 1; END"]
      srv.handler = handler(not_one.to_h { |sql| [sql, F.ddl] }.merge("BEGIN" => F.error("BEGIN refused")))
      c = connect(srv)
      not_one.each { |sql| c.exec(sql) }
      assert_raises(Skaidb::QueryError) { c.exec("BEGIN") } # refused: nothing was opened
      restart(srv, c)
      assert_equal 1, c.exec(insert(1)).cmd_tuples # replaced as always
      assert_equal 2, srv.connections
      c.close
    end
  end

  def test_a_commit_the_server_refuses_has_ended_the_transaction
    conflict = "transaction conflict: a row of table notes was changed by another writer"
    with_server do |srv|
      srv.handler = handler("COMMIT" => F.error(conflict), "ROLLBACK" => F.error("no transaction in progress"))
      [["COMMIT", Skaidb::TransactionConflict], ["ROLLBACK", Skaidb::QueryError]].each do |ending, error|
        c = connect(srv)
        c.exec("BEGIN")
        c.exec(insert(1))
        assert_raises(error, ending) { c.exec(ending) }
        assert c.usable?, ending
        restart(srv, c)
        assert_equal 1, c.exec(insert(2)).cmd_tuples, ending # no transaction is open: replaced as always
        c.close
      end
    end
  end

  def test_a_statement_that_fails_inside_the_transaction_leaves_it_open
    with_server do |srv|
      srv.handler = handler("SELECT nope" => F.error("no such column nope"))
      c = connect(srv)
      c.exec("BEGIN")
      assert_raises(Skaidb::QueryError) { c.exec("SELECT nope") }
      restart(srv, c)
      e = assert_raises(Skaidb::ConnectionError) { c.exec(insert(1)) }
      assert_match(/lost inside a transaction/, e.message)
      assert_equal :ddl, c.exec("ROLLBACK").kind
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_commit_and_rollback_with_no_transaction_noted_re_dial_and_are_sent
    with_server do |srv|
      srv.handler = handler("COMMIT" => F.error("no transaction in progress"))
      c = connect(srv)
      restart(srv, c)
      assert_equal :ddl, c.exec("ROLLBACK").kind
      assert_equal ["ROLLBACK"], arrived(srv, 2) # sent: the server's to answer
      restart(srv, c)
      e = assert_raises(Skaidb::QueryError) { c.exec("COMMIT") }
      assert_equal "no transaction in progress", e.message
      assert_equal ["COMMIT"], arrived(srv, 3)
      c.close
    end
  end

  # ---- an exception that lands in the middle of one of its statements ------

  def test_an_exception_that_lands_just_after_begins_reply_leaves_no_transaction_the_driver_does_not_know_of
    interrupt = Class.new(Exception) # rubocop:disable Lint/InheritException
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      # BEGIN was answered; the exception lands before the driver has noted it
      assert_raises(interrupt) { cut_after_the_reply(c, interrupt) { c.exec("BEGIN") } }
      refute c.usable?
      assert_hung_up srv, 1 # the server drops the transaction with the session
      assert_equal 1, c.exec(insert(1)).cmd_tuples
      assert_equal [insert(1)], arrived(srv, 2)
      c.close
    end
  end

  def test_a_commit_cut_short_before_it_is_sent_does_not_leave_the_transaction_open
    interrupt = Class.new(Exception) # rubocop:disable Lint/InheritException
    %w[COMMIT ROLLBACK].each do |ending|
      with_server do |srv|
        srv.handler = handler
        c = connect(srv)
        c.exec("BEGIN")
        c.exec(insert(1))
        assert_raises(interrupt, ending) { cut_before_the_request(c, ending, interrupt) { c.exec(ending) } }
        # the application was told its COMMIT failed; a transaction left
        # open behind it would swallow whatever it sends next
        refute c.usable?, ending
        assert_hung_up srv, 1, ending
        assert_equal ["BEGIN", insert(1)], arrived(srv, 1), ending
        assert_equal 1, c.exec(insert(2)).cmd_tuples, ending
        assert_equal [insert(2)], arrived(srv, 2), ending
        c.close
      end
    end
  end

  # ---- the helper keeps working, and the two agree -------------------------

  def test_the_helper_leaves_no_note_behind
    with_server do |srv|
      srv.handler = handler(insert(9) => :close)
      c = connect(srv)
      assert_equal :done, c.transaction { |tx| tx.exec(insert(1)) && :done }
      restart(srv, c)
      assert_equal 1, c.exec(insert(2)).cmd_tuples # committed and over: replaced as always
      # a block that raises is rolled back, and over
      assert_raises(RuntimeError) { c.transaction { |_tx| raise "boom" } }
      restart(srv, c)
      assert_equal 1, c.exec(insert(3)).cmd_tuples
      # a helper that lost its connection reports it, and is over when it returns
      assert_raises(Skaidb::ConnectionError) { c.transaction { |tx| tx.exec(insert(9)) } }
      assert_equal 1, c.exec(insert(4)).cmd_tuples
      assert_equal 4, srv.connections
      assert_equal ["BEGIN", insert(1), "COMMIT"], arrived(srv, 1)
      assert_equal [insert(2), "BEGIN", "ROLLBACK"], arrived(srv, 2)
      assert_equal [insert(3), "BEGIN", insert(9)], arrived(srv, 3)
      assert_equal [insert(4)], arrived(srv, 4)
      c.close
    end
  end

  def test_the_helper_inside_a_hand_written_transaction_leaves_that_one_noted
    with_server do |srv|
      srv.handler = handler("BEGIN" => in_turn(F.ddl, F.error("a transaction is already in progress")))
      c = connect(srv)
      c.exec("BEGIN")
      assert_raises(Skaidb::QueryError) { c.transaction { |_tx| flunk "the block must not run" } }
      restart(srv, c)
      # the hand-written transaction is still the driver's to guard
      e = assert_raises(Skaidb::ConnectionError) { c.exec(insert(1)) }
      assert_match(/lost inside a transaction/, e.message)
      assert_equal :ddl, c.exec("ROLLBACK").kind
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_a_hand_written_commit_inside_the_helper_does_not_let_the_block_out_of_its_session
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          tx.exec(insert(1))
          restart(srv, tx)
          assert_raises(Skaidb::ConnectionError) { tx.exec(insert(2)) }
          assert_equal :ddl, tx.exec("ROLLBACK").kind # ended by hand, client-side
          tx.exec(insert(3)) # still inside the helper: not on a new session
        end
      end
      assert_match(/lost inside a transaction/, e.message)
      assert_equal ["BEGIN", insert(1)], arrived(srv, 1)
      assert_equal 1, srv.connections
      c.close
    end
  end
end
