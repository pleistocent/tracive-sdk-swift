import Foundation

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// The seam over "can the OS open this?" and "open it".
///
/// Two §6 requirements live behind it:
///
/// 1. **The app-presence pre-check happens before any redirect.** If Tracive is not installed, the
///    SDK opens the clean install link and stops — it must not push the user at an authorize URL
///    that will dead-end on a browser fallback page carrying `state` and `code_challenge`.
/// 2. **The authorize URL is opened with `UIApplication.open`, never a WebView.** App Links do not
///    fire from an in-app WebView — a bank app's habitual container would strand the user on the
///    fallback page even with Tracive installed — and RFC 8252 forbids WebViews for OAuth anyway.
///    It is also **not** `ASWebAuthenticationSession`: v1 has no web consent at all (§4.2), so
///    there is no web page to host.
///
/// Both methods are `async` because the UIKit implementations must hop to the main actor.
public protocol TraciveAppLauncher: Sendable {
  /// Whether the OS can open `url`. On iOS this is `UIApplication.canOpenURL`, which needs the
  /// scheme declared in the host app's `LSApplicationQueriesSchemes` — see
  /// `TraciveAppPresence.querySchemeInfoPlistKey`.
  func canOpen(_ url: URL) async -> Bool

  /// Opens `url` outside the app. Returns whether the OS accepted it.
  @discardableResult
  func open(_ url: URL) async -> Bool
}

/// Which app to look for, and where the install funnel goes when it is missing (§4.2, §4.3).
public enum TraciveAppPresence {

  /// Custom scheme of the production Tracive app (`com.pleistocent.tracive`).
  public static let productionScheme = "tracive"
  /// Custom scheme of the sandbox/dev app (`com.pleistocent.tracive.dev`). Sandbox and production
  /// are fully separate worlds by design — a production app never handles a sandbox consent.
  public static let sandboxScheme = "tracivedev"

  /// The `Info.plist` key the **host app** must populate for the pre-check to work.
  ///
  /// Without `LSApplicationQueriesSchemes` containing the scheme below, `canOpenURL` returns
  /// `false` even when Tracive is installed, and every user is sent down the install funnel. This
  /// is the single most likely integration mistake, so the README repeats it.
  public static let querySchemeInfoPlistKey = "LSApplicationQueriesSchemes"

  /// The probe URL for the pre-check.
  public static func probeURL(for environment: TraciveEnvironment) -> URL {
    URL(string: "\(scheme(for: environment))://") ?? URL(string: "tracive://")!
  }

  public static func scheme(for environment: TraciveEnvironment) -> String {
    switch environment {
    case .production: return productionScheme
    case .sandbox: return sandboxScheme
    // A custom base URL is a partner proxy or a local server; the app on the device is still the
    // production one unless the integrator says otherwise.
    case .custom: return productionScheme
    }
  }

  /// The **clean** install link (§6 step 3).
  ///
  /// It carries no OAuth parameters at all — no `state`, no `code_challenge`, no `redirect_uri`.
  /// That is a privacy requirement, not tidiness: chottu is a third-party service, and routing
  /// consent parameters through a processor is exactly what §4.2 rules out for production. An
  /// attribution tag naming the *client* is explicitly allowed, so `ref` carries the OAuth client
  /// id — the partner's own identifier, never the end user's.
  ///
  /// There is no deferred resume. The user installs Tracive and retries in the partner app; a
  /// consent request only lives ten minutes server-side, which a download plus registration will
  /// always outlast.
  public static func installURL(clientId: String?) -> URL {
    var components = URLComponents(string: "https://tracive.chottu.link")!
    var items = [URLQueryItem(name: "utm_source", value: "tracive-sdk-ios")]
    if let clientId, !clientId.isEmpty {
      items.append(URLQueryItem(name: "ref", value: clientId))
    }
    components.queryItems = items
    return components.url ?? URL(string: "https://tracive.chottu.link")!
  }

  /// The default launcher for the current platform.
  public static func makeDefaultLauncher() -> any TraciveAppLauncher {
    #if canImport(UIKit) && !os(watchOS)
      return UIKitAppLauncher()
    #else
      return UnavailableAppLauncher()
    #endif
  }
}

#if canImport(UIKit) && !os(watchOS)

  /// `UIApplication`-backed launcher: `canOpenURL` for the pre-check, `open(_:options:)` for the
  /// Universal Link hand-off to the Tracive app.
  public struct UIKitAppLauncher: TraciveAppLauncher {

    public init() {}

    public func canOpen(_ url: URL) async -> Bool {
      await MainActor.run { UIApplication.shared.canOpenURL(url) }
    }

    @discardableResult
    public func open(_ url: URL) async -> Bool {
      await withCheckedContinuation { continuation in
        Task { @MainActor in
          UIApplication.shared.open(url, options: [:]) { accepted in
            continuation.resume(returning: accepted)
          }
        }
      }
    }
  }

#endif

/// The launcher used where there is no `UIApplication` — notably macOS, where this package's unit
/// tests run.
///
/// It reports that nothing can be opened, so `authorize()` answers `.appNotInstalled` rather than
/// pretending to have launched something. Tests that need a launch inject their own conformer.
public struct UnavailableAppLauncher: TraciveAppLauncher {

  public init() {}

  public func canOpen(_ url: URL) async -> Bool { false }

  @discardableResult
  public func open(_ url: URL) async -> Bool { false }
}
