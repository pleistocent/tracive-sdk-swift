import Foundation

/// Freshness rules for the local encrypted result cache.
///
/// The per-tier defaults come straight from the spec: `HIGH` 30 d, `ELEVATED` 7 d, `CAUTION` 24 h,
/// `NONE` 1 h. A high-risk verdict is stable, so it can be held for a month; a clean verdict is the
/// one most likely to go stale (today's clean number is tomorrow's scammer), so it is held for an
/// hour.
public struct CachePolicy: Equatable, Hashable, Sendable {

  /// Turn the cache off entirely. Every check then goes to the server and is billed.
  public var isEnabled: Bool
  public var highTtl: TimeInterval
  public var elevatedTtl: TimeInterval
  public var cautionTtl: TimeInterval
  public var noneTtl: TimeInterval
  /// Cap on stored rows. Enforced after every write and by the prune pass; `nil` means unbounded.
  ///
  /// **The default is 5 000, and an unbounded default would be the wrong one.** This is an
  /// encrypted database on someone's phone, and the two mechanisms that used to be relied on to
  /// hold it down do not: lazy expiry only touches rows that are read again, and the prune-on-open
  /// pass only deletes rows that are already expired. A `HIGH` verdict is held for thirty days, so
  /// a screen that checks a fresh identifier on every render can accumulate a month of them with
  /// nothing to stop it. Growth like that is silent — no error, no warning, just a file that gets
  /// bigger — and the device it lands on is one this SDK has no further contact with.
  ///
  /// The number matches the Flutter SDK, so both bound the same store at the same size.
  ///
  /// Eviction takes the rows **closest to expiring** first, because those have the least value
  /// left: a row about to die was going to be re-fetched shortly anyway. Not LRU, which would mean
  /// a write on every cache hit and turn the cheap path into the expensive one.
  public var maxEntries: Int?

  /// How long a transaction record — the answer that was shown for one of your transactions — is
  /// kept. Zero or less stores none at all.
  ///
  /// A separate knob from the TTLs above because it answers a different question. A TTL asks "is
  /// this verdict still worth trusting?", and an hour is right for a clean one. A retention asks
  /// "can the user still see what they were told before they sent the money?", and that does not
  /// decay: the record is a fact about the past, so the only thing that should end it is the host's
  /// own data-minimisation policy.
  ///
  /// 90 days matches how far back a transaction list is usually browsed. Raise it if your history
  /// screen goes back further — and raise `maxEntries` with it, since records are counted by the
  /// same cap as cache entries.
  ///
  public var transactionCheckRetention: TimeInterval

  public init(
    isEnabled: Bool = true,
    highTtl: TimeInterval = 30 * 24 * 60 * 60,
    elevatedTtl: TimeInterval = 7 * 24 * 60 * 60,
    cautionTtl: TimeInterval = 24 * 60 * 60,
    noneTtl: TimeInterval = 60 * 60,
    maxEntries: Int? = 5_000,
    transactionCheckRetention: TimeInterval = 90 * 24 * 60 * 60
  ) {
    self.isEnabled = isEnabled
    self.highTtl = highTtl
    self.elevatedTtl = elevatedTtl
    self.cautionTtl = cautionTtl
    self.noneTtl = noneTtl
    self.maxEntries = maxEntries
    self.transactionCheckRetention = transactionCheckRetention
  }

  /// The spec defaults.
  public static let `default` = CachePolicy()

  /// No local caching at all.
  public static let disabled = CachePolicy(isEnabled: false)

  /// How long a result of this tier stays usable — the whole of the cache's lifetime policy.
  ///
  /// There is no per-response override. The backend used to be able to send a `cacheTtlSeconds`
  /// that replaced this, which duplicated the ladder below on the server; cache lifetime is the
  /// SDK's own business, so a host that wants different numbers sets them here.
  public func ttl(for tier: RiskTier) -> TimeInterval {
    switch tier {
    case .high: return highTtl
    case .elevated: return elevatedTtl
    case .caution: return cautionTtl
    case .none: return noneTtl
    }
  }

  /// Whether a stored result is still fresh at `now`.
  public func isFresh(_ result: CheckResult, now: Date) -> Bool {
    guard isEnabled else { return false }
    return now.timeIntervalSince(result.fetchedAt) < ttl(for: result.riskTier)
  }
}
