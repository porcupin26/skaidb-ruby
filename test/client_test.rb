# frozen_string_literal: true

# The connection end to end against the in-process fake server: handshake,
# Hello, every response kind, prepared statements, batches, streaming
# (including the abandon/drain rule), multi-set replies, failover, reconnect,
# the session database, the pool and subscribe().
require "test_helper"
require "timeout"

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
      assert_equal :mutation, m.kind
      d = c.exec("CREATE TABLE t (PRIMARY KEY (id))")
      assert_equal [0, 0], [d.cmd_tuples, d.ntuples]
      assert_equal :ddl, d.kind # a bare acknowledgement, told apart from "0 rows affected"
      assert_equal :rows, r.kind
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
      # an extra parameter is refused too, before anything is sent
      sent = srv.requests.length
      e = assert_raises(Skaidb::QueryError) { c.exec_params(sql, [1, [], {}, "EXTRA"]) }
      assert_equal "more parameters (4) than placeholders ($3)", e.message
      assert_equal sent, srv.requests.length
      assert_equal 2, executed.length
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
      # a row with an extra value is refused (never silently truncated), and
      # no frame goes out, so the well-formed rows before it are not applied
      batches = srv.requests.count { |q| q.op == 7 }
      e = assert_raises(Skaidb::QueryError) { c.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", [[10, "a"], [11, "b", "EXTRA"]]) }
      assert_equal "more parameters (3) than placeholders ($2)", e.message
      assert_equal batches, srv.requests.count { |q| q.op == 7 }
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
      # the rows went to the block; the returned Result carries the columns
      assert_equal :stream, ret.kind
      assert_equal %w[id v], ret.fields
      assert_empty ret.rows
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
      res = c.stream("INSERT INTO t VALUES (1)") { |_| flunk "no rows expected" }
      assert_equal :mutation, res.kind
      assert_equal 1, res.cmd_tuples
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
      assert_hung_up srv, 1 # and its socket is closed there and then
      c.close
    end
  end

  def test_a_connection_marked_broken_closes_its_socket_at_once
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        # the server stops sending and keeps the session
        "SELECT lost" => :half_close,
        # a stream whose rest cannot be drained: an unexpected frame follows
        "SELECT weird" => [F.header(["id"]), F.chunk([[1]]), F.ddl],
        "SELECT 1" => F.rows(["c"], [[1]])
      )
      c = connect(srv)
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT lost") }
      refute c.usable?
      # the server is not left holding the session until this connection's
      # next statement, or its close
      assert_hung_up srv, 1
      assert_equal 1, srv.connections
      assert_equal 1, c.exec("SELECT 1")[0]["c"] # re-dialled
      c.stream("SELECT weird") { |_row| break } # the drain gives up on the frame
      refute c.usable?
      assert_hung_up srv, 2
      assert_equal 2, srv.connections
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 3, srv.connections
      c.close
    end
  end

  def test_a_statement_that_times_out_closes_its_socket_at_once
    with_server do |srv|
      gate = Queue.new
      srv.handler = FakeSkaidb.scripted(
        "SELECT slow" => ->(_req, _conn) { gate.pop && F.rows(["c"], [["slow"]]) },
        "SELECT 1" => F.rows(["c"], [[1]])
      )
      c = connect(srv)
      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { c.exec("SELECT slow") } }
      refute c.usable?
      gate << true
      assert_hung_up srv, 1
      assert_equal 1, srv.connections
      assert_equal 1, c.exec("SELECT 1")[0]["c"] # its own reply, on a new socket
      assert_equal 2, srv.connections
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

  def test_a_streamed_call_that_emits_returns_its_result_sets
    # One ResultSets frame, as exec receives it: [a: x, y] then [b: z].
    sets = F.result_sets([[%w[a], [["x"], ["y"]]], [%w[b], [["z"]]]])
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        "CALL report(?)" => sets, # with parameters: OP_QUERY_STREAM_PARAMS, $1 sent as ?
        "CALL report()" => sets,  # without: OP_QUERY_STREAM
        "SELECT 1" => F.rows(["c"], [[1]])
      )
      c = connect(srv)
      [["CALL report($1)", [5]], ["CALL report()", []]].each do |sql, params|
        seen = []
        res = c.stream(sql, params) { |row| seen << row }
        # the block gets what exec's Result yields: the call's final result ...
        assert_equal [{ "b" => "z" }], seen, sql
        # ... and the return value is that Result, every set in order behind it
        assert_equal [:rows, %w[b], [["z"]]], [res.kind, res.fields, res.rows]
        assert_equal "xy|z", res.result_sets.map { |s| s.rows.flatten.join }.join("|"), sql
        assert_equal [%w[a], %w[b]], res.result_sets.map(&:fields)
        assert c.usable?
      end
      assert_equal [9, 5], srv.requests.map(&:op).reject { |op| op == 8 }
      assert_equal [5], srv.requests.find { |q| q.op == 9 }.params
      # the Enumerator form; and nothing is in flight, so the block may use the connection
      assert_equal [{ "b" => "z" }], c.stream("CALL report()").to_a
      c.stream("CALL report()") { |_| assert_equal 1, c.exec("SELECT 1")[0]["c"] }
      # nothing was left on the socket: the same connection reads its own reply
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 1, srv.connections
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

  # ---- a reply that cannot be read -----------------------------------------
  #
  # A tag the protocol does not have, or a message shorter than its own
  # fields say: the peer is not speaking the protocol, and what follows on
  # the socket cannot be placed. Such a connection carries nothing more.

  ONE = "SELECT 1"
  ONE_ROW = F.rows(["c"], [[1]])

  # The connection is retired — not usable, its socket closed at once — and
  # the next statement runs on a new one.
  def assert_dropped(srv, conn, what)
    refute conn.usable?, what
    assert_hung_up srv, 1, what
    assert_equal 1, srv.connections, what
    assert_equal 1, conn.exec(ONE)[0]["c"], what
    assert_equal 2, srv.connections, what
    assert conn.usable?, what
  end

  def test_a_reply_that_cannot_be_read_drops_the_connection
    rows = F.rows(%w[id name], [[1, "Ada"]])
    bad_value = [0].pack("C") + [1].pack("V") + F.str("c") + [1].pack("V") + [1].pack("V") + [1].pack("V") + "\x63".b
    replies = {
      "an unknown response tag" => "\x09".b,
      "an empty frame" => "".b,
      "Rows cut short" => rows[0, rows.bytesize - 3],
      "a Mutation cut short" => F.mutation(1)[0, 5],
      "an Error cut short" => F.error("no such table")[0, 9],
      "ResultSets cut short" => F.result_sets([[%w[a], [[1]]]])[0, 7],
      "a value of an unknown type" => bad_value
    }
    calls = {
      "exec" => ->(c) { c.exec("SELECT x") },
      "exec_params, sent as text" => ->(c) { c.exec_params("SELECT x") },
      "exec_params, prepared" => ->(c) { c.exec_params("SELECT $1", [1]) },
      "exec_prepared" => ->(c) { c.exec_prepared(c.prepare_server("SELECT ?")[0], [1], 1) },
      "exec_batch" => ->(c) { c.exec_batch("SELECT $1", [[1], [2]]) }
    }
    replies.to_a.product(calls.to_a).each do |(reply_name, reply), (call_name, call)|
      what = "#{reply_name}, answering #{call_name}"
      with_server do |srv|
        srv.handler = FakeSkaidb.scripted(
          { "SELECT x" => reply, ONE => ONE_ROW },
          prepared: { "SELECT ?" => 1 }, on_execute: ->(_s, _req) { reply }, on_batch: ->(_s, _req) { reply }
        )
        c = connect(srv)
        assert_raises(Skaidb::ConnectionError, what) { call.call(c) }
        assert_dropped srv, c, what
        c.close
      end
    end
  end

  def test_a_prepare_reply_that_cannot_be_read_drops_the_connection
    replies = {
      "an unknown response tag" => ["\x09".b, Skaidb::QueryError],
      "an empty frame" => ["".b, Skaidb::ConnectionError],
      "Prepared cut short" => [F.prepared(7, 1)[0, 4], Skaidb::ConnectionError],
      "an Error cut short" => [F.error("cannot prepare this statement")[0, 9], Skaidb::ConnectionError]
    }
    calls = {
      "exec_params" => ->(c) { c.exec_params("SELECT $1", [1]) },
      "exec_batch" => ->(c) { c.exec_batch("SELECT $1", [[1]]) },
      "prepare_server" => ->(c) { c.prepare_server("SELECT ?") }
    }
    replies.to_a.product(calls.to_a).each do |(reply_name, (reply, error)), (call_name, call)|
      what = "#{reply_name}, answering the prepare of #{call_name}"
      with_server do |srv|
        srv.handler = ->(req, _conn) { req.op == 2 ? reply : (req.op == 1 ? ONE_ROW : nil) }
        c = connect(srv)
        assert_raises(error, what) { call.call(c) }
        assert_dropped srv, c, what
        c.close
      end
    end
  end

  def test_a_stream_reply_that_cannot_be_read_drops_the_connection
    header = F.header(%w[id name])
    chunk = F.chunk([[1, "Ada"], [2, "Linus"]])
    replies = {
      "an unknown response tag" => ["\x09".b, Skaidb::QueryError],
      "an empty frame" => ["".b, Skaidb::ConnectionError],
      "a Mutation cut short" => [F.mutation(1)[0, 5], Skaidb::ConnectionError],
      "an Error cut short" => [F.error("no such table")[0, 9], Skaidb::ConnectionError],
      "ResultSets cut short" => [F.result_sets([[%w[a], [[1]]]])[0, 7], Skaidb::ConnectionError],
      "a header cut short" => [[header[0, header.bytesize - 2], chunk, F.rows_end], Skaidb::ConnectionError],
      # the frames after it are whole, so the reply's end could be found —
      # by a peer that is not to be trusted with where it is
      "a chunk cut short" => [[header, chunk[0, chunk.bytesize - 3], F.rows_end], Skaidb::ConnectionError],
      "an empty frame after the header" => [[header, "".b, F.rows_end], Skaidb::ConnectionError],
      "an Error cut short after a chunk" =>
        [[header, chunk, F.error("scan budget exceeded")[0, 9], F.rows_end], Skaidb::ConnectionError]
    }
    calls = {
      "stream" => ->(c) { c.stream("SELECT x") { |_row| nil } },
      "stream, as an Enumerator" => ->(c) { c.stream("SELECT x").to_a },
      "stream with parameters" => ->(c) { c.stream("SELECT x WHERE id > $1", [0]) { |_row| nil } }
    }
    replies.to_a.product(calls.to_a).each do |(reply_name, (reply, error)), (call_name, call)|
      what = "#{reply_name}, answering #{call_name}"
      with_server do |srv|
        srv.handler = FakeSkaidb.scripted("SELECT x" => reply, "SELECT x WHERE id > ?" => reply, ONE => ONE_ROW)
        c = connect(srv)
        assert_raises(error, what) { call.call(c) }
        assert_dropped srv, c, what
        c.close
      end
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

  def test_a_connect_that_fails_after_the_handshake_closes_its_socket
    interrupt = Class.new(Exception) # rubocop:disable Lint/InheritException
    with_server do |srv|
      gate = Queue.new
      srv.handler = lambda do |req, _conn|
        next gate.pop && F.ddl if req.op == 8 && srv.hellos.length == 2 # the second connection's Hello is sat on
        next nil if req.op == 8

        F.error(%(database "nope" does not exist))
      end
      # the handshake succeeded, so the server holds a session; the database
      # is refused, so the caller gets an error and no connection to close
      e = assert_raises(Skaidb::QueryError) { connect(srv, database: "nope") }
      assert_equal %(database "nope" does not exist), e.message
      assert_hung_up srv, 1 # at once, not when the collector comes to it
      # the same for a connect cut short after its handshake
      worker = Thread.new do
        Thread.current.report_on_exception = false
        connect(srv)
      end
      until_true { srv.hellos.length == 2 }
      until_true { worker.status == "sleep" }
      worker.raise(interrupt)
      assert_raises(interrupt) { worker.join(2) || flunk("the connect went on waiting") }
      gate << true
      assert_hung_up srv, 2
      # and a pool's checkout
      pool = Skaidb::Pool.new(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret", database: "nope")
      assert_raises(Skaidb::QueryError) { pool.checkout }
      assert_hung_up srv, 3
      pool.close
    end
  end

  def test_a_connect_that_reaches_no_endpoint_prints_no_warning
    dead = TCPServer.new("127.0.0.1", 0)
    dead_port = dead.addr[1]
    dead.close
    # ruby -w, whatever the suite was started with: before Ruby 3.0 it
    # reports an instance variable read before anything was assigned to it
    _out, err = capture_io do
      verbose = $VERBOSE
      $VERBOSE = true
      begin
        assert_raises(Skaidb::ConnectionError) { Skaidb.connect(host: "127.0.0.1", port: dead_port, timeout: 1) }
      ensure
        $VERBOSE = verbose
      end
    end
    assert_equal "", err
  end

  # A connection given its endpoints in a fixed order, as a pool gives them.
  def connect_in_order(*servers, **kw)
    opts = Skaidb.connection_options(user: "ada", password: "secret", **kw)
    Skaidb::Connection.new(**opts, endpoints: servers.map { |s| ["127.0.0.1", s.port] })
  end

  def test_a_dial_that_moves_on_to_the_next_endpoint_is_not_left_marked_broken
    with_server do |down|
      with_server do |srv|
        down.refuse = true # its port accepts, then hangs up where the handshake's reply should be
        srv.handler = FakeSkaidb.scripted(ONE => ONE_ROW, %(USE "app") => F.ddl)
        c = connect_in_order(down, srv)
        assert_equal "127.0.0.1:#{srv.port}", c.endpoint
        # the socket that answered is a healthy one: nothing about it is broken
        assert c.usable?
        assert_equal 1, c.exec(ONE)[0]["c"]
        assert_equal 1, srv.connections # ... and the statement ran on it, not on a second one
        c.close
        # with a database to enter: one USE, on that one socket
        c = connect_in_order(down, srv, database: "app")
        assert c.usable?
        assert_equal 1, c.exec(ONE)[0]["c"]
        assert_equal 2, srv.connections
        assert_equal 1, srv.requests.count { |q| q.sql == %(USE "app") }
        c.close
      end
    end
  end

  def test_a_re_dial_that_moves_on_to_the_next_endpoint_is_not_left_marked_broken
    with_server do |first|
      with_server do |second|
        [first, second].each { |s| s.handler = FakeSkaidb.scripted(ONE => ONE_ROW, "SELECT lost" => :close) }
        c = connect_in_order(first, second)
        assert_equal "127.0.0.1:#{first.port}", c.endpoint
        assert_raises(Skaidb::ConnectionError) { c.exec("SELECT lost") }
        first.refuse = true # the member is going down: the re-dial tries it first, in vain
        assert_equal 1, c.exec(ONE)[0]["c"]
        assert_equal "127.0.0.1:#{second.port}", c.endpoint
        assert c.usable?
        assert_equal 1, c.exec(ONE)[0]["c"]
        assert_equal 1, second.connections
        c.close
      end
    end
  end

  def test_a_pool_keeps_the_connection_whose_dial_moved_on_to_another_member
    with_server do |down|
      with_server do |srv|
        down.refuse = true
        srv.handler = FakeSkaidb.scripted(ONE => ONE_ROW)
        pool = Skaidb::Pool.new(seeds: ["127.0.0.1:#{down.port}", "127.0.0.1:#{srv.port}"], user: "ada",
                                password: "secret", load_balancing: :round_robin, eject_errors: 100)
        # round robin: one of the two checkouts dials the member that is down first
        held = Array.new(2) { pool.checkout }
        held.each { |c| assert_equal 1, c.exec(ONE)[0]["c"] }
        # each got the socket its dial made; none was thrown away as broken and dialled again
        assert_equal 2, srv.connections
        held.each { |c| pool.checkin(c) }
        pool.close
      end
    end
  end

  def test_a_lost_connection_is_re_dialled_on_the_next_statement_and_prepared_ids_are_dropped
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted(
        # the server takes the statement and goes away instead of answering
        { "SELECT 1" => F.rows(["c"], [[1]]), %(USE "app") => F.ddl, "SELECT lost" => :close },
        prepared: { "SELECT ?" => 1 }, on_execute: ->(_s, req) { F.rows(["p"], [[req.params[0]]]) }
      )
      c = connect(srv, database: "app")
      assert_equal 7, c.exec_params("SELECT $1", [7])[0]["p"]
      # lost under a statement: that statement may have run, so it is not
      # sent again — it raises, and the one after it re-dials
      assert_raises(Skaidb::ConnectionError) { c.exec("SELECT lost") }
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

  def test_a_re_dial_that_fails_is_tried_again_by_the_next_statement
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("SELECT 1" => F.rows(["c"], [[1]]))
      c = connect(srv)
      srv.refuse = true # the server is down: its port accepts, then hangs up
      restart(srv, c)
      3.times do
        e = assert_raises(Skaidb::ConnectionError) { c.exec("SELECT 1") } # re-dials, in vain
        assert_match(/no reachable endpoint/, e.message)
      end
      refute c.usable?
      refute c.finished? # still down is not closed
      srv.refuse = false # ... and it is back
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert c.usable?
      c.close
      assert c.finished?
    end
  end

  def test_a_re_dial_cut_short_does_not_leave_a_half_made_connection_to_the_next_statement
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with
    with_server do |srv|
      gate = Queue.new
      answers = FakeSkaidb.scripted("SELECT 1" => F.rows(["c"], [[1]]), "SELECT 2" => F.rows(["c"], [[2]]))
      hellos = 0
      srv.handler = lambda do |req, conn|
        next answers.call(req, conn) unless req.op == 8

        (hellos += 1) == 2 ? (gate.pop && F.ddl) : F.ddl # the second connection's Hello is sat on
      end
      c = connect(srv)
      restart(srv, c)
      worker = Thread.new do
        Thread.current.report_on_exception = false
        c.exec("SELECT 1") # re-dials: handshake, then Hello — whose reply does not come
      end
      begin
        until_true { srv.hellos.length == 2 }
        until_true { worker.status == "sleep" }
        worker.raise(interrupt)
        assert_raises(interrupt) { worker.join(2) || flunk("the re-dial went on waiting") }
      ensure
        gate << true # Hello's reply now arrives on the half-made connection
      end
      # the next statement reads its own reply — not Hello's — on a third socket
      assert_equal [[2]], c.exec("SELECT 2").rows
      assert_equal 3, srv.connections
      c.close
    end
  end

  def test_a_re_dial_cut_short_in_its_handshake_does_not_leave_a_half_made_connection_either
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with: not a StandardError
    cuts = {
      "an exception raised into the thread" => ->(thread) { thread.raise(interrupt) },
      "Thread#kill" => ->(thread) { thread.kill }
    }
    cuts.each do |cut_name, cut|
      what = "the handshake cut short by #{cut_name}"
      with_server do |srv|
        gate = Queue.new
        srv.handler = FakeSkaidb.scripted(ONE => ONE_ROW, "SELECT 2" => F.rows(["c"], [[2]]), "SELECT lost" => :close)
        srv.on_auth_start = ->(number) { gate.pop if number == 2 } # the second connection's challenge is sat on
        c = connect(srv)
        assert_raises(Skaidb::ConnectionError) { c.exec("SELECT lost") } # the next statement re-dials
        worker = Thread.new do
          Thread.current.report_on_exception = false
          c.exec(ONE) # re-dials: AuthStart is out, the challenge does not come
        end
        begin
          until_true { srv.connections == 2 }
          until_true { worker.status == "sleep" }
          cut.call(worker)
          begin
            worker.join(2) || flunk("#{what}: the re-dial went on waiting")
          rescue interrupt
            nil
          end
          # a socket in the middle of its handshake is no connection
          refute c.usable?, what
        ensure
          gate << true # the challenge now arrives on the half-made connection
        end
        # the next statement reads its own reply — not the challenge — on a third socket
        assert_equal [[2]], c.exec("SELECT 2").rows, what
        assert_equal 3, srv.connections, what
        assert c.usable?, what
        c.close
      end
    end
  end

  def test_a_round_trip_cut_short_retires_the_socket_instead_of_leaving_its_reply_to_the_next_statement
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with: not a StandardError
    calls = {
      "exec" => ->(c) { c.exec("SELECT slow") },
      "stream" => ->(c) { c.stream("SELECT slow") { |_| nil } }
    }
    cuts = {
      "an exception raised into the thread" => ->(thread) { thread.raise(interrupt) },
      "Thread#kill" => ->(thread) { thread.kill }
    }
    calls.to_a.product(cuts.to_a).each do |(call_name, call), (cut_name, cut)|
      what = "#{call_name}, cut short by #{cut_name}"
      with_server do |srv|
        gate = Queue.new # the server sits on the statement until the gate opens
        slow = lambda do |req, _conn|
          gate.pop
          req.op == 5 ? [F.header(["c"]), F.chunk([["slow"]]), F.rows_end] : F.rows(["c"], [["slow"]])
        end
        srv.handler = FakeSkaidb.scripted(
          { "SELECT slow" => slow, "SELECT 1" => F.rows(["c"], [[1]]) },
          prepared: { "SELECT ?" => 1 }, on_execute: ->(_s, req) { F.rows(["p"], [[req.params[0]]]) }
        )
        c = connect(srv)
        assert_equal 7, c.exec_params("SELECT $1", [7])[0]["p"] # prepared, and cached
        worker = Thread.new do
          Thread.current.report_on_exception = false
          call.call(c)
        end
        until_true { srv.requests.any? { |q| q.sql == "SELECT slow" } } # the request is out, its reply is not
        cut.call(worker)
        begin
          worker.join(5) || flunk("#{what}: the thread did not end")
        rescue interrupt
          nil
        end
        # no transport error happened, yet the socket is no longer at a request boundary
        refute c.usable?, what
        gate << true # the late reply finds the old socket closed
        assert_hung_up srv, 1, what
        # the next statement reads its own reply, on a new socket — a cached
        # prepared statement included (prepared again there)
        assert_equal 8, c.exec_params("SELECT $1", [8])[0]["p"], what
        assert_equal 1, c.exec("SELECT 1")[0]["c"], what
        assert_equal 2, srv.connections, what
        assert_equal 2, srv.requests.count { |q| q.op == 2 }, what
        c.close
      end
    end
  end

  # A stream whose server sends the header, one chunk and the first +part+
  # bytes of the next frame, then nothing until the gate opens.
  def stalled_stream(gate, part)
    second = FakeSkaidb.frame(F.chunk([[2]]))
    lambda do |_req, conn|
      conn[:sock].write(FakeSkaidb.frame(F.header(["id"])) + FakeSkaidb.frame(F.chunk([[1]])) + second[0, part])
      gate.pop
      conn[:sock].write(second[part..] + FakeSkaidb.frame(F.rows_end))
      []
    end
  end

  def test_a_stream_cut_short_while_it_reads_a_frame_retires_the_socket_instead_of_draining_it
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with
    stalls = { "between two frames" => 0, "in the middle of a frame" => 6 }
    cuts = {
      "an exception raised into the thread" => ->(thread) { thread.raise(interrupt) },
      "Thread#kill" => ->(thread) { thread.kill }
    }
    stalls.to_a.product(cuts.to_a).each do |(stall_name, part), (cut_name, cut)|
      what = "stalled #{stall_name}, cut short by #{cut_name}"
      with_server do |srv|
        gate = Queue.new
        srv.handler = FakeSkaidb.scripted("SELECT slow" => stalled_stream(gate, part),
                                          "SELECT 1" => F.rows(["c"], [[1]]))
        c = connect(srv)
        seen = Queue.new
        worker = Thread.new do
          Thread.current.report_on_exception = false
          c.stream("SELECT slow") { |row| seen << row["id"] }
        end
        begin
          assert_equal 1, seen.pop
          until_true { worker.status == "sleep" } # back in the stream, waiting for the next frame
          cut.call(worker)
          # the exception is not held back until the server has sent the rest
          # (and what is left of a frame read half-way is not a frame to drain)
          begin
            worker.join(2) || flunk("#{what}: the stream went on reading")
          rescue interrupt
            nil
          end
          refute c.usable?, what
        ensure
          gate << true # the server goes on: the rest of the stream finds the socket closed
        end
        assert_hung_up srv, 1, what
        assert_equal 1, srv.connections, what
        # the next statement reads its own reply, on a new socket
        assert_equal 1, c.exec("SELECT 1")[0]["c"], what
        assert_equal 2, srv.connections, what
        c.close
      end
    end
  end

  def test_a_stream_cut_short_between_its_header_and_its_first_row_retires_the_socket
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with
    big = "SELECT * FROM big"
    calls = {
      "stream" => ->(c, seen) { c.stream(big) { |row| seen << row } },
      "stream, as an Enumerator" => ->(c, seen) { c.stream(big).each { |row| seen << row } },
      "stream with parameters" => ->(c, seen) { c.stream("SELECT * FROM big WHERE id > $1", [0]) { |row| seen << row } }
    }
    calls.each do |what, call|
      with_server do |srv|
        reply = [F.header(["id"]), F.chunk([[1], [2]]), F.chunk([[3]]), F.rows_end]
        srv.handler = FakeSkaidb.scripted(big => reply, "SELECT * FROM big WHERE id > ?" => reply, ONE => ONE_ROW,
                                          "SELECT 2" => F.rows(["c"], [[2]]))
        c = connect(srv)
        seen = []
        # the header frame has been read; the exception lands before the
        # stream has taken up the frames that follow it
        assert_raises(interrupt, what) { cut_after_the_reply(c, interrupt) { call.call(c, seen) } }
        assert_empty seen, what
        # those frames are still coming, so nothing more goes down that
        # socket: the connection is retired, not left looking idle
        refute c.usable?, what
        assert_hung_up srv, 1, what
        assert_equal 1, srv.connections, what
        # each statement after it reads its own reply — not a chunk of the stream
        assert_equal [1, 2], [ONE, "SELECT 2"].map { |sql| c.exec(sql)[0]["c"] }, what
        assert_equal 2, srv.connections, what
        assert c.usable?, what
        c.close
      end
    end
  end

  def test_a_drain_cut_short_retires_the_socket_instead_of_leaving_the_stream_to_the_next_statement
    interrupt = Class.new(Exception) # an Interrupt, or what Timeout.timeout unwinds with
    cuts = {
      "an exception raised into the thread" => ->(thread) { thread.raise(interrupt) },
      "Thread#kill" => ->(thread) { thread.kill }
    }
    cuts.each do |cut_name, cut|
      what = "the drain cut short by #{cut_name}"
      with_server do |srv|
        gate = Queue.new
        srv.handler = FakeSkaidb.scripted(
          "SELECT slow" => stalled_stream(gate, 0),
          "SELECT 1" => F.rows(["c"], [[1]]), "SELECT 2" => F.rows(["c"], [[2]]), "SELECT 3" => F.rows(["c"], [[3]])
        )
        c = connect(srv)
        left = Queue.new
        worker = Thread.new do
          Thread.current.report_on_exception = false
          c.stream("SELECT slow") do |_row|
            left << true
            break # leaves the stream: what the server still sends is drained on the way out
          end
        end
        begin
          left.pop
          until_true { worker.status == "sleep" } # the drain waits for the next frame
          cut.call(worker)
          begin
            worker.join(2) || flunk("#{what}: the drain went on reading")
          rescue interrupt
            nil
          end
        ensure
          gate << true # the server sends the rest of the stream
        end
        # each statement reads its own reply — not a chunk the drain left
        # behind, and not the reply of the statement before it
        assert_equal [1, 2, 3], (1..3).map { |n| c.exec("SELECT #{n}")[0]["c"] }, what
        assert c.usable?, what
        assert_equal 2, srv.connections, what
        c.close
      end
    end
  end

  def test_a_stream_that_times_out_waiting_for_a_frame_raises_at_the_timeout
    with_server do |srv|
      gate = Queue.new
      srv.handler = FakeSkaidb.scripted("SELECT slow" => stalled_stream(gate, 0), "SELECT 1" => F.rows(["c"], [[1]]))
      c = connect(srv)
      seen = []
      # the server goes on after 3 s, so a stream that waits for the rest of
      # the reply instead of raising is a failure here, not a hang
      late = Thread.new { sleep(3) && gate << true }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { c.stream("SELECT slow") { |row| seen << row["id"] } } }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
      assert_equal [1], seen
      refute c.usable?
      late.kill
      gate << true # the server goes on: the rest of the stream finds the socket closed
      assert_hung_up srv, 1
      assert_equal 1, srv.connections
      assert_equal 1, c.exec("SELECT 1")[0]["c"]
      assert_equal 2, srv.connections
      c.close
    end
  end

  def test_a_cached_parameterised_statement_re_dials_a_lost_connection_too
    with_server do |srv|
      lost = -1 # the server takes a statement bound to this value and goes away instead of answering
      srv.handler = FakeSkaidb.scripted(
        {}, prepared: { "SELECT ?" => 1, "INSERT INTO t (id) VALUES (?)" => 1 },
        on_execute: ->(_s, req) { req.params[0] == lost ? :close : F.rows(["p"], [[req.params[0]]]) },
        on_batch: ->(_s, req) { req.rows[0][0] == lost ? :close : F.mutation(req.rows.length) }
      )
      c = connect(srv)
      assert_equal 7, c.exec_params("SELECT $1", [7])[0]["p"]
      assert_equal 2, c.exec_batch("INSERT INTO t (id) VALUES ($1)", [[1], [2]])
      assert_raises(Skaidb::ConnectionError) { c.exec_params("SELECT $1", [lost]) } # the loss, under it
      refute c.usable?
      # the cached id is not sent down the dead socket: re-dialled, prepared again
      assert_equal 9, c.exec_params("SELECT $1", [9])[0]["p"]
      assert c.usable?
      assert_equal 2, srv.connections
      assert_equal 3, srv.requests.count { |q| q.op == 2 }
      assert_raises(Skaidb::ConnectionError) { c.exec_batch("INSERT INTO t (id) VALUES ($1)", [[lost]]) }
      assert_equal 1, c.exec_batch("INSERT INTO t (id) VALUES ($1)", [[3]])
      assert_equal 3, srv.connections
      # an id handed out by prepare_server is never sent down another socket:
      # its statement is prepared again on the one that replaced it
      id, = c.prepare_server("SELECT ?")
      assert_raises(Skaidb::ConnectionError) { c.exec_prepared(id, [lost], 1) } # the loss, under it
      prepares = srv.requests.count { |q| q.op == 2 }
      assert_equal 1, c.exec_prepared(id, [1], 1)[0]["p"]
      assert_equal prepares + 1, srv.requests.count { |q| q.op == 2 }
      assert_equal 4, srv.connections
      c.close
    end
  end

  def test_pool_reuses_idle_connections_and_discards_broken_ones
    with_server do |srv|
      srv.handler = FakeSkaidb.scripted("SELECT 1" => F.rows(["c"], [[1]]), "SELECT lost" => :close)
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
      pool.with { |c| assert_raises(Skaidb::ConnectionError) { c.exec("SELECT lost") } }
      assert a.finished?
      pool.with { |c| assert_equal 1, c.exec("SELECT 1")[0]["c"] }
      assert_equal 3, srv.connections
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
