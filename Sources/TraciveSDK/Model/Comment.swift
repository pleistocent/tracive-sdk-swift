import Foundation

/// A free-text comment left on a scammer record (`detail = .full` only, §4).
///
/// `date` is a **String** for the same reason as `Chronology.incidentDate`: the server sends a
/// display date, not a normalised instant.
///
/// `fromCredibleReport` distinguishes a comment attached to a report that passed Tracive's
/// credibility checks from one that did not — surface the difference in any UI.
public struct Comment: Codable, Equatable, Hashable, Sendable {
  public let date: String
  public let text: String
  public let fromCredibleReport: Bool

  public init(date: String, text: String, fromCredibleReport: Bool) {
    self.date = date
    self.text = text
    self.fromCredibleReport = fromCredibleReport
  }

  private enum CodingKeys: String, CodingKey {
    case date
    case text
    case fromCredibleReport
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.date = container.traciveStringIfPresent(.date) ?? ""
    self.text = try container.decode(String.self, forKey: .text)
    self.fromCredibleReport = container.traciveBool(.fromCredibleReport, default: false)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(date, forKey: .date)
    try container.encode(text, forKey: .text)
    try container.encode(fromCredibleReport, forKey: .fromCredibleReport)
  }
}
