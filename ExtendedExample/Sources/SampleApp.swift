import SwiftUI

@main
struct SampleApp: App {
  @StateObject private var model = SampleModel(flavor: .current)

  var body: some Scene {
    WindowGroup {
      SampleScreen(model: model)
        // Every incoming URL goes to the SDK, which ignores anything that is not its own redirect.
        .onOpenURL { model.handleRedirect($0) }
    }
  }
}
