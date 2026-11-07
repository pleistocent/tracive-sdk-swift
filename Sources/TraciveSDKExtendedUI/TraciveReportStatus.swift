import SwiftUI
import TraciveSDKExtended
import UIKit

/// How the status screen ended.
public enum ReportStatusOutcome: Equatable, Sendable {
  /// The user closed it.
  case closed
  /// No grant, or a grant without `report.read`. Authorize with the scope and open it again.
  case needsConsent
}

/// Tracive's status screen, for hosts that are not SwiftUI. In SwiftUI use `.traciveReportStatus`.
public enum TraciveReportStatus {

  @MainActor
  public static func present(
    reports: TraciveReports,
    reportId: String,
    theme: TraciveReportTheme = TraciveReportTheme(),
    from presenter: UIViewController,
    completion: ((ReportStatusOutcome) -> Void)? = nil
  ) {
    presenter.present(
      makeHost(reports: reports, reportId: reportId, theme: theme, completion: completion),
      animated: true
    )
  }

  @MainActor
  static func makeHost(
    reports: TraciveReports,
    reportId: String,
    theme: TraciveReportTheme,
    completion: ((ReportStatusOutcome) -> Void)?
  ) -> UIViewController {
    let model = ReportStatusModel(reports: reports, reportId: reportId)
    let host = ReportModalHost(
      rootView: ReportStatusModal(model: model, theme: ResolvedReportTheme(theme))
    )
    host.modalPresentationStyle = .formSheet
    model.onDone = { [weak host] in host?.close() }
    host.onClosed = {
      model.close()
      completion?(model.needsConsent ? .needsConsent : .closed)
    }
    return host
  }
}

extension View {

  /// Tracive's status screen for one report.
  public func traciveReportStatus(
    isPresented: Binding<Bool>,
    reports: TraciveReports,
    reportId: String,
    theme: TraciveReportTheme = TraciveReportTheme(),
    completion: ((ReportStatusOutcome) -> Void)? = nil
  ) -> some View {
    background(
      ReportModalPresenter(isPresented: isPresented) { onFinished in
        TraciveReportStatus.makeHost(
          reports: reports, reportId: reportId, theme: theme
        ) { outcome in
          onFinished()
          completion?(outcome)
        }
      }
    )
  }
}

@MainActor
final class ReportStatusModel: ObservableObject {

  enum Load: Equatable {
    case loading
    case loaded(ReportStatus)
    case failed(TraciveReportError.Code)
  }

  @Published private(set) var load = Load.loading
  @Published private(set) var traciveMissing = false
  private(set) var needsConsent = false

  var onDone: (() -> Void)?

  private let reports: TraciveReports
  private let reportId: String
  private var task: Task<Void, Never>?

  init(reports: TraciveReports, reportId: String) {
    self.reports = reports
    self.reportId = reportId
    fetch()
  }

  func retry() {
    load = .loading
    fetch()
  }

  func openInTracive() {
    reports.openInTracive(reportId) { [weak self] opened in self?.traciveMissing = !opened }
  }

  func close() {
    task?.cancel()
  }

  private func fetch() {
    let reports = reports
    let reportId = reportId
    task = Task { @MainActor [weak self] in
      do {
        let status = try await reports.status(reportId)
        self?.load = .loaded(status)
      } catch is CancellationError {
        // The screen is closing.
      } catch let error as TraciveReportError {
        if error.code == .needsConsent {
          self?.needsConsent = true
          self?.load = .failed(.needsConsent)
          self?.onDone?()
        } else {
          self?.load = .failed(error.code)
        }
      } catch {
        self?.load = .failed(.server)
      }
    }
  }
}

private struct ReportStatusModal: View {
  @ObservedObject var model: ReportStatusModel
  let theme: ResolvedReportTheme

  var body: some View {
    NavigationView {
      ReportStatusContent(model: model, theme: theme)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(ReportText.text("close")) { model.onDone?() }
              .accessibilityIdentifier("tracive.report.close")
          }
        }
    }
    .navigationViewStyle(.stack)
    .tint(theme.primary)
  }
}

/// The status screen pushed from the form's success screen.
struct ReportStatusContainer: View {
  @StateObject private var model: ReportStatusModel
  let theme: ResolvedReportTheme

  init(reports: TraciveReports, reportId: String, theme: ResolvedReportTheme) {
    _model = StateObject(wrappedValue: ReportStatusModel(reports: reports, reportId: reportId))
    self.theme = theme
  }

  var body: some View {
    ReportStatusContent(model: model, theme: theme)
  }
}

private struct ReportStatusContent: View {
  @ObservedObject var model: ReportStatusModel
  let theme: ResolvedReportTheme

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.secondarySystemBackground).ignoresSafeArea())
      .navigationTitle(ReportText.text("status_title"))
      .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private var content: some View {
    switch model.load {
    case .loading:
      ProgressView()
    case .loaded(let status):
      ReportMessageView(
        systemImage: Self.symbol(status),
        title: ReportText.statusTitle(status),
        line: ReportText.statusLine(status),
        theme: theme
      ) {
        if status == .needRevision {
          VStack(spacing: 8) {
            ReportPrimaryButton(ReportText.text("open_in_tracive"), theme: theme) {
              model.openInTracive()
            }
            .accessibilityIdentifier("tracive.report.openInTracive")
            if model.traciveMissing {
              Text(ReportText.text("tracive_missing"))
                .font(.footnote)
                .foregroundColor(.secondary)
            }
          }
        }
      }
    case .failed(.reportNotFound):
      ReportMessageView(
        systemImage: "clock.badge.xmark",
        title: ReportText.text("status_gone"),
        line: ReportText.error(.reportNotFound),
        theme: theme
      ) {
        EmptyView()
      }
    case .failed(let code):
      ReportMessageView(
        systemImage: "exclamationmark.circle",
        title: ReportText.text("load_failed"),
        line: ReportText.error(code),
        theme: theme
      ) {
        ReportPrimaryButton(ReportText.text("retry"), theme: theme) { model.retry() }
      }
    }
  }

  /// All neutral. `.reviewed` must not read as approved or rejected.
  private static func symbol(_ status: ReportStatus) -> String {
    switch status {
    case .submitted: return "paperplane.circle"
    case .inReview: return "clock"
    case .reviewed: return "doc.text"
    case .needRevision: return "pencil.circle"
    }
  }
}
