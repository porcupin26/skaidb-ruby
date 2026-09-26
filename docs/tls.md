# TLS

The binary protocol runs over plain TCP by default. A server configured with
`client_tls = required` refuses plaintext outright, so such a cluster is
only reachable with TLS switched on in the driver.

## Enabling it

Any one of these three keywords turns TLS on:

```ruby
Skaidb.connect(host: "db1", tls: true)                      # verify against the system trust store
Skaidb.connect(host: "db1", tls_ca: "/etc/skaidb/ca.crt")   # verify against this CA file only
Skaidb.connect(host: "db1", tls_insecure: true)             # encrypt, verify nothing
```

- `tls: true` uses OpenSSL's default certificate paths — right when the
  server's certificate chains to a public or system-installed CA.
- `tls_ca:` trusts exactly the certificates in that PEM file. This is the
  usual shape for a cluster with its own CA: hand the driver the CA
  certificate, nothing else.
- `tls_insecure: true` sets `VERIFY_NONE`. The connection is encrypted but
  the peer is not authenticated, so a man in the middle can present any
  certificate. Development and throw-away environments only.

`Skaidb::Pool` passes all of these through to every connection it opens.

## The server name

The driver sends `tls_server_name` as SNI and, unless `tls_insecure`, checks
it against the certificate's subject alternative names with
`post_connection_check`. The default is `"skaidb"`, the DNS SAN skaidb's own
generated certificates carry — which is usually **not** the address you
dial. If your certificate names the host instead, say so:

```ruby
Skaidb.connect(host: "db1.internal", tls_ca: "ca.crt", tls_server_name: "db1.internal")
```

A mismatch fails the connect with `Skaidb::ConnectionError` wrapping
OpenSSL's message.

## What runs inside the session

The TCP connection is upgraded to TLS *before* the login handshake, so the
user name, nonces and proof all travel encrypted; with `seeds:`, each
endpoint is upgraded and authenticated in turn until one succeeds.

## Client certificates

`tls_client_cert:` / `tls_client_key:` (PEM files) make the driver present a
client certificate in the TLS handshake, which a server with
`client_tls = "required"` and client verification needs. Either one turns TLS
on, and they go together. On its own the certificate only opens the TLS
session; the login is still the SCRAM user.

With `auth_mechanism: :certificate` the certificate IS the login (wire
mechanism EXTERNAL): the server maps its Common Name to a role and no
password is sent. The server needs `auth.x509_enabled`, and its client CA
must have signed the certificate.

```ruby
conn = Skaidb.connect(host: "db1", tls_ca: "/etc/skaidb/ca.crt",
                      tls_client_cert: "/etc/app/app.crt",
                      tls_client_key: "/etc/app/app.key",
                      auth_mechanism: :certificate, database: "app")
```

Pass `user:` only to assert the expected identity: a certificate mapped to a
different role fails the connect. The server's answer carries no signature
to check — TLS already authenticated the server, so keep `tls_ca:` (or the
system store) and do not combine a certificate login with `tls_insecure`.
`Skaidb::Pool` passes these keywords through like the others.

## Failures

- Wrong CA, expired certificate, name mismatch: `Skaidb::ConnectionError`
  with the OpenSSL message, from `connect` (or from the statement that
  triggered a re-dial).
- A certificate login the server refuses (no role for the CN, `user:` not
  matching it, x509 login disabled): `Skaidb::ConnectionError` with
  `authentication denied: <reason>`.
- Plain TCP against a `client_tls = required` server: the handshake cannot
  complete, so `connect` raises `Skaidb::ConnectionError`
  (`no reachable endpoint in …`) naming the underlying failure.

See also `examples/tls.rb`.
