import CryptoKit
import Foundation
import Security

/// One PKCE pair plus the CSRF `state` for a single authorization attempt (RFC 7636, §6 step 1).
///
/// The verifier is the secret: whoever holds it, plus the authorization code, can complete the
/// exchange. It never leaves the device for a `.public` client, and for a `.confidential` client it
/// goes back to the host app through `AuthResult.codeReceived` so the partner's *backend* can do
/// the exchange. Either way it is never logged — hence the redacted `description`.
public struct PKCE: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// 43–128 characters from the unreserved set, per RFC 7636 §4.1.
  public let codeVerifier: String
  /// `BASE64URL(SHA256(ASCII(codeVerifier)))`.
  public let codeChallenge: String
  /// Random CSRF token echoed back on the callback and compared in `handleCallback(url:)`.
  public let state: String

  public init(codeVerifier: String, codeChallenge: String, state: String) {
    self.codeVerifier = codeVerifier
    self.codeChallenge = codeChallenge
    self.state = state
  }

  /// **S256 only.** RFC 7636 permits `plain`; Tracive's authorization server rejects it (§4.2), and
  /// so does this SDK — with `plain` the challenge *is* the verifier, so an attacker who can read
  /// the authorize URL can complete the exchange.
  public static let codeChallengeMethod = "S256"

  /// `BASE64URL(SHA256(ASCII(verifier)))`.
  ///
  /// Verified against RFC 7636 Appendix B in `OAuthTests`.
  public static func challenge(for verifier: String) -> String {
    Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  public var description: String {
    "PKCE(codeVerifier: <redacted>, codeChallenge: <redacted>, state: <redacted>)"
  }

  public var debugDescription: String { description }
}

/// Produces PKCE material. Injectable so a test can pin the verifier and assert on the exact
/// authorize URL; production always uses `SystemPKCEGenerator`.
public protocol PKCEGenerating: Sendable {
  func generate() -> PKCE
}

/// The real generator: 32 cryptographically random bytes for the verifier and 32 more for the
/// state, each base64url-encoded to 43 unreserved characters.
///
/// 32 bytes is 256 bits — comfortably past RFC 7636's 43-character floor while staying well under
/// its 128-character ceiling, and it needs no padding stripping beyond base64url's own.
public struct SystemPKCEGenerator: PKCEGenerating {

  public init() {}

  public func generate() -> PKCE {
    let verifier = Base64URL.encode(SecureRandom.bytes(32))
    return PKCE(
      codeVerifier: verifier,
      codeChallenge: PKCE.challenge(for: verifier),
      state: Base64URL.encode(SecureRandom.bytes(32))
    )
  }
}

/// base64url without padding (RFC 4648 §5) — the encoding RFC 7636 requires for the challenge.
enum Base64URL {

  static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func encode<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    encode(Data(bytes))
  }
}

/// Cryptographically secure random bytes.
///
/// `SecRandomCopyBytes` is the platform's CSPRNG. `SystemRandomNumberGenerator` is the documented
/// fallback — it is also cryptographically secure on Apple platforms (it draws from `arc4random`) —
/// and exists only so a `SecRandomCopyBytes` failure cannot leave us returning zeros, which would
/// silently produce a guessable verifier.
enum SecureRandom {

  static func bytes(_ count: Int) -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
    if status == errSecSuccess {
      return Data(buffer)
    }
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
  }
}

/// Compares two strings in time independent of how many leading bytes match.
///
/// Used for the `state` check. The practical risk of a timing oracle here is low, but the cost of
/// removing it is four lines, and `==` on `String` short-circuits on the first differing byte.
func traciveConstantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
  let left = Array(lhs.utf8)
  let right = Array(rhs.utf8)
  guard left.count == right.count else { return false }
  var difference: UInt8 = 0
  for index in left.indices {
    difference |= left[index] ^ right[index]
  }
  return difference == 0
}
