# frozen_string_literal: true

# A thread-safe connection pool balanced across the cluster's members: one
# connection per thread, reused across checkouts, broken ones replaced
# transparently. Every Skaidb.connect keyword passes through (seeds, database,
# TLS, consistency). With load_balancing: :least_latency and discover: true
# the pool spreads its checkouts over every member it learns from SHOW
# ENDPOINTS, skipping members that are resyncing and ejecting ones that fail
# or turn slow.
#
#   ruby examples/pool.rb [host] [port] [user] [password] [database]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host, port, user, pw, db = ARGV[0] || "localhost", (ARGV[1] || 7000).to_i, ARGV[2] || "anonymous", ARGV[3] || "", ARGV[4]

pool = Skaidb::Pool.new(seeds: ["#{host}:#{port}"], user: user, password: pw, database: db, maxsize: 4,
                        load_balancing: :least_latency, discover: true)

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

# What the pool sees per member.
pool.members.each do |m|
  puts format("%-22s %-11s latency=%s in_use=%d idle=%d", m[:endpoint], m[:state],
              m[:latency_ms] ? format("%.2fms", m[:latency_ms]) : "-", m[:in_use], m[:idle])
end
pool.close
