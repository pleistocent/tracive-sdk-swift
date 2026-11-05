import Foundation

/// One file to hand to the Tracive report form: a receipt screenshot or a PDF.
///
/// Build one with `.image(_:mimeType:)` or `.pdf(_:)`. Nothing is checked here; `openReportForm`
/// validates every attachment before it opens anything, and answers `.failed` with the index of the
/// first one it refuses. The accepted types are the ones the Tracive app itself accepts: JPEG, PNG,
/// WebP, HEIC, HEIF, BMP and PDF. GIF is refused. A PDF must be under 1 MiB; images have no size
/// cap of their own, because the app compresses them.
public struct ReportAttachment: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{

  public let bytes: Data
  /// As given. `image/jpg` and any letter case are accepted, and normalised in the package.
  public let mimeType: String

  init(bytes: Data, mimeType: String) {
    self.bytes = bytes
    self.mimeType = mimeType
  }

  /// An image. `mimeType` is one of `image/jpeg` (or `image/jpg`), `image/png`, `image/webp`,
  /// `image/heic`, `image/heif` or `image/bmp`, and must match the bytes: a PNG labelled
  /// `image/jpeg` is refused with `.contentMismatch`.
  public static func image(_ bytes: Data, mimeType: String) -> ReportAttachment {
    ReportAttachment(bytes: bytes, mimeType: mimeType)
  }

  /// A PDF, strictly under 1 MiB (1,048,576 bytes).
  public static func pdf(_ bytes: Data) -> ReportAttachment {
    ReportAttachment(bytes: bytes, mimeType: "application/pdf")
  }

  /// The type and the size only. A receipt shows the account number and the name of whoever was
  /// paid, so its bytes stay out of logs and crash reports.
  public var description: String {
    "ReportAttachment(mimeType: \(mimeType), \(bytes.count) bytes <redacted>)"
  }

  public var debugDescription: String { description }
}
