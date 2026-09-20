# skaidb — Ruby driver

[![CI](https://github.com/porcupin26/skaidb-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/porcupin26/skaidb-ruby/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/porcupin26/skaidb-ruby?label=release)](https://github.com/porcupin26/skaidb-ruby/releases/latest)
[![License: SSPL-1.0](https://img.shields.io/badge/license-SSPL--1.0-blue.svg)](https://github.com/porcupin26/skaidb-ruby/blob/main/LICENSE)

The official Ruby driver for [skaidb](https://skaidb.org). The API is modelled
on the [ruby-pg](https://rubygems.org/gems/pg) gem: `Skaidb.connect` returns a
connection, `exec` / `exec_params` run statements with `$1`-style parameters,
and the result behaves like `PG::Result`. **Pure standard library** (`socket`,
`openssl`, `securerandom`, `bigdecimal`) — no third-party code, one file,
Ruby 2.7 through 3.4. It speaks skaidb's binary protocol directly:
SCRAM-SHA-256 authentication, server-side prepared statements with typed
parameters, one-round-trip batches, streamed result sets, multi-seed failover,
transparent reconnect, TLS and connection pooling.

- Repository: <https://github.com/porcupin26/skaidb-ruby>
- Full reference: [`docs/`](https://github.com/porcupin26/skaidb-ruby/tree/main/docs) —
  [getting started](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/getting-started.md),
  [API reference](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/api.md),
  [types](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/types.md),
  [TLS](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/tls.md),
  [streaming](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/streaming.md),
  [pooling](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/pooling.md),
  [changelog](https://github.com/porcupin26/skaidb-ruby/blob/main/CHANGELOG.md)
- Server documentation: <https://skaidb.org/docs/>
- Wire protocol the driver speaks: <https://skaidb.org/docs/PROTOCOL.html>

## Install

The gem is not on RubyGems.org yet; installs come from the GitHub release or
the git tag. The package is named `skaidb` and required as `require "skaidb"`
whichever way it is installed.

From the release asset:

```sh
curl -LO https://github.com/porcupin26/skaidb-ruby/releases/download/v1.0.0/skaidb-1.0.0.gem
gem install ./skaidb-1.0.0.gem
```

With Bundler, from the tag:

```ruby
gem 'skaidb', git: 'https://github.com/porcupin26/skaidb-ruby', tag: 'v1.0.0'
```

Bundler resolves the gem's one dependency, `bigdecimal` (part of Ruby's
standard library, declared because it is a bundled rather than default gem
from Ruby 3.4), from RubyGems.org and compiles it, even on a Ruby that ships
it; that needs the Ruby headers and a C toolchain (`ruby-dev` and
`build-essential` on Debian/Ubuntu, `ruby-devel` and `gcc` on Fedora/RHEL,
Xcode command-line tools on macOS). `gem install` of the release asset and
vendoring reuse the `bigdecimal` already installed and compile nothing.

Or vendor the single file: copy
[`lib/skaidb.rb`](https://github.com/porcupin26/skaidb-ruby/blob/v1.0.0/lib/skaidb.rb)
into your project and `require_relative` it. It has no dependencies beyond
Ruby's standard library.

## Quick start

```ruby
require "skaidb"

conn = Skaidb.connect(host: "localhost", port: 7000,
                      user: "skaidb", password: "secret", database: "app")

conn.exec("CREATE TABLE users (PRIMARY KEY (id))")
conn.exec_params("INSERT INTO users (id, name, tags) VALUES ($1, $2, $3)",
                 [1, "Ada", ["math", "eng"]])

res = conn.exec_params("SELECT id, name, tags FROM users WHERE id = $1", [1])
res.each { |row| puts row["name"] }     # Ada
p res.fields                            # ["id", "name", "tags"]
p res.rows                              # [[1, "Ada", ["math", "eng"]]]

conn.close
```

With a block the connection is closed for you:

```ruby
Skaidb.connect(host: "localhost", user: "skaidb", password: "secret") do |conn|
  conn.exec("SELECT id, name FROM users ORDER BY id").each { |row| p row }
end
```

## Table of contents

- [Connecting](#connecting) — host/port, seeds and failover, `database:`,
  timeout, TLS, consistency, health
- [Statements and parameters](#statements-and-parameters) — `$1` binding,
  prepared statements, `exec_batch`
- [Results](#results)
- [Streaming large results](#streaming-large-results)
- [Connection pool](#connection-pool)
- [Streams (`CREATE STREAM`)](#streams-create-stream) — `subscribe`
- [Type mapping](#type-mapping)
- [Errors](#errors)
- [Transactions](#transactions)
- [Thread safety](#thread-safety)
- [Client identification and version](#client-identification-and-version)
- [Compatibility](#compatibility)

## Connecting

```ruby
Skaidb.connect(
  host: "localhost", port: 7000,
  user: "anonymous", password: "",
  consistency: :quorum,        # :one | :quorum | :all (also "ONE"… or 0/1/2)
  timeout: 10.0,               # TCP connect timeout in seconds; nil = none
  database: nil,               # run USE <database> as part of connecting
  seeds: nil,                  # ["db1", "db2:7000", …] tried in random order
  tls: false, tls_ca: nil, tls_insecure: false, tls_server_name: "skaidb"
) # => Skaidb::Connection (or the block's value when a block is given)
```

`connect` dials, runs the SCRAM-SHA-256 handshake (with mutual
authentication — the server proves it knows your password too), sends a
best-effort `Hello` naming the driver and its version, and runs `USE` if a
`database` was given. Omit `user`/`password` for a server with authentication
disabled.

### Seeds and failover

skaidb is leaderless: every node accepts every read and write. Pass the
cluster's addresses as `seeds`; they are tried in **randomized order** until
one connects *and* authenticates, which also spreads a fleet of clients across
the nodes.

```ruby
conn = Skaidb.connect(seeds: ["db1", "db2:7000", "db3"], database: "app")
```

Each seed is `"host"` or `"host:port"` (the port after the last colon wins; a
seed without a port uses `port:`). When a connection's transport dies, the
**next statement re-dials** across the same seeds, re-authenticates, re-sends
`Hello`, re-runs `USE`, and drops the connection's prepared statements — a
recovered connection is indistinguishable from a fresh one. The statement that
discovered the loss raises `Skaidb::ConnectionError`; the one after it goes
through.

### Timeout

`timeout` bounds the TCP dial only. Reads have no deadline: a peer that is
alive but silent blocks the caller, as in ruby-pg. `close` deliberately does
not take the connection's lock, so another thread can break a stuck read by
closing the connection.

### TLS

```ruby
conn = Skaidb.connect(host: "db1", tls: true)                     # system trust store
conn = Skaidb.connect(host: "db1", tls_ca: "/etc/skaidb/ca.crt")  # the cluster CA
conn = Skaidb.connect(host: "db1", tls_insecure: true)            # dev only: no verification
```

Any of the three enables TLS. The server name sent as SNI and checked against
the certificate is `tls_server_name` (default `"skaidb"`, the SAN skaidb's own
certificates carry). SCRAM runs inside the TLS session. The driver does not
present a client certificate. Details: [docs/tls.md](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/tls.md).

### Consistency

skaidb has tunable consistency; the driver's default is `:quorum`. Set it per
connection and override it per statement:

```ruby
conn = Skaidb.connect(host: "db1", consistency: :one)
conn.consistency = :all                                   # subsequent statements
conn.exec_params("SELECT …", [], consistency: :one)       # this statement only
conn.exec_batch("INSERT …", rows, consistency: :quorum)
conn.stream("SELECT …", consistency: :one) { |row| … }
```

`Skaidb::Consistency::ONE / QUORUM / ALL` are the integers `0 / 1 / 2`;
`Skaidb::Consistency.resolve` accepts a Symbol, a String (any case) or the
integer and raises `Skaidb::Error` otherwise. DDL is always run at quorum by
the server regardless of this setting.

### Health

- `conn.usable?` — no round-trip. `true` unless the connection is closed, was
  left out of sync by a transport error or an undrainable abandoned stream, or
  is currently mid-stream.
- `conn.closed` / `conn.finished?` — `true` after `close`.

## Statements and parameters

Placeholders are pg-style `$1`, `$2`, …; pass parameters as an Array:

```ruby
conn.exec_params("SELECT * FROM users WHERE name = $1 AND age > $2", ["O'Brien", 30])
```

`exec(sql)` (alias `query`) runs a statement with no parameters. The same
`$N` may appear more than once. A bare `?` in a statement that has parameters
is rejected up front with a message saying the driver's syntax is `$1, $2, …`
(the server would otherwise fail it late with a confusing arity error).

### How binding works

A parameterized statement is **prepared on the server** and its values are
sent as typed values over the binary protocol. Nothing is interpolated into
SQL text, so `"O'Brien"` needs no escaping, and a parameter can be an Array
(→ Array) or a Hash (→ Document), which have no SQL literal form:

```ruby
conn.exec_params("INSERT INTO docs (id, meta) VALUES ($1, $2)",
                 [7, { "city" => "London", "tags" => ["a", "b"] }])
conn.exec_params("SELECT id FROM users WHERE id IN ($1)", [[1, 2, 3]])   # set membership
```

Prepared statements are cached per connection (up to 240 entries, under the
server's 256-per-connection limit) and reused. The cache is dropped when the
connection re-dials.

Statement kinds the server refuses to prepare (DDL and session control such
as `USE`) fall back to **client-side text binding** for scalar parameters: a
String is quoted with `''` escaping, a `Time` becomes epoch milliseconds, a
binary String becomes a hex literal, and Arrays/Hashes raise `QueryError` on
this path — with the server's reason for refusing the prepare appended, since
that is usually the real mistake. Mismatched placeholder/parameter counts
raise `QueryError` on either path.

### `exec_batch` — bulk writes in one round-trip

```ruby
n = conn.exec_batch("INSERT INTO t (id, v) VALUES ($1, $2)", [[1, "a"], [2, "b"], [3, "c"]])
n   # => 3, total rows affected
```

The statement is prepared once and **every parameter row ships in a single
frame** (`ExecuteBatch`). Each row autocommits on its own; on a failure the
`QueryError` names the row index and earlier rows stay applied, so the
statement should be idempotent. A statement the server cannot prepare raises
`QueryError` rather than falling back. An empty row list returns 0 without a
round-trip.

## Results

`exec`, `query`, `exec_params` and `exec_prepared` return a `Skaidb::Result`,
shaped like `PG::Result`:

- `fields` (alias `columns`): column names in order; `nfields` / `num_fields`.
- `rows`: rows as Arrays of values; `ntuples` / `num_tuples`.
- `each` / `Enumerable` / `values` / `to_a`: rows as Hashes keyed by column
  name (String keys); `res[i]` is row `i` as a Hash; `getvalue(row, col)` one
  cell by index or column name.
- `cmd_tuples`: rows affected by `INSERT`/`UPDATE`/`DELETE`; `0` for a
  `SELECT` and for DDL.
- `result_sets`: for a `CALL` whose procedure `EMIT`s several result sets,
  every set in order (each a `Result`); the last set is the result's own
  `rows`/`fields`. Empty for an ordinary reply.

A result holds all its rows in memory; for results that do not fit, stream.

## Streaming large results

`conn.stream(sql, consistency: nil)` runs the statement over the streaming
opcode and yields one row Hash at a time, holding **one chunk** in memory:

```ruby
conn.stream("SELECT id, pad FROM big ORDER BY id") do |row|
  break if enough?(row)          # leaving early drains the tail
end

first = conn.stream("SELECT id FROM big ORDER BY id").first(10)   # Enumerator form
```

`stream` takes SQL text only (no parameters). A non-row statement returns
`nil` without yielding.

**The abandon/drain rule.** The connection is busy for the whole stream:
a statement from another thread waits for it. Leaving the block early —
`break`, `return`, an exception, or any Enumerable method on the Enumerator
form — drains the frames the server is still sending so the socket sits at a
request boundary again. Draining transfers the rest of the result: if you only
want the first rows, say so with `LIMIT`. External iteration (`next`/`peek`)
on the Enumerator form cannot unwind and leaves the connection marked busy;
iterate with a block or `each`. A frame that makes no sense mid-stream, or a
dead socket, marks the connection broken instead; `usable?` turns `false`
and the next statement re-dials. Details: [docs/streaming.md](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/streaming.md).

## Connection pool

```ruby
pool = Skaidb::Pool.new(seeds: ["db1", "db2", "db3"], database: "app", maxsize: 8)

pool.with { |conn| conn.exec_params("SELECT … WHERE id IN ($1)", [[1, 2, 3]]) }

conn = pool.checkout; …; pool.checkin(conn)   # the explicit form
pool.close                                    # closes idle connections
```

`Skaidb::Pool` is thread-safe and accepts every `Skaidb.connect` keyword.
`maxsize` bounds the number of **idle** connections retained; checkout never
blocks — when no idle connection is available a new one is dialed, and a
returned connection beyond `maxsize` is closed. Connections are validated with
`usable?` on checkout and check-in, so one broken by a transport error or an
undrained stream is closed and replaced. Details: [docs/pooling.md](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/pooling.md).

## Streams (`CREATE STREAM`)

`conn.subscribe(name, after: nil, poll: 0.5)` yields a stream's events forever
as Hashes with `"id"`, `"op"`, `"k"`, `"ts"`, `"doc"`. It polls the stream's
log with a keyset cursor (500 events per page, sleeping `poll` seconds when
caught up), so it needs no MQTT client. `id` is an opaque String that sorts in
log order — persist the last one you handled and pass it as `after:` to resume
exactly there.

```ruby
conn.subscribe("big_orders", after: checkpoint) do |ev|
  handle(ev["doc"])
  checkpoint = ev["id"]
end
```

For push delivery, subscribe to `$stream/<db>/<name>` with any MQTT client
instead; the events are identical.

## Type mapping

| skaidb value | Ruby → bind                                   | Ruby ← result                       |
|--------------|-----------------------------------------------|-------------------------------------|
| Null         | `nil`                                         | `nil`                               |
| Bool         | `true` / `false`                              | `true` / `false`                    |
| Int          | `Integer` (signed 64-bit)                     | `Integer`                           |
| Float        | `Float` (finite only)                         | `Float`                             |
| Decimal      | `BigDecimal` (finite, 128-bit mantissa)       | `BigDecimal`                        |
| String       | `String` (any text encoding), `Symbol`        | `String` (UTF-8)                    |
| Bytes        | `String` with `Encoding::BINARY` (`"…".b`)    | `String` with `Encoding::BINARY`    |
| Uuid         | `Skaidb::Uuid`                                | `String`, canonical lowercase       |
| Timestamp    | `Time` (millisecond precision)                | `Time` (UTC)                        |
| Array        | `Array`                                       | `Array`                             |
| Document     | `Hash` (keys become Strings)                  | `Hash`, keys in server order        |

Worth knowing:

- A `String` binds as Bytes when its encoding is `ASCII-8BIT`/`BINARY` and as
  String otherwise, so read a file with `File.binread` or call `.b` to store
  raw bytes, and keep text in UTF-8.
- A UUID result is a String, so `"…" == row["id"]` works; to *bind* one with
  the Uuid type wrap it: `Skaidb::Uuid.new("6ba7b810-…")`, `Skaidb::Uuid.random`,
  `Skaidb::Uuid.from_bytes(raw16)`. A `Uuid` compares equal to a String in the
  same canonical form.
- `Time` keeps its instant whatever its zone; sub-millisecond precision is
  truncated. Results are UTC.
- A Document result is a `Hash` whose keys come back in the order the server
  sends them, which is not the order they were bound in: the server stores a
  document in canonical form, with keys sorted at every level. Do not rely
  on key order.
- An `Integer` outside the signed 64-bit range, a `NaN`/`Infinity` Float, a
  non-finite `BigDecimal` or one whose digits exceed a signed 128-bit
  mantissa, and any other type (`Date`, `Rational`, …) raise `QueryError` —
  convert them yourself.

Details: [docs/types.md](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/types.md).

## Errors

```
StandardError
└── Skaidb::Error                # also: invalid consistency, pool closed
    ├── Skaidb::ConnectionError  # dial/auth/transport failures, framing, closed connection
    └── Skaidb::QueryError       # the server rejected the statement; bad parameters
```

- A server `Error` frame is a **statement** error (`QueryError`); the
  connection stays usable.
- A transport failure (`ConnectionError`) marks the connection broken; the
  next statement re-dials, or a pool replaces it.
- `ArgumentError` for `Pool.new(maxsize: 0)` and for `Skaidb::Uuid.new` of a
  string that is not a UUID.

## Transactions

skaidb autocommits every statement. There is no `BEGIN` on this driver's API;
where your server supports statement-level transaction control, issue
`BEGIN`/`COMMIT`/`ROLLBACK` as ordinary statements. **On a cluster,
transaction control is not available** — a `BEGIN` there is refused by the
server as a statement error. See the server documentation for what your
deployment supports.

## Thread safety

Threads may share the module but should not share a connection. A connection
serializes its own round-trips with a Mutex, and a stream claims it outright,
but the intended shape for concurrency is one connection per thread, which is
what a [pool](#connection-pool) gives you.

## Client identification and version

`Skaidb::VERSION` is the package version — defined once in `lib/skaidb.rb`,
read by the gemspec, and what the driver reports to the server in the `Hello`
frame after every handshake. It shows up as `client_name = 'ruby'` /
`client_version` in the server's `drivers` table:

```sql
SELECT client_name, client_version FROM drivers;
-- ruby | 1.0.0
```

The server records the row asynchronously, so a `SELECT` immediately after
connecting may not show it yet. `Hello` is telemetry: a server that does not
know the opcode answers with an error the driver ignores.

## Compatibility

- Ruby 2.7 – 3.4 (CI covers 3.1 – 3.4), MRI. No third-party dependencies;
  `bigdecimal` is declared because it is a bundled gem since Ruby 3.4.
- Works with any skaidb server. Where a server predates an opcode the driver
  falls back: prepared statements → client-side text binding, `Hello` →
  ignored. `stream` and `exec_batch` need a server with those opcodes and
  raise `QueryError` otherwise.
- The wire protocol (framing, SCRAM handshake, value encoding, opcodes) is
  specified at <https://skaidb.org/docs/PROTOCOL.html>. The driver speaks the
  binary protocol on port 7000; the server's REST/JSON gateway (port 7080)
  is a dependency-free alternative for other clients.

## Examples

[`examples/`](https://github.com/porcupin26/skaidb-ruby/tree/main/examples)
contains runnable scripts: `basic.rb`, `prepared_batch.rb`, `stream.rb`,
`pool.rb`, `tls.rb`, `subscribe.rb`. Each takes
`host port user password [database]` on the command line and defaults to
`localhost:7000`.

```sh
ruby examples/basic.rb localhost 7000 skaidb secret app
```

## Development

```sh
git clone https://github.com/porcupin26/skaidb-ruby
cd skaidb-ruby
rake test            # unit tests against an in-process fake server; no skaidb needed
gem build skaidb.gemspec
```

The end-to-end test in `test/live/` runs against a real server when
`SKAIDB_LIVE=1` is set (with `SKAIDB_HOST`, `SKAIDB_PORT`, `SKAIDB_USER`,
`SKAIDB_PASSWORD`, `SKAIDB_DATABASE`), and is skipped otherwise:

```sh
SKAIDB_LIVE=1 SKAIDB_HOST=127.0.0.1 SKAIDB_PORT=7000 SKAIDB_USER=admin SKAIDB_PASSWORD=secret \
SKAIDB_DATABASE=default rake test:live
```

## License

[SSPL-1.0](https://github.com/porcupin26/skaidb-ruby/blob/main/LICENSE) (Server Side Public License), the same license as skaidb.
