# frozen_string_literal: true

# Stream a large result set: rows arrive chunk by chunk and the driver holds
# one chunk at a time, so memory stays flat however big the table is.
#
#   ruby examples/stream.rb [host] [port] [user] [password] [database]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host, port, user, pw, db = ARGV[0] || "localhost", (ARGV[1] || 7000).to_i, ARGV[2] || "anonymous", ARGV[3] || "", ARGV[4]

Skaidb.connect(host: host, port: port, user: user, password: pw, database: db) do |conn|
  conn.exec("CREATE TABLE big (PRIMARY KEY (id))")
  (1..20_000).each_slice(1000) do |ids|
    conn.exec_batch("INSERT INTO big (id, pad) VALUES ($1, $2)", ids.map { |i| [i, "x" * 64] })
  end

  # Block form: yields one row Hash at a time.
  count = 0
  conn.stream("SELECT id, pad FROM big ORDER BY id") do |row|
    count += 1
    puts "row #{row['id']}" if (row['id'] % 5000).zero?
  end
  puts "streamed #{count} rows"

  # Enumerator form: any Enumerable method works. Leaving early (first,
  # take, break) drains the rest of the stream so the connection is reusable;
  # prefer a LIMIT in SQL when you only want a few rows.
  first = conn.stream("SELECT id FROM big ORDER BY id").first(3)
  puts "first three: #{first.map { |r| r['id'] }.inspect}"
  puts "connection still usable: #{conn.usable?}"

  conn.exec("DROP TABLE big")
end
