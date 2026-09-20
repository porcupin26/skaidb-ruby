# API reference

Everything lives under the `Skaidb` module in `lib/skaidb.rb`.

## `Skaidb.connect(**options) → Connection`

| Keyword | Default | Meaning |
|---|---|---|
| `host` | `"localhost"` | Node to dial (ignored when `seeds` is given). |
| `port` | `7000` | Binary-protocol port; also the port for a seed without one. |
| `user` | `"anonymous"` | SCRAM user name. |
| `password` | `""` | SCRAM password. Empty skips server-signature verification (anonymous connect). |
| `consistency` | `:quorum` | Default level for every statement: `:one`, `:quorum`, `:all`, `"ONE"`…, or `0`/`1`/`2`. |
| `timeout` | `10.0` | TCP connect timeout in seconds; `nil` for none. Reads are not bounded. |
| `database` | `nil` | Runs `USE "<database>"` after the handshake (and after every re-dial). |
| `seeds` | `nil` | `["host", "host:port", …]`, tried in random order until one connects **and** authenticates. |
| `tls` | `false` | Enable TLS with the system trust store. |
| `tls_ca` | `nil` | PEM file to trust instead of the system store; implies `tls`. |
| `tls_insecure` | `false` | TLS without any certificate verification; implies `tls`. Development only. |
| `tls_server_name` | `"skaidb"` | SNI name, also checked against the certificate's SANs. |

With a block, yields the connection and closes it when the block returns
(the block's value is returned). Raises `Skaidb::ConnectionError` when no
endpoint accepts the handshake (`no reachable endpoint in …: <last error>`),
`authentication denied: …` on a wrong password, and
`server signature mismatch` when the server fails mutual authentication.

## `Skaidb::Connection`

### Statements

- `exec(sql) → Result` (alias `query`) — run a statement with no parameters
  at the connection's consistency.
- `exec_params(sql, params = [], consistency: nil) → Result` — bind `$1`,
  `$2`, … from `params` (an Array), preparing the statement on the server and
  sending the values typed. Falls back to client-side text binding when the
  server refuses to prepare the statement (DDL, `USE`, old servers); on that
  path an Array/Hash parameter raises `QueryError` that includes the server's
  refusal reason. `consistency:` overrides the connection default for this
  statement.
- `exec_batch(sql, rows, consistency: nil) → Integer` — prepare once, execute
  once per row in one frame, return the total affected count. `rows` is an
  Array of parameter Arrays. An empty `rows` returns `0` with no round-trip.
  Raises `QueryError` if the statement cannot be prepared, if a row's length
  differs from the statement's parameter count, or with the server's message
  (which names the failing row index; earlier rows stay applied).
- `exec_prepared(id, params, consistency) → Result` — run a statement by the
  id `prepare_server` returned, with an Array of typed values in `?` order.
- `prepare_server(sql) → [id, nparams] | nil` — prepare a statement with `?`
  placeholders on the server; `nil` when the server refuses. Cached per
  connection (240 entries); the cache is cleared on re-dial.
- `stream(sql, consistency: nil) { |row| … } → nil` — see
  [streaming.md](streaming.md). Without a block returns an Enumerator.
- `subscribe(stream_name, after: nil, poll: 0.5) { |event| … }` — yields a
  `CREATE STREAM` log's events forever, each a Hash with `"id"`, `"op"`,
  `"k"`, `"ts"`, `"doc"`. Polls `_stream_<name>` 500 rows at a time with a
  keyset cursor, sleeping `poll` seconds when caught up. `after:` is the last
  `"id"` (an opaque String) already handled.

### State

- `consistency` / `consistency=` — the default level (`0`/`1`/`2`; the setter
  accepts anything `Consistency.resolve` does).
- `usable?` — `false` once closed, once a transport error broke the socket,
  or while a stream is in flight (including one abandoned through external
  iteration). No round-trip.
- `closed`, `finished?` — `true` after `close`.
- `close` — closes the socket; idempotent. Does not take the connection's
  lock, so another thread can use it to break a blocked read.

### Reconnect

A transport failure raises `Skaidb::ConnectionError` and marks the
connection broken. The next `exec`/`exec_params`/`exec_batch`/`stream`
re-dials across the original seeds, re-authenticates, re-sends `Hello`,
re-runs `USE`, and starts with an empty prepared-statement cache. If the
re-dial fails, that statement raises `ConnectionError` and the one after it
tries again.

## `Skaidb::Result`

Shaped like `PG::Result`; `Enumerable` over row Hashes.

| Member | Meaning |
|---|---|
| `fields` (alias `columns`) | Column names, in order. |
| `nfields` / `num_fields` | Column count. |
| `rows` | Rows as Arrays of decoded values. |
| `ntuples` / `num_tuples` | Row count. |
| `each { |hash| }` / `to_a` / `values` | Rows as Hashes with String keys. |
| `[i]` | Row `i` as a Hash, or `nil`. |
| `getvalue(row, col)` | One cell; `col` is an index or a column name. |
| `cmd_tuples` | Rows affected by `INSERT`/`UPDATE`/`DELETE`; `0` for `SELECT` and DDL. |
| `result_sets` | For a `CALL` whose body `EMIT`s, every result set in order (each a `Result`); the last one is this result's own `rows`/`fields`. `[]` otherwise. |

## `Skaidb::Pool`

`Skaidb::Pool.new(maxsize: 10, **connect_options)` — see
[pooling.md](pooling.md). `with { |conn| }`, `checkout`, `checkin(conn)`,
`close`. Raises `ArgumentError` for `maxsize < 1` and `Skaidb::Error` on
checkout from a closed pool.

## `Skaidb::Uuid`

A value wrapper for binding a UUID with the Uuid type tag (results decode to
a canonical String). `Uuid.new(str)` accepts 32 hex digits with or without
dashes and raises `ArgumentError` otherwise; `Uuid.random` (version 4);
`Uuid.from_bytes(raw16)`; `to_s` (canonical lowercase), `bytes` (16 raw
bytes), `==`/`eql?`/`hash` (equal to another `Uuid` or to a String with the
same canonical form).

## `Skaidb::Consistency`

`ONE = 0`, `QUORUM = 1`, `ALL = 2`; `resolve(value)` maps a Symbol, a String
(any case) or an Integer to the wire value and raises `Skaidb::Error`
otherwise.

## Errors

- `Skaidb::Error < StandardError` — base class; raised directly for an
  invalid consistency level and for checkout from a closed pool.
- `Skaidb::ConnectionError < Error` — dial, handshake, framing and transport
  failures; a statement on a closed connection. The connection is broken and
  will re-dial on the next statement.
- `Skaidb::QueryError < Error` — the server rejected the statement (the
  message is the server's), or a parameter could not be bound
  (placeholder/parameter mismatch, out-of-range Integer, non-finite Float or
  BigDecimal, unsupported type). The connection stays usable.

## Codec helpers

Exposed for tests and tooling: `Skaidb.encode_value(v)` / `Skaidb.decode_value(reader)`
(the §4 value codec), `Skaidb::Reader`, `Skaidb.quote(v)` and
`Skaidb.bind(sql, params)` (the client-side text fallback),
`Skaidb.to_qmark(sql, params)` (`$N` → `?` rewrite with the values in wire
order), `Skaidb.decimal_parts(bigdecimal)`, `Skaidb.time_ms(time)`,
`Skaidb.format_uuid(bytes)`, `Skaidb.scram(password, salt, iterations, auth_message)`.

## `Skaidb::VERSION`

The package version, defined once in `lib/skaidb.rb`. The gemspec reads it
and the driver sends it in the `Hello` frame after every handshake; the
server shows it in the `drivers` table (`client_name = 'ruby'`,
`client_version = Skaidb::VERSION`). The server records that row
asynchronously, so a query issued immediately after connecting may not show
it yet.
