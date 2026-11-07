import SwiftUI
import TraciveSDKExtended
import TraciveSDKExtendedUI

struct SampleScreen: View {
  @ObservedObject var model: SampleModel

  @State private var showingForm = false
  @State private var showingStatus = false

  var body: some View {
    NavigationView {
      Form {
        Section(SampleFlavor.current.rawValue) {
          Text(model.message).font(.footnote)
          if SampleFlavor.current != .demo {
            Button("Authorize") { model.authorize() }
          }
        }
        Section("Report") {
          Button("Report with Tracive's form") { showingForm = true }
          NavigationLink("Report with your own UI") {
            OwnFormScreen(reports: model.reports, query: model.ownDraftIdentifier) {
              model.reportId = $0
            }
          }
        }
        Section("Status") {
          TextField("Report id", text: $model.reportId)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
          Button("Show status") { showingStatus = true }
            .disabled(model.reportId.isEmpty)
        }
      }
      .navigationTitle("Tracive Extended")
    }
    .navigationViewStyle(.stack)
    .traciveReportForm(
      isPresented: $showingForm,
      reports: model.reports,
      prefill: model.prefill,
      theme: model.theme
    ) { model.onFormOutcome($0) }
    .traciveReportStatus(
      isPresented: $showingStatus,
      reports: model.reports,
      reportId: model.reportId,
      theme: model.theme
    ) { model.onStatusOutcome($0) }
  }
}
