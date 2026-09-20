# frozen_string_literal: true

# Connect over TLS. Any of tls: true / tls_ca: / tls_insecure: switches TLS
# on; the SCRAM handshake then runs inside the TLS session.
#
#   ruby examples/tls.rb host port user password [ca.crt]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host, port, user, pw, ca = ARGV[0] || "localhost", (ARGV[1] || 7000).to_i, ARGV[2] || "anonymous", ARGV[3] || "", ARGV[4]

opts = if ca
         { tls_ca: ca }                # trust the cluster's CA file
       elsif ENV["SKAIDB_TLS_INSECURE"]
         { tls_insecure: true }        # encrypt but verify nothing: development only
       else
         { tls: true }                 # the system trust store
       end
# The name checked against the certificate (and sent as SNI) defaults to
# "skaidb", the SAN skaidb's own certificates carry; override it with
# tls_server_name: if your certificate names the host instead.
opts[:tls_server_name] = ENV["SKAIDB_TLS_SERVER_NAME"] if ENV["SKAIDB_TLS_SERVER_NAME"]

Skaidb.connect(host: host, port: port, user: user, password: pw, **opts) do |conn|
  puts conn.exec("SHOW DATABASES").to_a.inspect
end
