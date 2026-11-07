import Foundation
import TraciveSDK
import TraciveSDKExtended

/// How this build runs: the `sandbox` or `demo` scheme, each its own app, because the SDK's token
/// store is not keyed by environment. Values come from `Flavors/*.xcconfig` through `Info.plist`.
enum SampleFlavor: String {
  case sandbox
  case demo

  static let current: SampleFlavor = {
    guard let flavor = info("TraciveFlavor").flatMap(SampleFlavor.init) else {
      fatalError("Info.plist has no valid TraciveFlavor. Build a flavor scheme.")
    }
    return flavor
  }()

  var environment: TraciveEnvironment {
    Self.info("TraciveBaseURL").flatMap(URL.init(string:)).map { .custom(baseUrl: $0) } ?? .sandbox
  }

  var clientId: String { Self.info("TraciveClientId") ?? "" }

  /// Read from `Info.plist`, which builds it from the scheme `CFBundleURLTypes` registers.
  var redirectUri: URL {
    guard let url = Self.info("TraciveRedirectURI").flatMap(URL.init(string:)) else {
      fatalError("Info.plist has no valid TraciveRedirectURI.")
    }
    return url
  }

  var appScheme: String { Self.info("TraciveAppScheme") ?? TraciveAppPresence.sandboxScheme }

  /// Which Tracive app `openInTracive` opens, when it is not the one the environment implies. The
  /// bundle id only matters to `openReportForm`, which this sample does not call.
  var reportTarget: ReportFormTarget? {
    guard appScheme != ReportFormTarget.for(environment).scheme else { return nil }
    return ReportFormTarget(
      bundleIdentifier: "",
      scheme: appScheme,
      capabilityScheme: "\(appScheme)-report",
      fileExtension: "\(appScheme)report"
    )
  }

  private static func info(_ key: String) -> String? {
    let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
    return value?.isEmpty == false ? value : nil
  }
}

/// A build outside the release pair claims no universal link, so consent reaches it on its scheme.
private struct SchemeAppLauncher: TraciveAppLauncher {
  let scheme: String
  private let system = UIKitAppLauncher()

  func canOpen(_ url: URL) async -> Bool {
    guard let probe = URL(string: "\(scheme)://") else { return false }
    return await system.canOpen(probe)
  }

  func open(_ url: URL) async -> Bool { await system.open(url) }
}

extension TraciveClient {

  static func sample(flavor: SampleFlavor) -> TraciveClient {
    let mode = TraciveMode.oauth(
      clientId: flavor.clientId,
      redirectUri: flavor.redirectUri,
      scopes: [TraciveReportScopes.create, TraciveReportScopes.read],
      // TODO(partner): your own stable, opaque id for this user, never a phone number or an email.
      partnerUserId: "partner-user-1"
    )
    var oauth: TraciveOAuth?
    if flavor.reportTarget != nil, let configuration = mode.oauthConfiguration {
      oauth = try? TraciveOAuth(
        configuration: configuration,
        environment: flavor.environment,
        appLauncher: SchemeAppLauncher(scheme: flavor.appScheme),
        authorizationEndpoint: URL(string: "\(flavor.appScheme)://oauth/authorize")
      )
    }
    return TraciveClient(
      mode: mode, environment: flavor.environment, cachePolicy: .disabled, oauth: oauth)
  }
}
