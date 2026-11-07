import Foundation
import TraciveSDKExtended

enum ReportText {

  /// The user's language, not the host app's: iOS picks a framework's strings from the languages
  /// the app itself localizes, so an app without `id.lproj` would get an English form on an
  /// Indonesian device. Android follows the device, and the two must read the same.
  private static let bundle: Bundle =
    Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    ?? .module

  static let language: String = {
    let preferred = Locale.preferredLanguages.first ?? "en"
    return preferred.hasPrefix("id") || preferred.hasPrefix("in") ? "id" : "en"
  }()

  static func text(_ key: String) -> String {
    bundle.localizedString(forKey: key, value: nil, table: nil)
  }

  static func text(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), arguments: arguments)
  }

  static func error(_ code: TraciveReportError.Code) -> String {
    switch code {
    case .needsConsent: return text("error_needs_consent")
    case .emailNotVerified: return text("error_email_not_verified")
    case .reportNotFound: return text("error_report_not_found")
    case .termsOutdated: return text("error_terms_outdated")
    case .invalidReport: return text("error_invalid_report")
    case .attachmentInvalid: return text("error_attachment_invalid")
    case .dailyLimitReached: return text("error_daily_limit")
    case .reportingDisabled: return text("error_reporting_disabled")
    case .network: return text("error_network")
    case .server: return text("error_server")
    case .unsupportedFile: return text("error_unsupported_file")
    case .fileTooLarge: return text("error_file_too_large")
    case .imageUnreadable: return text("error_image_unreadable")
    }
  }

  static func failure(_ failure: ReportFormModel.Failure) -> String {
    guard failure.code == .dailyLimitReached, let seconds = failure.retryAfterSeconds else {
      return error(failure.code)
    }
    let hours = (seconds + 3599) / 3600
    return text(hours == 1 ? "error_daily_limit_hour" : "error_daily_limit_hours", hours)
  }

  static func problem(
    _ problem: ReportFieldProblem,
    limits: ReportLimits,
    maxEvidence: Int
  ) -> String {
    switch problem {
    case .noIdentifier: return text("problem_no_identifier")
    case .tooManyIdentifiers: return text("problem_too_many_identifiers", limits.maxIdentifiers)
    case .titleMissing: return text("problem_title_missing")
    case .titleTooLong: return text("problem_too_long", limits.titleMaxLength)
    case .chronologyTooShort: return text("problem_too_short", limits.chronologyMinLength)
    case .chronologyTooLong: return text("problem_too_long", limits.chronologyMaxLength)
    case .commentTooLong: return text("problem_too_long", limits.commentMaxLength)
    case .noEvidence: return text("problem_no_evidence")
    case .tooManyEvidence: return text("problem_too_many_evidence", maxEvidence)
    case .incidentDateInvalid: return text("problem_date_missing")
    case .incidentDateInFuture: return text("problem_date_future")
    }
  }

  static func statusTitle(_ status: ReportStatus) -> String {
    switch status {
    case .submitted: return text("status_submitted")
    case .inReview: return text("status_in_review")
    case .reviewed: return text("status_reviewed")
    case .needRevision: return text("status_need_revision")
    }
  }

  static func statusLine(_ status: ReportStatus) -> String {
    switch status {
    case .submitted: return text("status_submitted_line")
    case .inReview: return text("status_in_review_line")
    case .reviewed: return text("status_reviewed_line")
    case .needRevision: return text("status_need_revision_line")
    }
  }

  static func termName(_ id: String) -> String {
    switch id {
    case "TERMS_OF_SERVICE": return text("term_terms_of_service")
    case "PRIVACY_POLICY": return text("term_privacy_policy")
    default:
      return id.split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }
  }
}
