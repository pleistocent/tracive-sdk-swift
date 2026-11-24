import Foundation

/// What Tracive read from the first verified QR in the reports on a QRIS. QRIS hits only.
///
/// The merchant name is chosen by whoever made the QR: show it, but never identify anyone by it.
/// The PAN is never returned.
public struct QrisDetails: Codable, Equatable, Hashable, Sendable {
  public let merchantName: String?
  public let city: String?
  public let criteria: QrisCriteria?
  /// The acquirer's GUID, e.g. `ID.DANA.WWW`.
  public let acquirer: String?

  public init(
    merchantName: String? = nil,
    city: String? = nil,
    criteria: QrisCriteria? = nil,
    acquirer: String? = nil
  ) {
    self.merchantName = merchantName
    self.city = city
    self.criteria = criteria
    self.acquirer = acquirer
  }

  private enum CodingKeys: String, CodingKey {
    case merchantName, city, criteria, acquirer
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.merchantName = container.traciveStringIfPresent(.merchantName)
    self.city = container.traciveStringIfPresent(.city)
    self.criteria = container.traciveStringIfPresent(.criteria).map(QrisCriteria.init(rawValue:))
    self.acquirer = container.traciveStringIfPresent(.acquirer)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(merchantName, forKey: .merchantName)
    try container.encodeIfPresent(city, forKey: .city)
    try container.encodeIfPresent(criteria?.rawValue, forKey: .criteria)
    try container.encodeIfPresent(acquirer, forKey: .acquirer)
  }
}

/// The business size a QRIS is registered under. Only UMI and UKE are ever in Tracive's reports.
///
/// Open like `TraciveQuery.Kind`: a value this SDK does not know decodes as itself instead of
/// failing the check it rides on, and a `switch` over it keeps a `default:`.
public struct QrisCriteria: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Micro business (usaha mikro).
  public static let umi = QrisCriteria(rawValue: "UMI")
  /// Small business (usaha kecil).
  public static let uke = QrisCriteria(rawValue: "UKE")
  /// Medium business (usaha menengah).
  public static let ume = QrisCriteria(rawValue: "UME")
  /// Large business (usaha besar).
  public static let ube = QrisCriteria(rawValue: "UBE")

  public var description: String { rawValue }
}

/// The QRIS owner's reply to the reports, reviewed by Tracive.
///
/// Show `text` as written, untranslated, below the warning and never above it.
public struct RightOfReply: Codable, Equatable, Hashable, Sendable {
  public let text: String
  /// BCP-47 code of `text`, e.g. `id`.
  public let language: String

  public init(text: String, language: String) {
    self.text = text
    self.language = language
  }
}
