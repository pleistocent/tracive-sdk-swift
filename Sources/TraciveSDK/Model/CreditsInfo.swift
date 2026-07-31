import Foundation

/// Result of `GET /credits` (§4).
///
/// Do **not** call `credits()` before every check. Handle the `402` from the check itself instead —
/// it saves one round trip per transaction, and the balance you read a moment earlier can be stale
/// by the time the check lands anyway (§3.3).
public struct CreditsInfo: Codable, Equatable, Hashable, Sendable {
  public let subscriptionCredits: Int
  /// Subscription tier label as the server spells it. Kept as a `String` because the tier
  /// vocabulary is owned by billing and changes without an SDK release.
  public let tier: String
  /// When the subscription allowance resets. Absent for tiers that do not reset.
  public let nextResetAt: Date?

  public init(subscriptionCredits: Int, tier: String, nextResetAt: Date? = nil) {
    self.subscriptionCredits = subscriptionCredits
    self.tier = tier
    self.nextResetAt = nextResetAt
  }

  private enum CodingKeys: String, CodingKey {
    case subscriptionCredits
    case tier
    case nextResetAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.subscriptionCredits = container.traciveInt(.subscriptionCredits, default: 0)
    self.tier = container.traciveStringIfPresent(.tier) ?? ""
    self.nextResetAt = container.traciveDateIfPresent(.nextResetAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(subscriptionCredits, forKey: .subscriptionCredits)
    try container.encode(tier, forKey: .tier)
    try container.traciveEncodeISO8601IfPresent(nextResetAt, forKey: .nextResetAt)
  }
}
