import Foundation

/// Who paid for a check and how much it cost (§4).
///
/// Billing is **never cached** — a cache hit costs nothing, so replaying a stored `Billing` would
/// claim a charge that did not happen. See `CheckResult.cacheableCopy()`.
public struct Billing: Codable, Equatable, Hashable, Sendable {
  public let creditSource: CreditSource
  public let unitsCharged: Int
  /// Only present when the charge came off a partner balance rather than the end user's credits.
  public let partnerBalanceRemaining: Int?

  public init(creditSource: CreditSource, unitsCharged: Int, partnerBalanceRemaining: Int? = nil) {
    self.creditSource = creditSource
    self.unitsCharged = unitsCharged
    self.partnerBalanceRemaining = partnerBalanceRemaining
  }

  private enum CodingKeys: String, CodingKey {
    case creditSource
    case unitsCharged
    case partnerBalanceRemaining
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.creditSource =
      container.traciveDecodeIfPresent(CreditSource.self, forKey: .creditSource) ?? .user
    self.unitsCharged = container.traciveInt(.unitsCharged, default: 0)
    self.partnerBalanceRemaining = container.traciveIntIfPresent(.partnerBalanceRemaining)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(creditSource, forKey: .creditSource)
    try container.encode(unitsCharged, forKey: .unitsCharged)
    try container.encodeIfPresent(partnerBalanceRemaining, forKey: .partnerBalanceRemaining)
  }
}

/// Which pot a check was charged against.
///
/// phase 1 always sends `creditSource: "USER"` (§4). `PARTNER` exists because §7 defines an
/// `insufficient_partner_balance` error and §4 defines `partnerBalanceRemaining`.
///
/// Unlike `RiskTier` this type keeps an `.other` escape hatch: an unknown credit source is
/// bookkeeping metadata, so failing an entire fraud check over it would be a worse outcome than
/// carrying the raw string through.
public enum CreditSource: RawRepresentable, Codable, Hashable, Sendable {
  case user
  case partner
  case other(String)

  public init(rawValue: String) {
    switch rawValue {
    case "USER": self = .user
    case "PARTNER": self = .partner
    default: self = .other(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .user: return "USER"
    case .partner: return "PARTNER"
    case .other(let raw): return raw
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
