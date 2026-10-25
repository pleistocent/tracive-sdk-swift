import Foundation

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// The seam over "can the OS open this?" and "open it".
///
/// Two requirements of the consent flow live behind it:
///
/// 1. **The app-presence pre-check happens before any redirect.** If Tracive is not installed, the
///    SDK opens the clean install link and stops — it must not push the user at an authorize URL
///    that will dead-end on a browser fallback page carrying `state` and `code_challenge`.
/// 2. **The authorize URL is opened with `UIApplication.open`, never a WebView.** App Links do not
///    fire from an in-app WebView — a bank app's habitual container would strand the user on the
///    fallback page even with Tracive installed — and RFC 8252 forbids WebViews for OAuth anyway.
///    It is also **not** `ASWebAuthenticationSession`: v1 has no web consent at all, so
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

/// Which app to look for, and where the install funnel goes when it is missing.
public enum TraciveAppPresence {

  /// Custom scheme of the production Tracive app (`com.pleistocent.tracive`).
  public static let productionScheme = "tracive"
  /// Custom scheme of the sandbox build. Sandbox and production are fully separate worlds by
  /// design — a production app never handles a sandbox consent, and neither claims the other's
  /// scheme. The scheme is what this SDK probes for; the sandbox build's application id is not
  /// something it needs, so it is not named here.
  public static let sandboxScheme = "tracivesandbox"

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

  /// The **clean** install link (step 3).
  ///
  /// `https://tracive.chottu.link/install`, with two optional, non-sensitive query parameters:
  /// `ref` (the OAuth client id, omitted when nil or empty) and `utm_source`. The path is part of
  /// the link — the bare host does not resolve to the install page.
  ///
  /// It carries no OAuth parameters at all — no `state`, no `code_challenge`, no `code_verifier`,
  /// no `partner_user_id`, no `redirect_uri`, no `scope`. That is a privacy requirement, not
  /// tidiness: the link transits a third-party link service, and routing consent parameters through
  /// one is exactly what the contract rules out. An attribution tag naming the *client* is
  /// explicitly allowed, so `ref` carries the OAuth client id — the partner's own identifier, never
  /// the end user's.
  ///
  /// There is no deferred resume. The user installs Tracive and retries in the partner app; a
  /// consent request only lives ten minutes server-side, which a download plus registration will
  /// always outlast.
  public static func installURL(clientId: String?) -> URL {
    let base = "https://tracive.chottu.link/install"
    var components = URLComponents(string: base)!
    var items = [URLQueryItem(name: "utm_source", value: "tracive-sdk-ios")]
    if let clientId, !clientId.isEmpty {
      items.append(URLQueryItem(name: "ref", value: clientId))
    }
    components.queryItems = items
    return components.url ?? URL(string: base)!
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
