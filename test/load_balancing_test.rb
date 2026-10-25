# frozen_string_literal: true

# Pool load balancing (PROTOCOL.md §6.1): policies, idle order, health
# ejection and re-admission, member discovery (SHOW ENDPOINTS) and
# read-your-writes affinity — against fake members that each serve many
# connections.
require "test_helper"

# A fake skaidb member: the fake server's SCRAM on every connection, then
# `SELECT …` answers one row naming the member (after +delay+ seconds),
# `SHOW ENDPOINTS` answers +listing+ (a Proc returning the rows),
# `SHOW DATABASES` (the pool's probe) answers no rows, and anything else is
# a one-row mutation. +refuse+ closes each new connection before the
# handshake; +old_server+ answers SHOW ENDPOINTS with a parse error.
class FakeMember
  F = FakeSkaidb::F

  attr_reader :name
  attr_accessor :delay, :old_server, :listing

  def initialize(name)
    @name = name
    @delay = 0.0
    @old_server = false
    @listing = nil
    @srv = FakeSkaidb::Server.new(password: "secret") { |req, _conn| answer(req) }.start
  end

  def port
    @srv.port
  end

  def endpoint
    "127.0.0.1:#{port}"
  end

  def refuse=(on)
    @srv.refuse = on
  end

  # How many times +sql+ reached this member.
  def asked(sql)
    @srv.requests.count { |r| r.sql == sql }
  end

  def stop
    @srv.stop
  end

  private

  def answer(req)
    return nil unless req.op == 1 # Hello is acknowledged by the server

    case req.sql
    when "SHOW ENDPOINTS"
      return F.error("parse error: expected TABLES, found ENDPOINTS") if @old_server || @listing.nil?

      F.rows(%w[endpoint state local], @listing.call)
    when "SHOW DATABASES"
      F.rows(["name"], [])
    when /\ASELECT/
      sleep(@delay) if @delay.positive?
      F.rows(["member"], [[@name]])
    else
      F.mutation(1)
    end
  end
end

module BalancingHelpers
  def setup
    @members = %w[a b c].map { |n| FakeMember.new(n) }
    @pools = []
  end

  def teardown
    @pools.each(&:close)
    @members.each(&:stop)
  end

  def pool(members, **kw)
    kw[:seeds] ||= members.map(&:endpoint)
    pl = Skaidb::Pool.new(**{ user: "ada", password: "secret", timeout: 5 }.merge(kw))
    @pools << pl
    pl
  end

  # The member that served one SELECT on a connection checked out from +pl+.
  def who(pl, affinity: nil)
    pl.with(affinity: affinity) { |c| c.exec("SELECT member()")[0]["member"] }
  end

  def state(pl, member)
    pl.members.find { |r| r[:endpoint] == member.endpoint }[:state]
  end

  # The pool's own record of +member+.
  def record(pl, member)
    pl.instance_variable_get(:@members)[member.endpoint]
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_for(what, secs = 5)
    deadline = now + secs
    until yield
      flunk "timed out waiting for #{what}" if now > deadline
      sleep 0.05
    end
  end
end

class PolicyTest < Minitest::Test
  include BalancingHelpers

  def test_round_robin_rotates_over_every_member
    pl = pool(@members, load_balancing: "round_robin") # a String works like a Symbol
    served = Array.new(9) { who(pl) }
    assert_equal (%w[a b c] * 3).sort, served.sort
    # Strict rotation: three in a row are three different members.
    served.each_slice(3) { |three| assert_equal 3, three.uniq.length, served.inspect }
  end

  def test_least_latency_prefers_the_faster_member
    a, b, = @members
    b.delay = 0.02
    pl = pool([a, b], load_balancing: :least_latency, eject_latency_factor: 0)
    served = Array.new(60) { who(pl) }
    assert_operator served.count("a"), :>, 48, served.inspect
    assert_operator served.count("b"), :>, 0, "b was measured at least once"
  end

  def test_least_latency_re_measures_a_member_it_has_not_used_lately
    a, b, = @members
    b.delay = 0.02
    pl = pool([a, b], load_balancing: :least_latency, eject_latency_factor: 0)
    20.times { who(pl) }
    # b is slow, then recovers: an idle pool notices once b's average goes
    # stale instead of never asking b again.
    b.delay = 0.0
    record(pl, b).last_sample -= 10
    assert_includes Array.new(3) { who(pl) }, "b"
  end

  def test_random_policy_keeps_the_1_1_behaviour
    pl = pool(@members)
    # One connection, reused: random never targets a member.
    assert_equal 1, Array.new(5) { who(pl) }.uniq.length
  end

  def test_unknown_options_are_refused
    assert_raises(ArgumentError) { Skaidb::Pool.new(load_balancing: :nearest) }
    assert_raises(ArgumentError) { Skaidb::Pool.new(idle_order: "random") }
    assert_raises(ArgumentError) { Skaidb::Pool.new(eject_errors: 0) }
    Skaidb::Pool.new(load_balancing: "least_latency", idle_order: :fifo).close
  end

  def test_members_counts_checked_out_and_idle_connections
    a, = @members
    pl = pool([a])
    c1 = pl.checkout
    c2 = pl.checkout
    row = pl.members.first
    assert_equal({ endpoint: a.endpoint, canonical: nil, state: :ready, latency_ms: nil,
                   in_use: 2, idle: 0, seed: true }, row)
    c1.exec("SELECT 1")
    pl.checkin(c1)
    c2.close # closed while checked out: no longer counted against a
    row = pl.members.first
    assert_equal [0, 1], [row[:in_use], row[:idle]]
    assert_kind_of Float, row[:latency_ms]
  end
end

class IdleOrderTest < Minitest::Test
  include BalancingHelpers

  def three(**kw)
    pl = pool([@members[0]], **kw)
    conns = Array.new(3) { pl.checkout }
    conns.each { |c| pl.checkin(c) }
    [pl, conns]
  end

  def test_lifo_hands_out_the_most_recently_returned
    pl, conns = three
    assert_same conns[2], pl.checkout
  end

  def test_fifo_hands_out_the_longest_idle
    pl, conns = three(idle_order: :fifo)
    got = Array.new(3) { pl.checkout }
    got.zip(conns).each { |g, c| assert_same c, g }
  end
end

class EjectionTest < Minitest::Test
  include BalancingHelpers

  def test_a_failing_member_is_ejected_then_readmitted_by_the_probe
    _, b, = @members
    b.refuse = true
    log = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| log << msg }
    pl = pool(@members, load_balancing: :round_robin, eject_errors: 2, eject_backoff: 0.3, logger: logger)
    served = Array.new(12) { who(pl) }
    refute_includes served, "b"
    assert_equal :ejected, state(pl, b)
    assert(log.any? { |m| m.include?("ejecting #{b.endpoint}") }, log.inspect)
    # Healthy again: the background probe re-admits it after the backoff.
    b.refuse = false
    wait_for("b to be re-admitted") { state(pl, b) == :ready }
    assert_includes Array.new(6) { who(pl) }, "b"
  end

  def test_a_probe_that_fails_doubles_the_backoff
    _, b, = @members
    b.refuse = true
    pl = pool(@members, load_balancing: :round_robin, eject_errors: 1, eject_backoff: 0.2)
    6.times { who(pl) }
    m = record(pl, b)
    wait_for("the probe") { m.ejections >= 2 }
    assert_equal :ejected, state(pl, b)
    assert_operator pl.send(:backoff_for, m), :>=, 0.4
  end

  def test_a_consistently_slow_member_is_ejected
    _, b, = @members
    b.delay = 0.05
    pl = pool(@members, load_balancing: :round_robin, eject_latency_floor: 0.02, eject_backoff: 30)
    45.times { who(pl) }
    assert_equal :ejected, state(pl, b)
    refute_includes Array.new(6) { who(pl) }, "b"
  end

  def test_one_slow_statement_does_not_eject_a_member
    _, b, = @members
    pl = pool(@members, load_balancing: :round_robin, eject_latency_floor: 0.05)
    36.times { who(pl) }
    b.delay = 0.5
    nil until who(pl) == "b"
    b.delay = 0.0
    6.times { who(pl) }
    assert_equal :ready, state(pl, b)
  end

  def test_the_last_usable_member_is_never_ejected
    a, b, c = @members
    b.refuse = c.refuse = true
    pl = pool(@members, load_balancing: :round_robin, eject_errors: 1)
    6.times { assert_equal "a", who(pl) }
    a.refuse = true
    # Idle connections to a still work (how many depends on the dial order
    # above); once they are used up, every dial fails.
    held = []
    assert_raises(Skaidb::ConnectionError) { 12.times { held << pl.checkout } }
    assert_equal :ready, state(pl, a)
  ensure
    held&.each(&:close)
  end

  def test_a_refused_login_is_not_a_member_fault
    refute Skaidb.member_fault?(Skaidb::ConnectionError.new("authentication denied: bad password"))
    assert Skaidb.member_fault?(Skaidb::ConnectionError.new("authentication denied: too many connections: 500"))
    refute Skaidb.member_fault?(Skaidb::ConnectionError.new("server signature mismatch (mutual auth failed)"))
    assert Skaidb.member_fault?(Skaidb::ConnectionError.new("connection closed by server"))
    assert Skaidb.member_fault?(Errno::ECONNREFUSED.new)
    # End to end: a wrong password fails every dial and ejects nobody.
    pl = pool(@members, password: "wrong", eject_errors: 1)
    3.times { assert_raises(Skaidb::ConnectionError) { pl.checkout } }
    assert_equal [:ready], pl.members.map { |r| r[:state] }.uniq
  end
end

class DiscoveryTest < Minitest::Test
  include BalancingHelpers

  def setup
    super
    a, b, c = @members
    @states = { a.endpoint => "ready", b.endpoint => "ready", c.endpoint => "resyncing" }
    @members.each do |m|
      m.listing = -> { @states.sort.map { |ep, st| [ep, st, ep == m.endpoint] } }
    end
  end

  def refresh(pl)
    conn = pl.checkout
    pl.send(:list_through, conn)
    pl.checkin(conn)
  end

  def test_members_are_discovered_and_resyncing_ones_get_no_connections
    a, _, c = @members
    pl = pool([a], load_balancing: :round_robin, discover: true)
    served = Array.new(8) { who(pl) }
    assert_equal %w[a b], served.uniq.sort, served.inspect
    assert_equal :resyncing, state(pl, c)
    # c catches up: the next refresh lets it in, measured afresh.
    m = record(pl, c)
    m.ewma = 9.9
    m.samples = 50
    @states[c.endpoint] = "ready"
    refresh(pl)
    assert_nil m.ewma
    assert_equal 0, m.samples
    assert_includes Array.new(6) { who(pl) }, "c"
  end

  def test_a_listing_with_a_member_not_ready_refreshes_sooner
    a, _, c = @members
    pl = pool([a], load_balancing: :round_robin, discover: true, refresh_interval: 60)
    who(pl)
    assert_operator pl.instance_variable_get(:@next_refresh) - now, :<=, 5.0 # c resyncing
    @states[c.endpoint] = "ready"
    refresh(pl)
    assert_operator pl.instance_variable_get(:@next_refresh) - now, :>, 50.0
  end

  def test_a_seed_given_by_another_name_is_not_counted_twice
    a, = @members
    pl = pool([a], seeds: ["localhost:#{a.port}"], load_balancing: :round_robin, discover: true)
    who(pl)
    rows = pl.members
    assert_equal 3, rows.length, rows.inspect
    seed = rows.find { |r| r[:seed] }
    assert_equal "localhost:#{a.port}", seed[:endpoint]
    assert_equal a.endpoint, seed[:canonical]
  end

  def test_a_member_that_leaves_the_listing_is_dropped
    a, b, = @members
    pl = pool([a], load_balancing: :round_robin, discover: true)
    who(pl)
    @states.delete(b.endpoint)
    refresh(pl)
    refute_includes pl.members.map { |r| r[:endpoint] }, b.endpoint
  end

  def test_a_seed_that_leaves_the_listing_is_kept_as_unlisted
    a, b, = @members
    pl = pool([a, b], load_balancing: :round_robin, discover: true)
    who(pl)
    @states.delete(a.endpoint)
    refresh(pl) # whichever member answers, its listing no longer names a
    assert_equal :unlisted, state(pl, a)
    assert_equal 3, pl.members.length
    refute_includes Array.new(4) { who(pl) }, "a"
  end

  def test_an_old_server_turns_discovery_off_and_keeps_the_seeds
    a, = @members
    a.old_server = true
    pl = pool([a], load_balancing: :round_robin, discover: true)
    assert_equal ["a"], Array.new(4) { who(pl) }.uniq
    assert pl.instance_variable_get(:@discovery_off)
    assert_equal 1, pl.members.length
  end

  def test_a_standalone_server_turns_discovery_off
    a, = @members
    a.listing = -> { [] }
    pl = pool([a], discover: true)
    conns = Array.new(3) { pl.checkout } # three new connections, one question
    conns.each { |c| pl.checkin(c) }
    assert pl.instance_variable_get(:@discovery_off)
    assert_equal 1, a.asked("SHOW ENDPOINTS")
    assert_equal 1, pl.members.length
  end

  def test_the_background_thread_stops_when_the_pool_closes
    a, = @members
    pl = pool([a], discover: true)
    who(pl)
    thread = pl.instance_variable_get(:@maintainer)
    assert thread&.alive?
    pl.close
    assert thread.join(2), "the background thread outlived the pool"
  end
end

class ReadYourWritesTest < Minitest::Test
  include BalancingHelpers

  def test_reads_follow_the_member_that_took_the_write
    pl = pool(@members, load_balancing: :round_robin, read_your_writes: 0.4)
    wrote = pl.with(affinity: "alice") do |conn|
      conn.exec("INSERT INTO t VALUES (1)")
      conn.endpoint
    end
    writer = @members.find { |m| m.endpoint == wrote }.name
    assert_equal [writer], Array.new(6) { who(pl, affinity: "alice") }.uniq
    # Another key, or no key, still rotates.
    assert_equal 3, Array.new(3) { who(pl, affinity: "bob") }.uniq.length
    sleep 0.5
    assert_equal 3, Array.new(3) { who(pl, affinity: "alice") }.uniq.length
  end

  def test_reads_do_not_set_affinity
    pl = pool(@members, load_balancing: :round_robin, read_your_writes: 5)
    who(pl, affinity: "alice")
    assert_equal 3, Array.new(3) { who(pl, affinity: "alice") }.uniq.length
  end

  def test_statement_classification
    ["SELECT 1", "  select 1", "(SELECT 1)", "-- c\nSHOW TABLES", "/* x */ EXPLAIN SELECT 1",
     "WITH a AS (SELECT 1) SELECT * FROM a", "DESCRIBE t", "DESC t", "VALUES (1)", "use app"].each do |sql|
      refute Skaidb.write_statement?(sql), sql
    end
    ["INSERT INTO t VALUES (1)", "update t set a = 1", "DELETE FROM t",
     "CREATE TABLE t (id INT PRIMARY KEY)", "COMMIT", "CALL p()", "selectx"].each do |sql|
      assert Skaidb.write_statement?(sql), sql
    end
  end
end
