import Foundation
import TraciveReportCore
import TraciveSDK
import UIKit

/// Lets a user report a scammer without leaving your app.
///
/// ```swift
/// let reports = TraciveReports(client: traciveClient)
/// let requirements = try await reports.requirements()
/// let evidence = try await reports.prepare(data, mimeType: "image/png")
/// let draft = ReportDraft(
///   query: query, title: title, chronology: chronology, incidentDate: date,
///   evidence: [evidence], acceptedTerms: requirements.terms)
/// let result = try await reports.submit(draft) { fraction in … }
/// ```
///
/// The user needs a Tracive account and a grant with `TraciveReportScopes.create`. Without one,
/// calls answer `.needsConsent`: run your authorize flow with the scope added, and call again.
///
/// Evidence goes straight from the device to Tracive when `submit` runs. It never passes through
/// your servers.
public final class TraciveReports: @unchecked Sendable {

  private let core: TraciveReportCore.TraciveReports

  /// Uses the grant `client` already holds, and its single-flight refresh.
  ///
  /// - Parameter target: the Tracive build `openInTracive` opens. Nil follows the environment.
  public convenience init(client: TraciveClient, target: ReportFormTarget? = nil) {
    let oauth = client.oauth
    self.init(environment: client.environment, target: target) { stale in
      guard let oauth else { throw TraciveError.proxyModeNotImplemented }
      if let stale { return try await oauth.refreshTokens(staleAccessToken: stale) }
      return try await oauth.accessToken()
    }
  }

  /// For a partner that keeps tokens on its own backend.
  ///
  /// Keep refresh in one place. A refresh token rotates and a reused one revokes the grant, so
  /// refresh only when `stale` asks for it.
  ///
  /// - Parameters:
  ///   - target: the Tracive build `openInTracive` opens. Nil follows the environment.
  ///   - accessToken: receives the token the server just refused, or nil on a first call. A
  ///     `TraciveError` that means the grant is gone, or a `TraciveReportError` with
  ///     `.needsConsent`, ends in `.needsConsent`. Any other error reaches the caller as it is.
  public init(
    environment: TraciveEnvironment,
    target: ReportFormTarget? = nil,
    accessToken: @escaping @Sendable (_ stale: String?) async throws -> String
  ) {
    core = TraciveReportCore.TraciveReports(
      baseUrl: environment.baseUrl.absoluteString,
      appUrlScheme: (target ?? ReportFormTarget.for(environment)).scheme,
      accessToken: TokenBridge(accessToken)
    )
  }

  deinit {
    core.close()
  }

  /// What a report must satisfy right now, and the terms the user accepts by submitting.
  public func requirements() async throws -> ReportRequirements {
    try await bridged(ReportRequirements.init) { core.startRequirements(completion: $0) }
  }

  /// Compresses one piece of evidence: to AVIF, under 200 KB, 1024 px on the shortest side, with
  /// metadata dropped. A PDF under 1 MiB passes through.
  public func prepare(_ data: Data, mimeType: String) async throws -> PreparedEvidence {
    try await bridged(PreparedEvidence.init) {
      core.startPrepare(data: data, mimeType: mimeType, completion: $0)
    }
  }

  /// Uploads the evidence and files the report.
  ///
  /// Call again with the same draft after a failure: finished uploads are skipped and the report
  /// is created once. A second call for a report already filed answers the same result.
  ///
  /// - Parameter onProgress: the share of evidence uploaded, from 0 to 1, on no particular thread.
  public func submit(
    _ draft: ReportDraft,
    onProgress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> SubmitResult {
    let listener = onProgress.map(ProgressBridge.init)
    return try await bridged(SubmitResult.init) {
      core.startSubmit(draft: draft.core, onProgress: listener, completion: $0)
    }
  }

  /// One report's status. Needs `TraciveReportScopes.read`. Reports answer for 30 days.
  public func status(_ reportId: String) async throws -> ReportStatus {
    try await bridged(ReportStatus.init) {
      core.startStatus(reportId: reportId, completion: $0)
    }
  }

  /// Opens the report in the Tracive app, where a revision is made.
  ///
  /// - Parameter completion: false when the app could not be opened.
  public func openInTracive(
    _ reportId: String,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    let link = detailsLink(reportId)
    Task { @MainActor in
      var opened = false
      if let url = URL(string: link) { opened = await UIApplication.shared.open(url) }
      completion?(opened)
    }
  }

  func detailsLink(_ reportId: String) -> String {
    core.reportDetailsLink(reportId: reportId)
  }
}
