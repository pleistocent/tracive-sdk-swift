import SwiftUI
import TraciveExample
import TraciveSDK

/// Hosts `ScammerCheckView` so the example can actually be run on a simulator or a device.
///
/// Everything on screen comes from the `TraciveExample` library; this file is only the composition
/// root — the place a real app builds its dependencies and hands them to the UI. The flavor decides
/// which dependencies: the offline stub for `demo`, a real `TraciveClient` for the other two.
@main
struct TraciveExampleApp: App {

  var body: some Scene {
    WindowGroup {
      TabView {
        checkScreen
          .tabItem { Label("Check", systemImage: "checkmark.shield") }
        ReportScammerView(opener: LiveReportFormOpener(client: Self.reportClient))
          .tabItem { Label("Report", systemImage: "exclamationmark.bubble") }
      }
    }
  }

  @ViewBuilder
  private var checkScreen: some View {
    if let client = Self.liveClient, let environment = ExampleFlavor.current.environment {
      LiveCheckScreen(client: client, environment: environment)
    } else {
      ScammerCheckView(checker: Self.demoChecker, isOfflineDemo: true)
    }
  }

  /// `openReportForm` needs no grant, no network and no credit, so even the offline demo can call
  /// it for real. The demo's client exists only for that: it never authorizes and caches nothing.
  private static let reportClient: TraciveClient =
    liveClient
    ?? TraciveClient(
      mode: .oauth(
        clientId: ExampleFlavor.current.clientId,
        redirectUri: ExampleFlavor.current.redirectUri,
        partnerUserId: "partner-user-1"
      ),
      environment: .sandbox,
      cache: NoOpCheckCache()
    )

  /// Built once, like the demo checker below. The initialiser opens the on-disk cache synchronously,
  /// which is acceptable for an example; see `TraciveClient.init` if it is not for your launch.
  private static let liveClient: TraciveClient? = ExampleFlavor.current.environment.map {
    TraciveClient(
      mode: .oauth(
        clientId: ExampleFlavor.current.clientId,
        redirectUri: ExampleFlavor.current.redirectUri,
        // TODO(partner): the narrowest set your integration needs.
        scopes: [TraciveScopes.scammerCheck],
        // TODO(partner): your own stable, opaque id for this user — never a phone number or an
        // email.
        partnerUserId: "partner-user-1"
      ),
      environment: $0
    )
  }

  /// Built once. `body` can be evaluated more than once, and opening a database per evaluation
  /// would be a new empty cache each time.
  private static let demoChecker: any ScammerChecking = makeDemoChecker()

  /// The demo's stub. The live flavors show the real seam: `LiveChecker` over `checkScammer`, where
  /// `Source.cacheFirst` does what `CacheFirstChecker` spells out here.
  private static func makeDemoChecker() -> any ScammerChecking {
    let sample = SampleChecker()
    return CacheFirstChecker(cache: makeCache()) { try await sample.check($0) }
  }

  /// Deliberately not `ScammerCheckView()`'s own in-memory cache.
  ///
  /// That initialiser passes `SQLiteCheckCache.inMemory()`, which defaults to
  /// `EphemeralCacheKeyStore` — so it never touches the Keychain and leaves no file behind, which is
  /// what a library target compiled by CI wants. On-disk plus `KeychainCacheKeyStore` is the pairing
  /// only an installed app can exercise: the app-sandbox Application Support directory, the file
  /// protection class applied to it, and a data key that has to survive a relaunch. Check the same
  /// number after a cold start and a "Cached" badge is the proof that it did.
  private static func makeCache() -> any CheckCache {
    do {
      return try SQLiteCheckCache()
    } catch {
      // Loud, because the degraded path is indistinguishable from a working one on screen: every
      // check would simply read "Just checked" and look like a cache miss rather than a refusal.
      print("[TraciveExample] on-disk cache unavailable — caching is off for this run: \(error)")
      return NoOpCheckCache()
    }
  }
}

/// `openReportForm`, from SwiftUI: there is no `UIView` to anchor the sheet to, so it is presented
/// from the key window's top view controller.
struct LiveReportFormOpener: ReportFormOpening {
  let client: TraciveClient
  @MainActor
  func open(
    _ query: TraciveQuery,
    incidentDate: ReportIncidentDate?,
    attachments: [ReportAttachment],
    target: ReportFormTarget?
  ) async -> ReportFormResult {
    await client.openReportForm(
      query, incidentDate: incidentDate, attachments: attachments, target: target, from: .keyWindow)
  }
}

/// The real seam, in the one line a partner writes.
struct LiveChecker: ScammerChecking {
  let client: TraciveClient
  func check(_ query: TraciveQuery) async throws -> CheckResult {
    try await client.checkScammer(query)
  }
}

/// The sandbox and production flavors: the same screen, over a real client, with the OAuth controls
/// the demo does not need.
struct LiveCheckScreen: View {
  let client: TraciveClient
  let environment: TraciveEnvironment

  @State private var authorized = false
  @State private var notice: String?

  var body: some View {
    // Stacked rather than a top safe-area inset: an inset lays the bar over the navigation bar's
    // large title instead of pushing it down.
    VStack(spacing: 0) {
      bar
      ScammerCheckView(checker: LiveChecker(client: client))
    }
    // Every incoming URL goes to the SDK, which answers nil for anything that is not its own
    // redirect. This is also where the outcome of a flow arrives after iOS terminated this app
    // while the user was in the Tracive app.
    .onOpenURL { url in
      Task {
        // TODO(partner): nil means not a Tracive redirect — route it to the rest of your app.
        guard let result = await client.handleCallback(url: url) else { return }
        show(result)
      }
    }
    .task { authorized = await client.isAuthorized }
  }

  private var bar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(ExampleFlavor.current.rawValue) · \(environment.baseUrl.absoluteString)")
        .font(.footnote.weight(.semibold))
        .foregroundColor(.accentColor)
      HStack {
        Button(authorized ? "Authorized" : "Authorize") {
          notice = "Consent screen opened. Finish it in the Tracive app."
          // Suspends until the redirect reaches handleCallback above, then answers the same result.
          Task { show(await client.authorize()) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(authorized)
        Button("Sign out") {
          Task {
            await client.signOut()
            authorized = false
            notice = "Signed out. The grant and the cached verdicts are gone."
          }
        }
        .buttonStyle(.bordered)
        .disabled(!authorized)
      }
      if let notice {
        Text(notice).font(.footnote).foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  @MainActor
  private func show(_ result: AuthResult) {
    switch result {
    case .authorized(let scopes):
      authorized = true
      notice = "Authorized. Scopes granted: \(scopes.joined(separator: ", "))"
    case .codeReceived:
      // Only reachable for a confidential client; this example is public.
      // TODO(partner): forward the code and verifier over TLS to your backend.
      notice = "Authorization code received. Forward it to your backend."
    case .denied:
      notice = "You declined the request."
    case .appNotInstalled:
      notice = "Install the Tracive app first — the install page has been opened."
    case .failed(let error):
      notice = error.localizedDescription
    }
  }
}
