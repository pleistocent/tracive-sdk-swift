import Foundation
import TraciveSDK

/// How this build of the example runs: the `demo`, `sandbox` or `production` scheme.
///
/// `demo` answers from `SampleChecker`, so a fresh clone runs with no credentials and nothing to
/// bill. `sandbox` and `production` are the real integration against that environment.
///
/// Each flavor installs as its own app. The SDK's token store and cache are not keyed by
/// environment, so a grant and cached verdicts left in an app later rebuilt for another environment
/// would be sent to it and served as its answers. Separate apps need separate redirect schemes too,
/// or iOS picks which of them receives the authorization code.
enum ExampleFlavor: String {
  case demo
  case sandbox
  case production

  /// The flavor this binary was built with, from `Flavors/<flavor>.xcconfig` through `Info.plist`.
  static let current: ExampleFlavor = {
    let name = Bundle.main.object(forInfoDictionaryKey: "TraciveFlavor") as? String
    guard let name, let flavor = ExampleFlavor(rawValue: name) else {
      fatalError("Info.plist has no valid TraciveFlavor (\(name ?? "nil")). Build a flavor scheme.")
    }
    return flavor
  }()

  /// `nil` for the demo.
  var environment: TraciveEnvironment? {
    switch self {
    case .demo: return nil
    case .sandbox: return .sandbox
    case .production: return .production
    }
  }

  /// Sandbox and production are separate registrations: a sandbox client id is unknown to
  /// production.
  var clientId: String {
    switch self {
    case .demo: return "demo-client"
    // TODO(partner): the client id Tracive issued you in sandbox, with this flavor's redirect
    // registered on it.
    case .sandbox: return "REPLACE_WITH_YOUR_SANDBOX_CLIENT_ID"
    // TODO(partner): the client id Tracive issued you in production.
    case .production: return "REPLACE_WITH_YOUR_PRODUCTION_CLIENT_ID"
    }
  }

  /// Read from `Info.plist`, which builds it from the scheme `CFBundleURLTypes` registers.
  var redirectUri: URL {
    guard
      let string = Bundle.main.object(forInfoDictionaryKey: "TraciveRedirectURI") as? String,
      let url = URL(string: string)
    else {
      fatalError("Info.plist has no valid TraciveRedirectURI.")
    }
    return url
  }
}
