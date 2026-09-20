# frozen_string_literal: true

# Connect, create a table, insert with typed parameters, query, clean up.
#
#   ruby examples/basic.rb [host] [port] [user] [password] [database]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host = ARGV[0] || "localhost"
port = (ARGV[1] || 7000).to_i
user = ARGV[2] || "anonymous"
pw   = ARGV[3] || ""
db   = ARGV[4]

Skaidb.connect(host: host, port: port, user: user, password: pw, database: db) do |conn|
  conn.exec("CREATE TABLE people (PRIMARY KEY (id))")

  people = [[1, "Ada", 36, %w[math eng]], [2, "Linus", 54, ["kernel"]], [3, "Margaret", 80, []]]
  people.each do |id, name, age, tags|
    conn.exec_params(
      "INSERT INTO people (id, name, age, tags) VALUES ($1, $2, $3, $4)",
      [id, name, age, tags]
    )
  end

  res = conn.exec_params("SELECT id, name, age, tags FROM people WHERE age > $1 ORDER BY id", [40])
  puts "columns: #{res.fields.join(', ')}"
  res.each do |row|
    puts "#{row['id']}\t#{row['name']}\t#{row['age']}\t#{row['tags'].inspect}"
  end
  puts "(#{res.ntuples} rows)"

  updated = conn.exec_params("UPDATE people SET age = $1 WHERE id = $2", [37, 1])
  puts "updated #{updated.cmd_tuples} row(s)"

  conn.exec("DROP TABLE people")
end
