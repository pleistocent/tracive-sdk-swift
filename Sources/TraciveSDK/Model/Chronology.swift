import Foundation

/// One narrated incident attached to a scammer record (`detail = .full` only).
///
/// `incidentDate` is a **String**, not an instant: the server sends the month as `"YYYY-MM"` (e.g.
/// `"2026-06"`) and never a day, so parsing it into a `Date` would invent precision that is not
/// there. Present it verbatim.
public struct Chronology: Codable, Equatable, Hashable, Sendable {
  public let chronology: String
  public let riskLevel: Int
  public let incidentDate: String?

  public init(chronology: String, riskLevel: Int, incidentDate: String? = nil) {
    self.chronology = chronology
    self.riskLevel = riskLevel
    self.incidentDate = incidentDate
  }

  private enum CodingKeys: String, CodingKey {
    case chronology
    case riskLevel
    case incidentDate
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.chronology = try container.decode(String.self, forKey: .chronology)
    self.riskLevel = container.traciveInt(.riskLevel, default: 0)
    self.incidentDate = container.traciveStringIfPresent(.incidentDate)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(chronology, forKey: .chronology)
    try container.encode(riskLevel, forKey: .riskLevel)
    try container.encodeIfPresent(incidentDate, forKey: .incidentDate)
  }
}
