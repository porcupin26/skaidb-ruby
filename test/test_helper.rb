# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(__dir__)

require "minitest/autorun"
require "skaidb"
require "fake_server"

module ServerHelpers
  # Start a fake server for the block and stop it afterwards.
  def with_server(password: "secret", tls: nil)
    srv = FakeSkaidb::Server.new(password: password, tls: tls).start
    yield srv
  ensure
    srv&.stop
  end

  # What the server just did to its connections — closed them, reset them,
  # stopped sending — has reached this side: each of +conns+' sockets has
  # something to read (an end-of-file, a reset). On loopback that is a
  # matter of microseconds, and of no guarantee.
  def let_the_loss_arrive(*conns)
    conns.each do |conn|
      io = conn.instance_variable_get(:@sock)&.to_io
      next if io.nil? || io.closed?

      IO.select([io], nil, nil, 2) or flunk "what the server did to the connection did not arrive"
    end
  end

  # The server restarts while +conns+ sit idle: every connection is closed,
  # and the close has reached the client's sockets.
  def restart(srv, *conns)
    srv.close_all
    let_the_loss_arrive(*conns)
  end

  def connect(srv, **kw)
    Skaidb.connect(**{ host: "127.0.0.1", port: srv.port, user: "ada", password: "secret" }.merge(kw))
  end

  # The client has closed +count+ of its sockets while the server still held
  # their sessions (waits up to +secs+ for the server to see it).
  def assert_hung_up(srv, count, msg = nil, secs = 2)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep 0.005 while srv.hangups < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < secs
    assert_equal count, srv.hangups, msg || "sockets the client has closed"
  end

  # Runs the block and raises +error+ in it at the moment +conn+ has read
  # the reply of its next round trip — nothing of the driver's has looked at
  # that reply yet. Where an exception from outside (Timeout.timeout, an
  # Interrupt, Thread#raise) lands is a matter of timing; this puts one at
  # that exact point, every time.
  def cut_after_the_reply(conn, error)
    armed = true
    trace = TracePoint.new(:return) do |tp|
      next unless armed && tp.method_id == :round_trip && tp.self.equal?(conn)

      armed = false
      raise error
    end
    trace.enable { yield }
  end

  # Runs the block and raises +error+ in it where +conn+ is about to send
  # the statement +sql+: the call has been made, nothing is written yet.
  def cut_before_the_request(conn, sql, error)
    armed = true
    trace = TracePoint.new(:call) do |tp|
      next unless armed && tp.method_id == :request && tp.self.equal?(conn)
      next unless tp.binding.local_variable_get(:req).include?(sql.b)

      armed = false
      raise error
    end
    trace.enable { yield }
  end

  # Wait (up to +secs+) until the block is true.
  def until_true(secs = 2)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    until yield
      raise "timeout waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > secs

      sleep 0.005
    end
  end
end
