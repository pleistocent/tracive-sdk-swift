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

/// An authorization that has been started and is waiting for its redirect.
///
/// Persisted, not merely held in a field. Consent happens in **another app**: the host app is
/// backgrounded for its whole duration, and iOS is entitled to terminate a backgrounded app under
/// memory pressure. A `code_verifier` that lived only in memory is gone when the Universal Link
/// brings the app back — the callback arrives, `state` matches nothing, the exchange cannot be
/// completed, and a user who consented successfully lands in a dead flow that reports itself as a
/// state mismatch.
///
/// `description` redacts the verifier and the `state`. The verifier is the secret half of the
/// exchange, which is also why this record belongs in the same secure store as the tokens and
/// **never** in `UserDefaults` or a plain file.
public struct PendingAuthorization: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  /// The CSRF nonce put on the authorize URL and compared on the way back.
  public let state: String
  /// The PKCE verifier whose challenge was sent. The secret.
  public let codeVerifier: String
  /// The redirect URI that was sent, which RFC 6749 §4.1.3 requires the exchange to repeat
  /// identically. Recorded rather than re-read from the configuration so a relaunched process
  /// replays the URI the authorization was actually started with.
  public let redirectUri: String
  /// When the attempt was started, by the SDK's clock. Used only to expire it.
  public let createdAt: Date

  /// How long a started-but-unfinished authorization stays resumable: **ten minutes**.
  ///
  /// Ten matches the lifetime of the authorization code itself (RFC 6749 §4.1.2 puts the maximum at
  /// ten minutes, and Tracive's server is at that maximum). Holding the verifier for longer buys no
  /// additional recovery, because by then the code the verifier would be exchanged with is already
  /// dead server-side: the flow cannot be completed however well the record survived. What a longer
  /// window does buy is a live `code_verifier` sitting on the device with nothing left to spend it
  /// on, and a wider replay window for an abandoned attempt. So the record is kept exactly as long
  /// as it can still be useful and not one minute more.
  public static let maxAge: TimeInterval = 600

  public init(state: String, codeVerifier: String, redirectUri: String, createdAt: Date) {
    self.state = state
    self.codeVerifier = codeVerifier
    self.redirectUri = redirectUri
    self.createdAt = createdAt
  }

  /// Whether this attempt is older than `maxAge` at `date`.
  ///
  /// Deliberately takes **no** window parameter. `maxAge` is the only place the number lives, and a
  /// per-call override — even one defaulting to `maxAge` — would be a second way for a window to
  /// enter the flow, which is precisely how a sibling SDK ended up with two independent copies of
  /// its own value that were free to disagree. Nothing in this SDK wants a different window; if
  /// something ever does, it should change the constant and say why.
  ///
  /// A `createdAt` in the future — only reachable if the device's wall clock moved backwards
  /// between the two halves of one consent flow — reads as "not stale", exactly as it does in the
  /// sibling SDKs. That is deliberate rather than overlooked: the code is dead server-side within
  /// ten minutes regardless, so the worst such a record can do is fail an exchange it was always
  /// going to fail.
  public func isStale(at date: Date) -> Bool {
    date.timeIntervalSince(createdAt) > Self.maxAge
  }

  public var description: String {
    "PendingAuthorization(state: <redacted>, codeVerifier: <redacted>, "
      + "redirectUri: \(redirectUri), createdAt: \(TraciveISO8601.string(from: createdAt)))"
  }

  public var debugDescription: String { description }
}

/// Where tokens live between launches.
///
/// The rule is categorical: **never** `UserDefaults`, never a plain file. On iOS that means the Keychain,
/// which is what `KeychainTokenStore` provides. The protocol is synchronous on purpose — the
/// single-flight refresh in `TraciveOAuth` reads the store inside its check-and-set, and an `await`
/// there would open a window for a second refresh to start and trip reuse detection.
///
/// The store also holds the **pending authorization**, for the reason `PendingAuthorization` gives:
/// it carries the `code_verifier`, so it is a credential and belongs nowhere else.
public protocol TraciveTokenStore: Sendable {
  func load() throws -> TraciveTokens?
  func save(_ tokens: TraciveTokens) throws
  /// Erases everything this store holds for the client — tokens **and** any pending authorization.
  func clear() throws

  /// The authorization waiting for its redirect, or `nil`.
  func loadPending() throws -> PendingAuthorization?
  /// Stores — or, with `nil`, erases — the pending authorization.
  func savePending(_ pending: PendingAuthorization?) throws
}

extension TraciveTokenStore {

  /// Default: no persistence.
  ///
  /// These two have defaults so that a host app which already conforms its own vault to this
  /// protocol keeps compiling, and keeps behaving exactly as it does today: `TraciveOAuth` holds
  /// the pending attempt in memory as well, and only consults the store when its own field is
  /// empty. A store that does not override these therefore loses nothing that used to work — it
  /// just cannot recover an authorization from a process that was terminated mid-consent.
  ///
  /// Override both if you want that recovery, and put the record wherever you put the tokens.
  public func loadPending() throws -> PendingAuthorization? { nil }

  /// Default: no persistence. See `loadPending()`.
  public func savePending(_ pending: PendingAuthorization?) throws {}
}

/// A `TraciveTokenStore` that keeps tokens in memory only.
///
/// For tests, for SwiftUI previews, and for a host app that deliberately wants the grant to die
/// with the process. Everything is lost on relaunch, which means the user re-consents — acceptable
/// as a choice, unacceptable as an accident, so production apps should use `KeychainTokenStore`.
public final class InMemoryTokenStore: TraciveTokenStore, @unchecked Sendable {

  private let lock = NSLock()
  private var tokens: TraciveTokens?
  private var pending: PendingAuthorization?

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
    pending = nil
  }

  public func loadPending() throws -> PendingAuthorization? {
    lock.lock()
    defer { lock.unlock() }
    return pending
  }

  public func savePending(_ pending: PendingAuthorization?) throws {
    lock.lock()
    defer { lock.unlock() }
    self.pending = pending
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
