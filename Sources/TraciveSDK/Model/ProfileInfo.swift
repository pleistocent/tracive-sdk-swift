import Foundation

/// Result of `GET /profile` (§4).
///
/// Every field except `sub` is optional: the granted OAuth scopes decide how much of the profile
/// the server is willing to return, so a narrow grant legitimately yields a profile with only a
/// subject id.
///
/// `description` redacts `sub` and `name` — this type must never be logged verbatim.
public struct ProfileInfo: Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// OAuth subject identifier for the authenticated Tracive user.
  public let sub: String
  public let name: String?
  /// ISO 3166-1 country as the server spells it.
  public let country: String?
  public let tier: String?
  public let memberSince: Date?

  public init(
    sub: String,
    name: String? = nil,
    country: String? = nil,
    tier: String? = nil,
    memberSince: Date? = nil
  ) {
    self.sub = sub
    self.name = name
    self.country = country
    self.tier = tier
    self.memberSince = memberSince
  }

  public var description: String {
    "ProfileInfo(sub: <redacted>, name: <redacted>, country: \(country ?? "nil"), "
      + "tier: \(tier ?? "nil"), memberSince: \(memberSince.map(TraciveISO8601.string(from:)) ?? "nil"))"
  }

  public var debugDescription: String { description }

  private enum CodingKeys: String, CodingKey {
    case sub
    case name
    case country
    case tier
    case memberSince
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.sub = try container.decode(String.self, forKey: .sub)
    self.name = container.traciveStringIfPresent(.name)
    self.country = container.traciveStringIfPresent(.country)
    self.tier = container.traciveStringIfPresent(.tier)
    self.memberSince = container.traciveDateIfPresent(.memberSince)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sub, forKey: .sub)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(country, forKey: .country)
    try container.encodeIfPresent(tier, forKey: .tier)
    try container.traciveEncodeISO8601IfPresent(memberSince, forKey: .memberSince)
  }
}
