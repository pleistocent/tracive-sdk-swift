import Foundation

/// One prepared authorization attempt: the URL to open plus the PKCE material that must survive
/// until the callback arrives (§6 steps 1 and 4).
///
/// `description` redacts everything. The URL embeds `state` and `code_challenge`, and the verifier
/// is the secret half of the exchange.
public struct AuthorizationRequest: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// The Universal Link to hand to `UIApplication.open`. The OS routes it to the Tracive app; there
  /// is no server hop and no browser in the happy path.
  public let url: URL
  public let state: String
  public let codeVerifier: String
  public let codeChallenge: String

  public init(url: URL, state: String, codeVerifier: String, codeChallenge: String) {
    self.url = url
    self.state = state
    self.codeVerifier = codeVerifier
    self.codeChallenge = codeChallenge
  }

  public var description: String {
    "AuthorizationRequest(url: <redacted>, state: <redacted>, codeVerifier: <redacted>)"
  }

  public var debugDescription: String { description }
}

/// Builds the `GET /oauth/authorize` URL (§4.2).
///
/// ## Why the host is not `api.tracive.id`
///
/// The authorize URL is not an API call — it is an **App Link / Universal Link** that the Tracive
/// app claims, so its host has to be a domain that ships an `apple-app-site-association`:
/// `tracive.id` in production, `sandbox.tracive.id` in the sandbox, each claimed by the matching
/// app flavour. §4.2 is explicit that the production authorize host must be `tracive.id` and not
/// the third-party `chottu.link` fallback, because `state`, `code_challenge` and `partner_user_id`
/// must not transit a processor.
public enum AuthorizeURLBuilder {

  /// The default authorize endpoint for an environment.
  public static func defaultEndpoint(for environment: TraciveEnvironment) -> URL {
    switch environment {
    case .production:
      return URL(string: "https://tracive.id/oauth/authorize")!
    case .sandbox:
      return URL(string: "https://sandbox.tracive.id/oauth/authorize")!
    case .custom(let baseUrl):
      // A local test server or partner proxy: hang the route off whatever root it was given.
      return baseUrl.appendingPathComponent("oauth").appendingPathComponent("authorize")
    }
  }

  /// Assembles the authorize URL.
  ///
  /// Parameters, and why each is there:
  /// - `response_type=code` — authorization-code flow (RFC 6749).
  /// - `client_id`, `redirect_uri`, `scope`, `state` — the standard set. The redirect URI is
  ///   exact-matched against the registered list server-side.
  /// - `code_challenge` + `code_challenge_method=S256` — PKCE is mandatory and `plain` is rejected.
  /// - `partner_user_id` — the partner's own opaque id for the user, which the server stores on the
  ///   grant so it can be echoed back in webhooks and can enforce the 1:1 account link.
  ///
  /// **`partner_user_id` is required by the authorization server** even though `OAuthConfiguration`
  /// makes it optional (the cross-language SDK surface is frozen that way). Omitting it produces a
  /// server-side rejection at the consent step, not a local error — so set it.
  ///
  /// There is no `client_secret` and no API key here, and there is nowhere to put one: a public
  /// mobile client cannot hold a secret, which is the whole reason PKCE exists (§11.1).
  public static func build(
    endpoint: URL,
    configuration: OAuthConfiguration,
    pkce: PKCE
  ) throws -> URL {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw TraciveError.unknown(
        status: nil,
        info: TraciveErrorInfo(
          code: "invalid_authorize_endpoint",
          message: "The authorize endpoint is not a valid URL."
        )
      )
    }

    var items = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: configuration.clientId),
      URLQueryItem(name: "redirect_uri", value: configuration.redirectUri.absoluteString),
      URLQueryItem(name: "state", value: pkce.state),
      URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: PKCE.codeChallengeMethod),
    ]
    if !configuration.scopes.isEmpty {
      items.append(
        URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " "))
      )
    }
    if let partnerUserId = configuration.partnerUserId, !partnerUserId.isEmpty {
      items.append(URLQueryItem(name: "partner_user_id", value: partnerUserId))
    }

    // Preserve anything the integrator baked into a custom endpoint.
    components.queryItems = (components.queryItems ?? []) + items

    guard let url = components.url else {
      throw TraciveError.unknown(
        status: nil,
        info: TraciveErrorInfo(
          code: "invalid_authorize_endpoint",
          message: "The authorize URL could not be assembled."
        )
      )
    }
    return url
  }
}

/// `application/x-www-form-urlencoded` bodies for the token and revoke endpoints (RFC 6749 §4.1.3,
/// RFC 7009 §2.1).
///
/// Hand-rolled because `URLComponents.percentEncodedQuery` does **not** encode `+`, and `+` in a
/// form body decodes as a space on the server — silently corrupting a base64 refresh token that
/// happens to contain one. The allowed set below is RFC 3986's unreserved set and nothing else.
enum FormURLEncoding {

  static func encode(_ fields: [(name: String, value: String)]) -> Data {
    let body = fields
      .map { "\(escape($0.name))=\(escape($0.value))" }
      .joined(separator: "&")
    return Data(body.utf8)
  }

  static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  /// RFC 3986 §2.3 unreserved: `ALPHA / DIGIT / "-" / "." / "_" / "~"`.
  private static let unreserved: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()
}
