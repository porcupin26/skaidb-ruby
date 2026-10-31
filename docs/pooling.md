# Connection pool

`Skaidb::Pool` keeps a bounded set of idle connections and hands one to each
caller, so a threaded server or job runner can use one connection per
thread without dialing and authenticating on every request. It spreads its
connections across the cluster's members by the rules every skaidb driver
shares.

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

## API

```ruby
Skaidb::Pool.new(
  maxsize: 10,
  load_balancing: :random,      # :random | :round_robin | :least_latency
  idle_order: :lifo,            # :lifo | :fifo
  discover: false,              # read the members from SHOW ENDPOINTS
  refresh_interval: 60.0,       # seconds between discovery refreshes
  read_your_writes: 0.0,        # seconds; 0 = off
  eject_errors: 3,              # consecutive transport failures
  eject_latency_factor: 3.0,    # x the other members' median; 0 = off
  eject_latency_floor: 0.05,    # seconds above the median, at least
  eject_backoff: 5.0,           # first ejection, doubling per repeat
  eject_backoff_max: 60.0,
  logger: nil,                  # anything with #warn: ejections, re-admissions
  **connect_options             # every Skaidb.connect keyword
)

pool.with(affinity: nil) { |conn| … }   # the block's value
pool.checkout(affinity: nil)  -> Skaidb::Connection
pool.checkin(conn)
pool.members                  -> Array of Hashes (see "Watching it")
pool.close
```

`load_balancing` and `idle_order` take a Symbol or a String. `host`/`port`/
`seeds` name the starting members; the other `Skaidb.connect` keywords
(`database`, TLS, `consistency`, `timeout`) apply to every connection, so
pooled connections run `USE` and authenticate exactly like single ones. A
pooled connection that re-dials after a transport error does so in the
pool's order: usable members first, the one it lost last.
`Connection#endpoint` names the member a connection reached.

## Balancing across members

With the default `load_balancing: :random` each new connection dials the
members in random order and stays on the member it reached — fine for many
clients, but one process can end up with most of its connections on one
member. Pick a policy to spread a single process's load:

```ruby
pool = Skaidb::Pool.new(
  seeds: ["db1", "db2", "db3"], database: "app", user: "app", password: pw,
  load_balancing: :least_latency, # or :round_robin
  discover: true,                 # learn the members from the cluster
  read_your_writes: 2.0,          # seconds; see below
  idle_order: :fifo
)
```

| Option | Default | What it does |
|---|---|---|
| `load_balancing` | `:random` | `:round_robin`: checkouts rotate over the usable members in endpoint order. `:least_latency`: of two members picked at random, the one with the lower round-trip average × (checked-out connections + 1), so near and idle members win; a member not measured yet, or not in the last 2 s, scores 0 and is tried, so a lightly loaded pool keeps re-measuring every member. |
| `idle_order` | `:lifo` | `:lifo` hands out the most recently returned connection first, so a quiet pool keeps few sockets warm. `:fifo` hands out the longest-idle one first, so every idle connection keeps being used and a server-side idle timeout never finds one. |
| `discover` | `false` | Reads the members with `SHOW ENDPOINTS` (server ≥ 0.327; no privilege needed) when a member is first reached and every `refresh_interval` (60 s) after — every 5 s while a member is `resyncing` or `unreachable`. New members are added, members that left are dropped (seeds are kept, marked `unlisted`), and members the server reports `resyncing` or `unreachable` get no new connections until they are `ready` again, when they start with a fresh latency average. An older or standalone server leaves the seeds as they are, and the pool stops asking. |
| `eject_errors` | `3` | Consecutive transport failures (a failed dial, an I/O error mid-request, a capacity refusal) that eject a member. Statement errors and refused logins do not count. |
| `eject_latency_factor`, `eject_latency_floor` | `3.0`, `0.05` | A member whose round-trip average is above factor × the other usable members' median **and** more than floor seconds above it is ejected (once it and another member have 10 samples each). The fastest of a member's first three round trips seeds its average, so a statement that stalls in your own process — a CPU-bound start-up — cannot get a healthy member ejected; the `logger` warning names the average, the median and the slowest of the member's last 10 round trips. A factor of `0` disables it. |
| `eject_backoff`, `eject_backoff_max` | `5.0`, `60.0` | How long an ejection lasts, doubling for each repeat up to the max; a member that stays healthy for `eject_backoff_max` after a re-admission starts over at the base. When the time is up a background thread dials the member and runs one statement: success re-admits it (with a fresh latency average), failure ejects it again. The last usable member is never ejected — a slow or flaky member beats none. |
| `read_your_writes` | `0.0` | Seconds after a write during which checkouts with the same `affinity` go to the member that took the write. |
| `logger` | `nil` | A `Logger` (or anything with `warn`) told of each ejection and re-admission. |

An ejected member gets no new connections and its idle ones are closed; a
connection to it that is returned to the pool is closed instead of kept.
With a target member (round-robin, least-latency, an affinity) the pool
hands out an idle connection to that member or dials it; a failed dial falls
through to the other usable members, then to the unusable ones, so a
checkout never has nowhere to go while any member is configured.

**Latency.** Per member the pool keeps an exponentially weighted average of
round trips (request sent to the first response frame). The fastest of the
member's first three round trips seeds it: a round trip is only ever
lengthened — by the member, the network or your own process (a thread that
stalls while the application starts, say) — so one or two slow first
statements cannot set it. From then on each sample moves it 5 % of the way,
and no sample counts for more than 10 × the larger of the current average
and `eject_latency_floor`. One slow statement barely moves it; a member that
stays slow is noticed within a few dozen statements. Until its average is
seeded a member counts as not measured.

**Read-your-writes.** The member that coordinated a write reads it back at
any consistency, `ONE` included; another member may not have applied it yet.
With `read_your_writes` set, pass an affinity key — a user or session id —
when you check out:

```ruby
pool.with(affinity: user_id) do |conn|
  conn.exec_params("INSERT INTO notes (id, owner, body) VALUES ($1, $2, $3)", [nid, user_id, body])
end
# … the next request for the same user, within the window:
pool.with(affinity: user_id) do |conn|        # same member
  conn.exec_params("SELECT body FROM notes WHERE id = $1", [nid])
end
```

The window starts when a write succeeds on a connection checked out under
the key, and checkouts under it go to that member until the window ends
(unless the member is ejected or not `ready`). Checkouts without a key
share one pool-wide key, so with constant writes everything follows the
latest writer — pass a key when you balance. A statement is a write unless
its first keyword (after whitespace, comments and opening parentheses) is
`SELECT`, `SHOW`, `EXPLAIN`, `DESCRIBE`, `DESC`, `VALUES`, `WITH` or `USE`.

Derive the key without touching the pool: if it comes from something that
itself queries the database through the same pool (a web framework's
"current user" loader), a helper that checks out a connection and computes
the key inside it re-enters itself. Read the raw id from the session or
token instead.

**Watching it.** `pool.members` returns one Hash per member, sorted by
endpoint:

```ruby
[{ endpoint: "db1:7000", canonical: "10.0.0.1:7000", state: :ready,
   latency_ms: 0.8, in_use: 2, idle: 3, seed: true }, …]
```

`endpoint` is what the pool dials, `canonical` the name the member reports
for itself (once discovered), `state` one of `:ready`, `:ejected`,
`:resyncing`, `:unreachable`, `:unlisted`, and `latency_ms` is `nil` until
the member has been measured (its first three round trips). The rules are
the same in every skaidb driver
([PROTOCOL.md §6.1](https://skaidb.org/docs/PROTOCOL.html#61-balancing-a-pool-across-members)).

## Behaviour

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
- `close` marks the pool closed, closes the idle connections and stops the
  background thread; connections checked out at the time are closed when
  they are returned. `checkout` on a closed pool raises `Skaidb::Error`.
  `maxsize < 1`, `eject_errors < 1` and an unknown `load_balancing` or
  `idle_order` raise `ArgumentError`.
- The pool is thread-safe: the idle list and the member table are guarded
  by one mutex. The background thread (probes and discovery refreshes) is
  started on first need; Ruby never waits for it at exit. A single
  connection should still be used by one thread at a time; the pool is what
  gives each thread its own.

See also `examples/pool.rb`.
