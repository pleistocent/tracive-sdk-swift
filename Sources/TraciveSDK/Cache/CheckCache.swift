import Foundation

/// The local result cache.
///
/// A cache hit costs **zero credits and performs zero network I/O**, which is the entire point: the
/// same phone number gets checked repeatedly in a real app, and every avoided round trip is a
/// charge the partner does not pay.
///
/// ## What a conforming store must guarantee
/// 1. **The raw identifier is never persisted.** Address rows by `CheckCacheKey`, which is
///    `SHA-256(searchQueryIndex)`.
/// 2. **Full detail is never cached.** Store `CheckResult.cacheableCopy()`, which drops
///    `topChronologies`, `comments`, `billing` and `checkId`. The key is the query alone, so a
///    cached `full` response would be served to a later `minimal` request and vice versa. If a
///    future version does cache full detail, the key must become `(query, detail, locale)`.
/// 3. **Freshness is decided on read**, from the current `policy` and the stored `fetchedAt`. An
///    expired entry reads as `nil`.
/// 4. **A read never returns a stale-but-plausible answer.** Wrongness here is silent and lands in
///    a fraud warning, so the failure mode must be "no answer", never "an old answer".
///
/// ## Errors and misses
/// A miss is `nil`, not an error. `TraciveError.cacheMiss` is raised by the *client* when
/// `Source.cache` was requested and the read came back empty — the store has no idea which
/// `Source` was asked for. Storage faults throw `CheckCacheError`; see that type for how callers
/// should treat them (short version: never fatal).
///
/// ## Threading
/// Methods are synchronous and must be safe to call from any thread. The SQLite implementation
/// serialises internally. They are not `async` because a local SQLite read completes in
/// microseconds; wrapping that in a suspension buys nothing and would force every call site into an
/// `await` for a cache lookup that is usually a hit.
public protocol CheckCache: AnyObject, Sendable {

  /// The freshness rules this store applies on read.
  var policy: CachePolicy { get }

  /// The freshest cached result for `key`, or `nil` when there is no entry or the entry has expired.
  ///
  /// Expiry is evaluated lazily here, so an entry that went stale while the app was backgrounded
  /// is never served.
  func read(_ key: CheckCacheKey) throws -> CheckResult?

  /// Stores `result` under `key`, replacing any existing entry.
  ///
  /// Implementations must persist `result.cacheableCopy()`, not `result`.
  func write(_ result: CheckResult, for key: CheckCacheKey) throws

  /// Deletes one entry. A key that is not present is not an error. Any transaction record that was
  /// taken from it is left alone.
  func remove(_ key: CheckCacheKey) throws

  /// Files `result` as the answer that was shown for `transactionId`.
  ///
  /// This is what a transaction-detail screen reads back weeks later — "checked before you sent it,
  /// no reports found" — and it exists because `read` cannot answer that question. `read` is keyed
  /// on the identifier and holds whatever the *latest* check said; a transaction detail has to show
  /// what the user was shown **at the time they decided**, and those two diverge the moment the same
  /// account is checked again.
  ///
  /// Three differences from `write`, all following from that:
  /// - **It is a snapshot, not a pointer.** Each call stores its own copy, so a later check of the
  ///   same account cannot rewrite what an earlier transaction says. Recording one answer against
  ///   two transactions — a user who transfers to the same account twice — is two calls with two
  ///   ids and one billed check.
  /// - **It outlives the cache entry.** The lifetime is `policy.transactionCheckRetention` rather
  ///   than a tier TTL, because a clean answer stops being *trustworthy* after an hour but never
  ///   stops being *what was shown*.
  /// - **`origin` and `fetchedAt` are stored as given**, so a record marked `.cache` is the honest
  ///   statement that this transfer spent no credit.
  ///
  /// Implementations must persist `result.transactionRecordCopy()`, not `result`.
  ///
  /// Call it **after** the transaction exists. In a transfer flow the check happens on the
  /// confirmation screen and the reference number is minted after the PIN, so there is no id to pass
  /// when the check is made — which is why this is a separate call rather than a parameter on
  /// `checkScammer`.
  ///
  /// - Throws: `CheckCacheError.invalidTransactionId` when `transactionId` is blank.
  func writeTransactionCheck(_ result: CheckResult, for transactionId: String) throws

  /// The answer recorded for `transactionId`, or `nil` when there is none.
  ///
  /// `nil` covers a transaction that was never recorded, one past its retention, and a record that
  /// would not decrypt. A UI must read it as **"no check is on file"** and show nothing, never as
  /// "no reports were found": the second is a clean bill of health for a transfer nobody checked.
  ///
  /// Unlike `read` this does not restamp `origin`, and it does not apply the tier TTL. The record is
  /// a statement about a past moment, not a cached answer offered as current.
  ///
  /// - Throws: `CheckCacheError.invalidTransactionId` when `transactionId` is blank.
  func readTransactionCheck(for transactionId: String) throws -> CheckResult?

  /// Deletes one transaction record. Leaves the cache entry it was copied from, and every other
  /// transaction's record, alone.
  ///
  /// - Throws: `CheckCacheError.invalidTransactionId` when `transactionId` is blank.
  func removeTransactionCheck(for transactionId: String) throws

  /// Deletes everything, transaction records included. This is what `client.cache.clear()` calls.
  ///
  /// Sign-out goes through here, so a host whose transaction history outlives a Tracive sign-out
  /// should expect the check card on those older transactions to go quiet: the verdict was read
  /// under a grant that no longer exists.
  func clear() throws

  /// Deletes expired entries and enforces `policy.maxEntries`.
  ///
  /// - Returns: how many rows were deleted.
  @discardableResult
  func prune() throws -> Int

  /// How many entries are stored, expired ones included. Diagnostics only.
  func count() throws -> Int
}

// MARK: - Query-shaped conveniences

extension CheckCache {

  /// `read` addressed by a query. The query is hashed here and the folded key is not retained.
  public func read(_ query: TraciveQuery) throws -> CheckResult? {
    try read(CheckCacheKey(query: query))
  }

  /// `write` addressed by a query.
  public func write(_ result: CheckResult, for query: TraciveQuery) throws {
    try write(result, for: CheckCacheKey(query: query))
  }

  /// `remove` addressed by a query.
  public func remove(_ query: TraciveQuery) throws {
    try remove(CheckCacheKey(query: query))
  }

  /// A read that swallows storage faults, for the common path where a broken cache should simply
  /// mean "go to the server". Returns `nil` on both a miss and a failure.
  ///
  /// Do **not** use this to serve `Source.cache`: that mode must be able to tell a miss from a
  /// fault, because it must surface `TraciveError.cacheMiss` explicitly.
  public func readIgnoringFailures(_ key: CheckCacheKey) -> CheckResult? {
    (try? read(key)) ?? nil
  }

  /// A write that swallows storage faults. A failed write costs one extra credit next time; it must
  /// never fail a check that already succeeded.
  public func writeIgnoringFailures(_ result: CheckResult, for key: CheckCacheKey) {
    try? write(result, for: key)
  }
}

// MARK: - Disabled

/// A cache that stores nothing.
///
/// Use it when `CachePolicy.isEnabled` is `false`, so the rest of the SDK can keep calling
/// `cache.read(...)` unconditionally instead of threading an optional through every path — an
/// optional cache is exactly the kind of thing that gets `!`-ed at 2am.
///
/// Every check then goes to the server and is billed. Reads return `nil`, which the client turns
/// into `TraciveError.cacheMiss` under `Source.cache`; that is the correct answer, since a disabled
/// cache genuinely has nothing.
public final class NoOpCheckCache: CheckCache {

  public let policy: CachePolicy

  public init(policy: CachePolicy = .disabled) {
    self.policy = policy
  }

  public func read(_ key: CheckCacheKey) throws -> CheckResult? { nil }
  public func write(_ result: CheckResult, for key: CheckCacheKey) throws {}
  public func remove(_ key: CheckCacheKey) throws {}
  public func clear() throws {}

  // Transaction records go with the cache, because they are rows in it. A host that wants the check
  // card on its transaction-detail screen has to wire a real cache — there is nowhere else to put
  // them, and quietly storing them somewhere this object controls would be a second, undocumented
  // store on a device whose owner was told there is none. The blank-id check still runs, so a host
  // finds that bug with the cache off rather than only in production.

  public func writeTransactionCheck(_ result: CheckResult, for transactionId: String) throws {
    _ = try Self.requireKey(transactionId)
  }

  public func readTransactionCheck(for transactionId: String) throws -> CheckResult? {
    _ = try Self.requireKey(transactionId)
    return nil
  }

  public func removeTransactionCheck(for transactionId: String) throws {
    _ = try Self.requireKey(transactionId)
  }

  private static func requireKey(_ transactionId: String) throws -> TransactionRecordKey {
    guard let key = TransactionRecordKey(transactionId: transactionId) else {
      throw CheckCacheError.invalidTransactionId
    }
    return key
  }

  @discardableResult
  public func prune() throws -> Int { 0 }

  public func count() throws -> Int { 0 }
}
