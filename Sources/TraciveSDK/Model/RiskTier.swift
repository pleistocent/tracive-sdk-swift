import Foundation

/// How dangerous the checked identifier looks (§4).
///
/// The wire form is UPPER_SNAKE; Swift cases are lowerCamelCase and decode from those exact
/// strings.
///
/// Decoding is deliberately **strict**: an unrecognised tier throws rather than degrading to a
/// safer-looking value. "Ignore unknown fields" (§4) is about unknown *keys*; quietly mapping a
/// future `SEVERE` onto `.none` would understate risk in a fraud-warning UI, and that failure is
/// both expensive and silent. A decode error is loud and fixable by shipping an SDK update.
public enum RiskTier: String, Codable, CaseIterable, Hashable, Sendable {
  case high = "HIGH"
  case elevated = "ELEVATED"
  case caution = "CAUTION"
  case none = "NONE"
}
