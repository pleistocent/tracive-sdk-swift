import Combine
import SwiftUI
import TraciveSDK
import TraciveSDKExtended
import UIKit

/// What you already know about the scammer. The user writes the chronology, so it cannot be
/// prefilled.
public struct ReportPrefill: Sendable {
  /// `TraciveQuery.searchQueryIndex` values, shown read-only.
  public let identifiers: [String]
  /// The user can change it, but not to a day in the future.
  public let incidentDate: ReportIncidentDate?
  /// The user can change it.
  public let title: String?
  /// The user can remove them. Each is compressed when the form opens.
  public let attachments: [ReportAttachment]

  public init(
    identifiers: [String],
    incidentDate: ReportIncidentDate? = nil,
    title: String? = nil,
    attachments: [ReportAttachment] = []
  ) {
    self.identifiers = identifiers
    self.incidentDate = incidentDate
    self.title = title
    self.attachments = attachments
  }

  public init(
    query: TraciveQuery,
    incidentDate: ReportIncidentDate? = nil,
    title: String? = nil,
    attachments: [ReportAttachment] = []
  ) {
    self.init(
      identifiers: [query.searchQueryIndex],
      incidentDate: incidentDate,
      title: title,
      attachments: attachments
    )
  }
}

/// How the form ended.
public enum ReportFormOutcome: Equatable, Sendable {
  /// The report was filed. Keep `reportId` with your transaction: reports cannot be listed.
  case submitted(reportId: String, status: ReportStatus)
  /// No grant, or a grant without `report.create`. Authorize with the scope and open it again.
  case needsConsent
  /// The user closed the form.
  case cancelled
}

/// Tracive's report form, for hosts that are not SwiftUI. In SwiftUI use `.traciveReportForm`.
public enum TraciveReportForm {

  /// Closing the form cancels an upload in progress.
  @MainActor
  public static func present(
    reports: TraciveReports,
    prefill: ReportPrefill,
    theme: TraciveReportTheme = TraciveReportTheme(),
    from presenter: UIViewController,
    completion: @escaping (ReportFormOutcome) -> Void
  ) {
    presenter.present(
      makeHost(reports: reports, prefill: prefill, theme: theme, completion: completion),
      animated: true
    )
  }

  @MainActor
  static func makeHost(
    reports: TraciveReports,
    prefill: ReportPrefill,
    theme: TraciveReportTheme,
    completion: @escaping (ReportFormOutcome) -> Void
  ) -> UIViewController {
    let model = ReportFormModel(reports: reports, prefill: prefill)
    let host = ReportModalHost(
      rootView: ReportFormScreen(model: model, theme: ResolvedReportTheme(theme))
    )
    host.modalPresentationStyle = .formSheet
    // A swipe must not throw away what the user wrote; Close still can.
    let swipeGuard = model.objectWillChange.receive(on: DispatchQueue.main)
      .sink { [weak host, weak model] _ in host?.isModalInPresentation = model?.hasWork ?? false }
    model.onFinish = { [weak host] in host?.close() }
    host.onClosed = {
      swipeGuard.cancel()
      model.close()
      completion(model.outcome)
    }
    return host
  }
}

extension View {

  /// Tracive's report form. Closing it cancels an upload in progress.
  public func traciveReportForm(
    isPresented: Binding<Bool>,
    reports: TraciveReports,
    prefill: ReportPrefill,
    theme: TraciveReportTheme = TraciveReportTheme(),
    completion: @escaping (ReportFormOutcome) -> Void
  ) -> some View {
    background(
      ReportModalPresenter(isPresented: isPresented) { onFinished in
        TraciveReportForm.makeHost(reports: reports, prefill: prefill, theme: theme) { outcome in
          onFinished()
          completion(outcome)
        }
      }
    )
  }
}
