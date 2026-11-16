# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(__dir__)

require "minitest/autorun"
require "skaidb"
require "fake_server"

module ServerHelpers
  # Start a fake server for the block and stop it afterwards.
  def with_server(password: "secret")
    srv = FakeSkaidb::Server.new(password: password).start
    yield srv
  ensure
    srv&.stop
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

  # Wait (up to +secs+) until the block is true.
  def until_true(secs = 2)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    until yield
      raise "timeout waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > secs

      sleep 0.005
    end
  end
end
