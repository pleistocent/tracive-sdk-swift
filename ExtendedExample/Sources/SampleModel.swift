import SwiftUI
import TraciveSDK
import TraciveSDKExtended
import TraciveSDKExtendedUI

/// A made-up account, so the sample runs with one tap and reports nobody real.
private let fakeScammer = try! TraciveQuery.bankAccount(
  countryAlpha3: "IDN", bankCode: "BCA", account: "0000000001")

@MainActor
final class SampleModel: ObservableObject {
  let client: TraciveClient
  let reports: TraciveReports

  // TODO(partner): your own brand.
  let theme = TraciveReportTheme(
    primaryColor: UIColor(red: 0, green: 0.412, blue: 0.361, alpha: 1),
    cornerRadius: 16
  )

  @Published var message = "Authorize first, unless this device already did."
  @Published var reportId = ""

  init(flavor: SampleFlavor) {
    client = .sample(flavor: flavor)
    if flavor == .demo {
      reports = TraciveReports(environment: flavor.environment, target: flavor.reportTarget) { _ in
        "demo-token"
      }
    } else {
      reports = TraciveReports(client: client, target: flavor.reportTarget)
    }
    if flavor == .demo { message = "Demo: start ExtendedExample/demo-server.py on this Mac." }
  }

  var prefill: ReportPrefill {
    ReportPrefill(
      query: fakeScammer,
      incidentDate: ReportIncidentDate(Date().addingTimeInterval(-86_400)),
      title: "Sample: fake seller",
      attachments: [.image(Self.sampleReceipt(), mimeType: "image/png")]
    )
  }

  /// Your own UI needs the identifier too. The chronology is the user's own words.
  var ownDraftIdentifier: TraciveQuery { fakeScammer }

  func authorize() {
    message = "Consent opened. Finish it in the Tracive app."
    Task { show(await client.authorize()) }
  }

  func handleRedirect(_ url: URL) {
    Task {
      guard let result = await client.handleCallback(url: url) else { return }
      show(result)
    }
  }

  func onFormOutcome(_ outcome: ReportFormOutcome) {
    switch outcome {
    case .submitted(let reportId, let status):
      self.reportId = reportId
      message = "Form: submitted \(reportId), \(status.rawValue)"
    case .needsConsent:
      message = "Form: needs consent. Authorize, then open it again."
    case .cancelled:
      message = "Form: cancelled."
    }
  }

  func onStatusOutcome(_ outcome: ReportStatusOutcome) {
    switch outcome {
    case .closed: message = "Status screen closed."
    case .needsConsent: message = "Status: needs consent. Authorize, then open it again."
    }
  }

  private func show(_ result: AuthResult) {
    switch result {
    case .authorized(let scopes): message = "Granted: \(scopes.joined(separator: ", "))"
    case .codeReceived: message = "Authorization code received. Forward it to your backend."
    case .denied: message = "You declined."
    case .appNotInstalled: message = "Install Tracive first. Its page has been opened."
    case .failed(let error): message = "Authorize failed: \(error.localizedDescription)"
    }
  }

  private static func sampleReceipt() -> Data {
    let size = CGSize(width: 600, height: 400)
    return UIGraphicsImageRenderer(size: size).pngData { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      ("Sample receipt\nRp 1.000.000\nBCA 0000000001" as NSString).draw(
        in: CGRect(x: 40, y: 40, width: 520, height: 320),
        withAttributes: [.font: UIFont.systemFont(ofSize: 40)]
      )
    }
  }
}
