# Streaming large results

`exec` and `exec_params` buffer the whole result in a `Skaidb::Result`. For
a result that should not be held in memory at once, `stream` runs the
statement over the protocol's streaming opcode: the server answers with a
header (the column names), then row chunks, then an end marker, and the
driver yields rows as each chunk arrives, holding one chunk at a time.

```ruby
conn.stream("SELECT id, payload FROM events ORDER BY id") do |row|
  export(row)                 # row is a Hash keyed by column name
end
```

- `stream(sql, consistency: nil)` takes SQL text only — no parameters.
- With a block it returns `nil` after the last row.
- Without a block it returns an Enumerator: `conn.stream(sql).first(10)`,
  `.each_slice(1000)`, `.lazy.map { … }`, and the rest of Enumerable work.
- A non-row statement (an `INSERT`, DDL, `USE`) answers with its ordinary
  result over the same opcode; `stream` returns `nil` without yielding.
- A server without the streaming opcode raises `Skaidb::QueryError`
  (`server does not support streaming: …`).

## Errors mid-stream

The server can fail a statement after it has started sending rows (a node
dying mid-scan, a scan budget tripping). The rows already yielded are valid;
the block stops and `stream` raises `Skaidb::QueryError` with the server's
message. The connection stays usable.

## The abandon/drain rule

The protocol forbids any other request on the connection until the stream
ends, so the whole exchange runs under the connection's lock: a statement
from another thread **waits** for the stream to finish rather than
interleaving with it.

Leaving the block early — `break`, `return`, `raise`, or any Enumerable
method that stops before the end (`first`, `take`, `find`) — unwinds through
an `ensure` that **drains** the frames the server is still sending, so the
socket is back at a request boundary and the next statement is clean:

```ruby
first = conn.stream("SELECT id FROM big ORDER BY id").first(3)
conn.usable?      # true
conn.exec("SELECT 1")
```

Draining is not free and there is no cancel opcode: breaking out of a
million-row scan still transfers the rest of it before the connection is
usable again. If you only want a few rows, say so in SQL (`LIMIT`).

Two things defeat the drain:

- **External iteration** — `e = conn.stream(sql); e.next` — runs the stream
  inside the Enumerator's Fiber. A Fiber abandoned part-way is collected
  without running any `ensure`, so nothing drains and the connection stays
  marked mid-stream: `usable?` is `false` for good and a pool will not hand
  it out again. Iterate with a block or `each`.
- **A frame that makes no sense mid-stream**, or a dead socket. The driver
  no longer knows where the reply ends, so it marks the connection broken
  instead of guessing; `usable?` turns `false`, and the next statement
  re-dials.

There is no read deadline: a peer that is alive but silent blocks the drain,
holding the lock. `close` does not take the lock, so another thread can break
such a read by closing the connection.

See also `examples/stream.rb`.
