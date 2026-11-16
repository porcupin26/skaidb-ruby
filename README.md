# skaidb — Ruby driver

[![CI](https://github.com/porcupin26/skaidb-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/porcupin26/skaidb-ruby/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/porcupin26/skaidb-ruby?label=release)](https://github.com/porcupin26/skaidb-ruby/releases/latest)
[![Gem](https://img.shields.io/gem/v/skaidb?label=rubygems)](https://rubygems.org/gems/skaidb)
[![License: SSPL-1.0](https://img.shields.io/badge/license-SSPL--1.0-blue.svg)](https://github.com/porcupin26/skaidb-ruby/blob/main/LICENSE)

The official Ruby driver for [skaidb](https://skaidb.org). The API is modelled
on the [ruby-pg](https://rubygems.org/gems/pg) gem: `Skaidb.connect` returns a
connection, `exec` / `exec_params` run statements with `$1`-style parameters,
and the result behaves like `PG::Result`. **Pure standard library** (`socket`,
`openssl`, `securerandom`, `bigdecimal`) — no third-party code, one file,
Ruby 2.7 through 3.4. It speaks skaidb's binary protocol directly:
SCRAM-SHA-256 authentication, server-side prepared statements with typed
parameters, one-round-trip batches, streamed result sets, a retrying
transaction helper, multi-seed failover, transparent reconnect, TLS and a
connection pool that balances across the cluster's members.

- Repository: <https://github.com/porcupin26/skaidb-ruby>
- RubyGems: <https://rubygems.org/gems/skaidb>
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

The gem is published on RubyGems.org as
[`skaidb`](https://rubygems.org/gems/skaidb) and is loaded with
`require "skaidb"`:

```sh
gem install skaidb
```

With Bundler:

```ruby
# Gemfile
gem "skaidb", "~> 1.0"
```

Bundler resolves the gem's one dependency, `bigdecimal` (part of Ruby's
standard library, declared because it is a bundled rather than default gem
from Ruby 3.4), from RubyGems.org and compiles it, even on a Ruby that ships
it; that needs the Ruby headers and a C toolchain (`ruby-dev` and
`build-essential` on Debian/Ubuntu, `ruby-devel` and `gcc` on Fedora/RHEL,
Xcode command-line tools on macOS). `gem install skaidb` and vendoring reuse
the `bigdecimal` already installed.

Or vendor the single file: copy
[`lib/skaidb.rb`](https://github.com/porcupin26/skaidb-ruby/blob/v1.5.2/lib/skaidb.rb)
into your project and `require_relative` it. It has no dependencies beyond
Ruby's standard library.

Every release is also attached as a `.gem` to its
[GitHub release](https://github.com/porcupin26/skaidb-ruby/releases) for
installs without registry access: `gem install ./skaidb-1.5.2.gem`.

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
- [Connection pool](#connection-pool) — balancing across members,
  health ejection, discovery, read-your-writes
- [Streams (`CREATE STREAM`)](#streams-create-stream) — `subscribe`
- [Type mapping](#type-mapping)
- [Errors](#errors)
- [Transactions](#transactions) — `transaction`, `TransactionConflict`,
  hand-written `BEGIN`/`COMMIT`
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
  tls: false, tls_ca: nil, tls_insecure: false, tls_server_name: "skaidb",
  tls_client_cert: nil, tls_client_key: nil,   # PEM files: present a client certificate
  auth_mechanism: :scram       # or :certificate: the client certificate is the login
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
`Hello`, re-enters the session's database, and drops the connection's prepared
statements.

A connection the server closed **while it sat idle** — a member restart, a
failover, an idle timeout — costs no statement. Before a request is written
the driver looks at the socket (one peek that does not wait, no round trip): an idle connection
has nothing to read, so an end-of-file, a reset or stray bytes there mean it
is gone, and the statement goes out on a new connection instead. A
connection lost **under a statement** — the request was written and the
reply did not come — raises `Skaidb::ConnectionError`: the statement may
have run, so the driver does not send it again. The one after it re-dials.

The database re-entered is the one the session was last in: `database:`, or
the one a later `USE <name>` statement sent with `exec` moved it to. It is
entered before anything else is sent on the new socket, and if the server
refuses it the statement raises that error instead of running in another
database. The one statement that does not wait for it is a `USE`: when the
session's database is gone — dropped while the connection was down — a
`USE` of another database is sent to the new session without the old one
being entered first, so the connection can always be moved out of it.

Session settings come back with it. The last `SET CONSISTENCY …` and the
last `SET SCAN BUDGET …` the server accepted are sent again on the new
socket, after the database and before the statement; one cleared with
`… DEFAULT` is not. If the server refuses a setting there, the statement
raises that error: it never runs under other settings than the ones you
set.

### Timeout

`timeout` bounds the TCP dial only. Reads have no deadline: a peer that is
alive but silent blocks the caller, as in ruby-pg. `close` deliberately does
not take the connection's lock, so another thread can break a stuck read by
closing the connection. A statement cut short while its reply is outstanding
— by `Timeout.timeout`, an `Interrupt`, `Thread#kill` — leaves the connection
marked broken, so the next statement re-dials instead of reading that reply.
A connection marked broken closes its socket there and then: the server
drops the session, and a transaction open on it, without waiting for that
next statement.

### TLS

```ruby
conn = Skaidb.connect(host: "db1", tls: true)                     # system trust store
conn = Skaidb.connect(host: "db1", tls_ca: "/etc/skaidb/ca.crt")  # the cluster CA
conn = Skaidb.connect(host: "db1", tls_insecure: true)            # dev only: no verification
```

Any of the three enables TLS. The server name sent as SNI and checked against
the certificate is `tls_server_name` (default `"skaidb"`, the SAN skaidb's own
certificates carry). SCRAM runs inside the TLS session.

`tls_client_cert:` / `tls_client_key:` present a client certificate; with
`auth_mechanism: :certificate` that certificate is the login (its Common Name
is the user, no password is sent):

```ruby
conn = Skaidb.connect(host: "db1", tls_ca: "/etc/skaidb/ca.crt",
                      tls_client_cert: "app.crt", tls_client_key: "app.key",
                      auth_mechanism: :certificate)
```

Details: [docs/tls.md](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/tls.md).

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

These are the level each request carries. A `SET CONSISTENCY { ONE | QUORUM
| ALL }` statement is something else: it makes the server run every
statement of the session at that level whatever the request says, until
`SET CONSISTENCY DEFAULT` (server ≥ 0.349). The driver follows it, and
`SET SCAN BUDGET`, across re-dials — see
[Seeds and failover](#seeds-and-failover).

### Health

- `conn.usable?` — no round-trip. `true` unless the connection is closed, was
  left out of sync by a transport error, a reply that could not be read, a
  round trip cut short or an undrainable abandoned stream, or is currently
  mid-stream.
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

Prepared statements are cached per connection and reused. The server holds
at most 256 per connection, so the cache keeps to 240: before a new statement
would exceed that, the least recently used one is closed on the server. A
connection can therefore run any number of distinct parameterised statements,
every one with typed values. The cache is dropped when the connection
re-dials.

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
- `kind`: `:rows`, `:mutation` (a count in `cmd_tuples`) or `:ddl` (a bare
  acknowledgement), which tells "DDL succeeded" from "0 rows affected".
- `result_sets`: for a `CALL` whose procedure `EMIT`s several result sets,
  every set in order (each a `Result`); the last set is the result's own
  `rows`/`fields`. Empty for an ordinary reply.

A result holds all its rows in memory; for results that do not fit, stream.

## Streaming large results

`conn.stream(sql, params = [], consistency: nil)` runs the statement over the
streaming opcode and yields one row Hash at a time, holding **one chunk** in
memory:

```ruby
conn.stream("SELECT id, pad FROM big ORDER BY id") do |row|
  break if enough?(row)          # leaving early drains the tail
end

first = conn.stream("SELECT id FROM big ORDER BY id").first(10)   # Enumerator form

conn.stream("SELECT id, ts, body FROM events WHERE ts >= $1 AND ts < $2", [from, to]) do |row|
  export(row)                    # bound parameters, typed
end
```

`params` bind `$1`, `$2`, … exactly as `exec_params` binds them — typed, with
the same values accepted — and need a server ≥ 0.330: an older one raises
`QueryError` (`server does not support parameterised streaming (skaidb >=
0.330): …`), and there is no client-side text fallback. A stream without
parameters sends the original streaming opcode, which every server
understands. The server pages a plain `SELECT` (bare columns from one table,
unordered or in storage-key order), and no scan budget applies to a streamed
page (server ≥ 0.330). With a block `stream` returns a `Result` whose `kind`
is `:stream` and whose `fields` are the column names (the rows went to the
block); a non-row statement returns its `:mutation` / `:ddl` Result without
yielding. A `CALL` whose body `EMIT`s result sets is answered with all of
them in one frame even when streamed: the block receives the rows `exec`
would return (the last set), and `stream` returns that same `Result`, every
set under `result_sets`.

**The abandon/drain rule.** The connection is busy for the whole stream:
a statement from another thread waits for it. Leaving the block early —
`break`, `return`, an exception, or any Enumerable method on the Enumerator
form — drains the frames the server is still sending so the socket sits at a
request boundary again. Draining transfers the rest of the result: if you only
want the first rows, say so with `LIMIT`. External iteration (`next`/`peek`)
on the Enumerator form cannot unwind and leaves the connection marked busy;
iterate with a block or `each`. A frame that makes no sense mid-stream, a
dead socket, or a stream cut short while it waits for a frame (a `Timeout`,
an `Interrupt`) marks the connection broken instead; `usable?` turns `false`
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
undrained stream is closed and replaced; and an idle connection the server
closed while it sat in the pool is found by a look at its socket (no round
trip) and replaced before it is handed out.

Every borrower gets the pool's own session state: the pool's database
(`database:`, or `default` when it names none), no transaction open, and no
`SET CONSISTENCY` or `SET SCAN BUDGET` of an earlier borrower. Whatever a
borrower changed is put back when the connection is returned — a `ROLLBACK`,
a `USE`, a `SET … DEFAULT`, only the ones needed — and a connection that
cannot be put back is closed.

The pool spreads its connections across the members by the rules every skaidb
driver shares
([PROTOCOL.md §6.1](https://skaidb.org/docs/PROTOCOL.html#61-balancing-a-pool-across-members)):

```ruby
pool = Skaidb::Pool.new(seeds: ["db1", "db2", "db3"], database: "app",
                        load_balancing: :least_latency, # or :round_robin; :random is the default
                        discover: true,                 # members from SHOW ENDPOINTS, resyncing ones skipped
                        read_your_writes: 2.0)          # seconds; see affinity below

pool.with(affinity: user_id) { |conn| conn.exec_params("INSERT INTO notes (id, owner) VALUES ($1, $2)", [nid, user_id]) }
pool.with(affinity: user_id) { |conn| conn.exec_params("SELECT * FROM notes WHERE id = $1", [nid]) } # same member

pool.members # => [{ endpoint: "db1:7000", canonical: "10.0.0.1:7000", state: :ready,
             #      latency_ms: 0.8, in_use: 2, idle: 3, seed: true }, …]
```

A member with consecutive transport failures, or a round-trip average far
above the others', is ejected and re-admitted by a background probe (the last
usable member never is). The fastest of a member's first three round trips
seeds its average, so a statement that stalls in your own process cannot get
a healthy member ejected; a latency ejection's `logger:` warning names the
average, the median and the slowest of the member's last 10 round trips.
`idle_order: :fifo` keeps every idle connection in use. Details: [docs/pooling.md](https://github.com/porcupin26/skaidb-ruby/blob/main/docs/pooling.md).

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
        └── Skaidb::TransactionConflict  # a COMMIT refused: another writer changed a row it writes
```

- A server `Error` frame is a **statement** error (`QueryError`); the
  connection stays usable.
- A server error whose message starts with `transaction conflict:` is a
  `TransactionConflict`, from every call that runs a statement. It is a
  `QueryError`, so `rescue Skaidb::QueryError` catches it too; see
  [Transactions](#transactions).
- A transport failure (`ConnectionError`) marks the connection broken and
  closes its socket; the next statement re-dials, or a pool replaces it. So
  does a reply that cannot be read (a tag the protocol does not have, a
  message shorter than its own fields say), and so does anything else that
  cuts a statement short between its request and its reply (an `Interrupt`,
  a `Timeout`); that exception propagates as it is.
- `ArgumentError` for `Pool.new(maxsize: 0)` or an unknown
  `load_balancing`/`idle_order`, for `Skaidb::Uuid.new` of a string that
  is not a UUID, for `stream` parameters that are not an Array, and for
  `transaction` with `attempts` below 1 or without a block.

## Transactions

skaidb autocommits every statement outside a transaction. A transaction is
ordinary statements on **one connection**: an opening statement, the
statements, then `COMMIT` or `ROLLBACK`. `conn.transaction` does that around
a block and returns the block's value:

```ruby
conn.transaction do |c|
  c.exec_params("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [10, 1])
  c.exec_params("UPDATE accounts SET balance = balance + $1 WHERE id = $2", [10, 2])
end

conn.transaction(attempts: 5, begin: "BEGIN ATOMIC") { |c| … }
pool.transaction { |c| … }      # one checked-out connection for all of it
```

`begin:` is the opening statement, sent as given: `"BEGIN"` (the default) on
a standalone server; a cluster takes `BEGIN ATOMIC` or
`BEGIN ATOMIC PARTITION (col = lit)`. The rest is the same on both.

**Conflicts.** A standalone server (≥ 0.346) refuses a `COMMIT` when another
writer changed a row the transaction writes after its `BEGIN`. Nothing was
applied, the transaction is over, and the connection is back in autocommit
and stays usable. The driver raises `Skaidb::TransactionConflict` for it — a
`QueryError` carrying the server's message, recognised by its
`transaction conflict:` prefix, from `exec` and every other call as well as
from the helper. Running the whole transaction again from its opening
statement is safe, and that is what `transaction` does: up to `attempts` runs
in all (default 3), with no pause between them — the other writer has
already finished, and the next run reads the rows as they are now. So **the
block must be safe to run more than once**, and should do nothing outside the
database that a repeat would do twice. The conflict of the last attempt is
raised.

What else `transaction` does:

- The opening statement is refused: its error is raised, the block never
  runs and nothing else is sent.
- The block does not run to its end (an exception, `break`, `throw`):
  `ROLLBACK` is sent, and the block's exception propagates unchanged
  whatever the `ROLLBACK` itself answers. Nothing is retried, a
  `TransactionConflict` raised inside the block included.
- Any other `COMMIT` error is raised as it is, with no retry and no
  `ROLLBACK`: a `COMMIT` that fails has ended the transaction.
- A transport failure is the usual `ConnectionError` and is not retried. The
  transaction lived on the socket that died, so until `transaction` returns
  the connection does not re-dial: no `ROLLBACK` is sent, and a statement the
  block still runs after rescuing the failure raises `ConnectionError`
  instead of running on a new session. The same goes for a block cut short
  in the middle of a round trip (an `Interrupt`, a `Timeout`): the reply is
  still on its way, so nothing more is written to that socket. Either way
  the socket is closed at once, and the server drops the transaction with
  it.
- Such an exception can also land between two statements — just after the
  opening statement's reply, or with the block done and `COMMIT` not yet
  written. `transaction` never leaves a transaction open on a connection
  that goes on being used: unless the server has answered a `ROLLBACK` or
  the `COMMIT`, the socket is closed, the server drops the transaction with
  it, and the connection's next statement re-dials.
- A stream the block leaves open — an Enumerator from `stream` advanced with
  `next` or `peek` and not read to its end — sits in the middle of its
  reply, so neither `COMMIT` nor `ROLLBACK` can be sent. The socket is
  closed instead, the server drops the transaction with it, and
  `transaction` raises `ConnectionError` — unless the block was itself
  leaving with an exception, `break` or `throw`, which carries on. The
  stream is ended too, so the connection's next statement re-dials as after
  any lost connection. Read a stream to its end, or give `stream` a block,
  before the transaction's block returns.
- `pool.transaction(attempts: 3, begin: "BEGIN", affinity: nil)` checks one
  connection out, runs every attempt on it, and returns it afterwards.

Written by hand, the same transaction is:

```ruby
conn.exec("BEGIN")                 # if this raises, stop here
begin
  conn.exec_params("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [10, 1])
  conn.exec_params("UPDATE accounts SET balance = balance + $1 WHERE id = $2", [10, 2])
rescue StandardError
  begin
    conn.exec("ROLLBACK")
  rescue Skaidb::Error
    nil                            # the clean-up never replaces the error it follows
  end
  raise
end
conn.exec("COMMIT")                # Skaidb::TransactionConflict: nothing was applied; run it again from BEGIN
```

The driver follows a transaction written this way: a statement the server
accepted whose first word is `BEGIN` opens it, and `COMMIT [TRANSACTION]` or
`ROLLBACK [TRANSACTION]` ends it once the server has answered, with success
or with an error (sent with `exec`, `query`, `exec_params` or `stream`; `--`
comments are skipped). While it is open **a lost connection is not
replaced**, exactly as inside `transaction`: a new session has no
transaction open, and the rest of the statements, and the `COMMIT`, would
each be committed on their own there.

- The statement under which the connection is lost raises
  `Skaidb::ConnectionError`, and so does every statement after it; none is
  sent.
- `ROLLBACK` then succeeds without being sent — the server discarded the
  transaction with the connection — and `COMMIT` raises `ConnectionError`
  (`connection lost inside a transaction: COMMIT was not sent and nothing
  was committed`). Either one ends the transaction for the driver; the next
  statement re-dials as after any lost connection.
- A connection lost under the `COMMIT` itself leaves the outcome unknown —
  the server may have applied it before its reply went missing — and the
  `ConnectionError` says so (`connection lost under COMMIT: whether the
  transaction was committed is not known`).

Two rules hold however the statements are sent:

- **One connection for the whole transaction.** Statements sent on another
  connection are not part of it, so with a pool check one connection out
  (`pool.with`) and keep it until the `COMMIT`; a statement another thread
  sends on that connection meanwhile is part of it.
- **Stop if `BEGIN` fails.** No transaction is open, so every statement sent
  after it would be committed on its own.

A statement that fails inside a transaction leaves it open: decide between
`ROLLBACK` and carrying on. A `ROLLBACK` with no transaction open succeeds on
a server ≥ 0.347 and is a statement error (`no transaction in progress`) on
an older one.

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
-- ruby | 1.5.2
```

The server records the row asynchronously, so a `SELECT` immediately after
connecting may not show it yet. `Hello` is telemetry: a server that does not
know the opcode answers with an error the driver ignores.

## Compatibility

- Ruby 2.7 – 3.4 (CI covers 3.1 – 3.4), MRI. No third-party dependencies;
  `bigdecimal` is declared because it is a bundled gem since Ruby 3.4.
- Works with any skaidb server. Where a server predates an opcode the driver
  falls back: prepared statements → client-side text binding, `Hello` →
  ignored, pool discovery (`SHOW ENDPOINTS`, server ≥ 0.327) → the
  configured seeds. `stream` and `exec_batch` need a server with those
  opcodes, and `stream` with parameters a server ≥ 0.330; they raise
  `QueryError` otherwise.
- The wire protocol (framing, SCRAM handshake, value encoding, opcodes) is
  specified at <https://skaidb.org/docs/PROTOCOL.html>. The driver speaks the
  binary protocol on port 7000; the server's REST/JSON gateway (port 7080)
  is a dependency-free alternative for other clients.

## Conformance

`test/conformance_test.rb` runs skaidb's shared wire-protocol conformance
suite, vendored byte-identical from the server repository in
[`conformance/`](https://github.com/porcupin26/skaidb-ruby/tree/main/conformance)
(`vectors.json` plus the contract in its `README.md`), as part of `rake test`:

- every value vector decodes to the expected Ruby value and encodes back to
  the reference bytes (a Uuid cell is compared as its canonical String, the
  form the driver returns);
- every SCRAM vector (auth message, salted password, client proof, server
  signature) through the driver's own SCRAM code;
- the auth outcomes against a fake server that verifies the client proof
  independently: `ok` connects, a server signature that does not verify
  fails the connect, `denied` fails with the server's reason;
- every case through the public API (`exec`, `stream`, `exec_params`,
  `exec_batch`, and sequences of them on one connection), checking the exact
  request bytes and the decoded result. The vectors' `?` placeholders are
  passed as this driver's `$1`, `$2`, ….

Nothing is skipped: the test prints `skipped call methods: none`. CI also
fails when the vendored `vectors.json` differs from the published
<https://skaidb.org/conformance/vectors.json>.

## Examples

[`examples/`](https://github.com/porcupin26/skaidb-ruby/tree/main/examples)
contains runnable scripts: `basic.rb`, `prepared_batch.rb`, `stream.rb`,
`transaction.rb`, `pool.rb`, `tls.rb`, `subscribe.rb`. Each takes
`host port user password` on the command line and defaults to
`localhost:7000`; the arguments after those differ per script:

- `basic.rb`, `prepared_batch.rb`, `stream.rb`, `transaction.rb`, `pool.rb`:
  `[database]`
- `subscribe.rb`: `[database] [stream]` (the stream defaults to
  `orders_stream`)
- `tls.rb`: `[ca.crt]`, a CA file to trust; without it the script uses the
  system trust store, or verifies nothing when `SKAIDB_TLS_INSECURE` is set
  (development only). It takes no database argument.

```sh
ruby examples/basic.rb localhost 7000 skaidb secret app
ruby examples/subscribe.rb localhost 7000 skaidb secret app orders_stream
ruby examples/tls.rb localhost 7000 skaidb secret /etc/skaidb/ca.crt
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

### Releasing

A release is a tag. Bump `Skaidb::VERSION` in `lib/skaidb.rb`, add the
`## [x.y.z]` entry to `CHANGELOG.md`, commit, then tag and push:

```sh
git tag v1.2.3 && git push origin main v1.2.3
```

[`publish.yml`](https://github.com/porcupin26/skaidb-ruby/blob/main/.github/workflows/publish.yml)
then runs the tests, checks the tag against `Skaidb::VERSION`, builds the
gem, pushes it to [RubyGems.org](https://rubygems.org/gems/skaidb) with the
`RUBYGEMS_API_KEY` repository secret (a rubygems.org API key with the push
scope; without the secret the push is skipped with a notice) and creates the
GitHub Release with the `.gem` attached.

## License

[SSPL-1.0](https://github.com/porcupin26/skaidb-ruby/blob/main/LICENSE) (Server Side Public License), the same license as skaidb.
