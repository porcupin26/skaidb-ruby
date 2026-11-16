# frozen_string_literal: true

# A connection the server closed while it sat idle — a member restart, a
# failover, an idle timeout. The driver looks at the socket before it writes
# a request: on an idle connection the server sends nothing, so anything to
# read there (an end-of-file, a reset, stray bytes) means the connection is
# gone, and the statement goes out on a new one instead. Nothing was sent on
# the dead socket, so no error reaches the application.
#
# On loopback a write to a closed socket fails at once, which hides the
# case: over a real network that write SUCCEEDS and only the read fails. The
# fake server's half-close reproduces it here — it stops sending, keeps the
# socket open, and goes on reading and recording whatever arrives.
require "test_helper"
require "timeout"
require "tmpdir"

class IdleLossTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  ONE = "SELECT 1"
  INSERT = "INSERT INTO notes (id) VALUES (1)"
  BIG = "SELECT id FROM big"
  WRITE = "UPDATE t SET v = $1 WHERE id = $2"
  QWRITE = "UPDATE t SET v = ? WHERE id = ?"

  def handler(overrides = {})
    FakeSkaidb.scripted(
      { ONE => F.rows(["c"], [[1]]), INSERT => F.mutation(1), "BEGIN" => F.ddl, "COMMIT" => F.ddl,
        "ROLLBACK" => F.ddl, %(USE "app") => F.ddl,
        BIG => [F.header(["id"]), F.chunk([[1], [2]]), F.rows_end],
        "SELECT id FROM big WHERE id > ?" => [F.header(["id"]), F.chunk([[2]]), F.rows_end] }.merge(overrides),
      prepared: { QWRITE => 2 }, on_execute: ->(_sql, _req) { F.mutation(1) }
    )
  end

  # Every way the server can take an idle connection away.
  def losses
    {
      "half-closed (the write still succeeds)" => ->(srv) { srv.half_close_all },
      "closed" => ->(srv) { srv.close_all },
      "reset" => ->(srv) { srv.reset_all }
    }
  end

  # Every call that runs a statement, with what it returns.
  def calls
    {
      "exec, a read" => [->(c) { c.exec(ONE)[0]["c"] }, 1],
      "exec, a write" => [->(c) { c.exec(INSERT).cmd_tuples }, 1],
      "exec_params without parameters" => [->(c) { c.exec_params(INSERT).cmd_tuples }, 1],
      "exec_params, prepared before the loss" => [->(c) { c.exec_params(WRITE, [1, 2]).cmd_tuples }, 1],
      "exec_batch" => [->(c) { c.exec_batch(WRITE, [[1, 2], [3, 4]]) }, 2],
      "stream" => [->(c) { c.stream(BIG).map { |row| row["id"] } }, [1, 2]],
      "stream with parameters" => [->(c) { c.stream("SELECT id FROM big WHERE id > $1", [1]).map { |r| r["id"] } }, [2]],
      "transaction" => [->(c) { c.transaction { |tx| tx.exec(INSERT).cmd_tuples } }, 1]
    }
  end

  # What arrived on connection +number+ (Hello left out), as [op, sql] pairs.
  def arrived(srv, number)
    srv.requests.select { |q| q.conn == number && q.op != 8 }.map { |q| [q.op, q.sql] }
  end

  def test_a_connection_lost_while_idle_costs_no_statement
    losses.to_a.product(calls.to_a).each do |(loss_name, lose), (call_name, (call, value))|
      what = "#{call_name} on a connection #{loss_name}"
      with_server do |srv|
        srv.handler = handler
        c = connect(srv, database: "app")
        assert_equal 1, c.exec_params(WRITE, [0, 0]).cmd_tuples # prepared, and cached, on the first connection
        before = arrived(srv, 1)
        lose.call(srv)
        let_the_loss_arrive(c)
        # no error reaches the caller: the statement runs, on a second connection
        assert_equal value, call.call(c), what
        assert_equal 2, srv.connections, what
        assert c.usable?, what
        # nothing was written to the dead socket — the server went on
        # reading it, and saw nothing more
        assert_equal before, arrived(srv, 1), what
        # and the new session was set up as every re-dial sets one up: the
        # database entered before anything else
        assert_equal [1, %(USE "app")], arrived(srv, 2).first, what
        c.close
      end
    end
  end

  def test_an_id_from_prepare_server_is_prepared_again_on_the_connection_that_replaces_a_lost_one
    losses.each do |loss_name, lose|
      with_server do |srv|
        srv.handler = handler
        c = connect(srv)
        id, = c.prepare_server(QWRITE)
        before = arrived(srv, 1)
        lose.call(srv)
        let_the_loss_arrive(c)
        assert_equal 1, c.exec_prepared(id, [1, 2], 1).cmd_tuples, loss_name
        assert_equal before, arrived(srv, 1), loss_name
        assert_equal [[2, QWRITE], [3, nil]], arrived(srv, 2), loss_name # prepared there first, then run
        c.close
      end
    end
  end

  def test_a_connection_that_is_alive_is_not_dialled_again
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      20.times { assert_equal 1, c.exec(ONE)[0]["c"] }
      assert_equal [1, 2], c.stream(BIG).map { |row| row["id"] }
      assert_equal 1, c.exec_params(WRITE, [1, 2]).cmd_tuples
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_stray_bytes_on_an_idle_connection_retire_it
    with_server do |srv|
      srv.handler = handler(
        # a reply, and after it a frame nobody asked for
        "SELECT chatty" => lambda do |_req, conn|
          conn[:sock].write(FakeSkaidb.frame(F.rows(["c"], [[7]])) + FakeSkaidb.frame(F.rows(["c"], [[8]])))
          []
        end
      )
      c = connect(srv)
      assert_equal 7, c.exec("SELECT chatty")[0]["c"]
      let_the_loss_arrive(c) # the second frame is there to be read
      # the next statement does not take it for its reply
      assert_equal 1, c.exec(ONE)[0]["c"]
      assert_equal 2, srv.connections
      c.close
    end
  end

  # ---- the pool ------------------------------------------------------------

  def pool_for(srv, **kw)
    Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret", **kw)
  end

  def test_a_pooled_connection_lost_while_idle_is_not_handed_out
    losses.each do |loss_name, lose|
      with_server do |srv|
        srv.handler = handler
        pool = pool_for(srv, maxsize: 2)
        idle = Array.new(2) { pool.checkout }
        idle.each { |c| assert_equal 1, c.exec(ONE)[0]["c"] }
        idle.each { |c| pool.checkin(c) }
        before = [arrived(srv, 1), arrived(srv, 2)]
        lose.call(srv)
        let_the_loss_arrive(*idle)
        # the checkout hands out a connection that works, not one of the dead
        pool.with do |c|
          refute idle.any? { |dead| dead.equal?(c) }, loss_name
          assert_equal 1, c.exec(INSERT).cmd_tuples, loss_name
        end
        assert_equal 3, srv.connections, loss_name
        assert_equal before, [arrived(srv, 1), arrived(srv, 2)], loss_name
        assert idle.all?(&:finished?), loss_name
        assert_equal [0, 1], pool.members[0].values_at(:in_use, :idle), loss_name
        # the member is not blamed for connections that were closed while idle
        assert_equal :ready, pool.members[0][:state], loss_name
        # the pool's transaction opens on a live connection too
        lose.call(srv)
        sleep 0.1
        assert_equal :done, pool.transaction { |conn| conn.exec(INSERT) && :done }, loss_name
        assert_equal 4, srv.connections, loss_name
        pool.close
      end
    end
  end

  def test_a_pooled_connection_lost_while_its_borrower_holds_it_idle_is_replaced_under_the_borrower
    with_server do |srv|
      srv.handler = handler
      pool = pool_for(srv, database: "app")
      pool.with do |c|
        assert_equal 1, c.exec(ONE)[0]["c"]
        srv.half_close_all
        let_the_loss_arrive(c)
        assert_equal 1, c.exec(INSERT).cmd_tuples
        assert_equal [[1, %(USE "app")], [1, INSERT]], arrived(srv, 2)
      end
      assert_equal 2, srv.connections
      assert_equal [0, 1], pool.members[0].values_at(:in_use, :idle)
      pool.close
    end
  end

  # ---- inside a transaction nothing changes (PROTOCOL.md §6 rule 7) --------

  def test_inside_the_transaction_helper_a_connection_lost_while_idle_is_the_transactions_loss
    losses.each do |loss_name, lose|
      with_server do |srv|
        srv.handler = handler
        c = connect(srv)
        before = nil
        e = assert_raises(Skaidb::ConnectionError, loss_name) do
          c.transaction do |tx|
            tx.exec(INSERT)
            before = arrived(srv, 1)
            lose.call(srv)
            let_the_loss_arrive(tx)
            # found dead before anything is written: reported, not re-dialled
            assert_raises(Skaidb::ConnectionError, loss_name) { tx.exec(INSERT) }
            assert_raises(Skaidb::ConnectionError, loss_name) { tx.exec(INSERT) }
            :returned
          end
        end
        assert_match(/lost inside a transaction/, e.message, loss_name)
        assert_equal before, arrived(srv, 1), loss_name # no statement, no COMMIT, no ROLLBACK
        assert_equal 1, srv.connections, loss_name
        # after the helper the connection is what it is after any loss
        assert_equal 1, c.exec(ONE)[0]["c"], loss_name
        assert_equal [[1, ONE]], arrived(srv, 2), loss_name
        c.close
      end
    end
  end

  # ---- a connection that is not idle is not looked at ----------------------

  def test_a_statement_from_another_thread_waits_for_a_stream_instead_of_taking_its_frames_for_a_loss
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      seen = []
      other = nil
      # (a look that took the stream's frames for a loss would replace the
      # socket under the stream: bounded, so that is a failure and not a hang)
      Timeout.timeout(10) do
        c.stream(BIG) do |row|
          seen << row["id"]
          next if other

          # the rest of the stream is on the socket, to be read: that is not
          # an idle connection with stray bytes on it
          let_the_loss_arrive(c)
          other = Thread.new { c.exec(ONE)[0]["c"] }
          until_true { other.status == "sleep" } # waiting for the stream to end
        end
      end
      assert_equal 1, other.value
      assert_equal [1, 2], seen
      assert_equal 1, srv.connections
      assert c.usable?
      c.close
    end
  end

  def test_the_look_waits_for_a_round_trip_in_flight
    with_server do |srv|
      gate = Queue.new
      srv.handler = handler("SELECT slow" => ->(_req, _conn) { gate.pop && F.rows(["c"], [["slow"]]) })
      c = connect(srv)
      first = Thread.new { c.exec("SELECT slow")[0]["c"] }
      until_true { srv.requests.any? { |q| q.sql == "SELECT slow" } }
      # another thread's statement, and the look on its own: neither judges
      # the socket while a reply is on its way to it
      second = Thread.new { c.exec(ONE)[0]["c"] }
      looker = Thread.new { c.lost_while_idle? }
      until_true { second.status == "sleep" && looker.status == "sleep" }
      gate << true
      assert_equal ["slow", 1, false], [first.value, second.value, looker.value]
      assert_equal 1, srv.connections
      c.close
    end
  end

  def test_a_stream_read_by_hand_is_not_an_idle_connection
    with_server do |srv|
      srv.handler = handler
      c = connect(srv)
      rows = c.stream(BIG)
      assert_equal 1, rows.next["id"]
      let_the_loss_arrive(c) # frames waiting on the socket, in the middle of the stream
      refute c.lost_while_idle?
      assert_equal 2, rows.next["id"]
      assert_raises(StopIteration) { rows.next }
      refute c.lost_while_idle?
      assert_equal 1, c.exec(ONE)[0]["c"]
      assert_equal 1, srv.connections
      c.close
    end
  end

  # ---- TLS: the look is at the TCP socket ----------------------------------

  def with_tls_server
    Dir.mktmpdir("skaidb-idle-test") do |dir|
      ctx, ca_file = FakeSkaidb.tls(dir)
      with_server(tls: ctx) { |srv| yield srv, ca_file }
    end
  end

  def test_under_tls_a_connection_lost_while_idle_costs_no_statement
    tls_losses = losses.merge("closed with a TLS goodbye" => ->(srv) { srv.close_all_politely })
    tls_losses.each do |loss_name, lose|
      with_tls_server do |srv, ca_file|
        srv.handler = handler
        c = connect(srv, tls_ca: ca_file)
        assert_equal 1, c.exec(ONE)[0]["c"]
        before = arrived(srv, 1)
        lose.call(srv)
        let_the_loss_arrive(c)
        assert_equal 1, c.exec(INSERT).cmd_tuples, loss_name
        assert_equal 2, srv.connections, loss_name
        assert_equal before, arrived(srv, 1), loss_name
        assert_equal [[1, INSERT]], arrived(srv, 2), loss_name
        c.close
      end
    end
  end

  def test_under_tls_stray_bytes_retire_the_connection_wherever_they_are
    arrivals = {
      # a TLS record of its own: still on the TCP socket when the look comes
      "in a record of their own" => ->(sock, reply, stray) { sock.write(reply) && sock.write(stray) },
      # the same record as the reply: decrypted with it, and waiting in the
      # TLS layer's buffer, where the TCP socket shows nothing
      "in the reply's record" => ->(sock, reply, stray) { sock.write(reply + stray) }
    }
    arrivals.each do |where, write|
      with_tls_server do |srv, ca_file|
        srv.handler = handler(
          "SELECT chatty" => lambda do |_req, conn|
            write.call(conn[:sock], FakeSkaidb.frame(F.rows(["c"], [[7]])), FakeSkaidb.frame(F.rows(["c"], [[8]])))
            []
          end
        )
        c = connect(srv, tls_ca: ca_file)
        assert_equal 7, c.exec("SELECT chatty")[0]["c"], where
        sleep 0.1 # the frame nobody asked for has arrived
        # the next statement does not take it for its reply
        assert_equal 1, c.exec(ONE)[0]["c"], where
        assert_equal 2, srv.connections, where
        c.close
      end
    end
  end

  def test_under_tls_a_connection_that_is_alive_is_not_dialled_again
    with_tls_server do |srv, ca_file|
      srv.handler = handler
      c = connect(srv, tls_ca: ca_file)
      20.times { assert_equal 1, c.exec(ONE)[0]["c"] }
      assert_equal [1, 2], c.stream(BIG).map { |row| row["id"] }
      assert_equal 1, c.exec(INSERT).cmd_tuples
      assert_equal 1, srv.connections
      c.close
    end
  end
end
