# Changelog

All notable changes to the skaidb Ruby driver. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-09-20

First release as a standalone repository
(`github.com/porcupin26/skaidb-ruby`), carrying its full history over from
the skaidb monorepo. The version series restarts at 1.0.0. This is also the
first release verified end to end against a live skaidb server (connect,
DDL, typed inserts of every value type, bound `SELECT`, `UPDATE` counts,
batches, a 2 500-row stream, error handling, and the `drivers` table showing
`ruby / 1.0.0`).

### Added
- `Skaidb::Uuid`: a value wrapper so a UUID can be bound with the Uuid type
  tag (`Skaidb::Uuid.new(str)`, `.random`, `.from_bytes`); results still
  decode to the canonical String, and a `Uuid` compares equal to it.
- Typed binding of `BigDecimal` (Decimal, exact 128-bit mantissa + scale)
  and of binary Strings (`Encoding::BINARY` → Bytes) on the prepared path.
  Before, a `BigDecimal` parameter raised `cannot bind value of type
  BigDecimal` and raw bytes were sent as a String.
- `Symbol` parameters bind as String.
- Unit tests with an in-process fake server (framing, SCRAM-SHA-256,
  Hello, the value codec for every type, prepare/execute with typed
  parameters, `exec_batch`, streaming chunks including the abandon/drain
  rule, multi-set replies, failover, reconnect, the pool, `subscribe`), a
  Hello-version-equals-package-version check, and a live end-to-end test
  (`test/live/`, opt-in with `SKAIDB_LIVE=1`, skipped otherwise).
- CI on Ruby 3.1, 3.2, 3.3 and 3.4; a publish workflow on `v*` tags that
  gates on tag == version, attaches the built gem to a GitHub Release and
  pushes to RubyGems.org only when `RUBYGEMS_API_KEY` is configured.
- Documentation: README plus `docs/` (getting started, API reference,
  types, TLS, streaming, pooling) and runnable `examples/`.
- `LICENSE` (SSPL-1.0), `CHANGELOG.md`, `Rakefile`, `.gitignore`.

### Fixed
- `Time` parameters were converted to milliseconds through `Float`
  (`to_f * 1000`), which can be off by one millisecond for some instants;
  the conversion is now exact (`Rational`) and truncates towards negative
  infinity, so a decoded Timestamp equals the bound one.
- An `Integer` outside the signed 64-bit range raised a raw `RangeError`
  from `pack`; it now raises `Skaidb::QueryError` naming the limit.
- When the server refused to prepare a statement and the client-side
  fallback could not render a parameter (an Array or a Hash), the error was
  `cannot bind value of type Array`, hiding the real cause — usually a SQL
  mistake such as a reserved word used as a column name. The server's reason
  for the refusal is now appended to that error.
- A bare `?` in a statement that has parameters was sent to the server as
  a placeholder and failed late with `statement expects N parameters, got
  0`; it is now rejected before anything is sent, with a message saying the
  driver's placeholders are `$1, $2, …`.
- The frame read buffer is created as a binary String, so appending socket
  bytes can never trigger an encoding conversion.
- On the prepared path (`exec_params`, `exec_batch`) a parameter that no
  `$N` placeholder referenced was dropped silently: `exec_params("… WHERE
  id = $1", [1, "extra"])` ran, and a batch row one value too long was
  truncated to the placeholders and applied. Both now raise `QueryError`
  (`more parameters (N) than placeholders ($M)`) before anything is sent,
  as the text path always did.
- Documentation: a Document result's `Hash` keys arrive in the order the
  server sends them (it stores documents with keys sorted at every level),
  not in binding order as the type tables claimed; the Install section says
  that Bundler compiles `bigdecimal` from RubyGems.org, which needs the Ruby
  headers and a C toolchain.

### Changed
- The version is defined once, as `Skaidb::VERSION` in `lib/skaidb.rb`; the
  gemspec reads it and the Hello frame carries it, and CI asserts both.
- Gem metadata: homepage, source, changelog, documentation and bug-tracker
  URLs point at this repository; license `SSPL-1.0`; `LICENSE` and
  `CHANGELOG.md` ship in the gem; `bigdecimal` is declared as a dependency
  because it is a bundled gem since Ruby 3.4.
- The example moved to `examples/basic.rb`.

[1.0.0]: https://github.com/porcupin26/skaidb-ruby/releases/tag/v1.0.0
