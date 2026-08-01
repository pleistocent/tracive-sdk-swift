import Foundation

/// The SDK's entry point.
///
/// ```swift
/// let tracive = TraciveClient(
///   mode: .oauth(
///     clientId: "bca-mobile",
///     redirectUri: URL(string: "https://app.bca.co.id/tracive")!,
///     scopes: ["scammer.check", "credits.read"],
///     partnerUserId: partnerCustomerHash
///   ),
///   cache: try? SQLiteCheckCache()
/// )
///
/// switch await tracive.authorize() {
/// case .authorized: break
/// case .appNotInstalled: showInstallPrompt()
/// default: return
/// }
///
/// let result = try await tracive.checkScammer(
///   .bankAccount(countryAlpha3: "IDN", bankCode: "BCA", account: "1234567890")
/// )
/// ```
///
/// ## Three things to know before integrating
///
/// 1. **The backend does not exist yet.** There is no live `/v1/*` route in
///    the Tracive API. Everything here is written against the documented
///    contract and verified against an injected fake transport; no test in this package opens a
///    socket.
/// 2. **Every call is billed, including a miss**. That is why queries are validated locally
///    before a request goes out, why the cache exists, and why a 5xx is not blindly retried.
/// 3. **There is no API-key parameter, in any mode**. A mobile binary cannot keep a secret.
///
/// ## Do not poll `credits()`
///
/// The rule is explicit: do **not** call `credits()` before each check. Handle the 402 from
/// `checkScammer` instead — it saves one round trip per transaction, and a balance read a moment
/// earlier can be stale by the time the check lands anyway.
///
/// The type is an `actor`, but it never holds its executor across a network call, so several checks
/// can be in flight at once.
public actor TraciveClient {

  // MARK: - Configuration

  public nonisolated let mode: TraciveMode
  public nonisolated let environment: TraciveEnvironment
  /// The freshness rules this client was configured with.
  ///
  /// When a `cache` is injected, **its own `policy` is what actually governs reads** — freshness is
  /// decided inside the store (see `CheckCache`), which is what lets a stale row be dropped on the
  /// way past. This property is the configured value and is used to build the default cache.
  public nonisolated let cachePolicy: CachePolicy
  /// The `source` used when a call does not name one.
  public nonisolated let defaultSource: Source
  public nonisolated let retryPolicy: RetryPolicy
  /// The local encrypted result cache. Backs `client.cache.clear()`.
  ///
  /// Never optional: `NoOpCheckCache` stands in when caching is off, so every path here can call
  /// the cache unconditionally instead of threading an optional through the check flow.
  public nonisolated let cache: any CheckCache
  /// Why the default cache could not be opened, when it could not.
  ///
  /// The SDK degrades to `NoOpCheckCache` rather than refusing to start — but silently paying for
  /// checks that should have been free is exactly the kind of expensive-and-quiet failure worth
  /// surfacing, so the reason is kept here instead of being swallowed. Log it at startup.
  public nonisolated let cacheInitializationError: (any Error)?
  /// The OAuth flow driver. `nil` in Proxy mode, which is phase 2.
  public nonisolated let oauth: TraciveOAuth?

  private let transport: any HTTPTransport
  private let clock: any TraciveClock

  // MARK: - Init

  /// - Parameters:
  ///   - mode: `.oauth(…)` today. `.proxy(…)` exists so adding it in phase 2 is not a breaking
  ///     change; every call in that mode throws `TraciveError.notImplemented`.
  ///   - cachePolicy: TTL rules. Used to build the default cache; ignored when `cache` is
  ///     supplied, since an injected store carries its own policy.
  ///   - transport: test seam. Defaults to `URLSessionHTTPTransport`.
  ///   - clock: test seam for TTL and backoff. Defaults to wall time.
  ///   - cache: the encrypted result store. When omitted, an on-disk `SQLiteCheckCache` is opened
  ///     if the policy is enabled, falling back to `NoOpCheckCache` (and recording
  ///     `cacheInitializationError`) if that fails. **Tests should always pass one explicitly** —
  ///     the default touches Application Support and the Keychain.
  ///
  /// ## This initialiser does blocking I/O
  ///
  /// When no `cache` is injected and caching is enabled, `init` synchronously opens (and on first
  /// run creates) the SQLite file in Application Support, configures and migrates it, and runs a
  /// prune pass. The first cache access after that reaches the Keychain and, on a device that has
  /// one, the Secure Enclave.
  ///
  /// All of it happens on whichever thread calls `init`. The guidance to build the client once at
  /// app start usually means the main thread in a SwiftUI or `AppDelegate` context, so on a cold
  /// launch — an empty database, a Keychain item that does not exist yet, an Enclave key still to
  /// be generated — this is real work in front of the first frame.
  ///
  /// If that matters for your launch budget, construct the client off the main thread and hand it
  /// to your UI once it is ready, or pass a `cache` you built yourself at a moment of your
  /// choosing. Passing `cachePolicy: .disabled` also avoids it, at the cost of paying for every
  /// repeat check.
  ///   - tokenStore: where OAuth tokens live. Defaults to the Keychain. Ignored if `oauth` is
  ///     supplied.
  ///   - oauth: a pre-built OAuth driver, for a host app that needs a custom app launcher or a
  ///     non-default authorize endpoint. When present it wins over `tokenStore`.
  public init(
    mode: TraciveMode,
    environment: TraciveEnvironment = .production,
    cachePolicy: CachePolicy = .default,
    defaultSource: Source = .cacheFirst,
    transport: (any HTTPTransport)? = nil,
    clock: (any TraciveClock)? = nil,
    cache: (any CheckCache)? = nil,
    tokenStore: (any TraciveTokenStore)? = nil,
    retryPolicy: RetryPolicy = .default,
    oauth: TraciveOAuth? = nil
  ) {
    let resolvedTransport = transport ?? URLSessionHTTPTransport()
    let resolvedClock = clock ?? TraciveSystemClock()

    self.mode = mode
    self.environment = environment
    self.cachePolicy = cachePolicy
    self.defaultSource = defaultSource
    self.retryPolicy = retryPolicy
    self.transport = resolvedTransport
    self.clock = resolvedClock

    if let cache {
      self.cache = cache
      self.cacheInitializationError = nil
    } else if cachePolicy.isEnabled {
      let clockForCache = resolvedClock
      do {
        self.cache = try SQLiteCheckCache(
          policy: cachePolicy,
          now: { clockForCache.now }
        )
        self.cacheInitializationError = nil
      } catch {
        self.cache = NoOpCheckCache(policy: cachePolicy)
        self.cacheInitializationError = error
      }
    } else {
      self.cache = NoOpCheckCache(policy: cachePolicy)
      self.cacheInitializationError = nil
    }

    if let oauth {
      self.oauth = oauth
    } else if let oauthConfiguration = mode.oauthConfiguration {
      self.oauth = TraciveOAuth(
        configuration: oauthConfiguration,
        environment: environment,
        transport: resolvedTransport,
        tokenStore: tokenStore,
        clock: resolvedClock
      )
    } else {
      self.oauth = nil
    }
  }

  // MARK: - Checks

  /// Checks one identifier against Tracive's scammer index.
  ///
  /// - Parameters:
  ///   - query: a validated, folded key. Building it already rejected anything that could not hit,
  ///     which matters commercially: a miss is billed, so a key that can never hit is a wasted
  ///     credit.
  ///   - source: cache-versus-network strategy. `nil` uses `defaultSource`.
  ///   - detail: `.minimal` (default) or `.full`. `.full` adds `topChronologies` and `comments`,
  ///     needs a contractual rider server-side, and is **never** cached.
  ///
  ///     ⚠️ Because full detail is never cached *and* the cache key is the query alone, a `.full`
  ///     request on a cache-reading source (`.cacheFirst` — the default — or `.cache`) can be
  ///     answered from a stored minimal row, returning `comments` and `topChronologies` as `nil`
  ///     with no network call. **That `nil` means "not fetched", not "none on file",** and the two
  ///     are otherwise indistinguishable. Either pass `source: .server` when you need full detail,
  ///     or check `result.origin == .server` before treating those fields as authoritative. See
  ///     `Docs/caching.md`.
  ///   - locale: BCP-47. Only meaningful for `.full`; omitted from the request otherwise, because
  ///     `minimal` is always English and a stray field would change the payload behind an
  ///     `Idempotency-Key`.
  ///   - idempotencyKey: pass one if you intend to retry. **Without it the SDK will not retry** a
  ///     5xx, a 429 or a timeout, because it cannot tell whether the first attempt was charged
  ///. The same key is reused on every attempt, which is what lets the server deduplicate.
  ///
  ///     Note that the request always carries *some* `Idempotency-Key`: when you supply none the
  ///     SDK generates a per-call one, so that its own replay after a 401 token refresh can be
  ///     collapsed server-side. That does not give you a retry budget — only your own key does —
  ///     and it is not a substitute for passing a key derived from your transaction if you want
  ///     retries or cross-process deduplication.
  ///
  /// - Throws: `TraciveError`. Notable cases: `.cacheMiss` for `source == .cache` with no fresh
  ///   entry, `.insufficientCredits` for a 402 (handle it — do not pre-poll `credits()`),
  ///   `.notImplemented` in Proxy mode.
  public func checkScammer(
    _ query: TraciveQuery,
    source: Source? = nil,
    detail: Detail = .minimal,
    locale: String? = nil,
    idempotencyKey: String? = nil
  ) async throws -> CheckResult {
    try requireOAuthMode()

    let resolvedSource = source ?? defaultSource
    let key = CheckCacheKey(query: query)

    switch resolvedSource {
    case .cache:
      // Deliberately the throwing read: this is the one mode that has to tell a miss from a
      // storage fault. A miss becomes `.cacheMiss`; a fault surfaces as itself, because answering
      // "no reports" when the truth is "the disk is broken" would be a fabricated clean verdict —
      // the single worst thing a fraud SDK can do.
      let stored: CheckResult?
      do {
        stored = try cache.read(key)
      } catch let error as CheckCacheError {
        throw error.asTraciveError
      }
      guard let stored else { throw TraciveError.cacheMiss }
      return stored

    case .cacheFirst:
      if let hit = cache.readIgnoringFailures(key) { return hit }
      return try await fetchAndStore(
        query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key)

    case .server:
      return try await fetchAndStore(
        query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key)

    case .serverFirst:
      do {
        return try await fetchAndStore(
          query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key)
      } catch let error as TraciveError {
        // "Network first, fall back to cache when it fails" means a *transport-shaped*
        // failure — offline, 5xx, rate limited. A 402 or a 403 is a real answer about the caller's
        // account, and quietly serving a cached verdict instead would hide a billing or permission
        // problem until it became someone else's incident.
        guard error.isTransient, let hit = cache.readIgnoringFailures(key) else { throw error }
        return hit
      }
    }
  }

  /// `GET /v1/credits` — the user's remaining subscription credits.
  ///
  /// Read the warning on this type: do not call this before each check.
  public func credits() async throws -> CreditsInfo {
    try requireOAuthMode()
    let request = HTTPRequest(
      method: .get,
      url: TraciveAPI.url(TraciveAPI.credits, in: environment),
      headers: ["Accept": "application/json"]
    )
    // A GET has no side effects and cannot double-charge, so it is always retryable.
    let response = try await sendAuthorized(request, isRetryable: true)
    return try TraciveResponseMapper.decode(CreditsInfo.self, from: response, now: clock.now)
  }

  /// `GET /v1/profile` — the minimal profile behind the grant.
  ///
  /// `sub` is a pairwise pseudonymous id: different partners see different values for the same
  /// Tracive user, and the underlying account id never leaves the server.
  public func profile() async throws -> ProfileInfo {
    try requireOAuthMode()
    let request = HTTPRequest(
      method: .get,
      url: TraciveAPI.url(TraciveAPI.profile, in: environment),
      headers: ["Accept": "application/json"]
    )
    let response = try await sendAuthorized(request, isRetryable: true)
    return try TraciveResponseMapper.decode(ProfileInfo.self, from: response, now: clock.now)
  }

  // MARK: - Cache

  /// Empties the local result cache. Equivalent to `client.cache.clear()`.
  public func clearCache() throws {
    try cache.clear()
  }

  // MARK: - OAuth passthrough

  /// Runs the consent flow. See `TraciveOAuth.authorize()`.
  @discardableResult
  public func authorize() async -> AuthResult {
    guard let oauth else {
      return .failed(.proxyModeNotImplemented)
    }
    return await oauth.authorize()
  }

  /// Forwards the redirect from `AppDelegate`/`SceneDelegate`. See
  /// `TraciveOAuth.handleCallback(url:)`.
  @discardableResult
  public func handleCallback(url: URL) async -> AuthResult {
    guard let oauth else {
      return .failed(.proxyModeNotImplemented)
    }
    return await oauth.handleCallback(url: url)
  }

  /// Revokes the grant best-effort and clears local tokens regardless of the outcome.
  public func signOut() async {
    await oauth?.signOut()
  }

  /// Whether a grant is stored. Not a liveness check — the server may have revoked it since.
  public var isAuthorized: Bool {
    get async {
      guard let oauth else { return false }
      return await oauth.isAuthorized
    }
  }

  // MARK: - Internals

  private func requireOAuthMode() throws {
    // Proxy mode is phase 2. The type exists in the surface so adding it later is not a breaking
    // change; until then every call fails with the exact message the spec names.
    guard mode.oauthConfiguration != nil, oauth != nil else {
      throw TraciveError.proxyModeNotImplemented
    }
  }

  /// A per-call key for a check the caller did not key itself.
  ///
  /// Prefixed so a key the SDK invented is distinguishable from a partner's own in a server-side
  /// log — useful when reconciling a disputed charge. A v4 UUID is the right shape here: the key
  /// only has to be unique, never guessable or reproducible, and it must never be derived from the
  /// query, since that would collapse two deliberate re-checks of the same identifier into one.
  private static func generatedIdempotencyKey() -> String {
    "sdk-" + UUID().uuidString.lowercased()
  }

  private func fetchAndStore(
    _ query: TraciveQuery,
    detail: Detail,
    locale: String?,
    idempotencyKey: String?,
    key: CheckCacheKey
  ) async throws -> CheckResult {
    let body = ScammerCheckRequestBody(query: query, detail: detail, locale: locale)
    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(body)
    } catch {
      throw TraciveError.sdk("invalid_request_body", "The check request could not be encoded.")
    }

    let callerKey = idempotencyKey.flatMap { $0.isEmpty ? nil : $0 }

    // Every check carries an `Idempotency-Key`, whether the caller supplied one or not.
    //
    // The SDK re-sends this exact POST after a 401 refresh (see `sendAuthorized`). Without a key
    // the two attempts are indistinguishable to the server, so any billing that happens before or
    // during authorisation is charged twice, with no way for the caller to detect it. This code
    // used to justify that with "a 401 is rejected before billing" — an assumption about a server
    // that does not exist yet, and the one premise this SDK otherwise refuses to make anywhere.
    // Generating a key removes the need to assume anything.
    //
    // A generated key is *not* a licence to retry: `isRetryable` below still keys off the caller's
    // key, so a 5xx, a 429 or a timeout on an unkeyed check is still surfaced immediately, exactly
    // as README and SECURITY.md promise. The key only makes the SDK's own replay collapsible.
    let headers = [
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Idempotency-Key": callerKey ?? Self.generatedIdempotencyKey(),
    ]

    let request = HTTPRequest(
      method: .post,
      url: TraciveAPI.url(TraciveAPI.scammerChecks, in: environment),
      headers: headers,
      body: encoded
    )

    // The retry rule, applied at the only place it matters: a check may be repeated only when the
    // caller gave us a key that lets the server deduplicate the charge.
    let isRetryable = callerKey != nil
    let response = try await sendAuthorized(request, isRetryable: isRetryable)

    let decoded = try TraciveResponseMapper.decode(CheckResult.self, from: response, now: clock.now)
    // The server sends no provenance; stamp it here so `fetchedAt` is measured on the same clock
    // the TTL is measured on, rather than on whatever `CheckResult.init(from:)` defaulted to.
    let result = decoded.withOrigin(.server, fetchedAt: clock.now)

    // The store persists `cacheableCopy()` itself, dropping checkId/billing/chronologies/comments.
    // A failed write must never fail a check that already succeeded — it costs one credit next
    // time, nothing more.
    cache.writeIgnoringFailures(result, for: key)

    return result
  }

  /// Sends an authenticated request, handling the 401 refresh dance and the retry policy.
  ///
  /// - Parameter isRetryable: whether repeating this exact request is safe. `true` for GETs and for
  ///   a check carrying an `Idempotency-Key`; `false` otherwise, in which case a 5xx, a 429 or a
  ///   timeout is surfaced immediately rather than risking a second charge.
  private func sendAuthorized(
    _ request: HTTPRequest,
    isRetryable: Bool
  ) async throws -> HTTPResponse {
    guard let oauth else { throw TraciveError.proxyModeNotImplemented }

    var completedAttempts = 0
    var didRefresh = false

    while true {
      let token = try await oauth.accessToken()
      var authorized = request
      authorized.setHeader("Authorization", to: "Bearer " + token)

      let response: HTTPResponse
      do {
        response = try await transport.send(authorized)
        completedAttempts += 1
      } catch {
        completedAttempts += 1
        let mapped = (error as? TraciveError) ?? .network(cause: error)
        guard isRetryable, retryPolicy.allowsAnotherAttempt(after: completedAttempts) else {
          throw mapped
        }
        try await clock.sleep(for: retryPolicy.delay(forRetry: completedAttempts))
        continue
      }

      if response.status == 401 {
        let info = TraciveResponseMapper.errorInfo(from: response.body)
        switch info.code {
        case "grant_revoked":
          // Usually the server's refresh-token reuse detection firing. The grant is gone; keeping
          // the tokens would only produce more failures. Do not retry.
          await oauth.clearStoredTokens()
          throw TraciveError.grantRevoked(info)

        case "expired_token" where !didRefresh:
          didRefresh = true
          // Single-flight: concurrent 401s funnel into one `POST /oauth/token`. Getting this wrong
          // trips the server's reuse detection, which revokes the whole grant.
          _ = try await oauth.refreshTokens(staleAccessToken: token)
          // Re-send the identical request. It carries an `Idempotency-Key` — `fetchAndStore`
          // attaches one even when the caller did not — so if the first attempt was billed after
          // all, the server can collapse the two into a single charge. This replay deliberately
          // does not consume the retry budget: it is a re-authentication, not a retry of a failed
          // check.
          continue

        default:
          break
        }
      }

      let isTransientStatus = response.status >= 500 || response.status == 429
      if isTransientStatus, isRetryable, retryPolicy.allowsAnotherAttempt(after: completedAttempts)
      {
        let retryAfter = TraciveError.retryAfterSeconds(
          from: response.header("Retry-After"),
          now: clock.now
        )
        try await clock.sleep(
          for: retryPolicy.delay(forRetry: completedAttempts, retryAfter: retryAfter)
        )
        continue
      }

      return response
    }
  }
}
