import Foundation

#if os(iOS)
  import UIKit

  extension TraciveClient {

    /// Opens the Tracive app's report form with the scammer's identifier, the transaction date and
    /// the receipt already filled in.
    ///
    /// ```swift
    /// let query = try TraciveQuery.bankAccount(
    ///   countryAlpha3: "IDN", bankCode: "BCA", account: "1234567890")
    /// let result = await tracive.openReportForm(
    ///   query,
    ///   incidentDate: ReportIncidentDate(transaction.date),
    ///   attachments: [.image(receiptPNG, mimeType: "image/png")],
    ///   from: .view(reportButton)
    /// )
    /// ```
    ///
    /// Needs no `authorize()`, no token and no network, and spends no credit, so it works for a
    /// `.confidential` client too. Everything stays on the device until the user submits the report
    /// inside Tracive.
    ///
    /// The attachments are validated first, and a failure opens nothing. Then, depending on the
    /// device:
    ///
    /// - **Tracive installed and able to take a package:** iOS's "Open in" sheet appears, anchored
    ///   to `anchor` (a popover on iPad), and this call suspends until the user chooses. Picking
    ///   the Tracive app answers `.opened(attachmentsDelivered: true)`; closing the sheet, "Save to
    ///   Files" or any other app answers `.cancelled`.
    /// - **An older Tracive app**, or a host app missing the report scheme in
    ///   `LSApplicationQueriesSchemes`: the form opens by link with the identifier only, after iOS
    ///   asks the user to confirm. `.opened(attachmentsDelivered: false)`, or `.cancelled` if they
    ///   decline.
    /// - **No Tracive app:** the install page opens, carrying nothing from the report.
    ///   `.installPageOpened`.
    ///
    /// The host app's `Info.plist` must list `tracive`, `tracivesandbox`, `tracive-report` and
    /// `tracivesandbox-report` under `LSApplicationQueriesSchemes`. See `Docs/integration.md`.
    ///
    /// - Parameters:
    ///   - query: the account the user is reporting. Its `searchQueryIndex` is what the form opens
    ///     with.
    ///   - incidentDate: the transaction's date. `nil` leaves it for the user to fill in.
    ///   - attachments: up to 5, or 10 for a phone number. See `ReportAttachment`.
    ///   - target: leave `nil` to follow this client's `environment`. Pass one only for testing
    ///     against a build the SDK does not know about.
    ///   - anchor: where the sheet's popover points on iPad. `.keyWindow` when there is no view to
    ///     hand, as in SwiftUI.
    @MainActor
    public func openReportForm(
      _ query: TraciveQuery,
      incidentDate: ReportIncidentDate? = nil,
      attachments: [ReportAttachment] = [],
      target: ReportFormTarget? = nil,
      from anchor: ReportFormAnchor
    ) async -> ReportFormResult {
      await openReportForm(
        query,
        incidentDate: incidentDate,
        attachments: attachments,
        target: target,
        presenter: DocumentInteractionMenuPresenter(anchor: anchor)
      )
    }
  }
#endif

extension TraciveClient {

  /// The whole of `openReportForm` behind its two seams: the sheet (`presenter`) and the OS
  /// (`launcher`, by default the one `authorize()` uses, so an injected launcher governs both).
  @MainActor
  func openReportForm(
    _ query: TraciveQuery,
    incidentDate: ReportIncidentDate?,
    attachments: [ReportAttachment],
    target: ReportFormTarget?,
    presenter: any OpenInMenuPresenting,
    launcher: (any TraciveAppLauncher)? = nil,
    store: ReportPackageStore = .default,
    gate: ReportFormGate? = nil,
    timeZone: TimeZone = .current
  ) async -> ReportFormResult {
    let flow = ReportFormFlow(
      target: target ?? .for(environment),
      installURL: oauth?.installURL ?? TraciveAppPresence.installURL(clientId: nil),
      launcher: launcher ?? oauth?.appLauncher ?? TraciveAppPresence.makeDefaultLauncher(),
      store: store,
      gate: gate ?? .shared
    )
    return await flow.run(
      searchQueryIndex: query.searchQueryIndex,
      incidentDate: incidentDate,
      attachments: attachments,
      today: ReportIncidentDate(clock.now, timeZone: timeZone),
      presenter: presenter
    )
  }
}
