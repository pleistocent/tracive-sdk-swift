import Foundation
import TraciveReportCore

/// A failed report call. The message never carries user data.
public struct TraciveReportError: Error, Sendable, CustomStringConvertible, LocalizedError {

  /// Why a call failed.
  public enum Code: String, CaseIterable, Sendable {
    /// No grant, or a grant without the scope. Run your authorize flow, then call again.
    case needsConsent = "NEEDS_CONSENT"
    /// The user must verify their email in Tracive.
    case emailNotVerified = "EMAIL_NOT_VERIFIED"
    /// Unknown, not sent through this app for this user, or older than 30 days.
    case reportNotFound = "REPORT_NOT_FOUND"
    /// The terms changed. Read the requirements again, show the new links, build a new draft.
    case termsOutdated = "TERMS_OUTDATED"
    /// A field failed. The message names it.
    case invalidReport = "INVALID_REPORT"
    /// A file is missing, or its bytes do not match its type.
    case attachmentInvalid = "ATTACHMENT_INVALID"
    /// Account or device cap. See `retryAfterSeconds`.
    case dailyLimitReached = "DAILY_LIMIT_REACHED"
    /// Reporting is switched off for now.
    case reportingDisabled = "REPORTING_DISABLED"
    /// No answer. Call `submit` again with the same draft: nothing is sent twice.
    case network = "NETWORK"
    /// The server failed, or answered something this version does not know.
    case server = "SERVER"
    /// Neither an image nor a PDF.
    case unsupportedFile = "UNSUPPORTED_FILE"
    /// A PDF of 1 MiB or more.
    case fileTooLarge = "FILE_TOO_LARGE"
    /// The image could not be decoded, or could not be brought under the size limit.
    case imageUnreadable = "IMAGE_UNREADABLE"
  }

  public let code: Code
  public let message: String
  /// The HTTP status, when the error came from a response.
  public let httpStatus: Int?
  /// Seconds to wait, for `.dailyLimitReached`.
  public let retryAfterSeconds: Int?

  public init(
    code: Code,
    message: String,
    httpStatus: Int? = nil,
    retryAfterSeconds: Int? = nil
  ) {
    self.code = code
    self.message = message
    self.httpStatus = httpStatus
    self.retryAfterSeconds = retryAfterSeconds
  }

  init(_ core: TraciveReportException) {
    self.init(
      code: Code(rawValue: core.code.name) ?? .server,
      message: core.message ?? core.code.name,
      httpStatus: core.httpStatus.map(\.intValue),
      retryAfterSeconds: core.retryAfterSeconds.map(\.intValue)
    )
  }

  var core: TraciveReportException {
    let name = code.rawValue
    return TraciveReportException(
      code: ReportErrorCode.entries.first { $0.name == name } ?? ReportErrorCode.server,
      message: message,
      httpStatus: httpStatus.map { KotlinInt(int: Int32($0)) },
      retryAfterSeconds: retryAfterSeconds.map { KotlinLong(longLong: Int64($0)) },
      cause: nil
    )
  }

  public var description: String { "TraciveReportError(\(code.rawValue)): \(message)" }

  public var errorDescription: String? { message }
}
