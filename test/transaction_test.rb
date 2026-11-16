# frozen_string_literal: true

# Transactions (PROTOCOL.md §6 rule 6): the typed error for a COMMIT the
# server refuses with "transaction conflict:", and the retrying
# Connection#transaction / Pool#transaction helper — asserted by the
# statements the fake server received.
require "test_helper"
require "timeout"

class TransactionTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  # The server's text; the driver matches the prefix only.
  CONFLICT = "transaction conflict: a row of table accounts was changed by another writer " \
             "after the transaction began — nothing was committed; run the transaction again"
  DEBIT = "UPDATE accounts SET balance = balance - 10 WHERE id = 1"
  CREDIT = "UPDATE accounts SET balance = balance + 10 WHERE id = 2"

  # What the fake server answers: BEGIN, COMMIT and ROLLBACK acknowledged,
  # the two UPDATEs and a SELECT; +overrides+ replace or add statements
  # (+:close+ drops the connection instead of answering).
  def script(overrides = {})
    { "BEGIN" => F.ddl, "COMMIT" => F.ddl, "ROLLBACK" => F.ddl,
      DEBIT => F.mutation(1), CREDIT => F.mutation(1),
      "SELECT 1" => F.rows(["c"], [[1]]) }.merge(overrides)
  end

  # Answers a statement with each payload in turn, the last one from then on.
  def in_turn(*payloads)
    ->(_req, _conn) { payloads.length > 1 ? payloads.shift : payloads[0] }
  end

  # Every statement the fake server received, in order (Hello left out).
  def statements(srv)
    srv.requests.reject { |q| q.op == 8 }.map(&:sql)
  end

  # ---- the typed error -----------------------------------------------------

  def test_a_conflict_is_a_typed_query_error_and_the_connection_stays_usable
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("COMMIT" => F.error(CONFLICT)))
      c = connect(srv)
      e = assert_raises(Skaidb::TransactionConflict) { c.exec("COMMIT") }
      assert_equal CONFLICT, e.message # the server's message, unchanged
      assert_kind_of Skaidb::QueryError, e
      assert_kind_of Skaidb::Error, e
      # code that rescues the statement error catches it as before
      caught = begin
        c.exec("COMMIT")
      rescue Skaidb::QueryError => err
        err
      end
      assert_instance_of Skaidb::TransactionConflict, caught
      # a statement error, not a connection failure: the next statement runs
      # on the same socket
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_only_the_prefix_decides_and_only_at_the_start_of_the_message
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        "COMMIT" => F.error("transaction conflict: reworded by a later server"),
        "SELECT a" => F.error("no such column a"),
        "SELECT b" => F.error("commit failed: transaction conflict: not at the start")
      )
      c = connect(srv)
      assert_equal "transaction conflict:", Skaidb::TransactionConflict::PREFIX
      e = assert_raises(Skaidb::QueryError) { c.exec("COMMIT") }
      assert_instance_of Skaidb::TransactionConflict, e
      assert_equal "transaction conflict: reworded by a later server", e.message
      ["SELECT a", "SELECT b"].each do |sql|
        assert_instance_of Skaidb::QueryError, assert_raises(Skaidb::QueryError) { c.exec(sql) }, sql
      end
      c.close
    end
  end

  def test_every_statement_path_raises_the_typed_error
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        script("COMMIT" => F.error(CONFLICT),
               "SELECT ?" => F.error(CONFLICT), # a parameterised stream, keyed by its ? SQL
               "SELECT late" => [F.header(["id"]), F.chunk([[1]]), F.error(CONFLICT)]),
        prepared: { "UPDATE t SET v = ? WHERE id = ?" => 2 },
        on_execute: ->(_sql, _req) { F.error(CONFLICT) },
        on_batch: ->(_sql, _req) { F.error(CONFLICT) }
      )
      c = connect(srv)
      paths = {
        "exec" => -> { c.exec("COMMIT") },
        "query" => -> { c.query("COMMIT") },
        "exec_params without parameters" => -> { c.exec_params("COMMIT") },
        "exec_params, prepared" => -> { c.exec_params("UPDATE t SET v = $1 WHERE id = $2", [1, 2]) },
        "exec_batch" => -> { c.exec_batch("UPDATE t SET v = $1 WHERE id = $2", [[1, 2], [3, 4]]) },
        "stream" => -> { c.stream("COMMIT") { |_| flunk "no rows expected" } },
        "stream with parameters" => -> { c.stream("SELECT $1", [1]) { |_| flunk "no rows expected" } },
        "stream, after rows" => -> { c.stream("SELECT late") { |_| nil } }
      }
      paths.each do |name, call|
        e = assert_raises(Skaidb::TransactionConflict, name) { call.call }
        assert_equal CONFLICT, e.message, name
        assert c.usable?, name
      end
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_a_conflict_does_not_count_against_a_pool_member_or_cost_the_connection
    with_server do |a|
      with_server do |b|
        [a, b].each { |srv| srv.handler = FakeSkaidb.scripted(script("COMMIT" => F.error(CONFLICT))) }
        # eject_errors: 1 — a single transport failure would eject the member
        pool = Skaidb::Pool.new(seeds: ["127.0.0.1:#{a.port}", "127.0.0.1:#{b.port}"], user: "ada",
                                password: "secret", load_balancing: :round_robin, eject_errors: 1)
        6.times { pool.with { |c| assert_raises(Skaidb::TransactionConflict) { c.exec("COMMIT") } } }
        assert_equal %i[ready ready], pool.members.map { |m| m[:state] }
        # each connection went back to the idle set and was handed out again
        assert_equal [1, 1], pool.members.map { |m| m[:idle] }
        assert_equal [1, 1], [a.connections, b.connections]
        pool.close
      end
    end
  end

  # ---- the helper ----------------------------------------------------------

  def test_success_sends_begin_the_block_and_commit_once_and_returns_the_blocks_value
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      c = connect(srv)
      handed = nil
      value = c.transaction do |tx|
        handed = tx
        tx.exec(DEBIT)
        tx.exec(CREDIT).cmd_tuples + 41
      end
      assert_equal 42, value
      assert_same c, handed # the block is handed the connection itself
      assert_equal ["BEGIN", DEBIT, CREDIT, "COMMIT"], statements(srv)
      assert c.usable?
      # a falsy value is a value: the block ran to its end, so it commits
      assert_nil(c.transaction { |tx| tx.exec(DEBIT) && nil })
      assert_equal false, c.transaction { |_tx| false }
      assert_equal ["BEGIN", DEBIT, "COMMIT", "BEGIN", "COMMIT"], statements(srv).drop(4)
      c.close
    end
  end

  def test_a_refused_commit_runs_the_block_again_and_the_last_runs_value_is_returned
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("COMMIT" => in_turn(F.error(CONFLICT), F.error(CONFLICT), F.ddl)))
      c = connect(srv)
      runs = 0
      value = c.transaction(attempts: 3) do |tx|
        runs += 1
        tx.exec(DEBIT)
        "run #{runs}"
      end
      assert_equal 3, runs
      assert_equal "run 3", value
      # each run starts again from BEGIN; nothing is rolled back in between
      assert_equal ["BEGIN", DEBIT, "COMMIT"] * 3, statements(srv)
      assert_equal 1, srv.connections
      assert c.usable?
      c.close
    end
  end

  def test_a_conflict_on_every_commit_is_raised_after_the_last_attempt
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("COMMIT" => F.error(CONFLICT)))
      c = connect(srv)
      runs = 0
      e = assert_raises(Skaidb::TransactionConflict) do
        c.transaction(attempts: 2) do |tx|
          runs += 1
          tx.exec(DEBIT)
        end
      end
      assert_equal CONFLICT, e.message
      assert_equal 2, runs
      assert_equal ["BEGIN", DEBIT, "COMMIT"] * 2, statements(srv)
      assert c.usable?
      # attempts: 1 never runs the block again; the default is three runs
      runs = 0
      assert_raises(Skaidb::TransactionConflict) { c.transaction(attempts: 1) { |_tx| runs += 1 } }
      assert_equal 1, runs
      runs = 0
      assert_raises(Skaidb::TransactionConflict) { c.transaction { |_tx| runs += 1 } }
      assert_equal 3, runs
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_a_block_that_raises_is_rolled_back_and_its_error_propagates_unchanged
    boom = RuntimeError.new("boom")
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("SELECT nope" => F.error("no such column nope")))
      c = connect(srv)
      runs = 0
      e = assert_raises(RuntimeError) do
        c.transaction do |tx|
          runs += 1
          tx.exec(DEBIT)
          raise boom
        end
      end
      assert_same boom, e
      assert_equal 1, runs
      assert_equal ["BEGIN", DEBIT, "ROLLBACK"], statements(srv) # and no COMMIT
      assert c.usable?
      # a statement the server refuses inside the block is the block's error too
      e = assert_raises(Skaidb::QueryError) { c.transaction { |tx| tx.exec("SELECT nope") } }
      assert_equal "no such column nope", e.message
      assert_equal ["BEGIN", "SELECT nope", "ROLLBACK"], statements(srv).drop(3)
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      c.close
    end
  end

  def test_a_rollback_the_server_refuses_never_replaces_the_blocks_error
    boom = RuntimeError.new("boom")
    with_server do |srv|
      # what a server before 0.347 answers a ROLLBACK with nothing open
      srv.handler = FakeSkaidb.scripted(script("ROLLBACK" => F.error("no transaction in progress")))
      c = connect(srv)
      e = assert_raises(RuntimeError) do
        c.transaction do |tx|
          tx.exec(DEBIT)
          raise boom
        end
      end
      assert_same boom, e
      assert_equal ["BEGIN", DEBIT, "ROLLBACK"], statements(srv)
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      c.close
    end
  end

  def test_a_conflict_raised_inside_the_block_is_rolled_back_and_not_retried
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script(DEBIT => F.error(CONFLICT)))
      c = connect(srv)
      runs = 0
      e = assert_raises(Skaidb::TransactionConflict) do
        c.transaction(attempts: 5) do |tx|
          runs += 1
          tx.exec(DEBIT)
        end
      end
      assert_equal CONFLICT, e.message
      assert_equal 1, runs
      assert_equal ["BEGIN", DEBIT, "ROLLBACK"], statements(srv)
      c.close
    end
  end

  # Leaves the transaction block with a +return+.
  def return_out_of_a_transaction(conn)
    conn.transaction do |tx|
      tx.exec(DEBIT)
      return :returned
    end
    :not_reached
  end

  def test_leaving_the_block_early_rolls_back
    fatal = Class.new(Exception) # not a StandardError, as an Interrupt or SystemExit is not
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      c = connect(srv)
      left = c.transaction do |tx|
        tx.exec(DEBIT)
        break :left
      end
      assert_equal :left, left
      thrown = catch(:out) do
        c.transaction do |tx|
          tx.exec(DEBIT)
          throw :out, :thrown
        end
      end
      assert_equal :thrown, thrown
      assert_equal :returned, return_out_of_a_transaction(c)
      e = assert_raises(fatal) do
        c.transaction do |tx|
          tx.exec(DEBIT)
          raise fatal, "stop"
        end
      end
      assert_equal "stop", e.message
      assert_equal ["BEGIN", DEBIT, "ROLLBACK"] * 4, statements(srv)
      assert c.usable?
      assert_equal 1, srv.connections
      c.close
    end
  end

  # Runs a transaction whose UPDATE the server sits on, yields the thread
  # running it while that reply is outstanding — to be cut short — and checks
  # that the helper wrote nothing more to the socket. A ROLLBACK written then
  # would wait for the UPDATE's reply and take it for its own.
  def cut_short_in_the_middle_of_a_round_trip
    with_server do |srv|
      gate = Queue.new
      srv.handler = FakeSkaidb.scripted(script(DEBIT => ->(_req, _conn) { gate.pop && F.mutation(1) }))
      c = connect(srv)
      worker = Thread.new do
        Thread.current.report_on_exception = false
        c.transaction { |tx| tx.exec(DEBIT) }
      end
      until_true { statements(srv).include?(DEBIT) } # the request is out, its reply is not
      yield worker
      refute c.usable?
      assert_equal ["BEGIN", DEBIT], statements(srv) # no ROLLBACK, no COMMIT
      assert_equal 1, srv.connections                # and no re-dial inside the helper
      gate << true
      assert_hung_up srv, 1 # the socket is closed, and the server's transaction with it
      # the next statement runs on a new socket and reads its own reply
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 2, srv.connections
      c.close
    end
  end

  def test_an_interrupt_in_the_middle_of_a_round_trip_is_not_followed_by_a_rollback
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with
    cut_short_in_the_middle_of_a_round_trip do |worker|
      worker.raise(interrupt, "interrupted")
      e = assert_raises(interrupt) { worker.join(5) || flunk("the helper is waiting on the socket") }
      assert_equal "interrupted", e.message
    end
  end

  def test_a_thread_killed_in_the_middle_of_a_round_trip_is_not_followed_by_a_rollback
    cut_short_in_the_middle_of_a_round_trip do |worker|
      worker.kill
      assert worker.join(5), "the helper is waiting on the socket"
    end
  end

  def test_a_refused_begin_never_runs_the_block_and_sends_nothing_else
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("BEGIN" => F.error("BEGIN refused")))
      c = connect(srv)
      ran = false
      e = assert_raises(Skaidb::QueryError) { c.transaction { |_tx| ran = true } }
      assert_equal "BEGIN refused", e.message
      refute ran
      assert_equal ["BEGIN"], statements(srv) # no COMMIT, no ROLLBACK
      assert c.usable?
      c.close
    end
  end

  def test_any_other_commit_error_is_raised_without_a_retry_or_a_rollback
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("COMMIT" => F.error("commit failed")))
      c = connect(srv)
      runs = 0
      e = assert_raises(Skaidb::QueryError) do
        c.transaction do |tx|
          runs += 1
          tx.exec(DEBIT)
        end
      end
      assert_instance_of Skaidb::QueryError, e
      assert_equal "commit failed", e.message
      assert_equal 1, runs
      assert_equal ["BEGIN", DEBIT, "COMMIT"], statements(srv)
      assert c.usable?
      c.close
    end
  end

  def test_attempts_below_one_is_an_argument_error_before_anything_is_sent
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      c = connect(srv)
      ran = false
      [0, -1, nil, 1.5, "3"].each do |bad|
        e = assert_raises(ArgumentError, bad.inspect) { c.transaction(attempts: bad) { |_tx| ran = true } }
        assert_equal "attempts must be an Integer >= 1, got #{bad.inspect}", e.message
      end
      assert_raises(ArgumentError) { c.transaction } # no block
      refute ran
      assert_empty statements(srv)
      c.close
    end
  end

  def test_a_custom_begin_is_sent_verbatim_on_every_attempt
    opening = "BEGIN ATOMIC PARTITION (tenant = 'acme')"
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script(opening => F.ddl, "COMMIT" => in_turn(F.error(CONFLICT), F.ddl)))
      c = connect(srv)
      c.transaction(begin: opening) { |tx| tx.exec(DEBIT) }
      assert_equal [opening, DEBIT, "COMMIT"] * 2, statements(srv)
      # the OP_QUERY frame carries the text as given (QUORUM, the default level)
      first = srv.requests.find { |q| q.op == 1 }
      assert_equal ([1, 1].pack("CC") + [opening.bytesize].pack("V") + opening).b, first.raw
      c.close
    end
  end

  # ---- transport failures --------------------------------------------------

  def test_a_lost_connection_in_the_block_is_a_connection_error_with_no_retry_and_no_re_dial
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script(DEBIT => :close))
      c = connect(srv)
      runs = 0
      assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          runs += 1
          tx.exec(DEBIT)
        end
      end
      assert_equal 1, runs
      # the transaction went with the socket: no ROLLBACK on a new session
      assert_equal ["BEGIN", DEBIT], statements(srv)
      assert_equal 1, srv.connections
      # once the helper has returned the connection re-dials as always, for a
      # statement and for the helper's own BEGIN alike
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 2, srv.connections
      srv.close_all
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") }
      assert_equal :done, c.transaction { |_tx| :done }
      assert_equal 3, srv.connections
      assert_equal %w[BEGIN COMMIT], statements(srv).last(2)
      c.close
    end
  end

  def test_a_block_that_rescues_a_lost_connection_cannot_autocommit_on_a_new_session
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script(DEBIT => :close))
      c = connect(srv)
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          begin
            tx.exec(DEBIT)
          rescue Skaidb::ConnectionError
            nil # carries on regardless
          end
          tx.exec(CREDIT)
        end
      end
      assert_match(/lost inside a transaction/, e.message)
      # ... and when the block swallows everything, neither is the COMMIT
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          begin
            tx.exec(DEBIT)
          rescue Skaidb::ConnectionError
            nil
          end
        end
      end
      assert_match(/lost inside a transaction/, e.message)
      # the first helper's BEGIN and DEBIT, then the second's on a re-dialled
      # connection: no CREDIT, no COMMIT, no ROLLBACK ever reached a session
      # without the transaction
      assert_equal ["BEGIN", DEBIT] * 2, statements(srv)
      assert_equal 2, srv.connections
      c.close
    end
  end

  def test_a_refused_inner_begin_leaves_the_outer_transaction_guarded
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        script("BEGIN" => in_turn(F.ddl, F.error("a transaction is already open")), DEBIT => :close)
      )
      c = connect(srv)
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          assert_raises(Skaidb::QueryError) { tx.transaction { |_inner| flunk "the inner block must not run" } }
          begin
            tx.exec(DEBIT)
          rescue Skaidb::ConnectionError
            nil
          end
          tx.exec(CREDIT)
        end
      end
      assert_match(/lost inside a transaction/, e.message)
      assert_equal ["BEGIN", "BEGIN", DEBIT], statements(srv)
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_a_lost_connection_on_commit_or_rollback_is_never_retried
    boom = RuntimeError.new("boom")
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script("COMMIT" => :close, "ROLLBACK" => :close))
      c = connect(srv)
      runs = 0
      assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          runs += 1
          tx.exec(DEBIT)
        end
      end
      assert_equal 1, runs
      assert_equal ["BEGIN", DEBIT, "COMMIT"], statements(srv)
      assert_equal 1, srv.connections
      # a ROLLBACK that dies in transport does not replace the block's error
      e = assert_raises(RuntimeError) do
        c.transaction do |tx|
          tx.exec(DEBIT)
          raise boom
        end
      end
      assert_same boom, e
      assert_equal ["BEGIN", DEBIT, "ROLLBACK"], statements(srv).drop(3)
      assert_equal 2, srv.connections
      c.close
    end
  end

  # ---- no statement of the block leaves the transaction's session ----------
  # (PROTOCOL.md §6 rule 7)

  def test_after_a_lost_connection_no_call_of_the_block_reaches_a_new_session
    write = "UPDATE t SET v = $1 WHERE id = $2"
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        script("SELECT big" => [F.header(["id"]), F.chunk([[1]]), F.rows_end]),
        prepared: { "UPDATE t SET v = ? WHERE id = ?" => 2 }, on_execute: ->(_sql, _req) { F.mutation(1) }
      )
      c = connect(srv)
      received = nil
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          tx.exec(DEBIT) # statement 1 succeeds
          tx.exec_params(write, [1, 2]) # prepared, and cached on this connection
          id, = tx.prepare_server("UPDATE t SET v = ? WHERE id = ?")
          srv.close_all # the connection is lost
          received = srv.requests.length
          # statement 2 meets the loss; the block rescues it and carries on
          assert_raises(Skaidb::ConnectionError) { tx.exec(CREDIT) }
          # statement 3, a write, by every call that runs one: none re-dials
          calls = {
            "exec" => -> { tx.exec(CREDIT) },
            "exec_params" => -> { tx.exec_params(CREDIT) },
            "exec_params, prepared before the loss" => -> { tx.exec_params(write, [3, 4]) },
            "exec_params, not prepared yet" => -> { tx.exec_params("UPDATE u SET v = $1", [5]) },
            "exec_batch" => -> { tx.exec_batch(write, [[5, 6], [7, 8]]) },
            "exec_prepared" => -> { tx.exec_prepared(id, [9, 10], 1) },
            "stream" => -> { tx.stream("SELECT big") { |_row| flunk "no rows expected" } },
            "stream, as an Enumerator" => -> { tx.stream("SELECT big").to_a },
            "stream with parameters" => -> { tx.stream("SELECT $1", [1]) { |_row| flunk "no rows expected" } },
            "a transaction inside it" => -> { tx.transaction { |_inner| flunk "the inner block must not run" } }
          }
          calls.each { |name, call| assert_raises(Skaidb::ConnectionError, name) { call.call } }
          :returned # ... and the block returns normally
        end
      end
      # the helper reports the loss; its COMMIT is not sent on a new session
      assert_match(/lost inside a transaction/, e.message)
      # nothing after the loss reached a session: no write, no COMMIT, no ROLLBACK
      assert_equal received, srv.requests.length
      assert_equal 1, srv.connections
      refute c.usable?
      # once the helper has returned the connection is what it is after any
      # lost connection: its next statement re-dials
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 2, srv.connections
      assert_equal 1, c.exec_params(write, [3, 4]).cmd_tuples
      assert_equal [DEBIT, "COMMIT"], (c.transaction { |tx| tx.exec(DEBIT) } && statements(srv).last(2))
      assert_equal 2, srv.connections
      c.close
    end
  end

  def test_pool_transaction_after_a_lost_connection_reaches_no_other_connection
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
      held = nil
      e = assert_raises(Skaidb::ConnectionError) do
        pool.transaction do |conn|
          held = conn
          conn.exec(DEBIT)
          srv.close_all
          assert_raises(Skaidb::ConnectionError) { conn.exec(CREDIT) }
          assert_raises(Skaidb::ConnectionError) { conn.exec(CREDIT) }
          :returned
        end
      end
      assert_match(/lost inside a transaction/, e.message)
      # neither the block's statements nor the COMMIT went to another connection
      assert_equal ["BEGIN", DEBIT], statements(srv)
      assert_equal 1, srv.connections
      # the connection is not handed out again; the next transaction dials its own
      assert held.finished?
      assert_equal [0, 0], pool.members[0].values_at(:in_use, :idle)
      assert_equal :done, pool.transaction { |conn| conn.exec(DEBIT) && :done }
      assert_equal ["BEGIN", DEBIT, "COMMIT"], statements(srv).drop(2)
      assert_equal 2, srv.connections
      pool.close
    end
  end

  # ---- the opening statement on a connection the server dropped ------------

  def test_the_opening_statement_meets_a_restarted_server_as_any_statement_does
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      plain = connect(srv)
      c = connect(srv)
      [plain, c].each { |conn| assert_equal 1, conn.exec("SELECT 1")[0]["c"] }
      srv.close_all # the server restarts while both sit idle
      # an ordinary statement: the one that meets the loss raises
      # ConnectionError, the one after it re-dials
      assert_raises(Skaidb::ConnectionError) { plain.exec("SELECT 1") }
      assert_equal 1, plain.exec("SELECT 1")[0]["c"]
      # the helper's opening statement is such a statement: the same
      # ConnectionError, the block not run, nothing else sent ...
      sent = statements(srv).length
      runs = 0
      assert_raises(Skaidb::ConnectionError) { c.transaction { |_tx| runs += 1 } }
      assert_equal 0, runs
      assert_equal sent, statements(srv).length
      refute c.usable?
      # ... and the next call re-dials: nothing is open yet, so BEGIN goes
      # out on the new session and the transaction runs there
      value = c.transaction do |tx|
        runs += 1
        tx.exec(DEBIT)
        :done
      end
      assert_equal [:done, 1], [value, runs]
      assert_equal ["BEGIN", DEBIT, "COMMIT"], statements(srv).last(3)
      assert_equal 4, srv.connections # two dialled, two re-dialled
      [plain, c].each(&:close)
    end
  end

  def test_pool_transaction_meets_a_restarted_server_as_any_pooled_statement_does
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
      pool.with { |conn| conn.exec("SELECT 1") }
      srv.close_all # the idle connection is gone, and looks fine from here
      assert_raises(Skaidb::ConnectionError) { pool.with { |conn| conn.exec("SELECT 1") } }
      assert_equal 1, pool.with { |conn| conn.exec("SELECT 1")[0]["c"] } # a new connection
      srv.close_all
      runs = 0
      assert_raises(Skaidb::ConnectionError) { pool.transaction { |_conn| runs += 1 } }
      assert_equal 0, runs
      assert_equal :done, pool.transaction { |conn| conn.exec(DEBIT) && :done }
      assert_equal ["BEGIN", DEBIT, "COMMIT"], statements(srv).last(3)
      assert_equal 3, srv.connections
      assert_equal [0, 1], pool.members[0].values_at(:in_use, :idle)
      pool.close
    end
  end

  # ---- a stream the block leaves open --------------------------------------
  #
  # An Enumerator from +stream+ advanced with +next+ runs the stream in its
  # own Fiber, which then sits in the middle of the reply until it is
  # advanced again: nothing else can be sent on that socket meanwhile, a
  # COMMIT or a ROLLBACK included.
  #
  # None of these tests leaves such a Fiber behind: an Enumerator dropped
  # while its Fiber holds a lock crashes Ruby 3.3 when it is collected.

  BIG = "SELECT id FROM big"

  def big_script(overrides = {})
    script({ BIG => [F.header(["id"]), F.chunk([[1], [2]]), F.chunk([[3]]), F.rows_end] }.merge(overrides))
  end

  def test_a_stream_the_block_leaves_open_cannot_leave_a_transaction_to_join
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(big_script)
      c = connect(srv)
      rows = nil
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          tx.exec(DEBIT)
          rows = tx.stream(BIG)
          assert_equal 1, rows.next["id"]
          :returned
        end
      end
      assert_match(/stream .*left open/, e.message)
      # neither COMMIT nor ROLLBACK could be sent, so the socket was closed:
      # the server drops the transaction with it
      assert_hung_up srv, 1
      assert_equal ["BEGIN", DEBIT, BIG], statements(srv)
      assert_equal 1, srv.connections
      # the stream was unwound with it: the connection is not left busy, it
      # is what it is after any lost connection
      refute c.usable?
      refute c.finished?
      # a later statement re-dials: a new session, with no transaction open
      assert_equal 1, c.exec(CREDIT).cmd_tuples
      assert_equal 2, srv.connections
      assert c.usable?
      # and the Enumerator, advanced again, starts its statement again there
      # — it does not go on reading the reply of the session that is gone
      assert_equal [1, 2, 3], Array.new(3) { rows.next["id"] }
      assert_raises(StopIteration) { rows.next }
      assert_equal [CREDIT, BIG], statements(srv).drop(3)
      assert_equal 2, srv.connections
      assert c.usable?
      c.close
    end
  end

  def test_a_block_that_raises_with_a_stream_open_keeps_its_error_and_loses_the_session
    boom = RuntimeError.new("boom")
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(big_script)
      c = connect(srv)
      e = assert_raises(RuntimeError) do
        c.transaction do |tx|
          tx.exec(DEBIT)
          tx.stream(BIG).next
          raise boom
        end
      end
      assert_same boom, e
      assert_hung_up srv, 1
      assert_equal ["BEGIN", DEBIT, BIG], statements(srv) # no ROLLBACK could be sent either
      refute c.usable?
      # the statement after it: on 1.5.0 the stream could be read to its end
      # and this then ran inside the transaction nothing had rolled back
      assert_equal 1, c.exec(CREDIT).cmd_tuples
      assert_equal 2, srv.connections
      # leaving with break is leaving: no error of the helper's, the same end
      left = c.transaction do |tx|
        tx.stream(BIG).next
        break :left
      end
      assert_equal :left, left
      assert_hung_up srv, 2
      assert_equal ["BEGIN", BIG], statements(srv).drop(4)
      refute c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 3, srv.connections
      c.close
    end
  end

  def test_a_stream_left_open_in_a_fiber_the_helper_cannot_reach_closes_the_connection_for_good
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(big_script)
      c = connect(srv)
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          # the stream is opened, and left, by another thread: its Fiber
          # cannot be resumed from this one
          Thread.new { tx.stream(BIG).next }.join
          :returned
        end
      end
      assert_match(/stream .*left open/, e.message)
      assert_hung_up srv, 1
      assert_equal ["BEGIN", BIG], statements(srv)
      # no re-dial under a stream that may still read this connection
      assert c.finished?
      assert_raises(Skaidb::ConnectionError) { c.exec(CREDIT) }
      assert_equal 1, srv.connections
    end
  end

  def test_a_stream_the_block_finished_or_left_through_its_ensure_commits_as_always
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(big_script)
      c = connect(srv)
      value = c.transaction do |tx|
        seen = []
        tx.stream(BIG) { |row| seen << row["id"] }   # to its end
        seen << tx.stream(BIG).first(1)[0]["id"]     # left early: drained on the way out
        tx.stream(BIG) { |_row| break }
        rows = tx.stream(BIG)                        # advanced by hand, to its end
        seen << rows.next["id"]
        loop { rows.next }
        seen
      end
      assert_equal [1, 2, 3, 1, 1], value
      assert_equal ["BEGIN", BIG, BIG, BIG, BIG, "COMMIT"], statements(srv)
      assert c.usable?
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_pool_transaction_does_not_take_back_a_connection_whose_block_left_a_stream_open
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(big_script)
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
      held = nil
      e = assert_raises(Skaidb::ConnectionError) do
        pool.transaction do |conn|
          held = conn
          conn.stream(BIG).next
          :returned
        end
      end
      assert_match(/stream .*left open/, e.message)
      assert_hung_up srv, 1
      assert held.finished?
      assert_equal [0, 0], pool.members[0].values_at(:in_use, :idle)
      # the next transaction gets a connection of its own, in autocommit
      assert_equal :done, pool.transaction { |conn| conn.exec(DEBIT) && :done }
      assert_equal ["BEGIN", BIG, "BEGIN", DEBIT, "COMMIT"], statements(srv)
      assert_equal 2, srv.connections
      pool.close
    end
  end

  # ---- a broken connection lets go of its socket ---------------------------
  #
  # The server keeps a session, the transaction open on it and the rows that
  # transaction claimed for as long as the socket is open.

  def test_a_connection_that_breaks_inside_a_transaction_closes_its_socket_at_once
    with_server do |srv|
      # the server stops sending and keeps the session
      srv.handler = FakeSkaidb.scripted(script(DEBIT => :half_close))
      c = connect(srv)
      e = assert_raises(Skaidb::ConnectionError) do
        c.transaction do |tx|
          assert_raises(Skaidb::ConnectionError) { tx.exec(DEBIT) }
          # while the block is still running — not at the connection's next
          # statement after the helper, or at its close
          assert_hung_up srv, 1
          tx.exec(CREDIT)
        end
      end
      assert_match(/lost inside a transaction/, e.message)
      assert_equal ["BEGIN", DEBIT], statements(srv)
      assert_equal 1, srv.connections
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 2, srv.connections
      c.close
    end
  end

  def test_a_block_that_times_out_in_a_round_trip_closes_its_socket_at_once
    with_server do |srv|
      gate = Queue.new
      srv.handler = FakeSkaidb.scripted(script(DEBIT => ->(_req, _conn) { gate.pop && F.mutation(1) }))
      c = connect(srv)
      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { c.transaction { |tx| tx.exec(DEBIT) } } }
      refute c.usable?
      gate << true
      # the client's read timeout is not the server's: the session is alive
      # there, and its transaction open, until the socket closes
      assert_hung_up srv, 1
      assert_equal ["BEGIN", DEBIT], statements(srv) # no ROLLBACK, no COMMIT
      assert_equal 1, srv.connections
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 2, srv.connections
      c.close
    end
  end

  # ---- the pool ------------------------------------------------------------

  def test_pool_transaction_holds_one_connection_for_every_attempt_and_returns_it
    with_server do |srv|
      conflicts = Array.new(3) { F.error(CONFLICT) }
      srv.handler = FakeSkaidb.scripted(script("BEGIN ATOMIC" => F.ddl, "COMMIT" => in_turn(*conflicts, F.ddl)))
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
      held = []
      # attempts, begin and affinity pass through: three conflicts need a fourth run
      value = pool.transaction(attempts: 4, begin: "BEGIN ATOMIC", affinity: "alice") do |conn|
        held << conn
        conn.exec(DEBIT)
        "run #{held.length}"
      end
      assert_equal "run 4", value
      assert_equal 1, held.map(&:object_id).uniq.length
      assert_equal ["BEGIN ATOMIC", DEBIT, "COMMIT"] * 4, statements(srv)
      assert_equal 1, srv.connections
      assert_equal [0, 1], pool.members[0].values_at(:in_use, :idle) # back in the pool
      # the defaults, on the idle connection
      assert_equal :ok, pool.transaction { |_conn| :ok }
      assert_equal %w[BEGIN COMMIT], statements(srv).drop(12)
      # a block that raises or leaves early: rolled back, the connection returned
      assert_raises(RuntimeError) { pool.transaction { |_conn| raise "boom" } }
      left = pool.transaction do |conn|
        conn.exec(DEBIT)
        break :left
      end
      assert_equal :left, left
      assert_equal ["BEGIN", "ROLLBACK", "BEGIN", DEBIT, "ROLLBACK"], statements(srv).drop(14)
      assert_equal 1, srv.connections
      assert_equal [0, 1], pool.members[0].values_at(:in_use, :idle)
      pool.close
    end
  end

  def test_pool_transaction_checks_its_arguments_before_it_checks_out_a_connection
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
      assert_raises(ArgumentError) { pool.transaction(attempts: 0) { |_conn| flunk "the block must not run" } }
      assert_raises(ArgumentError) { pool.transaction }
      assert_equal 0, srv.connections # nothing was dialled
      pool.close
    end
  end
end
