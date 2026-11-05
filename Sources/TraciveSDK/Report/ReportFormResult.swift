import Foundation

/// What `openReportForm` did.
public enum ReportFormResult: Equatable, Hashable, Sendable, CustomStringConvertible {

  /// The Tracive app opened its report form.
  ///
  /// `attachmentsDelivered` is `true` when the user picked the Tracive app in the "Open in" sheet
  /// and the whole package went to it: identifier, date and files. It is `false` when the installed
  /// Tracive app is too old to accept a package (or the host app's `LSApplicationQueriesSchemes`
  /// lacks the report scheme), so the SDK opened the form by link instead, carrying the identifier
  /// only. Ask the user to attach the receipt themselves in that case.
  case opened(attachmentsDelivered: Bool)

  /// The user closed the sheet, picked another app or "Save to Files", or declined iOS's prompt to
  /// open Tracive. Nothing was delivered.
  case cancelled

  /// Tracive is not installed. The SDK opened the install page, which carries nothing from the
  /// report: no identifier, no date, no file. There is no deferred resume; the user installs
  /// Tracive and taps Report again.
  case installPageOpened

  /// Nothing was opened. See `ReportFormError`.
  case failed(ReportFormError)

  public var description: String {
    switch self {
    case .opened(let delivered): return "opened(attachmentsDelivered: \(delivered))"
    case .cancelled: return "cancelled"
    case .installPageOpened: return "installPageOpened"
    case .failed(let error): return "failed(\(error))"
    }
  }
}

/// Why `openReportForm` opened nothing.
///
/// Every case but `.platform` is a validation failure, found before anything is written or opened,
/// and checked in this order: the date, the attachment count, then each attachment in turn (type,
/// then content, then PDF size), then the size of the whole package. The Tracive app re-checks all
/// of it on receipt.
public enum ReportFormError: Error, Equatable, Hashable, Sendable, CustomStringConvertible,
  LocalizedError
{

  /// `incidentDate` is after the device's local today.
  case incidentDateInFuture

  /// More attachments than the report form takes: 5, or 10 when the query is a phone number.
  case tooManyAttachments(max: Int)

  /// The attachment at `index` has a MIME type the Tracive app does not accept, such as GIF.
  case unsupportedType(index: Int)

  /// The bytes of the attachment at `index` are not the type it was labelled with, or are empty.
  case contentMismatch(index: Int)

  /// The PDF at `index` is 1 MiB (1,048,576 bytes) or more.
  case pdfTooLarge(index: Int)

  /// The encoded package is over `max` bytes (20 MiB). Attachments travel base64-encoded, so this
  /// is roughly 15 MB of files in total.
  case packageTooLarge(max: Int)

  /// The platform refused a step: the package could not be written, there was no view to present
  /// the sheet from, or iOS declined to open a link. `reason` is a stable `snake_case` code.
  case platform(reason: String)

  /// The contract's spelling, shared by all four Tracive SDKs: `INCIDENT_DATE_IN_FUTURE`,
  /// `TOO_MANY_ATTACHMENTS`, `UNSUPPORTED_TYPE`, `CONTENT_MISMATCH`, `PDF_TOO_LARGE`,
  /// `PACKAGE_TOO_LARGE`, or `PLATFORM_FAILURE` for `.platform`.
  public var code: String {
    switch self {
    case .incidentDateInFuture: return "INCIDENT_DATE_IN_FUTURE"
    case .tooManyAttachments: return "TOO_MANY_ATTACHMENTS"
    case .unsupportedType: return "UNSUPPORTED_TYPE"
    case .contentMismatch: return "CONTENT_MISMATCH"
    case .pdfTooLarge: return "PDF_TOO_LARGE"
    case .packageTooLarge: return "PACKAGE_TOO_LARGE"
    case .platform: return "PLATFORM_FAILURE"
    }
  }

  public var description: String {
    switch self {
    case .incidentDateInFuture: return code
    case .tooManyAttachments(let max), .packageTooLarge(let max): return "\(code)(max: \(max))"
    case .unsupportedType(let index), .contentMismatch(let index), .pdfTooLarge(let index):
      return "\(code)(index: \(index))"
    case .platform(let reason): return "\(code)(\(reason))"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .incidentDateInFuture:
      return "The transaction date is in the future."
    case .tooManyAttachments(let max):
      return "A report takes at most \(max) attachments."
    case .unsupportedType(let index):
      return "Attachment \(index + 1) is not a JPEG, PNG, WebP, HEIC, HEIF, BMP or PDF."
    case .contentMismatch(let index):
      return "Attachment \(index + 1) is not the file type it is labelled as."
    case .pdfTooLarge(let index):
      return "Attachment \(index + 1) is a PDF of 1 MB or more."
    case .packageTooLarge:
      return "The attachments are too large to send together."
    case .platform(let reason):
      return "The report form could not be opened (\(reason))."
    }
  }
}
