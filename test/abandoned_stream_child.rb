# frozen_string_literal: true

# Not a test: the process AbandonedStreamTest runs (abandoned_stream_test.rb).
# It does what an application does when it reads the first rows of a stream
# by external iteration and moves on:
#
#   conn.stream(sql).next    # the Enumerator is dropped half-read,
#                            # and later the connection with it
#
# The Enumerator's Fiber is suspended inside the connection's lock when the
# collector takes it. Ruby 3.3.8 crashes when a lock is freed after the
# Fiber that owns it — at that collection or at exit — unless the lock is
# kept (Skaidb.keep_stream_lock). This process must end with status 0;
# without the kept lock it segfaults in 40 runs of 40 at 300 rounds.
#
#   ruby -Ilib -Itest test/abandoned_stream_child.rb [rounds]
require "skaidb"
require "fake_server"

F = FakeSkaidb::F
BIG = "SELECT id FROM big"
rounds = Integer(ARGV[0] || "300")
srv = FakeSkaidb::Server.new.start
# the whole reply in one write (frame by frame, the second frame waits for
# the first one's delayed ACK: 40 ms a round)
reply = [F.header(["id"]), F.chunk([[1], [2]]), F.rows_end].map { |payload| FakeSkaidb.frame(payload) }.join
srv.handler = lambda do |req, conn|
  next nil unless req.sql == BIG

  conn[:sock].write(reply)
  []
end
filler = []
rounds.times do |round|
  conn = Skaidb.connect(host: "127.0.0.1", port: srv.port, user: "ada", password: "secret")
  conn.stream(BIG).next # parked in the middle of the reply; nothing keeps the Enumerator
  # What the application does next: it allocates, so the collector runs when
  # it must and hands the memory it frees out again. (No GC.start: a forced,
  # immediate sweep hides the crash.)
  48.times do |i|
    filler << ("\x05\x01\xaa\x00".b * (40 + ((round + i) % 480)))
    filler << Mutex.new.tap { |m| m.synchronize { nil } }
  end
  filler.shift(72) if filler.length > 4000
end
