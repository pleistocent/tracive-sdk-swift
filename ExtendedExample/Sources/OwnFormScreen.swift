import SwiftUI
import TraciveSDK
import TraciveSDKExtended

/// The smallest report you can build yourself. Your form must show Tracive's terms and let the user
/// write the chronology.
struct OwnFormScreen: View {
  let reports: TraciveReports
  let query: TraciveQuery
  let onReport: (String) -> Void

  @State private var requirements: ReportRequirements?
  @State private var chronology = ""
  @State private var draft: ReportDraft?
  @State private var busy = false
  @State private var message = ""

  var body: some View {
    Form {
      Section("What happened, in the user's own words") {
        TextEditor(text: $chronology).frame(minHeight: 120)
      }
      Section("By sending, the user agrees to") {
        ForEach(requirements?.terms ?? [], id: \.id) { term in
          if let url = URL(string: term.url) { Link(term.id, destination: url) }
        }
      }
      Section {
        Button("Send") { Task { await send() } }.disabled(busy || requirements == nil)
        if !message.isEmpty { Text(message).font(.footnote) }
      }
    }
    .navigationTitle("Your own UI")
    .task { await load() }
  }

  private func load() async {
    do {
      requirements = try await reports.requirements()
    } catch {
      message = "\(error)"
    }
  }

  private func send() async {
    guard let requirements else { return }
    busy = true
    defer { busy = false }
    do {
      // Kept across retries: its idempotency key is what stops a retry from filing twice.
      let report = try await currentDraft(requirements)
      let result = try await reports.submit(report) { fraction in
        print("Uploaded \(Int(fraction * 100))%")
      }
      switch result {
      case .submitted(let reportId, let status):
        onReport(reportId)
        message = "Submitted \(reportId), \(status.rawValue)"
      case .needsConsent:
        message = "Needs consent. Authorize, then send again."
      case .failed(let error):
        message = "\(error.code.rawValue): \(error.message)"
      }
    } catch {
      message = "\(error)"
    }
  }

  private func currentDraft(_ requirements: ReportRequirements) async throws -> ReportDraft {
    if let draft, draft.chronology == chronology { return draft }
    let size = CGSize(width: 200, height: 200)
    let receipt = UIGraphicsImageRenderer(size: size).pngData { context in
      UIColor.systemGray4.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    let evidence = try await reports.prepare(receipt, mimeType: "image/png")
    let next = ReportDraft(
      query: query,
      title: "Sample: fake seller",
      chronology: chronology,
      incidentDate: ReportIncidentDate(Date().addingTimeInterval(-86_400)),
      evidence: [evidence],
      acceptedTerms: requirements.terms
    )
    draft = next
    return next
  }
}
