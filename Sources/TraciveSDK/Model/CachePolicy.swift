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
  /// Whether `CheckResult.cacheTtlSeconds` overrides the per-tier default. Leave this on: it is the
  /// server's fleet-wide invalidation lever. Turning it off pins clients to local defaults and
  /// makes a bad cached verdict un-revocable.
  public var honorsServerTtlOverride: Bool
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

  public init(
    isEnabled: Bool = true,
    highTtl: TimeInterval = 30 * 24 * 60 * 60,
    elevatedTtl: TimeInterval = 7 * 24 * 60 * 60,
    cautionTtl: TimeInterval = 24 * 60 * 60,
    noneTtl: TimeInterval = 60 * 60,
    honorsServerTtlOverride: Bool = true,
    maxEntries: Int? = 5_000
  ) {
    self.isEnabled = isEnabled
    self.highTtl = highTtl
    self.elevatedTtl = elevatedTtl
    self.cautionTtl = cautionTtl
    self.noneTtl = noneTtl
    self.honorsServerTtlOverride = honorsServerTtlOverride
    self.maxEntries = maxEntries
  }

  /// The spec defaults.
  public static let `default` = CachePolicy()

  /// No local caching at all.
  public static let disabled = CachePolicy(isEnabled: false)

  /// The default TTL for a tier, ignoring any server override.
  public func ttl(for tier: RiskTier) -> TimeInterval {
    switch tier {
    case .high: return highTtl
    case .elevated: return elevatedTtl
    case .caution: return cautionTtl
    case .none: return noneTtl
    }
  }

  /// The TTL actually applied to a result: the server's `cacheTtlSeconds` when it sent one and
  /// overrides are honoured, otherwise the per-tier default. Negative values clamp to zero, which
  /// makes the entry stale immediately rather than eternally fresh.
  public func effectiveTtl(for tier: RiskTier, serverTtlSeconds: Int64?) -> TimeInterval {
    guard honorsServerTtlOverride, let serverTtlSeconds else { return ttl(for: tier) }
    return max(0, TimeInterval(serverTtlSeconds))
  }

  /// Convenience over `effectiveTtl(for:serverTtlSeconds:)` for a decoded result.
  public func effectiveTtl(for result: CheckResult) -> TimeInterval {
    effectiveTtl(for: result.riskTier, serverTtlSeconds: result.cacheTtlSeconds)
  }

  /// Whether a stored result is still fresh at `now`.
  public func isFresh(_ result: CheckResult, now: Date) -> Bool {
    guard isEnabled else { return false }
    return now.timeIntervalSince(result.fetchedAt) < effectiveTtl(for: result)
  }
}
