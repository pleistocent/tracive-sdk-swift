import Foundation

/// The OAuth scopes the authorization server recognises, as their exact wire strings.
///
/// Prefer these to string literals. A scope name is validated in exactly one place — the
/// authorization server — and an unrecognised one does not degrade into a narrower grant: the whole
/// consent request is rejected. A typo is therefore not a smaller permission, it is an integration
/// that cannot authorize at all, and the only place to discover that is a live consent screen.
///
/// Names are `resource.action`, where the resource is the thing being acted on rather than the
/// endpoint's path segment. Ask for the narrowest set that works: every extra scope is one more
/// permission on the consent screen for the user to accept, or refuse.
///
/// ```swift
/// .oauth(
///   clientId: "your-client-id",
///   redirectUri: URL(string: "https://yourapp.example.com/oauth/tracive")!,
///   scopes: [TraciveScopes.scammerCheck, TraciveScopes.creditsRead]
/// )
/// ```
///
/// ## Why `String` constants rather than a `RawRepresentable` enum
///
/// The granted set travels the other way too: `AuthResult.authorized(grantedScopes:)` and
/// `TraciveOAuth.grantedScopes` carry whatever the *server* said it granted, which may include a
/// scope registered after this SDK version shipped. A closed `enum` would have to either fail or
/// silently drop those, and `[TraciveScope]` on `OAuthConfiguration` would break a surface that is
/// frozen as `[String]` across the Kotlin, Flutter, React Native and Swift SDKs alike. Constants
/// add the spelling guarantee without taking the openness away, and they follow
/// `TraciveAppPresence`, which namespaces its own wire strings the same way.
///
/// The enum is caseless on purpose: it has no values, so it can only ever be a namespace.
///
/// ## What is deliberately not here
///
/// The authorization server also registers a scope for the daily usage aggregate. It is absent
/// because this SDK models no call that needs it — and a constant for a request the SDK cannot make
/// only invites asking a user to grant something that buys them nothing. It belongs here on the day
/// that endpoint does.
public enum TraciveScopes {

  /// Run a scammer check. Required by `TraciveClient.checkScammer(_:source:detail:locale:idempotencyKey:)`.
  public static let scammerCheck: String = "scammer.check"

  /// Read the user's remaining subscription credits. Required by `TraciveClient.credits()`.
  ///
  /// Worth requesting for a settings or billing screen. It is *not* needed to handle a 402 — the
  /// insufficient-credit signal rides on the check itself, which is why the SDK tells you not to
  /// poll `credits()` before every check.
  public static let creditsRead: String = "credits.read"

  /// Read the minimal user profile. Required by `TraciveClient.profile()`.
  ///
  /// Which fields of `ProfileInfo` actually come back still depends on what the user consented to,
  /// so a `nil` field means "not shared" rather than "not set".
  public static let profileRead: String = "profile.read"
}
