# Types

Results decode from skaidb's typed wire values; parameters encode back to
them when a statement is prepared, which is the normal path whenever you pass
values to `exec_params` or `exec_batch`.

| skaidb type | Result value | Accepted as a parameter |
|---|---|---|
| Null | `nil` | `nil` |
| Bool | `true` / `false` | `true` / `false` |
| Int (64-bit) | `Integer` | `Integer` in the signed 64-bit range |
| Float (64-bit) | `Float` | `Float`, finite (NaN and ±Infinity are refused) |
| Decimal | `BigDecimal`, exact | `BigDecimal`, finite, mantissa within a signed 128-bit integer |
| String | `String` (UTF-8) | `String` with any text encoding (sent as UTF-8 bytes); `Symbol` |
| Bytes | `String` with `Encoding::BINARY` | `String` whose encoding is `Encoding::BINARY` (`ASCII-8BIT`) |
| Uuid | `String`, canonical lowercase `8-4-4-4-12` | `Skaidb::Uuid` |
| Timestamp | `Time` in UTC, millisecond precision (may predate 1970) | `Time` (any zone) |
| Array | `Array` of mapped values | `Array` (elements follow this table) |
| Document | `Hash` with String keys, insertion order kept | `Hash` (keys are converted with `to_s`) |

## Notes

- **Bytes vs String** is decided by the Ruby String's encoding: `"…".b`,
  `String.new`, `File.binread` and `[…].pack` produce binary Strings and bind
  as Bytes; literals and `File.read` produce text and bind as String. A text
  String is sent as its UTF-8 bytes (it is `force_encoding`'d, not
  transcoded — keep text in UTF-8).
- **Uuid** results are Strings so they compare and print naturally. To bind
  a value *as* a UUID wrap it: `Skaidb::Uuid.new("6ba7b810-9dad-11d1-80b4-00c04fd430c8")`
  (dashes optional, any case), `Skaidb::Uuid.random`, or
  `Skaidb::Uuid.from_bytes(raw)`. `uuid == "6ba7b810-…"` is true when the
  canonical forms match, so a bound value compares equal to what comes back.
  A plain String parameter binds as String, not Uuid.
- **Decimal** is `mantissa × 10^-scale` on the wire. `BigDecimal("123.45")`
  is sent as mantissa `12345`, scale `2`; trailing zeros are dropped and a
  positive exponent (`BigDecimal("1e5")`) is folded into the mantissa. A
  mantissa beyond ±2^127 raises `QueryError`.
- **Timestamp**: a `Time` keeps its instant whatever its zone (local,
  `+05:30`, UTC) and is truncated to the millisecond towards negative
  infinity, so `decode(encode(t)) == t` for any millisecond-precision `Time`.
  Results are always UTC.
- **Int**: an `Integer` outside `-2^63 … 2^63-1` raises `QueryError` before
  anything is sent. There is no marker to force Float for an integral value;
  bind `3.0`, not `3`, when you mean a Float.
- **Document** keys become Strings (`{ city: "London" }` is stored with key
  `"city"`); nested Arrays and Hashes are encoded recursively.
- Any other class — `Date`, `DateTime`, `Rational`, `Set`, `Range`, your own
  objects — raises `QueryError("cannot bind value of type …")`. Convert
  first (`date.to_time`, `rational.to_f`, `set.to_a`).

## The client-side fallback

When the server refuses to prepare a statement (DDL, `USE`, and every
statement on a server without the prepare opcode), `exec_params` renders the
parameters into the SQL text instead:

| Ruby value | Literal |
|---|---|
| `nil` | `NULL` |
| `true` / `false` | `TRUE` / `FALSE` |
| `Integer`, `Float` (finite) | as printed |
| `BigDecimal` | plain decimal notation (`123.45`) |
| `String` (text), `Symbol` | single-quoted, `'` doubled |
| `String` (binary) | the hex digits, single-quoted |
| `Skaidb::Uuid` | the canonical form, single-quoted |
| `Time` | Unix milliseconds |
| `Array`, `Hash` | refused: `QueryError`, with the server's reason for not preparing the statement appended |
