import Foundation

/// Outcome of the OAuth + PKCE consent flow (§6).
///
/// `description` redacts the authorization code and the PKCE verifier: both are single-use
/// credentials, and a leaked pair lets an attacker complete the exchange.
public enum AuthResult: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {

  /// `.public` client: the SDK completed the token exchange and stored the tokens in the Keychain.
  /// `grantedScopes` is what the user actually consented to, which may be narrower than requested —
  /// check it before relying on a scope.
  case authorized(grantedScopes: [String])

  /// `.confidential` client: the SDK stopped at the authorization code, as the §4.2 sequence
  /// requires. Forward all three values to the partner's own backend, which completes the exchange
  /// with its `client_secret`. Nothing was stored locally.
  case codeReceived(code: String, codeVerifier: String, redirectUri: String)

  /// The user declined consent.
  case denied

  /// The Tracive app is not installed. The SDK opened the **clean** install link (no OAuth
  /// parameters on it) and did not start the flow. There is no deferred resume: the user comes back
  /// to the partner app and retries after installing.
  case appNotInstalled

  /// The flow failed. `stateMismatch` here means the callback's `state` did not match ours.
  case failed(TraciveError)

  public var description: String {
    switch self {
    case .authorized(let grantedScopes):
      return "authorized(grantedScopes: [\(grantedScopes.joined(separator: " "))])"
    case .codeReceived(_, _, let redirectUri):
      return "codeReceived(code: <redacted>, codeVerifier: <redacted>, redirectUri: \(redirectUri))"
    case .denied:
      return "denied"
    case .appNotInstalled:
      return "appNotInstalled"
    case .failed(let error):
      return "failed(\(error))"
    }
  }

  public var debugDescription: String { description }
}
