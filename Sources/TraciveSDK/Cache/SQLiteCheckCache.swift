import Foundation

/// The production `CheckCache`: system SQLite for storage, CryptoKit AES-GCM per row for
/// confidentiality.
///
/// ```swift
/// let cache = try SQLiteCheckCache()                       // Application Support, Keychain key
/// let cached = try cache.read(query)                       // nil when missing or stale
/// try cache.write(serverResult, for: query)
/// try cache.clear()                                        // backs client.cache.clear()
/// ```
///
/// ## What lands on disk
///
/// | Column | Contents | Readable without the key? |
/// |---|---|---|
/// | `key` | `SHA-256(searchQueryIndex)` hex | yes — a digest, never the identifier |
/// | `payload` | AES-GCM sealed box of the cacheable `CheckResult` JSON | no |
/// | `fetched_at` | when the server produced the data | yes |
/// | `expires_at` | prune hint, `fetched_at + TTL` at write time | yes |
///
/// Two kinds of row live in that table, told apart by the shape of the key and by nothing else: a
/// cached answer under `SHA-256(searchQueryIndex)`, and a transaction record under `txn:` +
/// `SHA-256(transactionId)`. `:` is not a hex digit, so the key spaces cannot collide, and each kind
/// authenticates under its own AAD label, so neither can be opened as the other. A plaintext `kind`
/// column would be the obvious alternative and is exactly what this schema avoids: it would sort a
/// stolen file into "answers held" and "transfers made" before anyone decrypted a byte.
///
/// The two timestamps are plaintext on purpose: pruning must not require decrypting every row, and
/// this is the whole of what they leak. `expires_at - fetched_at` reveals which per-tier TTL applied,
/// so an attacker holding the raw file can tell that *some* query resolved to a high-risk tier — but
/// not which query, and not a single field of the verdict. Trading that for a prune pass that is one
/// indexed `DELETE` instead of a full decrypt of the table is the right trade; the verdict itself and
/// the identifier both stay protected.
///
/// ## Freshness: read is authoritative, prune is best-effort
/// `read` decides staleness with the **current** `policy` applied to the decoded result, via
/// `CachePolicy.isFresh(_:now:)` — so it honours a `cacheTtlSeconds` the server sent (the
/// fleet-wide invalidation lever) and reacts immediately to a policy change. `expires_at` is only an
/// index for `prune`, computed from whatever policy was in force at write time. The split matters:
/// prune may leave a stale row behind for a while, and read will still refuse to serve it. It can
/// never go the other way.
///
/// ## Failure posture
/// A row that will not decrypt is deleted and reported as a miss, so a rotated Keychain key or a
/// restore onto another device degrades to a cold cache rather than a permanently throwing SDK. A
/// key-store fault (`dataKeyUnavailable`, `dataKeyCorrupt`) propagates instead — deleting the whole
/// table because the Keychain was briefly unavailable would be an own goal.
public final class SQLiteCheckCache: CheckCache, @unchecked Sendable {

  /// Bump this to invalidate every stored row on upgrade.
  ///
  /// Change it whenever the payload shape or the encryption format changes in a way an older row
  /// cannot satisfy. Nothing migrates: the table is dropped and recreated, because a cold cache
  /// costs credits while a mis-decoded one costs correctness in a fraud warning.
  public static let schemaVersion = 1

  public let policy: CachePolicy

  private let connection: SQLiteConnection
  private let cipher: CachePayloadCipher
  private let now: @Sendable () -> Date
  /// One lock for the whole store. SQLite is opened `FULLMUTEX`, but the read-decrypt-delete and
  /// write-then-evict sequences below have to be atomic as a whole, not statement by statement.
  private let lock = NSLock()

  // MARK: - Construction

  /// Opens (or creates) the store.
  ///
  /// - Parameters:
  ///   - url: database file. Defaults to `Application Support/TraciveSDK/check-cache.sqlite3`.
  ///   - policy: freshness rules. Defaults to the per-tier TTLs documented on `CachePolicy`.
  ///   - keyStore: where the AES data key lives. Defaults to the Keychain, Secure Enclave-backed
  ///     where the device has one. **Tests must pass `EphemeralCacheKeyStore()`** — an unsigned
  ///     `swift test` binary either cannot reach the Keychain or prompts a human for it.
  ///   - now: the clock, injected so TTL behaviour is testable without sleeping.
  public convenience init(
    url: URL? = nil,
    policy: CachePolicy = .default,
    keyStore: any CacheKeyStore = KeychainCacheKeyStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    let resolved = try url ?? Self.defaultStoreURL()
    try Self.prepareDirectory(for: resolved)
    try self.init(path: resolved.path, policy: policy, keyStore: keyStore, now: now)
    Self.applyFileProtection(to: resolved)
  }

  /// An entirely in-memory store. Nothing is written to disk and everything is gone when the
  /// instance is released. Handy for tests and for a host app that wants request coalescing within a
  /// session without persisting anything.
  public static func inMemory(
    policy: CachePolicy = .default,
    keyStore: any CacheKeyStore = EphemeralCacheKeyStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws -> SQLiteCheckCache {
    try SQLiteCheckCache(path: ":memory:", policy: policy, keyStore: keyStore, now: now)
  }

  /// Designated initialiser. `path` may be `":memory:"`.
  public init(
    path: String,
    policy: CachePolicy = .default,
    keyStore: any CacheKeyStore = KeychainCacheKeyStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    self.policy = policy
    self.now = now
    self.connection = try SQLiteConnection(path: path)
    self.cipher = CachePayloadCipher(keyStore: keyStore, schemaVersion: Self.schemaVersion)

    try configure()
    try migrate()
    // Prune on open. Best-effort: a store that cannot prune is still a usable store, and
    // refusing to open the cache because a `DELETE` failed would turn a housekeeping problem into a
    // billing one.
    _ = try? unlockedPrune()
  }

  // MARK: - CheckCache

  public func read(_ key: CheckCacheKey) throws -> CheckResult? {
    lock.lock()
    defer { lock.unlock() }

    guard policy.isEnabled else { return nil }

    let statement = try connection.prepare("SELECT payload FROM check_cache WHERE key = ? LIMIT 1;")
    try statement.bind(1, text: key.hex)
    guard try statement.step() else { return nil }
    let payload = statement.blob(0)

    // Release the SELECT's read cursor before anything below can DELETE from the same table on the
    // same connection. `statement` is still in scope, and a statement that returned `SQLITE_ROW`
    // without being stepped to completion holds its cursor open. Both removal paths below are
    // `try?`, so a `SQLITE_LOCKED` there would be swallowed and the row would quietly survive —
    // `read` would keep answering `nil` correctly while the file grew. `payload` is a `Data` copy,
    // so it stays valid after the reset.
    statement.reset()

    let result: CheckResult
    do {
      result = try cipher.open(payload, for: key)
    } catch CheckCacheError.payloadUnreadable {
      // Wrong key, tampered row, or a payload written by a build we can no longer decode. It will
      // never become readable, so drop it and answer as a miss.
      try? unlockedRemove(key)
      return nil
    }

    guard policy.isFresh(result, now: now()) else {
      try? unlockedRemove(key)
      return nil
    }

    // `cacheableCopy()` already stamped `.cache`; restate it so provenance cannot drift if the
    // stored payload predates that guarantee.
    return result.withOrigin(.cache)
  }

  public func write(_ result: CheckResult, for key: CheckCacheKey) throws {
    lock.lock()
    defer { lock.unlock() }

    // A disabled policy means "do not keep local copies". Honour that here too, so a store
    // constructed with `.disabled` cannot quietly accumulate rows.
    guard policy.isEnabled else { return }

    let entry = result.cacheableCopy()
    let payload = try cipher.seal(entry, for: key)
    // Expiry is measured from when the *data* was fetched, not from now — matching
    // `CachePolicy.isFresh`, which compares `now - fetchedAt`. Measuring from the write instant
    // would silently extend the life of a result that sat in a response queue.
    let expiresAt = entry.fetchedAt.addingTimeInterval(policy.effectiveTtl(for: entry))

    try connection.transaction {
      let statement = try connection.prepare(
        """
        INSERT OR REPLACE INTO check_cache (key, payload, fetched_at, expires_at, written_at)
        VALUES (?, ?, ?, ?, ?);
        """
      )
      try statement.bind(1, text: key.hex)
      try statement.bind(2, blob: payload)
      try statement.bind(3, double: entry.fetchedAt.timeIntervalSince1970)
      try statement.bind(4, double: expiresAt.timeIntervalSince1970)
      try statement.bind(5, double: now().timeIntervalSince1970)
      try statement.step()
    }

    // Enforce the cap after inserting, so the row just written is itself a candidate rather than
    // being exempt. Failing to evict must not fail the write.
    _ = try? unlockedEnforceMaxEntries()
  }

  public func remove(_ key: CheckCacheKey) throws {
    lock.lock()
    defer { lock.unlock() }
    try unlockedRemove(key)
  }

  public func writeTransactionCheck(_ result: CheckResult, for transactionId: String) throws {
    let key = try Self.recordKey(transactionId)

    lock.lock()
    defer { lock.unlock() }

    guard policy.isEnabled else { return }

    // A retention of zero or less means "keep no records", and it takes the ones already written
    // with it — the same shape as a disabled cache refusing to accumulate rows.
    guard policy.transactionCheckRetention > 0 else {
      try? unlockedRemoveRow(key.rowKey)
      return
    }

    let record = result.transactionRecordCopy()
    let payload = try cipher.sealRecord(record, for: key)
    // Measured from now, not from `fetchedAt`. A cache entry expires when its verdict goes stale, so
    // it is dated from when the data was produced; a record expires when the host stops wanting the
    // history, so it is dated from when the history was made.
    let expiresAt = now().addingTimeInterval(policy.transactionCheckRetention)

    try connection.transaction {
      let statement = try connection.prepare(
        """
        INSERT OR REPLACE INTO check_cache (key, payload, fetched_at, expires_at, written_at)
        VALUES (?, ?, ?, ?, ?);
        """
      )
      try statement.bind(1, text: key.rowKey)
      try statement.bind(2, blob: payload)
      try statement.bind(3, double: record.fetchedAt.timeIntervalSince1970)
      try statement.bind(4, double: expiresAt.timeIntervalSince1970)
      try statement.bind(5, double: now().timeIntervalSince1970)
      try statement.step()
    }

    _ = try? unlockedEnforceMaxEntries()
  }

  public func readTransactionCheck(for transactionId: String) throws -> CheckResult? {
    let key = try Self.recordKey(transactionId)

    lock.lock()
    defer { lock.unlock() }

    guard policy.isEnabled else { return nil }

    let statement = try connection.prepare(
      "SELECT payload, expires_at FROM check_cache WHERE key = ? LIMIT 1;"
    )
    try statement.bind(1, text: key.rowKey)
    guard try statement.step() else { return nil }
    let payload = statement.blob(0)
    let expiresAt = statement.double(1)

    // Release the cursor before the DELETEs below run on the same connection; see `read`.
    statement.reset()

    // The row's own `expires_at`, not `policy.isFresh`. Freshness asks whether a verdict is still
    // worth trusting and is measured from `fetched_at`; retention asks whether the user may still
    // see what they were told, and a record whose verdict went stale months ago is still the right
    // answer to that.
    guard expiresAt > now().timeIntervalSince1970 else {
      try? unlockedRemoveRow(key.rowKey)
      return nil
    }

    do {
      // No `withOrigin`: the origin this was recorded under is part of what happened.
      return try cipher.openRecord(payload, for: key)
    } catch CheckCacheError.payloadUnreadable {
      try? unlockedRemoveRow(key.rowKey)
      return nil
    }
  }

  public func removeTransactionCheck(for transactionId: String) throws {
    let key = try Self.recordKey(transactionId)
    lock.lock()
    defer { lock.unlock() }
    try unlockedRemoveRow(key.rowKey)
  }

  public func clear() throws {
    lock.lock()
    defer { lock.unlock() }
    try connection.execute("DELETE FROM check_cache;")
  }

  @discardableResult
  public func prune() throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    return try unlockedPrune()
  }

  public func count() throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    let statement = try connection.prepare("SELECT COUNT(*) FROM check_cache;")
    guard try statement.step() else { return 0 }
    return Int(statement.int(0))
  }

  // MARK: - Diagnostics

  /// `true` when a row exists for `key`, **regardless of freshness**.
  ///
  /// For deciding whether to call the server use `read`, which applies expiry. This is for tests and
  /// for confirming that an expired row was actually deleted rather than merely hidden.
  public func containsRow(for key: CheckCacheKey) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let statement = try connection.prepare("SELECT 1 FROM check_cache WHERE key = ? LIMIT 1;")
    try statement.bind(1, text: key.hex)
    return try statement.step()
  }

  // MARK: - Unlocked internals (callers already hold `lock`)

  private func unlockedRemove(_ key: CheckCacheKey) throws {
    try unlockedRemoveRow(key.hex)
  }

  private func unlockedRemoveRow(_ rowKey: String) throws {
    let statement = try connection.prepare("DELETE FROM check_cache WHERE key = ?;")
    try statement.bind(1, text: rowKey)
    try statement.step()
  }

  /// Hashes a transaction id, or throws. Done before the lock is taken: a caller's bad argument
  /// should not have to queue behind a write to be reported.
  private static func recordKey(_ transactionId: String) throws -> TransactionRecordKey {
    guard let key = TransactionRecordKey(transactionId: transactionId) else {
      throw CheckCacheError.invalidTransactionId
    }
    return key
  }

  private func unlockedPrune() throws -> Int {
    var deleted = 0
    let statement = try connection.prepare("DELETE FROM check_cache WHERE expires_at <= ?;")
    try statement.bind(1, double: now().timeIntervalSince1970)
    try statement.step()
    deleted += connection.changes
    deleted += try unlockedEnforceMaxEntries()
    return deleted
  }

  private func unlockedEnforceMaxEntries() throws -> Int {
    guard let maxEntries = policy.maxEntries, maxEntries >= 0 else { return 0 }

    let countStatement = try connection.prepare("SELECT COUNT(*) FROM check_cache;")
    guard try countStatement.step() else { return 0 }
    let total = Int(countStatement.int(0))
    guard total > maxEntries else { return 0 }

    // Evict the rows closest to expiring. Not LRU: tracking last-read would mean a write on every
    // cache hit, turning the cheap path into the expensive one. "Dies soonest" is the next best
    // proxy and needs no extra bookkeeping — it drops the entries whose re-fetch is imminent anyway.
    let statement = try connection.prepare(
      """
      DELETE FROM check_cache WHERE key IN (
        SELECT key FROM check_cache ORDER BY expires_at ASC, written_at ASC LIMIT ?
      );
      """
    )
    try statement.bind(1, int: Int64(total - maxEntries))
    try statement.step()
    return connection.changes
  }

  // MARK: - Schema

  private func configure() throws {
    // WAL keeps a reader from blocking the writer, which matters when a check fires while the UI is
    // reading. Harmless on an in-memory database, where SQLite simply reports "memory" back.
    let journal = try connection.prepare("PRAGMA journal_mode=WAL;")
    _ = try? journal.step()
    // NORMAL rather than FULL: this is a regenerable cache. Losing the last few writes to a power
    // cut costs a credit, and an fsync per write costs every user battery and latency.
    try connection.execute("PRAGMA synchronous=NORMAL;")
    try connection.execute("PRAGMA temp_store=MEMORY;")
    try connection.execute("PRAGMA busy_timeout=3000;")
  }

  private func migrate() throws {
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
      """
    )

    let storedVersion = try readSchemaVersion()
    if storedVersion != Self.schemaVersion {
      // Deliberately destructive. See `schemaVersion`.
      try connection.execute("DROP TABLE IF EXISTS check_cache;")
      try writeSchemaVersion(Self.schemaVersion)
    }

    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS check_cache (
        key        TEXT PRIMARY KEY NOT NULL,
        payload    BLOB NOT NULL,
        fetched_at REAL NOT NULL,
        expires_at REAL NOT NULL,
        written_at REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_check_cache_expires_at ON check_cache (expires_at);
      """
    )
  }

  private func readSchemaVersion() throws -> Int? {
    let statement = try connection.prepare("SELECT value FROM meta WHERE key = 'schema_version';")
    guard try statement.step(), let raw = statement.text(0) else { return nil }
    return Int(raw)
  }

  private func writeSchemaVersion(_ version: Int) throws {
    let statement = try connection.prepare(
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?);"
    )
    try statement.bind(1, text: String(version))
    try statement.step()
  }

  // MARK: - Location and file protection

  /// `Application Support/TraciveSDK/check-cache.sqlite3`.
  ///
  /// Application Support rather than Caches: the OS may evict Caches under disk pressure at any
  /// moment, and every eviction is a bill. The store prunes itself and honours
  /// `CachePolicy.maxEntries`, so it does not need the system to garbage-collect it.
  public static func defaultStoreURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return base
      .appendingPathComponent("TraciveSDK", isDirectory: true)
      .appendingPathComponent("check-cache.sqlite3", isDirectory: false)
  }

  private static func prepareDirectory(for url: URL) throws {
    let directory = url.deletingLastPathComponent()
    #if os(iOS)
      // Set the protection class on the *directory*, not only on the database file: SQLite in WAL
      // mode also creates `-wal` and `-shm` sidecars, and a freshly committed row lives in the `-wal`
      // before any checkpoint. Protecting only the main file would leave the most recent writes at
      // the app's default class. New files inherit the directory's class, so this covers all three.
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      )
    #else
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #endif
  }

  private static func applyFileProtection(to url: URL) {
    // Best-effort hardening; none of it is load-bearing, because the payloads are encrypted anyway.
    #if os(iOS)
      // Match the Keychain item's accessibility. `complete` would make the file unreadable while the
      // phone is locked, breaking background checks; `completeUntilFirstUserAuthentication` still
      // protects the file across a cold boot.
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
      )
    #endif

    // The cache is regenerable and the payloads are useless on another device (the data key is
    // `ThisDeviceOnly`), so backing it up wastes the user's iCloud quota for nothing.
    var mutable = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutable.setResourceValues(values)
  }
}
