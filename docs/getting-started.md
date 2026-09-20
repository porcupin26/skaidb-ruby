# Getting started

## Install

The gem is published on RubyGems.org as
[`skaidb`](https://rubygems.org/gems/skaidb); whichever way it is installed
the library is loaded with `require "skaidb"`.

```sh
gem install skaidb
```

With Bundler:

```ruby
# Gemfile
gem "skaidb", "~> 1.0"
```

Or vendor the single file `lib/skaidb.rb` into your project and
`require_relative` it — it needs nothing beyond Ruby's standard library
(`socket`, `openssl`, `securerandom`, `bigdecimal`).

Ruby 2.7 or newer; CI covers 3.1 through 3.4.

## Connect

```ruby
require "skaidb"

conn = Skaidb.connect(host: "localhost", port: 7000,
                      user: "skaidb", password: "secret",
                      database: "app")
```

`connect` opens the TCP connection, runs the four-frame SCRAM-SHA-256
handshake (verifying the server's signature when a password is given), sends
the driver's `Hello`, and runs `USE "app"` when `database:` is set. Pass a
block to have the connection closed when it returns:

```ruby
Skaidb.connect(host: "localhost", user: "skaidb", password: "secret") do |conn|
  # ...
end
```

For a server with authentication disabled, omit `user:` and `password:`.

For a cluster, pass every node as `seeds:` — they are tried in random order
until one accepts the connection and the handshake:

```ruby
conn = Skaidb.connect(seeds: ["db1", "db2:7000", "db3"], user: "app", password: "secret")
```

## Run statements

```ruby
conn.exec("CREATE TABLE users (PRIMARY KEY (id))")

conn.exec_params("INSERT INTO users (id, name, age, tags) VALUES ($1, $2, $3, $4)",
                 [1, "Ada", 36, ["math", "eng"]])

res = conn.exec_params("SELECT id, name, tags FROM users WHERE age > $1 ORDER BY id", [30])
res.each { |row| puts "#{row['id']} #{row['name']} #{row['tags'].inspect}" }
res.ntuples      # 1
res.fields       # ["id", "name", "tags"]
res.rows         # [[1, "Ada", ["math", "eng"]]]

conn.exec_params("UPDATE users SET age = $1 WHERE id = $2", [37, 1]).cmd_tuples   # 1
```

Placeholders are `$1`, `$2`, … and values are sent **typed** through a
server-side prepared statement: Strings need no escaping, and Arrays and
Hashes bind natively. See [types.md](types.md) for the full mapping.

## Bulk insert

```ruby
rows = (1..10_000).map { |i| [i, "row #{i}"] }
conn.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", rows)   # one round-trip
```

## Large results

```ruby
conn.stream("SELECT id, payload FROM events ORDER BY id") do |row|
  process(row)
end
```

Rows arrive chunk by chunk; the driver holds one chunk at a time. See
[streaming.md](streaming.md), in particular what happens when you leave the
block early.

## Errors

```ruby
begin
  conn.exec("SELECT nope FROM missing")
rescue Skaidb::QueryError => e       # the server rejected the statement; connection still fine
  warn e.message                     # table "missing" does not exist
rescue Skaidb::ConnectionError => e  # transport/handshake trouble; next statement re-dials
  warn e.message
end
```

Both inherit from `Skaidb::Error`.

## Close

```ruby
conn.close
```

Or use the block form of `connect`, or a [pool](pooling.md).

## Next

- [API reference](api.md)
- [Types](types.md)
- [TLS](tls.md)
- [Streaming](streaming.md)
- [Pooling](pooling.md)
- Runnable scripts in [`examples/`](../examples/)
- Server documentation: <https://skaidb.org/docs/> — the wire protocol this
  driver speaks: <https://skaidb.org/docs/PROTOCOL.html>
