# frozen_string_literal: true

# Typed parameters through server-side prepared statements, every value type,
# and a one-round-trip batch insert.
#
#   ruby examples/prepared_batch.rb [host] [port] [user] [password] [database]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host, port, user, pw, db = ARGV[0] || "localhost", (ARGV[1] || 7000).to_i, ARGV[2] || "anonymous", ARGV[3] || "", ARGV[4]

Skaidb.connect(host: host, port: port, user: user, password: pw, database: db) do |conn|
  conn.exec("CREATE TABLE events (PRIMARY KEY (id))")

  # One row with every type the wire protocol has. Values travel typed, so
  # arrays and hashes (Document) bind natively; BigDecimal, Skaidb::Uuid,
  # Time and binary strings keep their type on the server.
  conn.exec_params(
    "INSERT INTO events (id, name, score, ok, note, tags, meta, price, ref, at, blob) " \
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
    [1, "O'Brien", 2.5, true, nil, [1, "two", 3.0], { "city" => "London", "tags" => %w[a b] },
     BigDecimal("123.45"), Skaidb::Uuid.random, Time.now.utc, "\x00\x01\xfe\xff".b]
  )

  # exec_batch: the statement is prepared once and every row ships in ONE
  # frame. Rows autocommit individually.
  rows = (2..1001).map { |i| [i, "event #{i}", i / 10.0, i.even?] }
  n = conn.exec_batch("INSERT INTO events (id, name, score, ok) VALUES ($1, $2, $3, $4)", rows)
  puts "batch inserted #{n} rows"

  res = conn.exec_params("SELECT id, name, score, ok, tags, meta, price, ref, at, blob FROM events WHERE id <= $1 ORDER BY id", [3])
  res.each do |row|
    row.each { |k, v| puts "  #{k}: #{v.inspect} (#{v.class})" }
    puts
  end

  # The same parameter may be referenced twice; $N is positional.
  same = conn.exec_params("SELECT count(*) AS n FROM events WHERE score >= $1 AND score <= $1 + 1", [5.0])
  puts "count: #{same[0]['n']}"

  conn.exec("DROP TABLE events")
end
