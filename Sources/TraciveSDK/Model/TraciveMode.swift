import Foundation

/// How the SDK authenticates.
///
/// ## Hard design invariant
/// **There is no API-key parameter anywhere in this surface, in either mode**. A mobile
/// binary cannot keep a secret, so an API key embedded in one is a published credential. OAuth mode
/// carries a user-scoped access token; Proxy mode carries whatever headers the partner's own
/// backend minted for its own gateway. Do not add a key parameter to either configuration.
public enum TraciveMode: Equatable, Hashable, Sendable {
  case oauth(OAuthConfiguration)
  /// **phase 2.** Present in the surface so adding it later is not a breaking change.
  /// Every call made in this mode throws `TraciveError.notImplemented` until phase 2 lands.
  case proxy(ProxyConfiguration)

  /// Builds `.oauth` with the spec's defaults (`clientType` defaults to `.public`). Swift enum
  /// cases cannot carry default arguments, hence the factory.
  public static func oauth(
    clientId: String,
    redirectUri: URL,
    scopes: [String] = [],
    partnerUserId: String,
    clientType: ClientType = .public
  ) -> TraciveMode {
    .oauth(
      OAuthConfiguration(
        clientId: clientId,
        redirectUri: redirectUri,
        scopes: scopes,
        partnerUserId: partnerUserId,
        clientType: clientType
      )
    )
  }

  /// Builds `.proxy` (phase 2).
  public static func proxy(baseUrl: URL, authHeaders: [String: String] = [:]) -> TraciveMode {
    .proxy(ProxyConfiguration(baseUrl: baseUrl, authHeaders: authHeaders))
  }

  public var oauthConfiguration: OAuthConfiguration? {
    if case .oauth(let configuration) = self { return configuration }
    return nil
  }

  public var proxyConfiguration: ProxyConfiguration? {
    if case .proxy(let configuration) = self { return configuration }
    return nil
  }
}

/// OAuth + PKCE parameters. No client secret and no API key: a public mobile client has
/// nowhere safe to keep either.
public struct OAuthConfiguration: Equatable, Hashable, Sendable {
  public let clientId: String
  /// Must be an App Link / Universal Link that the partner app owns. RFC 8252 forbids completing
  /// this flow in an in-app WebView, and App Links do not fire from one either.
  public let redirectUri: URL
  /// The scopes to request. Name them with `TraciveScopes` rather than typing the strings: an
  /// unrecognised scope makes the authorization server reject the *whole* consent request, so a
  /// typo here is not a narrower grant, it is an integration that never authorizes.
  ///
  /// Kept as `[String]`, not a closed enum, because the granted set comes back from the server and
  /// may name a scope registered after this SDK version shipped.
  public let scopes: [String]
  /// The partner's own stable id for the end user, echoed back for reconciliation.
  ///
  /// **Required, and non-blank.** The Tracive app refuses a consent without one, client-side and
  /// before any network call, and by design returns no redirect — so the partner app is handed
  /// nothing to handle and nothing anywhere records the attempt. It is also what the grant is
  /// keyed on: echoed in `grant.revoked` and `grant.superseded` so a partner can map the event to
  /// their own customer, and what enforces one partner account to one Tracive account. Opaque —
  /// never a raw phone number or email.
  public let partnerUserId: String
  public let clientType: ClientType

  public init(
    clientId: String,
    redirectUri: URL,
    scopes: [String] = [],
    partnerUserId: String,
    clientType: ClientType = .public
  ) {
    precondition(
      !partnerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "OAuthConfiguration needs a partnerUserId. The authorization request must carry one: the Tracive app refuses a consent without it, client-side and with no redirect, so the failure would reach you as silence rather than as an error."
    )
    self.clientId = clientId
    self.redirectUri = redirectUri
    self.scopes = scopes
    self.partnerUserId = partnerUserId
    self.clientType = clientType
  }
}

/// Partner-proxy parameters (phase 2).
///
/// `authHeaders` are whatever the partner's gateway expects — they are forwarded verbatim and never
/// logged. This is still not an API-key parameter for the Tracive API: the partner's backend, not
/// the app, holds any Tracive credential.
public struct ProxyConfiguration: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let baseUrl: URL
  public let authHeaders: [String: String]

  public init(baseUrl: URL, authHeaders: [String: String] = [:]) {
    self.baseUrl = baseUrl
    self.authHeaders = authHeaders
  }

  /// Header **names** only. The values routinely carry bearer tokens, which must never reach a log.
  public var description: String {
    "ProxyConfiguration(baseUrl: \(baseUrl.absoluteString), "
      + "authHeaders: [\(authHeaders.keys.sorted().joined(separator: ", "))] = <redacted>)"
  }

  public var debugDescription: String { description }
}
