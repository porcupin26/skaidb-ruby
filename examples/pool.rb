# frozen_string_literal: true

# A thread-safe connection pool: one connection per thread, reused across
# checkouts, broken ones replaced transparently. Every Skaidb.connect keyword
# passes through (seeds, database, TLS, consistency).
#
#   ruby examples/pool.rb [host] [port] [user] [password] [database]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host, port, user, pw, db = ARGV[0] || "localhost", (ARGV[1] || 7000).to_i, ARGV[2] || "anonymous", ARGV[3] || "", ARGV[4]

pool = Skaidb::Pool.new(seeds: ["#{host}:#{port}"], user: user, password: pw, database: db, maxsize: 4)

pool.with { |conn| conn.exec("CREATE TABLE hits (PRIMARY KEY (id))") }

threads = (1..8).map do |t|
  Thread.new do
    pool.with do |conn|
      10.times { |i| conn.exec_params("INSERT INTO hits (id, thread) VALUES ($1, $2)", [(t * 100) + i, t]) }
    end
  end
end
threads.each(&:join)

pool.with do |conn|
  puts "hits: #{conn.exec('SELECT count(*) AS n FROM hits')[0]['n']}"
  conn.exec("DROP TABLE hits")
end
pool.close
