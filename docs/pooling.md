# Connection pool

`Skaidb::Pool` keeps a bounded set of idle connections and hands one to each
caller, so a threaded server or job runner can use one connection per
thread without dialing and authenticating on every request.

```ruby
pool = Skaidb::Pool.new(seeds: ["db1", "db2", "db3"], user: "app", password: "secret",
                        database: "app", maxsize: 8)

pool.with do |conn|                          # checked out; returned when the block ends
  conn.exec_params("SELECT … WHERE id = $1", [id])
end

conn = pool.checkout                         # the explicit form
begin
  conn.exec("…")
ensure
  pool.checkin(conn)
end

pool.close                                   # closes every idle connection
```

## Behaviour

- Every `Skaidb.connect` keyword passes through (`seeds`, `database`, TLS,
  `consistency`, `timeout`), so pooled connections fail over across seeds
  and run `USE` exactly like single ones.
- `maxsize` (default 10) bounds the connections kept **idle**, not the number
  checked out. `checkout` never blocks: with no idle connection available it
  dials a new one, and a connection returned while `maxsize` are already idle
  is closed instead of kept.
- `checkout` and `checkin` both validate with `usable?`: a connection broken
  by a transport error, or left mid-stream by an abandoned Enumerator, is
  closed and dropped rather than handed on. `usable?` is local knowledge
  only — a connection the server closed while it sat idle still looks fine
  and will fail its first statement with `Skaidb::ConnectionError`; that
  failure marks it broken, so `checkin` discards it and the next checkout
  gets a fresh one. Retry the statement in that case if it is safe to.
- `close` marks the pool closed and closes the idle connections; connections
  checked out at the time are closed when they are returned. `checkout` on a
  closed pool raises `Skaidb::Error`. `maxsize < 1` raises `ArgumentError`.
- The pool is thread-safe. A single connection should still be used by one
  thread at a time; the pool is what gives each thread its own.

See also `examples/pool.rb`.
