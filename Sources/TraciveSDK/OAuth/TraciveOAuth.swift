import Foundation

/// The OAuth + PKCE half of the SDK — app-to-app, no web view, no browser in the happy path.
///
/// ## The flow, end to end
///
/// 1. `authorize()` generates a PKCE pair and a `state`, and **writes them to the token store**
///    before anything is opened — see step 5 for why.
/// 2. It **pre-checks that the Tracive app is installed**, before any redirect.
/// 3. Not installed → it opens the clean install link and answers `.appNotInstalled`. The OAuth
///    flow never starts, and no consent parameter is handed to a third party.
/// 4. Installed → it opens the authorize Universal Link with `UIApplication.open`. The OS routes it
///    straight to the Tracive app. Never a WebView: App Links do not fire from one, and RFC 8252
///    forbids it. Never `ASWebAuthenticationSession` either — v1 has no web consent to host.
/// 5. The Tracive app returns to the partner app on its `redirect_uri`; the host app forwards that
///    URL to `handleCallback(url:)` from its `AppDelegate`/`SceneDelegate`. The host app may have
///    been **terminated** in the meantime — it was backgrounded for the whole of the user's visit
///    to Tracive, which is where the OS looks first under memory pressure — so the attempt is read
///    back from the store rather than from a field, and a relaunched process can finish a consent
///    it has no memory of starting.
/// 6. The attempt is expired if it is older than `PendingAuthorization.maxAge`, then `state` is
///    verified. A `.public` client then exchanges the code at `POST /v1/oauth/token` and stores the
///    tokens; a `.confidential` client stops at the code and hands it back for the partner's own
///    backend to exchange with its `client_secret`.
///
/// `authorize()` suspends until step 6 completes, so the whole flow reads as one `await` at the
/// call site even though it crosses a process boundary. The one thing that `await` cannot survive
/// is that process being killed: a continuation is a point in *this* process's stack, and a
/// relaunched one has none. That case is not a lost authorization — `handleCallback(url:)` still
/// completes it and still **returns** the outcome — but it is the reason to use that return value
/// rather than relying on `authorize()` alone.
///
/// ## Why this is an actor
///
/// Refresh must be **single-flight**. Tracive's refresh tokens rotate, and re-presenting a rotated
/// token trips the server's reuse detection, which revokes the entire grant. Two concurrent
/// checks that both hit a 401 must therefore produce exactly *one* `POST /oauth/token`. The actor
/// makes the "is a refresh already running?" check-and-set atomic, and the stored `Task` is what
/// the second caller awaits instead of starting its own.
///
/// ## There is no API key here
///
/// Not in the authorize URL, not in the token request, not in the configuration. A public mobile
/// client cannot keep a secret, so it is given none.
public actor TraciveOAuth {

  // MARK: - Configuration

  public nonisolated let configuration: OAuthConfiguration
  public nonisolated let environment: TraciveEnvironment
  /// The Universal Link the Tracive app claims. Defaults per environment; overridable for a local
  /// consent harness.
  public nonisolated let authorizationEndpoint: URL
  /// The clean install link opened when Tracive is missing. Carries no OAuth parameters.
  ///
  /// Whatever was passed to `init(…, installURL:)`, verbatim, or the per-client default when that
  /// was `nil`. It can never be blank: the initialiser refuses a blank override rather than
  /// storing one — see there.
  public nonisolated let installURL: URL

  private let transport: any HTTPTransport
  private let tokenStore: any TraciveTokenStore
  private let appLauncher: any TraciveAppLauncher
  private let pkceGenerator: any PKCEGenerating
  private let clock: any TraciveClock

  // MARK: - Flow state

  /// The attempt currently waiting on a callback, as this process remembers it.
  ///
  /// A cache in front of `tokenStore`, not the record itself — the authoritative copy is the one in
  /// the store, which is what survives the host app being terminated during consent. This field is
  /// what makes the ordinary in-process case cost no Keychain read, and what keeps a custom
  /// `TraciveTokenStore` that does not implement `savePending(_:)` working exactly as before.
  private var pending: PendingAuthorization?
  /// Resumed by `handleCallback(url:)` so `authorize()` can return the final outcome.
  ///
  /// Deliberately **not** persisted, because it cannot be: a continuation is a resumption point
  /// inside this process's stack, and a relaunched process has no stack to resume into. A callback
  /// recovered after a termination therefore has nobody awaiting `authorize()`, and reaches the
  /// host app the other way `handleCallback(url:)` already offers — as its return value. See there.
  private var pendingContinuation: CheckedContinuation<AuthResult, Never>?
  /// The in-flight refresh, if any. This single stored value *is* the single-flight guarantee.
  private var refreshTask: Task<TraciveTokens, Error>?

  /// Bumped every time the grant is deliberately dropped (`signOut()`, `clearStoredTokens()`).
  ///
  /// Every write to `tokenStore` is conditional on the generation being unchanged since the
  /// operation started. Without this, a token round trip that was already in flight when the user
  /// signed out resumes afterwards and writes its result into a store that was just cleared,
  /// leaving a live — and freshly rotated — refresh token on the device.
  ///
  /// Cancelling `refreshTask` is not a substitute. Cancellation in Swift is cooperative: a custom
  /// `HTTPTransport` need not observe it, and a response already on the wire is delivered whatever
  /// the task's cancellation state. The generation check is not cooperative — it runs immediately
  /// before the write, on the actor, so no suspension can occur between the check and the write.
  private var tokenGeneration: UInt64 = 0

  // MARK: - Init

  /// - Parameters:
  ///   - transport: defaults to `URLSessionHTTPTransport`. Inject a fake in tests — the Open API
  ///     does not exist yet, so nothing in this SDK's test suite may touch a network.
  ///   - tokenStore: defaults to `KeychainTokenStore` keyed on the client id. `UserDefaults` and
  ///     plain files are forbidden for these credentials.
  ///   - appLauncher: defaults to `UIApplication` on iOS and to a launcher that reports "nothing is
  ///     installed" elsewhere, so `authorize()` degrades to `.appNotInstalled` on macOS rather than
  ///     pretending.
  ///   - installURL: where a user without the Tracive app is sent. `nil` — and only `nil` — means
  ///     "no override", and selects the default clean install link for this client.
  ///
  ///     **A blank override is refused, not passed through and not silently replaced.** Supply a
  ///     whitespace-only URL and this initialiser throws `TraciveError` carrying the code
  ///     `blank_install_url`. Every Tracive SDK now applies the same rule with the same token.
  ///
  ///     This is **not** URL validation. Any non-blank value is used exactly as given, however
  ///     unlikely it looks — a scheme no phone can open, a bare word, a link with whitespace
  ///     around it. The SDK is in no position to judge whether an enterprise distribution host or
  ///     a partner's own shortener is a sensible install link, and refusing one that works is a
  ///     worse failure than accepting one that does not.
  ///
  ///     Blankness is the exception because of what a blank actually becomes downstream. It is
  ///     never a considered choice — it is an unread environment variable or an empty build
  ///     setting — and it produces a string no operating system will open, which is neither the
  ///     default nor the partner's link. Whatever the SDK does with it, the only signal reaches
  ///     the partner much later and only for a user who does *not* have Tracive installed: the
  ///     rarest path in the flow, and the one nobody is watching. Refusing here fails once, in the
  ///     host app's own code, on every run, during development, before an end user is involved.
  ///
  ///     Note the trap the `URL?` type sets: `URL(string:)` answers `nil` for an empty string, so
  ///     funnelling an unvalidated configuration value straight through it hands this initialiser a
  ///     `nil` that is indistinguishable from passing nothing — and that does get the default. Only
  ///     the call site can tell those apart, so check the string before converting it if the
  ///     distinction matters to you. Whitespace is what does survive the conversion, and it is what
  ///     this rule catches.
  ///
  /// - Throws: `TraciveError` with the code `blank_install_url` when `installURL` is non-`nil` and
  ///   blank. Nothing else here can fail.
  public init(
    configuration: OAuthConfiguration,
    environment: TraciveEnvironment = .production,
    transport: (any HTTPTransport)? = nil,
    tokenStore: (any TraciveTokenStore)? = nil,
    appLauncher: (any TraciveAppLauncher)? = nil,
    pkceGenerator: (any PKCEGenerating)? = nil,
    clock: (any TraciveClock)? = nil,
    authorizationEndpoint: URL? = nil,
    installURL: URL? = nil
  ) throws {
    self.init(
      configuration: configuration,
      environment: environment,
      transport: transport,
      tokenStore: tokenStore,
      appLauncher: appLauncher,
      pkceGenerator: pkceGenerator,
      clock: clock,
      authorizationEndpoint: authorizationEndpoint,
      // Resolved before delegation so the only failure this initialiser has happens before any
      // stored property exists.
      resolvedInstallURL: try Self.resolveInstallURL(
        override: installURL,
        clientId: configuration.clientId
      )
    )
  }

  /// The driver `TraciveClient` builds when the host app supplies none.
  ///
  /// Deliberately a factory rather than the public initialiser: that one throws, and the only thing
  /// that can make it throw is a blank `installURL` override. This path supplies no override at
  /// all, so it cannot fail — which is what keeps `TraciveClient.init` non-throwing for the
  /// overwhelming majority of integrators, who never name this parameter.
  static func withDefaultInstallURL(
    configuration: OAuthConfiguration,
    environment: TraciveEnvironment,
    transport: (any HTTPTransport)?,
    tokenStore: (any TraciveTokenStore)?,
    clock: (any TraciveClock)?
  ) -> TraciveOAuth {
    TraciveOAuth(
      configuration: configuration,
      environment: environment,
      transport: transport,
      tokenStore: tokenStore,
      appLauncher: nil,
      pkceGenerator: nil,
      clock: clock,
      authorizationEndpoint: nil,
      resolvedInstallURL: TraciveAppPresence.installURL(clientId: configuration.clientId)
    )
  }

  /// The one initialiser that actually stores anything. `resolvedInstallURL` has already been
  /// checked, so this cannot fail and every construction path funnels through it.
  private init(
    configuration: OAuthConfiguration,
    environment: TraciveEnvironment,
    transport: (any HTTPTransport)?,
    tokenStore: (any TraciveTokenStore)?,
    appLauncher: (any TraciveAppLauncher)?,
    pkceGenerator: (any PKCEGenerating)?,
    clock: (any TraciveClock)?,
    authorizationEndpoint: URL?,
    resolvedInstallURL: URL
  ) {
    self.configuration = configuration
    self.environment = environment
    self.transport = transport ?? URLSessionHTTPTransport()
    self.tokenStore = tokenStore ?? KeychainTokenStore(clientId: configuration.clientId)
    self.appLauncher = appLauncher ?? TraciveAppPresence.makeDefaultLauncher()
    self.pkceGenerator = pkceGenerator ?? SystemPKCEGenerator()
    self.clock = clock ?? TraciveSystemClock()
    self.authorizationEndpoint =
      authorizationEndpoint ?? AuthorizeURLBuilder.defaultEndpoint(for: environment)
    self.installURL = resolvedInstallURL
  }

  /// Applies the shared rule: absent takes the default, blank is refused, anything else is kept
  /// byte for byte.
  private static func resolveInstallURL(override: URL?, clientId: String) throws -> URL {
    guard let override else {
      return TraciveAppPresence.installURL(clientId: clientId)
    }
    guard !isBlank(override) else {
      throw TraciveError.sdk(
        "blank_install_url",
        "The installURL override is blank. Pass nil to use Tracive's own install link, or a real "
          + "link of your own."
      )
    }
    return override
  }

  /// Whether a `URL` carries no meaningful content at all.
  ///
  /// The percent-decode is not decoration. `URL` encodes whitespace on the way in, so
  /// `URL(string: "   ")` has the `absoluteString` `"%20%20%20"` — nine characters, none of them
  /// whitespace, which `trimmingCharacters` would call perfectly non-blank. Trimming the raw string
  /// would therefore accept every blank this rule exists to catch. The string is what gets
  /// inspected rather than any of `URL`'s components, because a whitespace-only URL has no scheme,
  /// no host and no path to look at.
  private static func isBlank(_ url: URL) -> Bool {
    let raw = url.absoluteString
    // A malformed escape sequence makes `removingPercentEncoding` answer `nil`; whatever that is,
    // it is not blank, so falling back to the raw string is the safe reading.
    let decoded = raw.removingPercentEncoding ?? raw
    return decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - State

  /// Whether a grant is stored. Not a liveness check — the server may have revoked it since.
  public var isAuthorized: Bool {
    storedTokens() != nil
  }

  /// The scopes the user actually consented to, which may be narrower than those requested.
  public var grantedScopes: [String] {
    storedTokens()?.scopes ?? []
  }

  /// The stored access token, or `nil` when there is no grant. Exposed for host apps that must
  /// attach the same bearer to their own backend call; treat it as a credential.
  public func currentAccessToken() -> String? {
    storedTokens()?.accessToken
  }

  // MARK: - Authorization

  /// Prepares an attempt: generates PKCE + `state`, records them, and returns the URL to open.
  ///
  /// `authorize()` calls this internally. It is public for a host app that wants to drive the
  /// launch itself (a custom presentation, a deferred hand-off) — but it does **not** perform the
  /// app-presence pre-check, so a caller using it directly owns step 2 of the flow above.
  ///
  /// Calling it discards any previously prepared attempt: only one `state` can be outstanding, or
  /// a stale callback could satisfy the check.
  ///
  /// The attempt is written to `tokenStore` here, **before** the URL this returns can be opened,
  /// which is what lets `handleCallback(url:)` finish a consent whose host app was terminated
  /// meanwhile. Persisting afterwards would leave the window this exists to close.
  @discardableResult
  public func makeAuthorizationRequest() throws -> AuthorizationRequest {
    let pkce = pkceGenerator.generate()
    let url = try AuthorizeURLBuilder.build(
      endpoint: authorizationEndpoint,
      configuration: configuration,
      pkce: pkce
    )
    let attempt = PendingAuthorization(
      state: pkce.state,
      codeVerifier: pkce.codeVerifier,
      redirectUri: configuration.redirectUri.absoluteString,
      createdAt: clock.now
    )
    pending = attempt
    // Best effort, and deliberately so. The store is the *recovery* copy; `pending` above is what
    // the ordinary flow runs on. Throwing here because the Keychain was momentarily unavailable
    // would turn a degraded recovery into an authorization the user cannot start at all, which is
    // the worse failure of the two — a store that cannot be written simply behaves as it did
    // before this record existed.
    try? tokenStore.savePending(attempt)
    return AuthorizationRequest(
      url: url,
      state: pkce.state,
      codeVerifier: pkce.codeVerifier,
      codeChallenge: pkce.codeChallenge
    )
  }

  /// Runs the whole consent flow and returns its outcome.
  ///
  /// Returns `.appNotInstalled` immediately when Tracive is missing — the install link is opened
  /// and nothing else happens. Otherwise it opens the authorize Universal Link and **suspends until
  /// `handleCallback(url:)` is called** with the redirect, which the host app forwards from its
  /// `AppDelegate`/`SceneDelegate`.
  ///
  /// If the user abandons the flow the suspension never ends on its own; call
  /// `cancelPendingAuthorization()` (for example when the partner screen is dismissed) to unblock
  /// it. Starting a second `authorize()` also releases the first.
  ///
  /// If the host app is **terminated** while the user is consenting, this `await` is gone with the
  /// process and nothing can resume it. The authorization itself is not lost: the attempt was
  /// persisted before the launch, and the relaunched process completes it through
  /// `handleCallback(url:)`, whose return value is where the outcome arrives in that case.
  public func authorize() async -> AuthResult {
    // Never leave an earlier caller suspended forever.
    resumePending(with: .failed(.sdk("authorization_superseded", "A newer authorize() replaced this attempt.")))

    // Step 2: pre-check *before* any redirect. Getting this wrong sends users carrying live
    // consent parameters to a browser fallback page.
    let probe = TraciveAppPresence.probeURL(for: environment)
    guard await appLauncher.canOpen(probe) else {
      forgetPendingAuthorization()
      // Step 3: the clean install link, with no OAuth parameter on it whatsoever.
      _ = await appLauncher.open(installURL)
      return .appNotInstalled
    }

    let request: AuthorizationRequest
    do {
      request = try makeAuthorizationRequest()
    } catch let error as TraciveError {
      return .failed(error)
    } catch {
      return .failed(.sdk("authorization_request_failed", "Could not build the authorize URL."))
    }

    // The continuation is installed **before** the launch, not after it.
    //
    // Opening the URL is an `await`, and the actor is free for its duration. A `handleCallback(url:)`
    // arriving in that window would find `pending` set, validate `state`, complete the exchange,
    // store the grant and call `resumePending(...)` — which would return early, because the
    // continuation did not exist yet. `authorize()` would then install a continuation nobody could
    // ever resume: the app authorized, the tokens stored, and the caller's `await` suspended
    // forever behind a spinner.
    //
    // Installing first closes the window: from here on there is always someone to resume, whether
    // the callback wins or the launch does.
    return await withCheckedContinuation { continuation in
      pendingContinuation = continuation
      // This `Task` inherits the actor's isolation, so `abandonAttempt` needs no hop — but the
      // `await` on `open` still releases the actor, which is exactly what lets a callback run.
      Task { [self] in
        guard await appLauncher.open(request.url) else {
          abandonAttempt(withState: request.state)
          return
        }
      }
    }
  }

  /// Fails the attempt identified by `state`, if it is still the outstanding one.
  ///
  /// The state check is what makes this safe to call from the detached launch task. By the time a
  /// refused `open` reports back, the slot may already belong to somebody else — a newer
  /// `authorize()`, or a callback that already consumed this attempt — and clearing `pending`
  /// unconditionally would cancel their flow instead of ours. In both of those cases our own
  /// continuation has already been resumed by whoever took the slot, so there is nothing stranded.
  private func abandonAttempt(withState state: String) {
    guard pending?.state == state else { return }
    forgetPendingAuthorization()
    resumePending(
      with: .failed(.sdk("app_launch_failed", "The system declined to open the authorize link."))
    )
  }

  /// Completes the flow from the redirect URL (steps 5–6).
  ///
  /// Call this from `application(_:open:options:)` or
  /// `scene(_:openURLContexts:)` / `scene(_:continue:)`. The result is both returned and delivered
  /// to whoever is awaiting `authorize()`, so either style works.
  ///
  /// **Use the return value.** It is the only channel that works when the host app was terminated
  /// while the user was consenting — a common fate for a backgrounded app, and the case the
  /// persisted attempt exists for. The relaunched process rebuilds this actor, finds the attempt in
  /// `tokenStore`, and completes the exchange exactly as if nothing had happened; but there is no
  /// suspended `authorize()` left anywhere to resume, so the outcome arrives here and nowhere else.
  /// A host app that discards it will store a perfectly good grant and never notice it did.
  ///
  /// The attempt is expired before anything is read from the URL, and the `state` check runs
  /// **before** the rest — including the `error` parameter: a callback whose state does not match
  /// ours is not ours, and reading its contents at all would be acting on an attacker-supplied URL.
  @discardableResult
  public func handleCallback(url: URL) async -> AuthResult {
    // In-memory first, store second. The store is only consulted when this process has no memory of
    // an attempt, which is exactly the post-termination case.
    guard let attempt = pending ?? storedPendingAuthorization() else {
      // Nothing outstanding: a replayed, late or forged callback. There is no state to compare
      // against, so it fails the same way a mismatch does.
      return finish(.failed(.stateMismatch))
    }

    if attempt.isStale(at: clock.now) {
      // Checked before `state`, so an attempt nobody ever came back to is collected rather than
      // left in the Keychain until something happens to dislodge it. Reported with its own code
      // rather than as `.stateMismatch`: this one means "start again", not "somebody may be
      // attacking you", and a partner should be able to tell those apart.
      forgetPendingAuthorization()
      return finish(
        .failed(
          .sdk(
            "authorization_expired",
            "The authorization attempt is older than \(Int(PendingAuthorization.maxAge / 60)) "
              + "minutes and can no longer be completed. Start it again."
          )
        )
      )
    }

    let parameters = Self.queryParameters(of: url)

    guard let state = parameters["state"], traciveConstantTimeEquals(state, attempt.state) else {
      // The record is deliberately **not** cleared here, and this is the one terminal-looking
      // outcome that must not clear it. Any app on the device can hand the host app a URL, so
      // clearing on a mismatch would let a stray or hostile redirect cancel the consent the user is
      // in the middle of — a denial of service that costs an attacker one `open`. Nothing is spent
      // by a mismatch, so nothing needs consuming: a genuinely abandoned attempt is collected by
      // the expiry above instead, and a spent one was cleared by whichever branch spent it.
      return finish(.failed(.stateMismatch))
    }

    // One callback per attempt: consume the material now so a replay cannot re-enter.
    forgetPendingAuthorization()

    if let errorCode = parameters["error"] {
      if errorCode == "access_denied" {
        return finish(.denied)
      }
      return finish(
        .failed(
          TraciveError.from(
            status: 400,
            code: errorCode,
            message: parameters["error_description"]
          )
        )
      )
    }

    guard let code = parameters["code"], !code.isEmpty else {
      return finish(
        .failed(.sdk("invalid_callback", "The callback carried neither a code nor an error."))
      )
    }

    // A confidential client stops here by design: the exchange needs a `client_secret`, and
    // a mobile binary is not allowed to hold one. Nothing is stored locally.
    if configuration.clientType == .confidential {
      return finish(
        .codeReceived(
          code: code,
          codeVerifier: attempt.codeVerifier,
          redirectUri: attempt.redirectUri
        )
      )
    }

    do {
      let generation = tokenGeneration
      let tokens = try await exchange(
        code: code,
        codeVerifier: attempt.codeVerifier,
        redirectUri: attempt.redirectUri
      )

      // Same race as the one `performRefresh` guards: the code exchange is a round trip, and a
      // `signOut()` during it must win. Storing here would hand the user a live grant they never
      // finished asking for.
      guard generation == tokenGeneration else {
        return finish(
          .failed(.sdk("authorization_cancelled", "Signed out while the authorization was completing."))
        )
      }

      do {
        try tokenStore.save(tokens)
      } catch {
        // Reporting `.authorized` after failing to persist would hand back a grant that silently
        // evaporates on relaunch. Fail loudly instead.
        return finish(
          .failed(.sdk("token_storage_failed", "The grant could not be stored securely."))
        )
      }
      return finish(.authorized(grantedScopes: tokens.scopes))
    } catch let error as TraciveError {
      return finish(.failed(error))
    } catch {
      return finish(.failed(.network(cause: error)))
    }
  }

  /// Releases a suspended `authorize()` when the user backs out of the partner's screen.
  ///
  /// Reported as `.failed` with the code `authorization_cancelled`, not as `.denied`: `.denied` is
  /// the user refusing consent *inside Tracive*, and conflating the two would tell a partner its
  /// offer was rejected when the user merely tapped Back.
  public func cancelPendingAuthorization() {
    forgetPendingAuthorization()
    resumePending(
      with: .failed(.sdk("authorization_cancelled", "The authorization attempt was cancelled."))
    )
  }

  // MARK: - Tokens

  /// The access token to put in `Authorization: Bearer …`.
  ///
  /// Throws `.invalidToken` with the code `no_grant` when nothing is stored — the host app should
  /// send the user through `authorize()`.
  ///
  /// This deliberately does **not** refresh pre-emptively on a locally-computed expiry. The SDK puts
  /// refresh on the 401 `expired_token` response, and the server's clock is the one that decides:
  /// refreshing off a device clock that has drifted forward would burn a refresh-token rotation
  /// (and edge the grant closer to reuse detection) for nothing.
  ///
  /// The one condition it does check is a stored access token that is **blank**, which is not the
  /// same state as no grant at all. `TraciveTokens.accessToken` is a plain `String`, so a stored
  /// record whose `access_token` is the empty string decodes perfectly cleanly to `""` — a partial
  /// write, a Keychain save interrupted by a termination, or a restored backup can all leave one
  /// behind. The refresh token sitting beside it is untouched, and a refresh token *is* the grant:
  /// discarding it because a different field is empty throws away a credential that still works.
  /// So a blank access token is refreshed rather than sent, and the fresh token is returned.
  ///
  /// The reactive 401 path cannot rescue this record, which is why the check is here rather than
  /// left to the server. `Bearer ` is not an expired token, it is a malformed one: the server
  /// answers `invalid_token`, and this SDK treats that as terminal — no refresh is attempted and
  /// the grant is discarded. The damaged record would therefore not heal on the next request; it
  /// would fail permanently, one wasted round trip at a time.
  ///
  /// With no refresh token beside it there is nothing to renew with, and that case is answered
  /// **here** rather than delegated: it throws `.invalidToken` with the code `unusable_grant`,
  /// sends nothing, and leaves the record exactly as it found it.
  ///
  /// It is not `.grantRevoked`, and the distinction is a matter of fact rather than of taste.
  /// `.grantRevoked` means the server revoked the grant, which is a real event with a real cause —
  /// usually reuse detection — and it is worth a partner's alert. Nothing is sent on this path and
  /// nothing is rejected on it: one field of a local record is empty and there is no credential
  /// left to spend. Reporting a revocation here fires that alert for a damaged file on a single
  /// device and sends whoever answers it looking for a server-side event that never happened.
  /// `.invalidToken` is the honest answer and the one the Kotlin, Flutter and React Native SDKs
  /// already give.
  ///
  /// The code is `unusable_grant` rather than `no_grant` because the two states want different
  /// things looked at: `no_grant` is a user who has not authorized, and this is local storage that
  /// kept half a grant. Both are terminal for the caller, and the remedy for both is `authorize()`.
  ///
  /// Nothing is erased, which is the other half of the correction. The old shape cleared the record
  /// as a side effect of routing through `refreshTokens(…)`, so a second call answered `no_grant`
  /// and a partner debugging the first report found a store that no longer held what the report was
  /// about. Reading a damaged record is not a reason to delete it: no sibling SDK deletes it, and
  /// nothing was spent here that needs consuming. `clearStoredTokens()` and `signOut()` remain the
  /// ways a grant is dropped, both of them deliberate.
  ///
  /// Ordinary calls pay one `isEmpty` for this and nothing else.
  ///
  /// The `async` belongs to the refresh. It costs external callers nothing: every call into an
  /// actor from outside it is already awaited, whatever effects the method itself declares.
  public func accessToken() async throws -> String {
    guard let tokens = storedTokens() else {
      throw TraciveError.invalidToken(
        TraciveErrorInfo(
          code: "no_grant",
          message: "No Tracive grant is stored. Call authorize() first."
        )
      )
    }
    guard tokens.accessToken.isEmpty else { return tokens.accessToken }
    // The same test `refreshTokens(…)` applies, deliberately: an empty-string refresh token is as
    // unrenewable as an absent one, and checking only for `nil` here would hand that record on to
    // be reported as a revocation nobody performed.
    guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
      throw TraciveError.invalidToken(
        TraciveErrorInfo(
          code: "unusable_grant",
          message: "The stored Tracive grant has a blank access token and no refresh token to "
            + "renew it with. Call authorize() again."
        )
      )
    }
    // Routed through the ordinary refresh rather than a private one, so this inherits the
    // single-flight guarantee: a blank access token discovered while a refresh is already running
    // waits for that one instead of starting a second, which is exactly what reuse detection
    // punishes. Passing the blank token as the stale one also keeps the cheap half of the
    // guarantee working — if another caller has already refreshed, its token is returned here with
    // no round trip at all.
    return try await refreshTokens(staleAccessToken: tokens.accessToken)
  }

  /// Refreshes the access token, **single-flight**.
  ///
  /// - Parameter staleAccessToken: the token whose use produced the 401. If the stored token has
  ///   already moved on, some other caller refreshed while this one was in flight and the fresh
  ///   token is returned without a second round trip. This is the cheap half of the guarantee; the
  ///   shared `Task` is the other half, for callers that raced with the *same* stale token.
  ///
  /// A refresh rejected with `invalid_grant` or `grant_revoked` clears the stored tokens and
  /// surfaces `.grantRevoked`. That is not retryable and must not be retried: the usual cause is
  /// the server's reuse detection having already killed the grant.
  @discardableResult
  public func refreshTokens(staleAccessToken: String? = nil) async throws -> String {
    if let staleAccessToken, let current = storedTokens(), current.accessToken != staleAccessToken {
      return current.accessToken
    }

    if let inFlight = refreshTask {
      return try await inFlight.value.accessToken
    }

    guard let stored = storedTokens() else {
      throw TraciveError.invalidToken(
        TraciveErrorInfo(
          code: "no_grant",
          message: "No Tracive grant is stored. Call authorize() first."
        )
      )
    }
    guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
      // An access token with no refresh token cannot be renewed; the grant is over.
      //
      // This branch answers for a token the server has already rejected — a 401 brought the caller
      // here — so a grant that cannot be renewed really is finished, and clearing it is right.
      // `accessToken()` no longer arrives here: on that path nothing has been sent and nothing
      // rejected, so it answers `.invalidToken` itself and keeps the record. See there.
      try? tokenStore.clear()
      throw TraciveError.grantRevoked(
        TraciveErrorInfo(
          code: "grant_revoked",
          message: "The stored grant has no refresh token."
        )
      )
    }

    // Check-and-set with no `await` between them: the actor cannot interleave here, so a second
    // caller either sees `refreshTask` above or is short-circuited by the token comparison.
    let generation = tokenGeneration
    let task = Task<TraciveTokens, Error> { [self] in
      defer { clearRefreshTask() }
      return try await performRefresh(
        previous: stored,
        refreshToken: refreshToken,
        generation: generation
      )
    }
    refreshTask = task
    return try await task.value.accessToken
  }

  /// Drops the stored grant without contacting the server.
  ///
  /// Called on a 401 `grant_revoked`: the tokens are already dead server-side, so keeping them only
  /// guarantees more failed calls.
  public func clearStoredTokens() {
    tokenGeneration &+= 1
    pending = nil
    try? tokenStore.clear()
  }

  /// Revokes the grant and forgets it locally.
  ///
  /// `POST /v1/oauth/revoke` is **best effort** — offline, 500, or a refused revoke all still clear
  /// local state. A sign-out that leaves a token on the device because the network was down is the
  /// worse failure of the two.
  ///
  /// Scope note: this clears the *grant*, not the check cache. `TraciveOAuth` does not own the
  /// cache and cannot reach it. See `TraciveClient.signOut()` for why the caller must clear it
  /// separately on a shared device.
  public func signOut() async {
    let tokens = storedTokens()

    // Everything that invalidates the grant happens *before* the first suspension point, with no
    // `await` in between, so no in-flight work can interleave and observe a half-done sign-out:
    // the generation bump makes any token write already in flight a no-op, and the store is empty
    // from here on even if the revoke round trip below hangs, fails, or the process is killed
    // during it. Clearing after the revoke instead would leave a live grant on disk for the whole
    // duration of a network call.
    tokenGeneration &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    // `tokenStore.clear()` erases the persisted attempt as well as the tokens, so a verifier cannot
    // outlive a sign-out; this drops the in-memory copy in the same breath.
    pending = nil
    try? tokenStore.clear()

    if let refreshToken = tokens?.refreshToken, !refreshToken.isEmpty {
      let body = FormURLEncoding.encode([
        (name: "token", value: refreshToken),
        (name: "token_type_hint", value: "refresh_token"),
        (name: "client_id", value: configuration.clientId),
      ])
      let request = HTTPRequest(
        method: .post,
        url: TraciveAPI.url(TraciveAPI.oauthRevoke, in: environment),
        headers: [
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json",
        ],
        body: body
      )
      _ = try? await transport.send(request)
    }

    resumePending(
      with: .failed(.sdk("authorization_cancelled", "Signed out while an authorization was pending."))
    )
  }

  // MARK: - Wire

  /// - Parameter redirectUri: taken from the pending record rather than from `configuration`,
  ///   because RFC 6749 §4.1.3 requires the exchange to repeat the URI the authorization was
  ///   *started* with, and a relaunched process could in principle be configured with another one.
  private func exchange(
    code: String,
    codeVerifier: String,
    redirectUri: String
  ) async throws -> TraciveTokens {
    // No `client_secret`: this is a public client, and PKCE is what replaces it.
    let body = FormURLEncoding.encode([
      (name: "grant_type", value: "authorization_code"),
      (name: "code", value: code),
      (name: "redirect_uri", value: redirectUri),
      (name: "client_id", value: configuration.clientId),
      (name: "code_verifier", value: codeVerifier),
    ])
    return try await postToken(body: body, issuedAt: clock.now)
  }

  private func performRefresh(
    previous: TraciveTokens,
    refreshToken: String,
    generation: UInt64
  ) async throws -> TraciveTokens {
    let body = FormURLEncoding.encode([
      (name: "grant_type", value: "refresh_token"),
      (name: "refresh_token", value: refreshToken),
      (name: "client_id", value: configuration.clientId),
    ])

    let refreshed: TraciveTokens
    do {
      refreshed = try await postToken(body: body, issuedAt: clock.now)
    } catch let error as TraciveError {
      // `invalid_grant` on a refresh means the refresh token is dead — expired, already rotated, or
      // killed by reuse detection. Either way the grant is gone; holding the tokens would only
      // produce more failures and more suspicious-looking traffic.
      let code = error.serverCode
      if code == "invalid_grant" || code == "grant_revoked" {
        try? tokenStore.clear()
        throw TraciveError.grantRevoked(
          TraciveErrorInfo(
            code: "grant_revoked",
            message: error.info?.message ?? "The refresh token was rejected."
          )
        )
      }
      throw error
    }

    // The grant may have been dropped while this round trip was in flight. Writing now would undo
    // a sign-out the user was already told had succeeded, and would leave the *rotated* refresh
    // token — the newest and longest-lived one — sitting on a device the user believes is signed
    // out. Fail the refresh instead; the stale token in `refreshed` is simply abandoned, which is
    // what the server's own rotation already assumes for an unused token.
    guard generation == tokenGeneration else {
      throw TraciveError.grantRevoked(
        TraciveErrorInfo(
          code: "grant_revoked",
          message: "The grant was dropped while the refresh was in flight."
        )
      )
    }

    // Rotation: replace the stored pair in one write so a crash cannot leave the old refresh token
    // behind to be replayed later.
    let merged = previous.replacing(with: refreshed)
    try tokenStore.save(merged)
    return merged
  }

  private func postToken(body: Data, issuedAt now: Date) async throws -> TraciveTokens {
    let request = HTTPRequest(
      method: .post,
      url: TraciveAPI.url(TraciveAPI.oauthToken, in: environment),
      headers: [
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
      ],
      body: body
    )

    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch let error as TraciveError {
      throw error
    } catch {
      throw TraciveError.network(cause: error)
    }

    let decoded = try TraciveResponseMapper.decode(
      OAuthTokenResponse.self,
      from: response,
      now: now
    )
    return decoded.tokens(issuedAt: now)
  }

  // MARK: - Helpers

  private func storedTokens() -> TraciveTokens? {
    (try? tokenStore.load()) ?? nil
  }

  /// The attempt this SDK persisted before the last launch, if the store kept one.
  ///
  /// A read failure reads as "no attempt". There is nothing better to do with it: the alternative
  /// outcome is the same dead flow, reported as a Keychain error the partner cannot act on.
  private func storedPendingAuthorization() -> PendingAuthorization? {
    (try? tokenStore.loadPending()) ?? nil
  }

  /// Drops the attempt from both places it can live.
  ///
  /// Called on every outcome that spends or abandons an attempt, so neither a completed nor a
  /// walked-away-from consent leaves a usable `code_verifier` behind for a later callback to
  /// replay. The one exception is a `state` mismatch — see `handleCallback(url:)` for why clearing
  /// there would hand any app on the device a way to cancel a consent in progress.
  private func forgetPendingAuthorization() {
    pending = nil
    try? tokenStore.savePending(nil)
  }

  private func clearRefreshTask() {
    refreshTask = nil
  }

  /// Returns `result` and hands the same value to a suspended `authorize()`, if there is one.
  private func finish(_ result: AuthResult) -> AuthResult {
    resumePending(with: result)
    return result
  }

  private func resumePending(with result: AuthResult) {
    guard let continuation = pendingContinuation else { return }
    pendingContinuation = nil
    continuation.resume(returning: result)
  }

  /// Reads the callback's query parameters.
  ///
  /// Query only — the authorization-code flow puts `code`/`state` there, and reading a fragment
  /// would be accepting implicit-flow-shaped input the server never sends.
  private static func queryParameters(of url: URL) -> [String: String] {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
      return [:]
    }
    var parameters: [String: String] = [:]
    for item in items where parameters[item.name] == nil {
      parameters[item.name] = item.value ?? ""
    }
    return parameters
  }
}
