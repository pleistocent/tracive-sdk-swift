import Foundation

/// The local result cache (§5).
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
/// 3. **Freshness is decided on read**, from the current `policy` and the stored `fetchedAt` /
///    `cacheTtlSeconds`. An expired entry reads as `nil`.
/// 4. **A read never returns a stale-but-plausible answer.** Wrongness here is silent and lands in
///    a fraud warning, so the failure mode must be "no answer", never "an old answer".
///
/// ## Errors and misses
/// A miss is `nil`, not an error. `TraciveError.cacheMiss` is raised by the *client* when
/// `Source.cache` was requested and the read came back empty (§5) — the store has no idea which
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
  /// Expiry is evaluated lazily here (§5), so an entry that went stale while the app was backgrounded
  /// is never served.
  func read(_ key: CheckCacheKey) throws -> CheckResult?

  /// Stores `result` under `key`, replacing any existing entry.
  ///
  /// Implementations must persist `result.cacheableCopy()`, not `result`.
  func write(_ result: CheckResult, for key: CheckCacheKey) throws

  /// Deletes one entry. A key that is not present is not an error.
  func remove(_ key: CheckCacheKey) throws

  /// Deletes everything. This is `client.cache.clear()` from §5.
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
  /// fault, because §5 requires it to surface `TraciveError.cacheMiss` explicitly.
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

  @discardableResult
  public func prune() throws -> Int { 0 }

  public func count() throws -> Int { 0 }
}
