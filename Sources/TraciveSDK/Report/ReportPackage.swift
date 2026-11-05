import Foundation

/// Validates a report and encodes it as the v1 package the Tracive app reads.
///
/// `{"v":1,"query":…,"incidentDate":"YYYY-MM-DD"?,"attachments":[{"name","mimeType","data"}]}`,
/// UTF-8 JSON with `data` in standard padded base64. The contract and its conformance vectors are
/// `report-package-vectors.json`, shared byte for byte with the other three SDKs.
enum ReportPackage {

  static let version = 1
  static let maxAttachments = 5
  static let maxAttachmentsForPhone = 10
  static let pdfMaxBytesExclusive = 1_048_576
  static let packageMaxBytes = 20_971_520

  static func build(
    searchQueryIndex: String,
    incidentDate: ReportIncidentDate?,
    attachments: [ReportAttachment],
    today: ReportIncidentDate
  ) -> Result<Data, ReportFormError> {
    if let incidentDate, incidentDate > today {
      return .failure(.incidentDateInFuture)
    }

    let max = searchQueryIndex.hasPrefix("PHONE_") ? maxAttachmentsForPhone : maxAttachments
    guard attachments.count <= max else {
      return .failure(.tooManyAttachments(max: max))
    }

    var accepted: [(type: AttachmentType, bytes: Data)] = []
    for (index, attachment) in attachments.enumerated() {
      guard let type = AttachmentType(mimeType: attachment.mimeType) else {
        return .failure(.unsupportedType(index: index))
      }
      guard type.matches(attachment.bytes) else {
        return .failure(.contentMismatch(index: index))
      }
      if type == .pdf, attachment.bytes.count >= pdfMaxBytesExclusive {
        return .failure(.pdfTooLarge(index: index))
      }
      accepted.append((type, attachment.bytes))
    }

    // The base64 alone is a lower bound on the package, so an oversized set is refused here without
    // allocating an encoding several times the size of the limit.
    let base64Bytes = accepted.reduce(0) { $0 + ($1.bytes.count + 2) / 3 * 4 }
    guard base64Bytes <= packageMaxBytes else {
      return .failure(.packageTooLarge(max: packageMaxBytes))
    }

    let wire = Wire(
      v: version,
      query: searchQueryIndex,
      incidentDate: incidentDate?.iso8601,
      attachments: accepted.enumerated().map { offset, attachment in
        Wire.Attachment(
          name: "attachment-\(offset + 1).\(attachment.type.fileExtension)",
          mimeType: attachment.type.mimeType,
          data: attachment.bytes.base64EncodedString()
        )
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(wire) else {
      return .failure(.platform(reason: "package_encoding_failed"))
    }
    guard encoded.count <= packageMaxBytes else {
      return .failure(.packageTooLarge(max: packageMaxBytes))
    }
    return .success(encoded)
  }

  private struct Wire: Encodable {
    struct Attachment: Encodable {
      let name: String
      let mimeType: String
      let data: String
    }
    let v: Int
    let query: String
    /// Synthesised `Encodable` uses `encodeIfPresent`, so `nil` leaves the key out, as the
    /// contract requires.
    let incidentDate: String?
    let attachments: [Attachment]
  }
}

enum AttachmentType: CaseIterable {
  case jpeg, png, webp, heic, heif, bmp, pdf

  init?(mimeType: String) {
    switch mimeType.lowercased() {
    case "image/jpeg", "image/jpg": self = .jpeg
    case "image/png": self = .png
    case "image/webp": self = .webp
    case "image/heic": self = .heic
    case "image/heif": self = .heif
    case "image/bmp": self = .bmp
    case "application/pdf": self = .pdf
    default: return nil
    }
  }

  var mimeType: String {
    switch self {
    case .jpeg: return "image/jpeg"
    case .png: return "image/png"
    case .webp: return "image/webp"
    case .heic: return "image/heic"
    case .heif: return "image/heif"
    case .bmp: return "image/bmp"
    case .pdf: return "application/pdf"
    }
  }

  var fileExtension: String {
    switch self {
    case .jpeg: return "jpg"
    case .png: return "png"
    case .webp: return "webp"
    case .heic: return "heic"
    case .heif: return "heif"
    case .bmp: return "bmp"
    case .pdf: return "pdf"
    }
  }

  func matches(_ data: Data) -> Bool {
    let bytes = [UInt8](data.prefix(12))
    func has(_ signature: [UInt8], at offset: Int) -> Bool {
      bytes.count >= offset + signature.count
        && Array(bytes[offset..<offset + signature.count]) == signature
    }
    switch self {
    case .jpeg: return has([0xFF, 0xD8, 0xFF], at: 0)
    case .png: return has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0)
    case .webp: return has(Array("RIFF".utf8), at: 0) && has(Array("WEBP".utf8), at: 8)
    case .bmp: return has(Array("BM".utf8), at: 0)
    case .heic, .heif:
      return has(Array("ftyp".utf8), at: 4)
        && Self.heifBrands.contains { has(Array($0.utf8), at: 8) }
    case .pdf: return has(Array("%PDF-".utf8), at: 0)
    }
  }

  private static let heifBrands = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
}
