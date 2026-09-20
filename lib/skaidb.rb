# frozen_string_literal: true

# skaidb — Ruby driver.
#
# A small, dependency-free client for skaidb's binary wire protocol. The API is
# modelled on the {https://github.com/ged/ruby-pg ruby-pg} gem (`PG`), so if you
# have used Postgres from Ruby it should feel familiar: +Skaidb.connect+ returns
# a connection, +exec+ / +exec_params+ run statements, and the result behaves
# like +PG::Result+ (Enumerable of row Hashes, plus +rows+, +fields+,
# +ntuples+, +cmd_tuples+).
#
# Pure standard library — only +socket+, +openssl+, +securerandom+ and
# +bigdecimal+. No gems.
#
#   require "skaidb"
#
#   conn = Skaidb.connect(host: "localhost", port: 7000,
#                         user: "skaidb", password: "secret")
#   conn.exec("CREATE TABLE users (PRIMARY KEY (id))")
#   conn.exec_params("INSERT INTO users (id, name) VALUES ($1, $2)", [1, "Ada"])
#   res = conn.exec_params("SELECT id, name FROM users WHERE id = $1", [1])
#   res.each { |row| puts row["name"] }    # => "Ada"
#   conn.close
#
# Placeholders use the pg-style +$1+, +$2+, ... . They are sent as TYPED values
# through a server-side prepared statement where the server accepts one, and
# interpolated into the SQL client-side, with correct quoting, where it does not
# (old servers, and statement kinds that cannot be prepared).
require "socket"
require "openssl"
require "securerandom"
require "bigdecimal"

module Skaidb
  # The package version — the single source of truth. The gemspec reads it,
  # and it is what the driver reports to the server in the Hello frame.
  VERSION = "1.0.2"

  # Base class for every error raised by this driver.
  class Error < StandardError; end

  # A connection / transport problem (socket, framing, handshake). When this is
  # raised mid-stream the connection is dead and must be discarded.
  class ConnectionError < Error; end

  # A statement failed (bad SQL, constraint violation, ...). The connection
  # stays usable for the next query.
  class QueryError < Error; end

  # Consistency levels — how many replicas must acknowledge/answer.
  module Consistency
    ONE = 0
    QUORUM = 1
    ALL = 2

    BY_NAME = { "one" => 0, "quorum" => 1, "all" => 2 }.freeze

    # Resolve a symbol/string/integer into the 0/1/2 wire value.
    def self.resolve(value)
      case value
      when Integer
        return value if [0, 1, 2].include?(value)

        raise Error, "invalid consistency #{value.inspect}"
      when String, Symbol
        v = BY_NAME[value.to_s.downcase]
        return v if v

        raise Error, "invalid consistency #{value.inspect}"
      else
        raise Error, "invalid consistency #{value.inspect}"
      end
    end
  end

  # Value type tags (§4 of PROTOCOL.md).
  module Tags
    NULL = 0
    BOOL = 1
    INT = 2
    FLOAT = 3
    DECIMAL = 4
    STRING = 5
    BYTES = 6
    UUID = 7
    TIMESTAMP = 8
    ARRAY = 9
    DOCUMENT = 10
  end

  # A UUID parameter. Results decode Uuid cells to their canonical lowercase
  # String, and a String binds as a String, so wrap a value in +Uuid+ to bind
  # it with the Uuid type tag: +Skaidb::Uuid.new("6ba7b810-9dad-11d1-80b4-00c04fd430c8")+.
  # Compares equal to another Uuid, or to a String, with the same canonical form.
  class Uuid
    HEX32 = /\A\h{32}\z/.freeze

    # @return [String] canonical lowercase 8-4-4-4-12 form
    attr_reader :to_s

    # @param str [String] 32 hex digits, with or without the usual dashes
    def initialize(str)
      hex = str.to_s.delete("-").downcase
      raise ArgumentError, "not a UUID: #{str.inspect}" unless HEX32.match?(hex)

      @to_s = Skaidb.format_uuid([hex].pack("H*")).freeze
    end

    # Build from the 16 raw bytes.
    def self.from_bytes(bytes)
      raise ArgumentError, "a UUID is 16 bytes" unless bytes.bytesize == 16

      new(bytes.unpack1("H*"))
    end

    # A random (version 4) UUID.
    def self.random
      new(SecureRandom.uuid)
    end

    # @return [String] the 16 raw bytes (RFC 4122 order)
    def bytes
      [@to_s.delete("-")].pack("H*")
    end

    def ==(other)
      case other
      when Uuid then @to_s == other.to_s
      when String
        hex = other.delete("-").downcase
        HEX32.match?(hex) && @to_s == Skaidb.format_uuid([hex].pack("H*"))
      else false
      end
    end
    alias eql? ==

    def hash
      @to_s.hash
    end

    def inspect
      "#<Skaidb::Uuid #{@to_s}>"
    end
  end

  # ---- byte reader ---------------------------------------------------------
  #
  # All integers here are little-endian (the frame length prefix, handled in
  # Connection, is the sole big-endian field).
  class Reader
    def initialize(buf)
      @buf = buf
      @pos = 0
    end

    def take(n)
      raise ConnectionError, "truncated server message" if @pos + n > @buf.bytesize

      s = @buf.byteslice(@pos, n)
      @pos += n
      s
    end

    def u8
      take(1).unpack1("C")
    end

    def u16
      take(2).unpack1("v")
    end

    def u32
      take(4).unpack1("V")
    end

    def i64
      take(8).unpack1("q<")
    end

    def u64
      take(8).unpack1("Q<")
    end

    def f64
      take(8).unpack1("E")
    end

    # signed little-endian 128-bit integer (16 bytes), assembled manually.
    def i128
      bytes = take(16)
      lo = bytes.byteslice(0, 8).unpack1("Q<")
      hi = bytes.byteslice(8, 8).unpack1("q<") # high half is signed
      (hi << 64) | lo
    end

    def blob
      take(u32)
    end

    def text
      blob.force_encoding("UTF-8")
    end
  end

  # Decode one self-describing Value (§4) from the reader.
  def self.decode_value(r)
    tag = r.u8
    case tag
    when Tags::NULL then nil
    when Tags::BOOL then r.u8 != 0
    when Tags::INT then r.i64
    when Tags::FLOAT then r.f64
    when Tags::DECIMAL
      mantissa = r.i128
      scale = r.u32
      # value = mantissa / 10^scale, built exactly via BigDecimal("<mantissa>e-<scale>")
      BigDecimal("#{mantissa}e-#{scale}")
    when Tags::STRING then r.text
    when Tags::BYTES then r.blob.force_encoding("BINARY")
    when Tags::UUID then format_uuid(r.take(16))
    when Tags::TIMESTAMP
      ms = r.i64
      # preserve millisecond precision; Time in UTC
      Time.at(ms / 1000, (ms % 1000) * 1000, :usec).utc
    when Tags::ARRAY
      Array.new(r.u32) { decode_value(r) }
    when Tags::DOCUMENT
      out = {}
      r.u32.times do
        key = r.text
        out[key] = decode_value(r)
      end
      out
    else
      raise ConnectionError, "unknown value tag #{tag}"
    end
  end

  # 16 raw bytes -> canonical lowercase 8-4-4-4-12 UUID string.
  def self.format_uuid(bytes)
    hex = bytes.unpack1("H*")
    "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
  end

  # ---- client-side parameter binding (§5) ----------------------------------

  # Quote a single Ruby value into a SQL literal.
  def self.quote(arg)
    case arg
    when nil
      "NULL"
    when true
      "TRUE"
    when false
      "FALSE"
    when Integer
      arg.to_s
    when Float
      raise QueryError, "cannot bind NaN/Infinity" if arg.nan? || arg.infinite?

      # round-trip-safe representation
      arg.to_s
    when BigDecimal
      arg.to_s("F")
    when String
      if arg.encoding == Encoding::BINARY
        # raw binary bytes (ASCII-8BIT) -> hex literal, mirroring Python's bytes
        "'" + arg.unpack1("H*") + "'"
      else
        # text string -> single-quoted, doubling embedded quotes
        "'" + arg.gsub("'", "''") + "'"
      end
    when Symbol
      "'" + arg.to_s.gsub("'", "''") + "'"
    when Uuid
      "'" + arg.to_s + "'"
    when Time
      time_ms(arg).to_s
    else
      raise QueryError, "cannot bind value of type #{arg.class}"
    end
  end

  # Interpolate +params+ into +sql+, replacing $1, $2, ... placeholders that
  # appear outside single-quoted string literals.
  # Rewrite pg-style +$N+ placeholders to the positional +?+ the server's
  # prepared statements use, returning [sql, params_in_wire_order]. A
  # parameter referenced twice is sent twice — +?+ is positional and cannot
  # say "the same one again". +$N+ inside a string literal is left alone.
  # Like +bind+, a parameter no placeholder references is an error: the
  # server only ever sees the referenced values, so without this check an
  # extra value (a batch row one column too long, say) would vanish silently.
  def self.to_qmark(sql, params)
    params ||= []
    out = +""
    order = []
    max_used = 0
    in_str = false
    i = 0
    n = sql.length
    while i < n
      ch = sql[i]
      if in_str
        out << ch
        if ch == "'"
          if i + 1 < n && sql[i + 1] == "'"
            out << "'"
            i += 2
            next
          end
          in_str = false
        end
        i += 1
        next
      end
      if ch == "'"
        in_str = true
        out << ch
        i += 1
        next
      end
      if ch == "$" && i + 1 < n && sql[i + 1] =~ /[0-9]/
        j = i + 1
        j += 1 while j < n && sql[j] =~ /[0-9]/
        idx = sql[(i + 1)...j].to_i
        raise QueryError, "invalid placeholder $0" if idx < 1
        raise QueryError, "placeholder $#{idx} has no parameter" if idx > params.length

        order << params[idx - 1]
        max_used = idx if idx > max_used
        out << "?"
        i = j
        next
      end
      if ch == "?" && !params.empty?
        # A `?` here would reach the server as ITS placeholder and fail late
        # with a confusing arity error; say what the driver's syntax is.
        raise QueryError, "this driver uses $1, $2, ... placeholders; '?' is not a placeholder"
      end

      out << ch
      i += 1
    end
    if params.length > max_used
      raise QueryError, "more parameters (#{params.length}) than placeholders ($#{max_used})"
    end

    [out, order]
  end

  I64_MIN = -(2**63)
  I64_MAX = 2**63 - 1
  I128_MIN = -(2**127)
  I128_MAX = 2**127 - 1
  U128_MASK = 2**128 - 1
  U64_MASK = 2**64 - 1

  # A BigDecimal as [mantissa, scale] with value = mantissa / 10^scale,
  # matching the wire codec. The scale is unsigned, so a positive exponent is
  # folded into the mantissa.
  def self.decimal_parts(d)
    raise QueryError, "cannot bind non-finite BigDecimal" if d.nan? || d.infinite?

    sign, digits, _base, exponent = d.split # value = sign * 0.<digits> * 10^exponent
    digits = digits.sub(/0+\z/, "")
    digits = "0" if digits.empty?
    mantissa = digits.to_i
    mantissa = -mantissa if sign.negative?
    scale = digits.length - exponent
    if scale.negative?
      mantissa *= 10**-scale
      scale = 0
    end
    if mantissa < I128_MIN || mantissa > I128_MAX
      raise QueryError, "BigDecimal mantissa does not fit a signed 128-bit integer"
    end

    [mantissa, scale]
  end

  # A Ruby Time as Unix milliseconds — exact (via Rational), truncated
  # towards negative infinity so that decoding gives the same millisecond.
  def self.time_ms(t)
    (t.to_r * 1000).floor
  end

  # Encode a Ruby value as a TYPED skaidb value (tag + payload), the inverse
  # of decode_value. Arrays become Array and Hashes become Document — the
  # point of the prepared path, since neither has a SQL literal form.
  def self.encode_value(v)
    case v
    when nil then [0].pack("C")
    when true then [1, 1].pack("CC")
    when false then [1, 0].pack("CC")
    when Integer
      raise QueryError, "integer #{v} does not fit a signed 64-bit Int" if v < I64_MIN || v > I64_MAX

      [2].pack("C") + [v].pack("q<")
    when Float
      raise QueryError, "cannot bind NaN/Infinity" if v.nan? || v.infinite?

      [3].pack("C") + [v].pack("E")
    when BigDecimal
      mantissa, scale = decimal_parts(v)
      m = mantissa & U128_MASK
      [4].pack("C") + [m & U64_MASK, m >> 64].pack("Q<Q<") + [scale].pack("V")
    when String
      if v.encoding == Encoding::BINARY
        # ASCII-8BIT is how Ruby says "raw bytes": bind as Bytes.
        [6].pack("C") + [v.bytesize].pack("V") + v
      else
        b = v.dup.force_encoding(Encoding::BINARY)
        [5].pack("C") + [b.bytesize].pack("V") + b
      end
    when Symbol
      encode_value(v.to_s)
    when Uuid
      [7].pack("C") + v.bytes
    when Time
      [8].pack("C") + [time_ms(v)].pack("q<")
    when Array
      out = +([9].pack("C") + [v.length].pack("V"))
      v.each { |item| out << encode_value(item) }
      out
    when Hash
      out = +([10].pack("C") + [v.length].pack("V"))
      v.each do |k, val|
        ks = k.to_s.dup.force_encoding(Encoding::BINARY)
        out << [ks.bytesize].pack("V") << ks << encode_value(val)
      end
      out
    else
      raise QueryError, "cannot bind value of type #{v.class}"
    end
  end

  def self.bind(sql, params)
    params ||= []
    out = +""
    in_str = false
    i = 0
    n = sql.length
    max_used = 0
    while i < n
      ch = sql[i]
      if in_str
        out << ch
        if ch == "'"
          if i + 1 < n && sql[i + 1] == "'"
            out << "'"
            i += 2
            next
          end
          in_str = false
        end
        i += 1
        next
      end

      if ch == "'"
        in_str = true
        out << ch
        i += 1
        next
      end

      if ch == "$" && i + 1 < n && sql[i + 1] =~ /[0-9]/
        j = i + 1
        j += 1 while j < n && sql[j] =~ /[0-9]/
        idx = sql[(i + 1)...j].to_i
        raise QueryError, "invalid placeholder $0" if idx < 1
        raise QueryError, "placeholder $#{idx} has no parameter" if idx > params.length

        out << quote(params[idx - 1])
        max_used = idx if idx > max_used
        i = j
        next
      end

      out << ch
      i += 1
    end

    if params.length > max_used
      raise QueryError, "more parameters (#{params.length}) than placeholders ($#{max_used})"
    end

    out
  end

  # ---- SCRAM-SHA-256 (§2) --------------------------------------------------

  # Compute the client proof and the expected server signature.
  def self.scram(password, salt, iterations, auth_message)
    digest = OpenSSL::Digest::SHA256
    salted = OpenSSL::KDF.pbkdf2_hmac(
      password, salt: salt, iterations: iterations, length: 32, hash: "sha256"
    )
    client_key = OpenSSL::HMAC.digest(digest.new, salted, "Client Key")
    stored_key = OpenSSL::Digest::SHA256.digest(client_key)
    client_sig = OpenSSL::HMAC.digest(digest.new, stored_key, auth_message)
    proof = xor_bytes(client_key, client_sig)
    server_key = OpenSSL::HMAC.digest(digest.new, salted, "Server Key")
    server_sig = OpenSSL::HMAC.digest(digest.new, server_key, auth_message)
    [proof, server_sig]
  end

  def self.xor_bytes(a, b)
    a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")
  end

  # Constant-time comparison for the server signature.
  def self.secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    res = 0
    a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
    res.zero?
  end

  # encode a string field: u32 LE length + UTF-8 bytes
  def self.enc_str(str)
    b = str.to_s.dup.force_encoding("UTF-8")
    bytes = b.bytesize
    [bytes].pack("V") + b.b
  end

  # ---- Result --------------------------------------------------------------

  # A query result, shaped like +PG::Result+. Enumerable over row Hashes
  # (String column-name keys); also exposes positional +rows+, +fields+,
  # +ntuples+ and +cmd_tuples+.
  class Result
    include Enumerable

    # @return [Array<String>] column names, in order
    attr_reader :fields
    # @return [Array<Array>] rows as arrays of values
    attr_reader :rows
    # @return [Integer] number of rows affected by a mutation (0 otherwise)
    attr_reader :cmd_tuples
    # @return [Array<Result>] every result set of a multi-set reply (a CALL
    #   whose body EMITted), in order; this Result is the LAST of them.
    #   Empty for an ordinary single-set reply.
    attr_reader :result_sets

    def initialize(fields:, rows:, cmd_tuples: 0, result_sets: [])
      @result_sets = result_sets
      @fields = fields
      @rows = rows
      @cmd_tuples = cmd_tuples
    end

    # pg alias for the column names.
    alias columns fields

    # @return [Integer] number of result rows
    def ntuples
      @rows.length
    end
    alias num_tuples ntuples

    # @return [Integer] number of columns
    def nfields
      @fields.length
    end
    alias num_fields nfields

    # Yield each row as a Hash keyed by column name (String keys).
    def each
      return enum_for(:each) unless block_given?

      @rows.each do |row|
        h = {}
        @fields.each_with_index { |name, idx| h[name] = row[idx] }
        yield h
      end
      self
    end

    # Row +i+ as a Hash keyed by column name.
    def [](i)
      row = @rows[i]
      return nil if row.nil?

      h = {}
      @fields.each_with_index { |name, idx| h[name] = row[idx] }
      h
    end

    # A single field value by row index and column (name or index).
    def getvalue(row, col)
      r = @rows[row]
      return nil if r.nil?

      col = @fields.index(col) if col.is_a?(String)
      col.nil? ? nil : r[col]
    end

    # All rows as Hashes.
    def values
      to_a
    end
  end

  # ---- Connection ----------------------------------------------------------

  @nonce_counter = 0
  @nonce_mutex = Mutex.new

  # Internal: a process-wide monotonic counter for client nonces.
  def self.next_nonce_id
    @nonce_mutex.synchronize { @nonce_counter += 1 }
  end

  # A connection to one skaidb node. Modelled on +PG::Connection+.
  class Connection
    # @return [Boolean] whether the connection has been closed
    attr_reader :closed

    def initialize(host:, port:, user:, password:, consistency:, timeout:,
                   database: nil, tls: false, tls_ca: nil, tls_insecure: false,
                   tls_server_name: "skaidb", seeds: nil)
      @consistency = Consistency.resolve(consistency)
      @mutex = Mutex.new
      @closed = false
      # Transport died; the next statement re-dials (see ensure_live!).
      @broken = false
      # A stream is in flight, so the socket sits mid-reply (see stream).
      @streaming = false
      @prepared = {}
      @last_prepare_error = nil
      # Retained so a reconnect repeats the original connect exactly.
      @dial_args = { host: host, port: port, user: user, password: password,
                     timeout: timeout, database: database, tls: tls, tls_ca: tls_ca,
                     tls_insecure: tls_insecure, tls_server_name: tls_server_name,
                     seeds: seeds }
      dial!
    end

    # Connect, authenticate and enter the session database. Used for the first
    # connect and for every reconnect, so a recovered connection is
    # indistinguishable from a fresh one.
    def dial!
      host = @dial_args[:host]
      port = @dial_args[:port]
      user = @dial_args[:user]
      password = @dial_args[:password]
      timeout = @dial_args[:timeout]
      database = @dial_args[:database]
      tls = @dial_args[:tls]
      tls_ca = @dial_args[:tls_ca]
      tls_insecure = @dial_args[:tls_insecure]
      tls_server_name = @dial_args[:tls_server_name]
      seeds = @dial_args[:seeds]
      # Seeds: try each until one connects AND authenticates — a node that
      # accepts TCP while unhealthy must not swallow the attempt. skaidb is
      # leaderless, so any node serves; the order is shuffled so many
      # clients spread instead of stampeding the first entry.
      endpoints = (seeds && !seeds.empty? ? seeds : ["#{host}:#{port}"]).map do |sd|
        h, _, p = sd.to_s.rpartition(":")
        h.empty? ? [sd.to_s, port] : [h, p.to_i]
      end.shuffle
      last = nil
      endpoints.each do |(h, prt)|
        begin
          @sock = Socket.tcp(h, prt, connect_timeout: timeout)
          @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          @sock = tls_wrap(@sock, tls_ca, tls_insecure, tls_server_name) if tls
          handshake(user.to_s, password.to_s)
          last = nil
          break
        rescue StandardError => e
          last = e
          begin
            @sock&.close
          rescue StandardError
            nil
          end
          @sock = nil
        end
      end
      if last
        @closed = true
        raise ConnectionError,
              "no reachable endpoint in #{endpoints.map { |(h, q)| "#{h}:#{q}" }.join(', ')}: #{last.message}"
      end
      send_hello
      # USE is per-connection session state, so it runs on every dial.
      exec(%(USE "#{database.to_s.gsub('"', '""')}")) if database && !database.to_s.empty?
    end

    # Best-effort self-identification: fills the server's +drivers+ table
    # client_name/client_version. An old server answers the unknown opcode
    # with an error frame, which is ignored — identity is telemetry, never
    # load-bearing.
    def send_hello
      name = "ruby"
      ver = Skaidb::VERSION # the package version, never a literal
      req = [8].pack("C") + [name.bytesize].pack("V") + name +
            [ver.bytesize].pack("V") + ver
      write_frame(req)
      read_frame
    rescue StandardError
      nil
    end

    # Upgrade a connected socket to TLS. A server with client_tls = required
    # refuses plaintext outright, so without this such a cluster is simply
    # unreachable. +tls_server_name+ must match a SAN on the server
    # certificate — skaidb's own certs carry DNS:skaidb, which is usually NOT
    # the address dialled.
    def tls_wrap(sock, ca_file, insecure, server_name)
      ctx = OpenSSL::SSL::SSLContext.new
      if insecure
        # Encrypts, but authenticates nothing: a man in the middle can present
        # any certificate. Development only.
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.cert_store = OpenSSL::X509::Store.new.tap do |store|
          ca_file && !ca_file.empty? ? store.add_file(ca_file) : store.set_default_paths
        end
      end
      ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      ssl.hostname = server_name          # SNI
      ssl.sync_close = true
      ssl.connect
      ssl.post_connection_check(server_name) unless insecure
      ssl
    end

    # Current default consistency level (0/1/2).
    attr_reader :consistency

    # Override the default consistency level for subsequent queries.
    def consistency=(value)
      @consistency = Consistency.resolve(value)
    end

    # Execute a statement with no parameters.
    # @return [Result]
    def exec(sql)
      run(sql.to_s, @consistency)
    end
    alias query exec

    # Execute a statement, interpolating +params+ at +$1+, +$2+, ... .
    # @param params [Array] positional parameters
    # @return [Result]
    def exec_params(sql, params = [], consistency: nil)
      level = consistency.nil? ? @consistency : Consistency.resolve(consistency)
      params ||= []
      unless params.empty?
        # Server-side prepare so parameters travel as TYPED values; arrays
        # and Hashes have no SQL literal form. $N is rewritten to the
        # positional ? the server expects.
        qsql, order = Skaidb.to_qmark(sql.to_s, params)
        prep = prepare_server(qsql)
        unless prep.nil?
          id, nparams = prep
          if nparams != order.length
            raise QueryError, "statement expects #{nparams} parameters, got #{order.length}"
          end

          return exec_prepared(id, order, level)
        end
      end
      text = begin
        Skaidb.bind(sql.to_s, params)
      rescue QueryError => e
        # The text path cannot carry this value (an Array, a Hash, ...), so
        # the interesting error is the server's reason for refusing to
        # prepare — usually a SQL mistake — not the fallback's limitation.
        raise QueryError, "#{e.message}; the server would not prepare the statement: #{@last_prepare_error}" if @last_prepare_error

        raise
      end
      run(text, level)
    end

    # Execute +sql+ once per row in ONE round-trip. Rows autocommit
    # individually: a failure names the row and earlier rows stay applied,
    # so the statement must be idempotent. Returns total affected rows.
    def exec_batch(sql, rows, consistency: nil)
      return 0 if rows.nil? || rows.empty?

      level = consistency.nil? ? @consistency : Consistency.resolve(consistency)
      qsql, = Skaidb.to_qmark(sql.to_s, rows.first)
      prep = prepare_server(qsql)
      raise QueryError, "statement cannot be prepared, so it cannot be batched" if prep.nil?

      id, nparams = prep
      ordered = rows.map { |r| Skaidb.to_qmark(sql.to_s, r)[1] }
      ordered.each do |r|
        raise QueryError, "batch row expects #{nparams} parameters, got #{r.length}" if r.length != nparams
      end
      raise ConnectionError, "connection is closed" if @closed

      req = +([7, level].pack("CC") + [id].pack("V") + [ordered.length].pack("V"))
      ordered.each do |r|
        req << [r.length].pack("v")
        r.each do |v|
          b = Skaidb.encode_value(v)
          req << [b.bytesize].pack("V") << b
        end
      end
      reader = nil
      @mutex.synchronize do
        write_frame(req)
        reader = Reader.new(read_frame)
      end
      parse_response(reader).cmd_tuples
    end

    # Stream a result set: yields one row Hash at a time while holding a
    # single chunk, instead of buffering the whole result. For exports and
    # large scans.
    #
    #   conn.stream("SELECT ...") { |row| puts row["id"] }
    #
    # The protocol forbids any other request on the connection until the
    # stream ends, so the whole exchange runs under the connection mutex
    # instead of one lock per frame: a statement from another thread WAITS
    # for the stream rather than interleaving frames with it.
    #
    # Leaving the block early — +break+, +return+ or an exception — unwinds
    # through the ensure below, which drains whatever the server is still
    # sending so the connection sits at a request boundary again. When it
    # cannot (dead socket, a frame that makes no sense mid-stream) the
    # connection is marked broken instead, so +usable?+ turns false and Pool
    # drops it rather than handing out a desynced socket.
    #
    # Draining is not free and there is no cancel opcode: breaking out of a
    # million-row scan still transfers the rest of it before the connection
    # is usable again. If you only want the first few rows, say so in SQL
    # (+LIMIT+) rather than by abandoning the stream.
    #
    # With no block this returns an Enumerator. +each+, +map+, +take+ and the
    # rest of Enumerable are safe — they unwind through the ensure. External
    # iteration (+next+, +peek+) is NOT: it runs the stream inside the
    # Enumerator's Fiber, and a Fiber abandoned part-way is collected without
    # running any ensure, so nothing drains and the mutex is never released.
    # Such a connection stays marked busy on purpose (+usable?+ is false for
    # the whole stream), which is what keeps it out of the pool. Iterate with
    # a block or +each+ if you mean to reuse the connection.
    #
    # Takes no parameters — the streaming opcode carries SQL text.
    def stream(sql, consistency: nil)
      return enum_for(:stream, sql, consistency: consistency) unless block_given?
      raise ConnectionError, "connection is closed" if @closed
      ensure_live!

      level = consistency.nil? ? @consistency : Consistency.resolve(consistency)
      sql_bytes = sql.dup.force_encoding("UTF-8").b
      req = [5, level].pack("CC") + [sql_bytes.bytesize].pack("V") + sql_bytes
      live = false
      @mutex.synchronize do
        write_frame(req)
        r = Reader.new(read_frame)
        tag = r.u8
        case tag
        when 3
          msg = r.text
          raise QueryError, msg.include?("unknown opcode") ? "server does not support streaming: #{msg}" : msg
        when 1, 2
          return nil # not row-producing
        when 5
          # The server has already committed to a row stream, so from here
          # the socket carries frames this call owns — mark it BEFORE
          # parsing the header, not after. `Reader#take` raises on a
          # truncated or absurd column count, and a raise between the
          # commitment and the flag skips the drain entirely: nothing sets
          # `@broken`, `usable?` stays true, and the pool files a socket
          # parked mid-reply back for the next caller, who reads a leftover
          # chunk and gets "unknown response tag 6". That is the very
          # desync the ensure below exists to prevent, reachable through a
          # two-line window.
          live = true
          @streaming = true
          cols = Array.new(r.u32) { r.text }
          begin
            while live
              fr = Reader.new(read_frame)
              case fr.u8
              when 6
                fr.u32.times do
                  ncells = fr.u32
                  cells = Array.new(ncells) { Skaidb.decode_value(Reader.new(fr.blob)) }
                  yield cols.zip(cells).to_h
                end
              when 7
                live = false
              when 3
                live = false
                raise QueryError, fr.text
              else
                # Mid-stream the server sends only RowsChunk, RowsEnd or Error.
                # Anything else means we no longer know where the reply ends, so
                # there is no draining back to a request boundary: retire it.
                live = false
                @broken = true
                raise QueryError, "unexpected frame in stream"
              end
            end
          ensure
            drain_stream! if live
            # Cleared last: until this point the connection is mid-reply, and a
            # caller who never unwinds here (an abandoned Enumerator Fiber)
            # leaves it set, so usable? keeps reporting the truth.
            @streaming = false
          end
        else
          raise QueryError, "unexpected response tag #{tag} to stream request"
        end
      end
      nil
    end

    # Prepare +sql+ on the SERVER, returning [id, nparams], or nil when the
    # server declines the statement kind (DDL, session statements) so the
    # caller falls back to text binding. Cached per connection.
    def prepare_server(sql)
      hit = @prepared[sql]
      return hit if hit
      raise ConnectionError, "connection is closed" if @closed
      ensure_live!

      sql_bytes = sql.dup.force_encoding("UTF-8").b
      req = [2].pack("C") + [sql_bytes.bytesize].pack("V") + sql_bytes
      reader = nil
      @mutex.synchronize do
        write_frame(req)
        reader = Reader.new(read_frame)
      end
      tag = reader.u8
      case tag
      when 4
        id = reader.u32
        nparams = reader.u16
        v = [id, nparams]
        @prepared[sql] = v if @prepared.length < 240
        v
      when 3
        # Refused: DDL/session statements cannot be prepared, and an old
        # server answers "unknown opcode". Kept for the caller's error message.
        @last_prepare_error = reader.text
        nil
      else
        raise QueryError, "unexpected prepare response tag #{tag}"
      end
    end

    # Execute a prepared statement with TYPED parameters.
    def exec_prepared(id, params, consistency)
      raise ConnectionError, "connection is closed" if @closed

      req = +([3, consistency].pack("CC") + [id].pack("V") + [params.length].pack("v"))
      params.each do |p|
        v = Skaidb.encode_value(p)
        req << [v.bytesize].pack("V") << v
      end
      reader = nil
      @mutex.synchronize do
        write_frame(req)
        reader = Reader.new(read_frame)
      end
      parse_response(reader)
    end

    # Close the connection. Idempotent.
    # Yield a stream's events as they arrive, forever.
    #
    # A dependency-free helper over the stream's log: pages it with the
    # keyset cursor and yields each event as a Hash (id, op, k, ts, doc).
    # +id+ is the position — keep the last one and pass it as +after+ to
    # resume exactly where you stopped, across restarts.
    #
    # This polls; for push delivery subscribe to $stream/<db>/<name> with any
    # MQTT client instead. The events are identical.
    #
    #   conn.subscribe("big_orders") { |ev| handle(ev["doc"]) }
    def subscribe(stream, after: nil, poll: 0.5)
      log = "_stream_#{stream}"
      cur = after
      loop do
        res = if cur.nil?
                exec("SELECT id, op, k, ts, doc FROM #{log} ORDER BY id LIMIT 500")
              else
                exec_params(
                  "SELECT id, op, k, ts, doc FROM #{log} WHERE id > $1 ORDER BY id LIMIT 500",
                  [cur]
                )
              end
        rows = res.to_a
        rows.each do |row|
          cur = row["id"]
          yield row
        end
        sleep(poll) if rows.empty?
      end
    end

    # False once closed, once a transport error broke the socket, or while a
    # stream is in flight — mid-stream the socket is parked in the middle of a
    # reply, and a stream abandoned without unwinding never clears the flag, so
    # this is what stops Pool checking a desynced connection back in.
    def usable?
      !@closed && !@broken && !@streaming
    end

    def close
      return if @closed

      @closed = true
      begin
        @sock&.close
      rescue StandardError
        # ignore — socket already gone
      end
      nil
    end

    def finished?
      @closed
    end

    private

    # -- framing --

    def write_frame(payload)
      payload = payload.b
      @sock.write([payload.bytesize].pack("N") + payload) # length is BE
    rescue StandardError => e
      @broken = true
      raise ConnectionError, "write failed: #{e.message}"
    end

    # Re-dial if the transport died since the last statement, BEFORE anything
    # is prepared on it.
    #
    # The prepared-statement cache MUST be cleared: an id is only valid on the
    # connection that created it, so carrying one across a reconnect would run
    # a different statement (or fail obscurely).
    def ensure_live!
      raise ConnectionError, "connection is closed" if @closed
      return unless @broken

      @prepared.clear
      begin
        @sock&.close
      rescue StandardError
        nil
      end
      @sock = nil
      # Cleared BEFORE dialling: dial! issues USE, which runs a statement and
      # would otherwise re-enter this method forever.
      @broken = false
      begin
        dial!
      rescue StandardError => e
        @broken = true          # still down; the next statement retries
        raise e
      end
    end

    def read_frame
      head = read_exact(4)
      length = head.unpack1("N") # BE
      read_exact(length)
    end

    # Read out the frames left over from a stream the caller walked away from,
    # so the connection is positioned at a request boundary again. Deliberately
    # Runs from an ensure, where an exception would replace whatever the
    # caller's block was already unwinding with — so an ordinary failure
    # marks the connection broken rather than raising. usable? then fails
    # and ensure_live! re-dials before the next statement.
    #
    # Not exception-PROOF, and the difference matters: the rescue below
    # catches StandardError, so Interrupt, SignalException and
    # NoMemoryError still escape. They also skip the `@streaming = false`
    # in the caller's ensure, which leaves the connection permanently
    # unusable — safe, but only because "unusable" is the failing
    # direction. Rescuing Exception here would hide a Ctrl-C, which is a
    # worse trade than retiring one connection.
    #
    # There is also no read DEADLINE. A peer that is alive but silent
    # blocks the drain forever, holding @mutex — the same as every other
    # read in this driver, and `close` deliberately does not take @mutex
    # so another thread can break it. A genuinely dead socket (EOF, RST)
    # exits correctly.
    def drain_stream!
      loop do
        tag = Reader.new(read_frame).u8
        break if tag == 7 || tag == 3 # RowsEnd, or an Error that ended the stream
        next if tag == 6              # RowsChunk: more to come

        @broken = true
        break
      end
    rescue StandardError
      # An I/O failure already set @broken in read_exact; set it for the rest
      # (a truncated frame, say) so the socket is never reused mid-reply.
      @broken = true
    end

    def read_exact(n)
      return "".b if n.zero?

      buf = String.new(capacity: n) # ASCII-8BIT, so appending raw bytes never re-encodes
      while buf.bytesize < n
        chunk = begin
          @sock.read(n - buf.bytesize)
        rescue StandardError => e
          @broken = true
          raise ConnectionError, "read failed: #{e.message}"
        end
        if chunk.nil? || chunk.empty?
          @broken = true
          raise ConnectionError, "connection closed by server"
        end

        buf << chunk
      end
      buf
    end

    # -- handshake --

    def handshake(user, password)
      counter = Skaidb.next_nonce_id
      client_nonce = "rb#{Process.pid}.#{counter}.#{SecureRandom.hex(4)}"

      start = [10].pack("C") + Skaidb.enc_str(user) + Skaidb.enc_str(client_nonce)
      write_frame(start)

      r = Reader.new(read_frame)
      raise ConnectionError, "bad handshake challenge" unless r.u8 == 11

      salt = r.blob
      iterations = r.u32
      server_nonce = r.text

      salt_hex = salt.unpack1("H*") # lowercase hex
      auth_message = [user, client_nonce, server_nonce, salt_hex, iterations.to_s]
                     .join("\0").dup.force_encoding("UTF-8")
      proof, expected_sig = Skaidb.scram(password, salt, iterations, auth_message)

      write_frame([12].pack("C") + proof) # 32 raw bytes, not length-prefixed

      r = Reader.new(read_frame)
      raise ConnectionError, "bad handshake outcome" unless r.u8 == 13

      if r.u8 == 1
        server_sig = r.take(32)
        if !password.empty? && !Skaidb.secure_compare(server_sig, expected_sig)
          raise ConnectionError, "server signature mismatch (mutual auth failed)"
        end
      else
        raise ConnectionError, "authentication denied: #{r.text}"
      end
    end

    # -- query --

    def run(sql, consistency)
      raise ConnectionError, "connection is closed" if @closed
      ensure_live!

      sql_bytes = sql.dup.force_encoding("UTF-8").b
      req = [1, consistency].pack("CC") + [sql_bytes.bytesize].pack("V") + sql_bytes
      reader = nil
      @mutex.synchronize do
        write_frame(req)
        reader = Reader.new(read_frame)
      end
      parse_response(reader)
    end

    def parse_response(r)
      tag = r.u8
      case tag
      when 0 # Rows
        ncols = r.u32
        columns = Array.new(ncols) { r.text }
        nrows = r.u32
        rows = Array.new(nrows) do
          ncells = r.u32
          Array.new(ncells) { Skaidb.decode_value(Reader.new(r.blob)) }
        end
        Result.new(fields: columns, rows: rows, cmd_tuples: 0)
      when 8 # ResultSets: a CALL whose body EMITted
        sets = Array.new(r.u32) do
          ncols = r.u32
          columns = Array.new(ncols) { r.text }
          nrows = r.u32
          rows = Array.new(nrows) do
            ncells = r.u32
            Array.new(ncells) { Skaidb.decode_value(Reader.new(r.blob)) }
          end
          Result.new(fields: columns, rows: rows, cmd_tuples: 0)
        end
        last = sets.last || Result.new(fields: [], rows: [], cmd_tuples: 0)
        Result.new(fields: last.fields, rows: last.rows, cmd_tuples: 0, result_sets: sets)
      when 1 # Mutation
        Result.new(fields: [], rows: [], cmd_tuples: r.u64)
      when 2 # Ddl
        Result.new(fields: [], rows: [], cmd_tuples: 0)
      when 3 # Error — a statement error, connection stays usable
        raise QueryError, r.text
      else
        raise ConnectionError, "unknown response tag #{tag}"
      end
    end
  end

  # ---- module entry point --------------------------------------------------

  # Open a connection to a skaidb node and run the SCRAM-SHA-256 handshake.
  #
  # @param host [String]
  # @param port [Integer]
  # @param user [String]
  # @param password [String]
  # @param consistency [Symbol, String, Integer] :one / :quorum / :all (or 0/1/2)
  # @param timeout [Numeric, nil] connect/IO timeout in seconds
  # @yield [conn] optional block; the connection is closed when it returns
  # @return [Connection] (or the block's value when a block is given)
  def self.connect(host: "localhost", port: 7000, user: "anonymous",
                   password: "", consistency: :quorum, timeout: 10.0,
                   database: nil, tls: false, tls_ca: nil, tls_insecure: false,
                   tls_server_name: "skaidb", seeds: nil)
    tls = true if tls_ca || tls_insecure
    conn = Connection.new(host: host, port: port, user: user,
                          password: password, consistency: consistency,
                          timeout: timeout, database: database, tls: tls,
                          tls_ca: tls_ca, tls_insecure: tls_insecure,
                          tls_server_name: tls_server_name, seeds: seeds)
    return conn unless block_given?

    begin
      yield conn
    ensure
      conn.close
    end
  end
  # A thread-safe pool of connections.
  #
  # +maxsize+ bounds the connections kept IDLE, not the number checked out: a
  # burst creates extras and the surplus is closed on return. Every keyword
  # accepted by Skaidb.connect passes through, so pooled connections inherit
  # seed failover, TLS and the session database.
  #
  #   pool = Skaidb::Pool.new(seeds: ["h1:7000", "h2:7000"], database: "app", maxsize: 8)
  #   pool.with { |conn| conn.exec("SELECT 1") }
  #   pool.close
  class Pool
    def initialize(maxsize: 10, **connect_kwargs)
      raise ArgumentError, "maxsize must be >= 1" if maxsize < 1

      @maxsize = maxsize
      @kwargs = connect_kwargs
      @idle = []
      @mutex = Mutex.new
      @closed = false
    end

    # Check out a usable connection, reusing an idle one when possible.
    def checkout
      loop do
        conn = @mutex.synchronize do
          raise Error, "pool is closed" if @closed

          @idle.pop
        end
        return Skaidb.connect(**@kwargs) if conn.nil?
        # A connection the server closed while it sat idle still looks fine
        # locally, so check before handing it out.
        return conn if conn.usable?

        begin
          conn.close
        rescue StandardError
          nil
        end
      end
    end

    # Return a connection, closing it if broken or the pool is full.
    def checkin(conn)
      keep = @mutex.synchronize do
        !@closed && conn.usable? && @idle.length < @maxsize
      end
      if keep
        @mutex.synchronize { @idle.push(conn) }
        return
      end
      begin
        conn.close
      rescue StandardError
        nil
      end
    end

    # Run the block with a checked-out connection, returning it afterwards.
    def with
      conn = checkout
      begin
        yield conn
      ensure
        checkin(conn)
      end
    end

    # Close the pool and every idle connection.
    def close
      drained = @mutex.synchronize do
        @closed = true
        d = @idle
        @idle = []
        d
      end
      drained.each do |c|
        begin
          c.close
        rescue StandardError
          nil
        end
      end
    end
  end
end
