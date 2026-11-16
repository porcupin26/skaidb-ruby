# frozen_string_literal: true

# Transactions on one connection: the transaction helper (BEGIN, the block,
# COMMIT; a ROLLBACK when the block raises; the whole of it again when the
# COMMIT is refused as a conflict), and the same thing written by hand.
# Plain BEGIN needs a standalone server; on a cluster pass the opening
# statement: conn.transaction(begin: "BEGIN ATOMIC") { ... }.
#
#   ruby examples/transaction.rb [host] [port] [user] [password] [database]
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "skaidb"

host = ARGV[0] || "localhost"
port = (ARGV[1] || 7000).to_i
user = ARGV[2] || "anonymous"
pw   = ARGV[3] || ""
db   = ARGV[4]

Skaidb.connect(host: host, port: port, user: user, password: pw, database: db) do |conn|
  conn.exec("CREATE TABLE accounts (PRIMARY KEY (id))")
  conn.exec_batch("INSERT INTO accounts (id, balance) VALUES ($1, $2)", [[1, 100], [2, 0]])
  balances = -> { conn.exec("SELECT id, balance FROM accounts ORDER BY id").rows.to_h }

  # Both updates or neither. The block may run more than once: a COMMIT the
  # server refuses because another writer changed one of the rows raises
  # Skaidb::TransactionConflict, and the helper runs the block again.
  moved = conn.transaction do |tx|
    tx.exec_params("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [10, 1])
    tx.exec_params("UPDATE accounts SET balance = balance + $1 WHERE id = $2", [10, 2])
    10
  end
  puts "moved #{moved}: #{balances.call}"                 # {1=>90, 2=>10}

  # A block that raises is rolled back, and its exception propagates.
  begin
    conn.transaction do |tx|
      tx.exec_params("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [500, 1])
      raise ArgumentError, "insufficient funds"
    end
  rescue ArgumentError => e
    puts "rolled back (#{e.message}): #{balances.call}"   # {1=>90, 2=>10}
  end

  # The same transaction, written by hand. The driver follows it: if the
  # connection is lost before COMMIT, nothing more is sent until ROLLBACK
  # (which then succeeds without being sent) or COMMIT (which raises).
  conn.exec("BEGIN") # if this raises, stop here
  begin
    conn.exec_params("UPDATE accounts SET balance = balance - $1 WHERE id = $2", [5, 1])
    conn.exec_params("UPDATE accounts SET balance = balance + $1 WHERE id = $2", [5, 2])
  rescue StandardError
    begin
      conn.exec("ROLLBACK")
    rescue Skaidb::Error
      nil # the clean-up never replaces the error it follows
    end
    raise
  end
  conn.exec("COMMIT")
  puts "by hand: #{balances.call}"                        # {1=>85, 2=>15}

  conn.exec("DROP TABLE accounts")
end
