import Foundation

/// Which side of the PKCE exchange the SDK is responsible for (§2, §6).
///
/// - `.public`: the SDK performs the token exchange itself (`POST /oauth/token` with
///   `code` + `code_verifier`) and stores the resulting tokens in the Keychain.
/// - `.confidential`: the SDK stops at the authorization code and hands it back via
///   `AuthResult.codeReceived`. The partner's own backend completes the exchange with its
///   `client_secret`, which must never be embedded in a mobile binary.
public enum ClientType: String, Codable, CaseIterable, Hashable, Sendable {
  case `public` = "PUBLIC"
  case confidential = "CONFIDENTIAL"
}
