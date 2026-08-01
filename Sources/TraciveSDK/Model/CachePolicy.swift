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
  /// Optional cap on stored rows; `nil` means unbounded (lazy expiry plus the prune-on-open pass
  /// keeps it in check).
  public var maxEntries: Int?

  public init(
    isEnabled: Bool = true,
    highTtl: TimeInterval = 30 * 24 * 60 * 60,
    elevatedTtl: TimeInterval = 7 * 24 * 60 * 60,
    cautionTtl: TimeInterval = 24 * 60 * 60,
    noneTtl: TimeInterval = 60 * 60,
    honorsServerTtlOverride: Bool = true,
    maxEntries: Int? = nil
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
