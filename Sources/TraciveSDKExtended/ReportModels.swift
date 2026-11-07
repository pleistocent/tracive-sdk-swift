import Foundation
import TraciveReportCore
import TraciveSDK

/// The OAuth scopes this SDK needs. Add them to the scopes your client requests.
public enum TraciveReportScopes {
  /// Send reports.
  public static let create = TraciveReportCore.TraciveReportScopes.shared.CREATE
  /// Read the status of reports sent through your app.
  public static let read = TraciveReportCore.TraciveReportScopes.shared.READ
}

/// What a report must satisfy right now. Read it before showing a form.
public struct ReportRequirements: Equatable, Sendable {
  /// False while reporting is switched off.
  public let enabled: Bool
  /// How many more reports this user can send today.
  public let remainingToday: Int
  public let limits: ReportLimits
  /// The documents the user accepts by submitting. Show a link to each one.
  public let terms: [RequiredTerm]

  init(_ core: TraciveReportCore.ReportRequirements) {
    enabled = core.enabled
    remainingToday = Int(core.remainingToday)
    limits = ReportLimits(core.limits)
    terms = core.terms.map(RequiredTerm.init)
  }
}

/// Field limits, from the server.
public struct ReportLimits: Equatable, Sendable {
  public let titleMaxLength: Int
  public let chronologyMinLength: Int
  public let chronologyMaxLength: Int
  public let commentMaxLength: Int
  public let maxIdentifiers: Int
  public let attachmentsPerIdentifier: Int
  public let extraAttachmentsWithPhone: Int
  public let maxAttachmentBytes: Int
  public let attachmentTypes: [String]

  init(_ core: TraciveReportCore.ReportLimits) {
    titleMaxLength = Int(core.titleMaxLength)
    chronologyMinLength = Int(core.chronologyMinLength)
    chronologyMaxLength = Int(core.chronologyMaxLength)
    commentMaxLength = Int(core.commentMaxLength)
    maxIdentifiers = Int(core.maxIdentifiers)
    attachmentsPerIdentifier = Int(core.attachmentsPerIdentifier)
    extraAttachmentsWithPhone = Int(core.extraAttachmentsWithPhone)
    maxAttachmentBytes = Int(core.maxAttachmentBytes)
    attachmentTypes = core.attachmentTypes
  }

  var core: TraciveReportCore.ReportLimits {
    TraciveReportCore.ReportLimits(
      titleMaxLength: Int32(titleMaxLength),
      chronologyMinLength: Int32(chronologyMinLength),
      chronologyMaxLength: Int32(chronologyMaxLength),
      commentMaxLength: Int32(commentMaxLength),
      maxIdentifiers: Int32(maxIdentifiers),
      attachmentsPerIdentifier: Int32(attachmentsPerIdentifier),
      extraAttachmentsWithPhone: Int32(extraAttachmentsWithPhone),
      maxAttachmentBytes: Int32(maxAttachmentBytes),
      attachmentTypes: attachmentTypes
    )
  }
}

/// One document the user accepts by submitting.
public struct RequiredTerm: Equatable, Hashable, Sendable {
  public let id: String
  public let version: String
  public let url: String

  public init(id: String, version: String, url: String) {
    self.id = id
    self.version = version
    self.url = url
  }

  init(_ core: TraciveReportCore.RequiredTerm) {
    self.init(id: core.id, version: core.version, url: core.url)
  }

  var core: TraciveReportCore.RequiredTerm {
    TraciveReportCore.RequiredTerm(id: id, version: version, url: url)
  }
}

/// A report's stage. It never says what a review concluded.
public enum ReportStatus: String, CaseIterable, Sendable {
  case submitted = "SUBMITTED"
  case inReview = "IN_REVIEW"
  case reviewed = "REVIEWED"
  case needRevision = "NEED_REVISION"

  init(_ core: TraciveReportCore.ReportStatus) {
    self = ReportStatus(rawValue: core.name) ?? .inReview
  }
}

/// The outcome of `TraciveReports.submit`.
public enum SubmitResult: Sendable {
  /// Accepted. Keep `reportId` with your transaction; there is no way to list reports.
  case submitted(reportId: String, status: ReportStatus)
  /// No grant, or a grant without `TraciveReportScopes.create`. Authorize and call again.
  case needsConsent
  case failed(TraciveReportError)

  init(_ core: TraciveReportCore.SubmitResult) {
    if let submitted = core as? TraciveReportCore.SubmitResult.Submitted {
      self = .submitted(reportId: submitted.reportId, status: ReportStatus(submitted.status))
    } else if let failed = core as? TraciveReportCore.SubmitResult.Failed {
      self = .failed(TraciveReportError(failed.error))
    } else {
      self = .needsConsent
    }
  }
}

/// Evidence ready to send, from `TraciveReports.prepare`.
public struct PreparedEvidence: @unchecked Sendable, Equatable {
  public let mimeType: String
  public let byteCount: Int

  let core: TraciveReportCore.PreparedEvidence

  init(_ core: TraciveReportCore.PreparedEvidence) {
    self.core = core
    mimeType = core.mimeType
    byteCount = Int(core.bytes.size)
  }

  /// The bytes that will be uploaded.
  public var data: Data { core.data }

  public static func == (lhs: PreparedEvidence, rhs: PreparedEvidence) -> Bool {
    lhs.core === rhs.core
  }
}

/// Field problems a form can show before sending anything.
public enum ReportFieldProblem: String, CaseIterable, Sendable {
  case noIdentifier = "NO_IDENTIFIER"
  case tooManyIdentifiers = "TOO_MANY_IDENTIFIERS"
  case titleMissing = "TITLE_MISSING"
  case titleTooLong = "TITLE_TOO_LONG"
  case chronologyTooShort = "CHRONOLOGY_TOO_SHORT"
  case chronologyTooLong = "CHRONOLOGY_TOO_LONG"
  case commentTooLong = "COMMENT_TOO_LONG"
  case noEvidence = "NO_EVIDENCE"
  case tooManyEvidence = "TOO_MANY_EVIDENCE"
  case incidentDateInvalid = "INCIDENT_DATE_INVALID"
  case incidentDateInFuture = "INCIDENT_DATE_IN_FUTURE"
}

/// One report. Keep the same draft across retries: its `idempotencyKey` is what stops a retry from
/// becoming a second report. Changing anything means building a new draft, with a new key.
///
/// The chronology must be the user's own words. You may prefill everything else.
public struct ReportDraft: Sendable {
  /// `TraciveQuery.searchQueryIndex` values.
  public let identifiers: [String]
  public let title: String
  public let chronology: String
  public let comment: String?
  public let incidentDate: ReportIncidentDate
  public let evidence: [PreparedEvidence]
  /// From `ReportRequirements.terms`, only what was shown to the user.
  public let acceptedTerms: [RequiredTerm]
  /// `id` or `en`. Nil uses the device language.
  public let language: String?
  public let idempotencyKey: String

  public init(
    identifiers: [String],
    title: String,
    chronology: String,
    comment: String? = nil,
    incidentDate: ReportIncidentDate,
    evidence: [PreparedEvidence],
    acceptedTerms: [RequiredTerm],
    language: String? = nil
  ) {
    self.identifiers = identifiers
    self.title = title
    self.chronology = chronology
    self.comment = comment
    self.incidentDate = incidentDate
    self.evidence = evidence
    self.acceptedTerms = acceptedTerms
    self.language = language
    idempotencyKey = Self.newIdempotencyKey()
  }

  public init(
    query: TraciveQuery,
    title: String,
    chronology: String,
    comment: String? = nil,
    incidentDate: ReportIncidentDate,
    evidence: [PreparedEvidence],
    acceptedTerms: [RequiredTerm],
    language: String? = nil
  ) {
    self.init(
      identifiers: [query.searchQueryIndex],
      title: title,
      chronology: chronology,
      comment: comment,
      incidentDate: incidentDate,
      evidence: evidence,
      acceptedTerms: acceptedTerms,
      language: language
    )
  }

  /// Everything wrong with this draft, in form order. Empty means it can be sent.
  public func problems(
    limits: ReportLimits,
    today: ReportIncidentDate = ReportIncidentDate(Date())
  ) -> [ReportFieldProblem] {
    let day = Kotlinx_datetimeLocalDate(
      year: Int32(today.year), monthNumber: Int32(today.month), dayOfMonth: Int32(today.day))
    return core.problems(limits: limits.core, today: day).compactMap {
      ReportFieldProblem(rawValue: $0.name)
    }
  }

  /// How many files this draft may carry.
  public func maxEvidence(limits: ReportLimits) -> Int {
    Int(core.maxEvidence(limits: limits.core))
  }

  var core: TraciveReportCore.ReportDraft {
    TraciveReportCore.ReportDraft(
      identifiers: identifiers,
      title: title,
      chronology: chronology,
      comment: comment,
      incidentDate: incidentDate.iso8601,
      evidence: evidence.map(\.core),
      acceptedTerms: acceptedTerms.map(\.core),
      language: language,
      idempotencyKey: idempotencyKey
    )
  }

  private static func newIdempotencyKey() -> String {
    (0..<16).map { _ in
      let byte = UInt8.random(in: .min ... .max)
      return (byte < 16 ? "0" : "") + String(byte, radix: 16)
    }
    .joined()
  }
}
