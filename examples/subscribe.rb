# frozen_string_literal: true

# Follow a CREATE STREAM log as an endless event iterator. subscribe() polls
# the stream's log with a keyset cursor; keep the last id you handled and
# pass it as after: to resume exactly there after a restart.
#
#   ruby examples/subscribe.rb [host] [port] [user] [password] [database] [stream]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host, port, user, pw, db = ARGV[0] || "localhost", (ARGV[1] || 7000).to_i, ARGV[2] || "anonymous", ARGV[3] || "", ARGV[4]
stream = ARGV[5] || "orders_stream"

Skaidb.connect(host: host, port: port, user: user, password: pw, database: db) do |conn|
  checkpoint = nil # persist this somewhere durable in a real consumer
  puts "following #{stream} (Ctrl-C to stop)"
  conn.subscribe(stream, after: checkpoint, poll: 0.5) do |ev|
    puts "#{ev['id']} #{ev['op']} #{ev['k']} #{ev['ts']} #{ev['doc'].inspect}"
    checkpoint = ev["id"]
  end
end
