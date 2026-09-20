# frozen_string_literal: true

# The connection end to end against the in-process fake server: handshake,
# Hello, every response kind, prepared statements, batches, streaming
# (including the abandon/drain rule), multi-set replies, failover, reconnect,
# the session database, the pool and subscribe().
require "test_helper"

class ClientTest < Minitest::Test
  include ServerHelpers
  F = FakeSkaidb::F

  def test_connect_runs_scram_verifies_the_server_and_sends_hello
    with_server do |srv|
      c = connect(srv)
      assert c.usable?
      refute c.finished?
      assert_equal 1, srv.hellos.length
      assert_equal %w[ruby] + [Skaidb::VERSION], [srv.hellos[0].name, srv.hellos[0].version]
      c.close
      refute c.usable?
      assert c.finished?
      assert c.closed
      c.close # idempotent
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") }
    end
  end

  def test_wrong_password_is_denied_and_a_forged_server_signature_is_refused
    with_server do |srv|
      e = assert_raises(Skaidb::ConnectionError) { connect(srv, password: "nope") }
      assert_match(/authentication denied: bad password/, e.message)
      srv.corrupt_server_signature = true
      e = assert_raises(Skaidb::ConnectionError) { connect(srv) }
      assert_match(/server signature mismatch/, e.message)
    end
  end

  def test_anonymous_connect_skips_server_verification
    with_server(password: "") do |srv|
      srv.corrupt_server_signature = true
      c = Skaidb.connect(host: "127.0.0.1", port: srv.port)
      assert c.usable?
      c.close
    end
  end

  def test_exec_decodes_rows_mutation_ddl_and_error
    script = {
      "SELECT id, name FROM t" => F.rows(%w[id name], [[1, "Ada"], [2, "Linus"]]),
      "INSERT INTO t VALUES (1)" => F.mutation(3),
      "CREATE TABLE t (PRIMARY KEY (id))" => F.ddl,
      "SELECT nope" => F.error("no such column nope"),
      "SELECT level" => ->(req, _c) { F.rows(["c"], [[req.consistency]]) },
    }
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(script)
      c = connect(srv, consistency: "ONE")
      r = c.exec("SELECT id, name FROM t")
      assert_equal %w[id name], r.fields
      assert_equal %w[id name], r.columns
      assert_equal 2, r.ntuples
      assert_equal 2, r.num_tuples
      assert_equal 2, r.nfields
      assert_equal [[1, "Ada"], [2, "Linus"]], r.rows
      assert_equal [{ "id" => 1, "name" => "Ada" }, { "id" => 2, "name" => "Linus" }], r.to_a
      assert_equal r.to_a, r.values
      assert_equal({ "id" => 2, "name" => "Linus" }, r[1])
      assert_nil r[5]
      assert_equal "Ada", r.getvalue(0, "name")
      assert_equal 2, r.getvalue(1, 0)
      assert_nil r.getvalue(0, "missing")
      assert_equal 0, r.cmd_tuples
      assert_equal [], r.result_sets
      assert_kind_of Enumerator, r.each
      assert_equal %w[Ada Linus], r.map { |row| row["name"] }

      m = c.query("INSERT INTO t VALUES (1)")
      assert_equal [3, [], []], [m.cmd_tuples, m.rows, m.fields]
      d = c.exec("CREATE TABLE t (PRIMARY KEY (id))")
      assert_equal [0, 0], [d.cmd_tuples, d.ntuples]
      e = assert_raises(Skaidb::QueryError) { c.exec("SELECT nope") }
      assert_equal "no such column nope", e.message
      assert c.usable? # a statement error keeps the connection

      assert_equal 0, c.exec("SELECT level")[0]["c"]       # connection default ONE
      assert_equal 2, c.exec_params("SELECT level", [], consistency: :all)[0]["c"]
      c.consistency = :quorum
      assert_equal 1, c.consistency
      assert_equal 1, c.exec("SELECT level")[0]["c"]
      c.close
    end
  end

  def test_parameters_go_through_server_side_prepare_with_typed_values_cached_per_connection
    executed = []
    sql = "SELECT * FROM t WHERE id = $1 AND tags = $2 AND meta = $3 AND id = $1"
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        {}, prepared: { "SELECT * FROM t WHERE id = ? AND tags = ? AND meta = ? AND id = ?" => 4 },
        on_execute: ->(_s, req) { executed << req; F.rows(["ok"], [[true]]) }
      )
      c = connect(srv)
      u = Skaidb::Uuid.random
      t = Time.utc(2020, 1, 2, 3, 4, 5, 678_000)
      meta = { "k" => t, "n" => nil, "b" => "z".b, "d" => BigDecimal("1.25"), "u" => u, "f" => 2.5 }
      r = c.exec_params(sql, [2**62, %w[a b], meta])
      assert_equal true, r[0]["ok"]
      c.exec_params(sql, [1, [], {}])
      assert_equal 1, srv.requests.count { |q| q.op == 2 } # prepared once, then cached
      assert_equal 2, executed.length
      assert_equal [2**62, %w[a b], { "k" => t, "n" => nil, "b" => "z".b, "d" => BigDecimal("1.25"), "u" => u.to_s, "f" => 2.5 }, 2**62],
                   executed[0].params
      assert_equal [1, [], {}, 1], executed[1].params
      assert_equal 1, executed[0].consistency # QUORUM default
      e = assert_raises(Skaidb::QueryError) { c.exec_params(sql, [1, 2]) }
      assert_match(/placeholder \$3 has no parameter/, e.message)
      c.close
    end
  end

  def test_unpreparable_statements_fall_back_to_text_binding
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        { "CREATE TABLE t (PRIMARY KEY (id)) WITH (ttl = 30, name = 'O''Brien')" => F.ddl },
        prepared: {}
      )
      c = connect(srv)
      c.exec_params("CREATE TABLE t (PRIMARY KEY (id)) WITH (ttl = $1, name = $2)", [30, "O'Brien"])
      assert_equal [8, 2, 1], srv.requests.map(&:op)
      # a value with no literal form reports the server's refusal reason too
      e = assert_raises(Skaidb::QueryError) { c.exec_params("CREATE TABLE t2 (x = $1)", [[1, 2]]) }
      assert_match(/cannot bind value of type Array; the server would not prepare the statement: cannot prepare this statement/, e.message)
      c.close
    end
  end

  def test_exec_batch_ships_every_row_in_one_frame
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        {}, prepared: { "INSERT INTO t (id, v) VALUES (?, ?)" => 2 },
        on_batch: ->(_s, req) { req.rows.length == 3 ? F.mutation(3) : F.error("row 1 failed: 1 rows applied") }
      )
      c = connect(srv)
      rows = [[1, "a"], [2, nil], [3, [1, 2]]]
      assert_equal 3, c.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", rows)
      assert_equal 0, c.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", [])
      batch = srv.requests.find { |q| q.op == 7 }
      assert_equal rows, batch.rows
      assert_equal 1, srv.requests.count { |q| q.op == 7 }
      e = assert_raises(Skaidb::QueryError) { c.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", [[1, "a"], [2, "b"]]) }
      assert_match(/row 1 failed/, e.message)
      assert_raises(Skaidb::QueryError) { c.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", [[1]]) }
      assert_raises(Skaidb::QueryError) { c.exec_batch("CREATE TABLE $1", [[1]]) } # unpreparable
      c.close
    end
  end

  def test_stream_yields_rows_chunk_by_chunk_and_drains_on_early_exit
    stream = [F.header(%w[id v]), F.chunk([[1, "a"], [2, "b"]]), F.chunk([[3, "c"]]), F.chunk([]), F.rows_end]
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        "SELECT * FROM big" => stream,
        "INSERT INTO t VALUES (1)" => F.mutation(1),
        "SELECT boom" => [F.header(["id"]), F.chunk([[1]]), F.error("scan budget exceeded")],
        "SELECT 1" => F.rows(["c"], [[1]])
      )
      c = connect(srv)
      seen = []
      ret = c.stream("SELECT * FROM big") { |row| seen << row }
      assert_nil ret
      assert_equal [{ "id" => 1, "v" => "a" }, { "id" => 2, "v" => "b" }, { "id" => 3, "v" => "c" }], seen
      assert c.usable?
      # Enumerator form; abandoning early drains the rest so the next request is clean
      assert_equal [1], c.stream("SELECT * FROM big").first(1).map { |r| r["id"] }
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      # break out of the block
      c.stream("SELECT * FROM big") { |_row| break }
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      # a non-row statement over the streaming opcode
      assert_nil c.stream("INSERT INTO t VALUES (1)") { |_| flunk "no rows expected" }
      # an error after the header ends the stream; rows before it were valid
      got = []
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT boom") { |r| got << r } }
      assert_equal [{ "id" => 1 }], got
      assert_match(/scan budget/, e.message)
      assert c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      # unknown statement: an error before the header
      assert_raises(Skaidb::QueryError) { c.stream("SELECT nope") { |_| nil } }
      c.close
    end
  end

  def test_stream_with_an_unexpected_frame_marks_the_connection_broken
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("SELECT weird" => [F.header(["id"]), F.ddl])
      c = connect(srv)
      e = assert_raises(Skaidb::QueryError) { c.stream("SELECT weird") { |_| nil } }
      assert_match(/unexpected frame/, e.message)
      refute c.usable?
      c.close
    end
  end

  def test_result_sets_from_a_call_that_emits
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("CALL p()" => F.result_sets([[%w[a], [[1], [2]]], [%w[b], [["x"]]]]))
      c = connect(srv)
      r = c.exec("CALL p()")
      assert_equal 2, r.result_sets.length
      assert_equal [[1], [2]], r.result_sets[0].rows
      assert_equal %w[b], r.fields # the LAST set is the result's own rows
      assert_equal [["x"]], r.rows
      c.close
    end
  end

  def test_unknown_response_tag_is_a_connection_error
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("SELECT x" => "\x09".b)
      c = connect(srv)
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT x") }
      c.close
    end
  end

  def test_hello_refused_by_an_old_server_is_ignored
    with_server do |srv|
      srv.handler = ->(req, _c) { req.op == 8 ? F.error("unknown opcode 8") : F.rows(["c"], [[1]]) }
      c = connect(srv)
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      c.close
    end
  end

  def test_database_runs_use_on_every_dial_and_seeds_fail_over
    with_server do |srv|
      srv.handler = ->(_req, _c) { F.ddl }
      dead = TCPServer.new("127.0.0.1", 0)
      dead_port = dead.addr[1]
      dead.close
      c = Skaidb.connect(seeds: ["127.0.0.1:#{dead_port}", "127.0.0.1:#{srv.port}"], user: "ada",
                         password: "secret", database: "app")
      assert_equal [[8, nil], [1, %(USE "app")]], srv.requests.map { |q| [q.op, q.sql] }
      c.close
      e = assert_raises(Skaidb::ConnectionError) do
        Skaidb.connect(seeds: ["127.0.0.1:#{dead_port}"], user: "ada", password: "secret", timeout: 1)
      end
      assert_match(/no reachable endpoint/, e.message)
    end
  end

  def test_a_lost_connection_is_re_dialled_on_the_next_statement_and_prepared_ids_are_dropped
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        { "SELECT 1" => F.rows(["c"], [[1]]), %(USE "app") => F.ddl },
        prepared: { "SELECT ?" => 1 }, on_execute: ->(_s, req) { F.rows(["p"], [[req.params[0]]]) }
      )
      c = connect(srv, database: "app")
      assert_equal 7, c.exec_params("SELECT $1", [7])[0]["p"]
      srv.close_all
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") }
      refute c.usable?
      assert_equal 1, c.exec("SELECT 1")[0]["c"] # transparently reconnected
      assert c.usable?
      assert_equal 2, srv.connections
      assert_equal 2, srv.hellos.length
      assert_equal 2, srv.requests.count { |q| q.op == 1 && q.sql == %(USE "app") }
      assert_equal 8, c.exec_params("SELECT $1", [8])[0]["p"]
      assert_equal 2, srv.requests.count { |q| q.op == 2 } # re-prepared on the new socket
      c.close
    end
  end

  def test_pool_reuses_idle_connections_and_discards_broken_ones
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("SELECT 1" => F.rows(["c"], [[1]]))
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret", maxsize: 1)
      3.times { pool.with { |c| assert_equal 1, c.exec("SELECT 1")[0]["c"] } }
      assert_equal 1, srv.connections
      a = pool.checkout
      b = pool.checkout # a second, beyond maxsize: created, closed on return
      assert_equal 2, srv.connections
      pool.checkin(a)
      pool.checkin(b)
      assert b.finished?
      refute a.finished?
      # a broken connection is dropped, not handed out again
      srv.close_all
      pool.with { |c| assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") } }
      pool.with { |c| assert_equal 1, c.exec("SELECT 1")[0]["c"] }
      pool.close
      assert_raises(Skaidb::Error) { pool.checkout }
      assert_raises(ArgumentError) { Skaidb::Pool.new(maxsize: 0) }
    end
  end

  def test_subscribe_pages_the_stream_log_with_a_keyset_cursor
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        { "SELECT id, op, k, ts, doc FROM _stream_orders ORDER BY id LIMIT 500" =>
            F.rows(%w[id op k ts doc], [["a1", "put", "k1", Time.at(1).utc, { "x" => 1 }], ["a2", "put", "k2", Time.at(2).utc, {}]]) },
        prepared: { "SELECT id, op, k, ts, doc FROM _stream_orders WHERE id > ? ORDER BY id LIMIT 500" => 1 },
        on_execute: lambda { |_s, req|
          case req.params
          when ["a2"] then F.rows(%w[id op k ts doc], [["a3", "del", "k1", Time.at(3).utc, nil]])
          when ["zz"] then F.rows(%w[id op k ts doc], [["zz1", "put", "k9", Time.at(9).utc, {}]])
          else F.rows(%w[id op k ts doc], [])
          end
        }
      )
      c = connect(srv)
      got = []
      c.subscribe("orders", poll: 0.01) do |ev|
        got << ev["id"]
        break if got.length == 3
      end
      assert_equal %w[a1 a2 a3], got
      assert_equal [["a2"]], srv.requests.select { |q| q.op == 3 }.map(&:params) # keyset cursor = last id seen
      # resuming from a checkpoint passes it as the cursor
      got = []
      c.subscribe("orders", after: "zz", poll: 0.01) do |ev|
        got << ev["id"]
        break
      end
      assert_equal %w[zz1], got
      assert_equal ["zz"], srv.requests.select { |q| q.op == 3 }.last.params
      c.close
    end
  end
end
