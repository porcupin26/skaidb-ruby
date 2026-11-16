# API reference

Everything lives under the `Skaidb` module in `lib/skaidb.rb`.

## `Skaidb.connect(**options) → Connection`

| Keyword | Default | Meaning |
|---|---|---|
| `host` | `"localhost"` | Node to dial (ignored when `seeds` is given). |
| `port` | `7000` | Binary-protocol port; also the port for a seed without one. |
| `user` | `"anonymous"` (SCRAM), `""` (certificate) | User name. Under `auth_mechanism: :certificate` it is optional and, when given, must equal the certificate's Common Name. |
| `password` | `""` | SCRAM password. Empty skips server-signature verification (anonymous connect). |
| `consistency` | `:quorum` | Default level for every statement: `:one`, `:quorum`, `:all`, `"ONE"`…, or `0`/`1`/`2`. |
| `timeout` | `10.0` | TCP connect timeout in seconds; `nil` for none. Reads are not bounded. |
| `database` | `nil` | Runs `USE "<database>"` after the handshake (and after every re-dial). |
| `seeds` | `nil` | `["host", "host:port", …]`, tried in random order until one connects **and** authenticates. |
| `tls` | `false` | Enable TLS with the system trust store. |
| `tls_ca` | `nil` | PEM file to trust instead of the system store; implies `tls`. |
| `tls_insecure` | `false` | TLS without any certificate verification; implies `tls`. Development only. |
| `tls_server_name` | `"skaidb"` | SNI name, also checked against the certificate's SANs. |
| `tls_client_cert` | `nil` | PEM file of a client certificate to present in the TLS handshake; implies `tls`. Needs `tls_client_key`. |
| `tls_client_key` | `nil` | PEM file of that certificate's private key. |
| `auth_mechanism` | `:scram` | `:scram` (user + password) or `:certificate` (the client certificate is the login, wire mechanism EXTERNAL; needs `tls_client_cert`/`tls_client_key`). Strings and the aliases `"password"`, `"external"`, `"x509"` are accepted. |

With a block, yields the connection and closes it when the block returns
(the block's value is returned). Raises `Skaidb::ConnectionError` when no
endpoint accepts the handshake (`no reachable endpoint in …: <last error>`),
`authentication denied: …` on a wrong password, and
`server signature mismatch` when the server fails mutual authentication.
Raises `Skaidb::Error` before dialing for an unknown `auth_mechanism`, a
`tls_client_cert` without its `tls_client_key` (or the reverse), and
`:certificate` without a client certificate.

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
  The id is valid on the socket that prepared it: on a broken connection
  this raises `ConnectionError` instead of re-dialing, and `prepare_server`
  hands out a new id.
- `prepare_server(sql) → [id, nparams] | nil` — prepare a statement with `?`
  placeholders on the server; `nil` when the server refuses. Cached per
  connection (240 entries); the cache is cleared on re-dial.
- `stream(sql, params = [], consistency: nil) { |row| … } → Result` — see
  [streaming.md](streaming.md). `params` (an Array) bind `$1`, `$2`, …
  exactly as `exec_params` binds them, typed, over `OP_QUERY_STREAM_PARAMS`
  (server ≥ 0.330; an older one raises `QueryError` `server does not support
  parameterised streaming (skaidb >= 0.330): …`, with no text fallback);
  without parameters (`nil` or `[]`) the request is the original
  `OP_QUERY_STREAM`, which every server understands. A placeholder/parameter
  mismatch or a value that cannot be bound raises `QueryError` before
  anything is sent, and `params` that are not an Array raise
  `ArgumentError`. For a row stream the returned Result has
  `kind == :stream`, the column names in `fields` and no `rows` (they went to
  the block); a statement without rows returns its `:mutation` / `:ddl`
  Result without yielding; a `CALL` whose body `EMIT`s result sets (answered
  in one frame even when streamed) yields the rows `exec` would return (the
  last set) and returns that same `:rows` Result, every set under
  `result_sets`. Without a block returns an Enumerator.
- `subscribe(stream_name, after: nil, poll: 0.5) { |event| … }` — yields a
  `CREATE STREAM` log's events forever, each a Hash with `"id"`, `"op"`,
  `"k"`, `"ts"`, `"doc"`. Polls `_stream_<name>` 500 rows at a time with a
  keyset cursor, sleeping `poll` seconds when caught up. `after:` is the last
  `"id"` (an opaque String) already handled.

### Transactions

`transaction(attempts: 3, begin: "BEGIN") { |conn| … } → the block's value`
runs the block inside a transaction on this connection: it sends `begin`,
yields the connection, then sends `COMMIT`.

- `begin:` is the opening statement, sent as given: `"BEGIN"` on a standalone
  server, `"BEGIN ATOMIC"` or `"BEGIN ATOMIC PARTITION (col = lit)"` on a
  cluster.
- A `COMMIT` refused with `TransactionConflict` (a standalone server ≥ 0.346:
  another writer changed a row the transaction writes after its `BEGIN`;
  nothing was applied) runs the whole transaction again from `begin`, up to
  `attempts` runs in all with no pause between them. The block may therefore
  run more than once: it must be safe to repeat and should do nothing outside
  the database that a repeat would do twice. The conflict of the last
  attempt is raised.
- `begin` refused: its error is raised, the block never runs and nothing
  else is sent.
- The block does not run to its end (an exception of any class, `break`,
  `throw`, a `return` out of it): `ROLLBACK` is sent and the exception
  propagates unchanged, whatever the `ROLLBACK` itself answers — an error
  from it is ignored. Nothing is retried, a `TransactionConflict` raised
  inside the block included.
- Any other `COMMIT` error is raised as it is, with no retry and no
  `ROLLBACK` (a `COMMIT` that fails has ended the transaction).
- A transport failure is the usual `ConnectionError` and is not retried.
  Until `transaction` returns the connection does not re-dial: no `ROLLBACK`
  is sent, and a statement the block runs after rescuing the failure raises
  `ConnectionError` (`connection lost inside a transaction; …`). A
  `ConnectionError` from the `COMMIT` leaves its outcome unknown.
- A block cut short in the middle of a round trip (an `Interrupt`, a
  `Timeout`, `Thread#kill`) leaves a reply on its way, so the connection is
  not `usable?` and nothing more is written to it: no `ROLLBACK`. The
  transaction ends with that socket, which is closed at once — the server
  drops the transaction with it — and which the next statement after
  `transaction` replaces.
- A stream the block leaves open (an Enumerator from `stream` advanced with
  `next`/`peek` and not read to its end) sits in the middle of its reply, so
  neither `COMMIT` nor `ROLLBACK` can be sent. The connection is marked
  broken — its socket closed, so the server drops the transaction — and the
  stream is ended, which frees the connection: its next statement re-dials.
  `transaction` raises `ConnectionError` (`a stream opened inside the
  transaction was left open, …`) when the block ran to its end; a block
  that was leaving with an exception, `break` or `throw` leaves with that.
  The Enumerator, advanced again, starts its statement again on the
  re-dialled connection, outside any transaction. (A stream opened by
  another thread cannot be ended from here: the connection is closed for
  good instead, `finished?` is `true`.)
- Raises `ArgumentError`, before anything is sent, when `attempts` is not an
  Integer ≥ 1 or no block is given.

The whole transaction runs on this one connection, so no other thread may
use it meanwhile.

### State

- `consistency` / `consistency=` — the default level (`0`/`1`/`2`; the setter
  accepts anything `Consistency.resolve` does).
- `usable?` — `false` once closed, once a transport error broke the socket
  or a round trip was cut short with its reply outstanding, or while a
  stream is in flight (including one abandoned through external iteration).
  No round-trip.
- `endpoint` — the member the connection reached, as the `"host:port"` it
  dialed (it changes when a re-dial lands on another member).
- `closed`, `finished?` — `true` after `close`.
- `close` — closes the socket; idempotent. Does not take the connection's
  lock, so another thread can use it to break a blocked read.

### Reconnect

A transport failure raises `Skaidb::ConnectionError` and marks the
connection broken. A statement cut short between its request and its reply
by anything else (an `Interrupt`, `Timeout.timeout`, `Thread#kill`) marks it
broken too, since that reply is still on its way; the exception propagates
as it is. A connection marked broken closes its socket there and then, so
the server drops the session — and a transaction left open on it — without
waiting for the connection's next statement or its `close`. The next
`exec`/`exec_params`/`exec_batch`/`stream`
re-dials across the original seeds (a pooled connection: in the pool's
order, usable members first and the one it lost last), re-authenticates,
re-sends `Hello`, re-runs `USE`, and starts with an empty prepared-statement
cache. If the re-dial fails, that statement raises `ConnectionError` and the
one after it tries again. Inside `transaction` there is no re-dial: the
transaction ended with its socket, so every further statement raises
`ConnectionError` until the helper returns.

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
| `kind` | What the server answered: `:rows` (a result set, or several in `result_sets`), `:mutation` (a count in `cmd_tuples`), `:ddl` (a bare acknowledgement — no rows and no count), `:stream` (the summary `stream` returns). |
| `result_sets` | For a `CALL` whose body `EMIT`s, every result set in order (each a `Result`); the last one is this result's own `rows`/`fields`. `[]` otherwise. |

## `Skaidb::Pool`

```ruby
Skaidb::Pool.new(maxsize: 10, load_balancing: :random, idle_order: :lifo, discover: false,
                 refresh_interval: 60.0, read_your_writes: 0.0, eject_errors: 3,
                 eject_latency_factor: 3.0, eject_latency_floor: 0.05, eject_backoff: 5.0,
                 eject_backoff_max: 60.0, logger: nil, **connect_options)
```

A thread-safe pool balanced across the cluster's members — see
[pooling.md](pooling.md) for every option.

- `with(affinity: nil) { |conn| … }` — check out, yield, check in; returns
  the block's value.
- `transaction(attempts: 3, begin: "BEGIN", affinity: nil) { |conn| … }` —
  `Connection#transaction` on one checked-out connection, held for every
  attempt and checked in afterwards; returns the block's value. The
  arguments are checked before a connection is checked out.
- `checkout(affinity: nil) → Connection` — an idle connection to the member
  the policy picks, or a new one. Never blocks. `affinity` (any Hash key;
  `nil` = pool-wide) scopes `read_your_writes`.
- `checkin(conn)` — return it; closed instead when broken, when its member
  is ejected or gone, or when `maxsize` are already idle.
- `members → Array<Hash>` — per member: `:endpoint`, `:canonical`, `:state`
  (`:ready`, `:ejected`, `:resyncing`, `:unreachable`, `:unlisted`),
  `:latency_ms` (`nil` until measured), `:in_use`, `:idle`, `:seed`.
- `close` — closes the idle connections and stops the background thread.

`load_balancing` (`:random`, `:round_robin`, `:least_latency`) and
`idle_order` (`:lifo`, `:fifo`) take a Symbol or a String. Raises
`ArgumentError` for `maxsize < 1`, `eject_errors < 1`, an unknown
`load_balancing`/`idle_order` or a `transaction` with `attempts` below 1 or
no block, and `Skaidb::Error` on checkout from a closed pool.

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
- `Skaidb::TransactionConflict < QueryError` — the server refused a `COMMIT`
  because another writer changed a row the transaction writes after its
  `BEGIN` (a standalone server ≥ 0.346). Raised by every call that runs a
  statement, for a server error whose message starts with
  `Skaidb::TransactionConflict::PREFIX` (`"transaction conflict:"`); the
  message is the server's. Nothing was applied, the transaction is over and
  the connection stays usable, in autocommit; running the whole transaction
  again from `BEGIN` is safe, which is what `transaction` does.

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
