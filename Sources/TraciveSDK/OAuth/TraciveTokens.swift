import Foundation

/// The token pair issued by `POST /v1/oauth/token`.
///
/// - `accessToken` is a JWT with a one-hour life. It goes in `Authorization: Bearer …`.
/// - `refreshToken` is an opaque, **rotating** string. Every refresh returns a new one and the old
///   one dies. Presenting a dead refresh token trips the server's reuse detection, which revokes
///   the entire grant — which is why refreshing is single-flighted and why replacing the
///   stored token must be atomic.
///
/// `description` and `debugDescription` are redacted. This type is a credential; the only place it
/// is allowed to exist in plaintext is the Keychain.
public struct TraciveTokens: Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let accessToken: String
  public let refreshToken: String?
  public let tokenType: String
  /// When the access token expires, when the server told us. Derived from `expires_in` at the
  /// moment of issue.
  public let expiresAt: Date?
  /// The scopes actually granted, which may be **narrower** than those requested.
  public let scopes: [String]

  public init(
    accessToken: String,
    refreshToken: String? = nil,
    tokenType: String = "Bearer",
    expiresAt: Date? = nil,
    scopes: [String] = []
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.tokenType = tokenType
    self.expiresAt = expiresAt
    self.scopes = scopes
  }

  /// Whether the access token is known to have expired at `date`.
  ///
  /// Informational only: the SDK does **not** refresh pre-emptively on it. Refresh happens on
  /// a 401 `expired_token`, and the server's clock is the one that decides — refreshing on a local
  /// estimate would burn a refresh-token rotation every time a device's clock drifted forward.
  /// `nil` `expiresAt` reads as "not known to be expired".
  public func isExpired(at date: Date, leeway: TimeInterval = 0) -> Bool {
    guard let expiresAt else { return false }
    return date.addingTimeInterval(leeway) >= expiresAt
  }

  /// Returns a copy carrying a freshly rotated pair, keeping the old refresh token if the server
  /// omitted a new one (RFC 6749 permits that; Tracive always rotates).
  public func replacing(with refreshed: TraciveTokens) -> TraciveTokens {
    TraciveTokens(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken ?? refreshToken,
      tokenType: refreshed.tokenType,
      expiresAt: refreshed.expiresAt,
      scopes: refreshed.scopes.isEmpty ? scopes : refreshed.scopes
    )
  }

  public var description: String {
    "TraciveTokens(accessToken: <redacted>, refreshToken: "
      + "\(refreshToken == nil ? "nil" : "<redacted>"), tokenType: \(tokenType), "
      + "expiresAt: \(expiresAt.map(TraciveISO8601.string(from:)) ?? "nil"), "
      + "scopes: [\(scopes.joined(separator: " "))])"
  }

  public var debugDescription: String { description }
}

/// Where tokens live between launches.
///
/// The rule is categorical: **never** `UserDefaults`, never a plain file. On iOS that means the Keychain,
/// which is what `KeychainTokenStore` provides. The protocol is synchronous on purpose — the
/// single-flight refresh in `TraciveOAuth` reads the store inside its check-and-set, and an `await`
/// there would open a window for a second refresh to start and trip reuse detection.
public protocol TraciveTokenStore: Sendable {
  func load() throws -> TraciveTokens?
  func save(_ tokens: TraciveTokens) throws
  func clear() throws
}

/// A `TraciveTokenStore` that keeps tokens in memory only.
///
/// For tests, for SwiftUI previews, and for a host app that deliberately wants the grant to die
/// with the process. Everything is lost on relaunch, which means the user re-consents — acceptable
/// as a choice, unacceptable as an accident, so production apps should use `KeychainTokenStore`.
public final class InMemoryTokenStore: TraciveTokenStore, @unchecked Sendable {

  private let lock = NSLock()
  private var tokens: TraciveTokens?

  public init(tokens: TraciveTokens? = nil) {
    self.tokens = tokens
  }

  public func load() throws -> TraciveTokens? {
    lock.lock()
    defer { lock.unlock() }
    return tokens
  }

  public func save(_ tokens: TraciveTokens) throws {
    lock.lock()
    defer { lock.unlock() }
    self.tokens = tokens
  }

  public func clear() throws {
    lock.lock()
    defer { lock.unlock() }
    tokens = nil
  }
}

/// The `POST /v1/oauth/token` response (RFC 6749 §5.1).
///
/// Unknown fields are ignored, per the SDK-wide forward-compatibility rule. `scope` is the RFC's
/// space-delimited string; a `scopes` array is accepted too, because it costs three lines now and
/// would cost a release later.
struct OAuthTokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String?
  let tokenType: String?
  let expiresIn: Double?
  let scope: String?
  let scopes: [String]?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case scope
    case scopes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // The access token is the whole point of the exchange: a response without one is broken, not
    // merely newer, so it is the single strictly-decoded field here.
    self.accessToken = try container.decode(String.self, forKey: .accessToken)
    self.refreshToken = (try? container.decodeIfPresent(String.self, forKey: .refreshToken)) ?? nil
    self.tokenType = (try? container.decodeIfPresent(String.self, forKey: .tokenType)) ?? nil
    if let seconds = try? container.decodeIfPresent(Double.self, forKey: .expiresIn) {
      self.expiresIn = seconds
    } else if let text = try? container.decodeIfPresent(String.self, forKey: .expiresIn) {
      self.expiresIn = Double(text)
    } else {
      self.expiresIn = nil
    }
    self.scope = (try? container.decodeIfPresent(String.self, forKey: .scope)) ?? nil
    self.scopes = (try? container.decodeIfPresent([String].self, forKey: .scopes)) ?? nil
  }

  /// Materialises the wire response into stored tokens, resolving `expires_in` against `now`.
  func tokens(issuedAt now: Date) -> TraciveTokens {
    let granted: [String]
    if let scopes, !scopes.isEmpty {
      granted = scopes
    } else if let scope {
      granted = scope.split(separator: " ").map(String.init)
    } else {
      granted = []
    }
    return TraciveTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      tokenType: tokenType ?? "Bearer",
      expiresAt: expiresIn.map { now.addingTimeInterval($0) },
      scopes: granted
    )
  }
}
