import Foundation

/// Which Tracive Open API deployment to talk to.
///
/// **The Open API is not live yet.** These hosts are the documented contract; nothing answers on
/// them today, which is exactly why every unit test in this SDK runs against an injected fake
/// transport instead of a real endpoint.
public enum TraciveEnvironment: Equatable, Hashable, Sendable {
  case production
  case sandbox
  /// Partner proxy (phase 2) or a local test server.
  case custom(baseUrl: URL)

  /// The `/v1` root that every API path hangs off.
  public var baseUrl: URL {
    switch self {
    case .production:
      return TraciveEnvironment.productionBaseUrl
    case .sandbox:
      return TraciveEnvironment.sandboxBaseUrl
    case .custom(let url):
      return url
    }
  }

  /// Convenience for a base URL that arrives as a string (e.g. from a partner's own config).
  /// Returns `nil` rather than trapping when the string is not a URL.
  public static func custom(baseUrlString: String) -> TraciveEnvironment? {
    guard let url = URL(string: baseUrlString) else { return nil }
    return .custom(baseUrl: url)
  }

  // Force-unwrapped because these are compile-time constants covered by a unit test; if either
  // literal is ever mistyped the test fails before the SDK ships.
  private static let productionBaseUrl = URL(string: "https://api.tracive.id/v1")!
  private static let sandboxBaseUrl = URL(string: "https://api-sandbox.tracive.id/v1")!
}
