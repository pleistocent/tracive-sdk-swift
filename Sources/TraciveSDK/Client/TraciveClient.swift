import Foundation

/// The SDK's entry point.
///
/// ```swift
/// let tracive = TraciveClient(
///   mode: .oauth(
///     clientId: "bca-mobile",
///     redirectUri: URL(string: "https://app.bca.co.id/tracive")!,
///     scopes: [TraciveScopes.scammerCheck, TraciveScopes.creditsRead],
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
/// 1. **Sandbox and production are separate registrations.** Each needs a client id issued for
///    it, with your redirect registered on that client. Everything here is verified against an
///    injected fake transport; no test in this package opens a socket.
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
/// can be in flight at once. Two overlapping checks asking the *same* question are the exception:
/// they share one request and therefore one charge. "The same question" is the identifier, the
/// detail level, the locale and your own idempotency key. See `latchedFetch`.
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
  /// The checks currently on the wire, keyed on the record key plus the detail level, the locale
  /// and the caller's own idempotency key when there is one. This one map *is* the single-flight
  /// guarantee for billable checks; `latchedFetch` says what it covers and what it deliberately
  /// does not.
  private var inFlightChecks: [String: Task<CheckResult, Error>] = [:]

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
      // `TraciveOAuth.init` throws on a blank `installURL` override, and there is no override to
      // be blank here — this client exposes no such parameter. The factory says so in the type
      // rather than in a comment, which is what keeps this initialiser non-throwing: an integrator
      // who never heard of install links cannot be made to write `try` by a rule about them.
      self.oauth = TraciveOAuth.withDefaultInstallURL(
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
  ///     A `.full` request neither reads nor writes the cache. `source` is interpreted accordingly:
  ///     `.cacheFirst` skips the cache read and calls the server, `.cache` raises `.cacheMiss`, and
  ///     `.serverFirst` surfaces the network error instead of falling back — and none of them
  ///     stores the response, because it carries locale-dependent text that the locale-less row key
  ///     cannot hold. The consequence for you: a `.full` result always has `origin == .server`, so
  ///     `comments == nil` means "none on file" and nothing else, and a `.full` check never warms
  ///     the cache for a later one. See `Docs/caching.md`.
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
  ///     Your key also keeps this check out of somebody else's shared flight: see below.
  ///
  /// ## Overlapping identical checks are billed once
  ///
  /// While a check for one identifier is on the wire, a second check for that same identifier at
  /// the same `detail` and `locale`, and carrying the same `idempotencyKey` — including the usual
  /// case of neither carrying one — joins it instead of sending a second request: both callers get
  /// the one answer, and the partner pays for it once. A different identifier, a different detail
  /// level, a different locale or a different caller-supplied key is a different question and goes
  /// out on its own. See `latchedFetch` for why the key is all four, and for what happens to a
  /// cancelled caller.
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

    // A full-detail request neither reads nor writes the cache. One flag, gating both directions
    // and the `.serverFirst` fallback, because the cache is wrong for `.full` in *both* directions
    // — for two different reasons that each independently produce silently wrong content.
    //
    // **Reading is wrong because of `detail`.** `cacheableCopy()` strips `topChronologies` and
    // `comments` on the way in, since the row key is the query alone. Stripping them is right.
    // Serving the stripped row back to a `.full` caller is not: the caller receives
    // `comments == nil`, which is byte-identical to "the server answered in full and there are no
    // incidents on file". That is a wrong fraud answer about an identifier that may have four of
    // them, and it is silent — nothing throws, nothing logs, and no request leaves the device.
    //
    // **Writing is wrong because of `locale`.** The same projection *keeps* `tags` and
    // `disclaimer`, and `CheckCacheKey` is `SHA-256(searchQueryIndex)` with no locale in it. Only a
    // `.full` request sends a `locale`, so storing its projection files locale-specific text under
    // a locale-less key, and the next `.minimal` caller — which sends no locale at all — reads it
    // back as if it were the default. `disclaimer` is the one string this SDK requires every
    // integrator to render, so that surfaces a legal notice in a language the user did not ask for.
    // Skipping only the read would not help: the poisoned row is written by the `.full` call and
    // collected by a later `.minimal` call that is reading the cache quite legitimately.
    //
    // `.minimal` routing is untouched in every respect. Kotlin and Flutter carry the same joint
    // rule, so the surface stays 1:1 across the three SDKs.
    let cacheApplies = detail != .full

    switch resolvedSource {
    case .cache:
      // Deliberately the throwing read: this is the one mode that has to tell a miss from a
      // storage fault. A miss becomes `.cacheMiss`; a fault surfaces as itself, because answering
      // "no reports" when the truth is "the disk is broken" would be a fabricated clean verdict —
      // the single worst thing a fraud SDK can do.
      //
      // A `.full` request is the same situation viewed from the other side: this source is
      // forbidden to call the network and the cache holds nothing that answers the question, so
      // the honest reply is the miss the caller already handles. A stored row is not a hit here.
      guard cacheApplies else { throw TraciveError.cacheMiss }
      let stored: CheckResult?
      do {
        stored = try cache.read(key)
      } catch let error as CheckCacheError {
        throw error.asTraciveError
      }
      guard let stored else { throw TraciveError.cacheMiss }
      return stored

    case .cacheFirst:
      if cacheApplies, let hit = cache.readIgnoringFailures(key) { return hit }
      return try await latchedFetch(
        query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key,
        cacheApplies: cacheApplies)

    case .server:
      return try await latchedFetch(
        query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key,
        cacheApplies: cacheApplies)

    case .serverFirst:
      do {
        return try await latchedFetch(
          query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key,
          cacheApplies: cacheApplies)
      } catch let error as TraciveError {
        // "Network first, fall back to cache when it fails" means a *transport-shaped*
        // failure — offline, 5xx, rate limited. A 402 or a 403 is a real answer about the caller's
        // account, and quietly serving a cached verdict instead would hide a billing or permission
        // problem until it became someone else's incident.
        //
        // Full detail is excluded for a different reason. Falling back is a trade of freshness for
        // an answer, and for `.minimal` that trade is sound — the risk tier is the same fact an
        // hour later. There is no stale version of narrative content, only a missing one that
        // renders as an empty one, so a `.full` request that fails on the network surfaces the
        // failure and lets the caller decide whether to retry, degrade the UI, or ask for
        // `.minimal` explicitly.
        guard cacheApplies, error.isTransient, let hit = cache.readIgnoringFailures(key) else {
          throw error
        }
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
  ///
  /// **Handle the returned `AuthResult` here, not only where `authorize()` was called.** If iOS
  /// terminated the app while the user was consenting — which it is entitled to do, because the app
  /// is backgrounded for the whole of that visit — the SDK still completes the authorization from
  /// its persisted record, but the `await` on `authorize()` died with the old process and this
  /// return value is the only place the outcome appears.
  ///
  /// Route every incoming deep link through here. A URL that is not this client's redirect, or that
  /// carries no OAuth parameter, answers `nil` and leaves everything untouched — including a consent
  /// the user is in the middle of.
  ///
  /// Proxy mode is the one non-`nil` refusal: it answers `.failed(.proxyModeNotImplemented)` rather
  /// than `nil`, because that is a fact about how this client was configured and not about the URL.
  @discardableResult
  public func handleCallback(url: URL) async -> AuthResult? {
    guard let oauth else {
      return .failed(.proxyModeNotImplemented)
    }
    return await oauth.handleCallback(url: url)
  }

  /// Revokes the grant best-effort, clears local tokens regardless of the outcome, and **empties
  /// the result cache**.
  ///
  /// The cache goes too, and that is not housekeeping. Its rows were fetched under the grant of the
  /// user who just signed out, and they are keyed by `SHA-256` of a phone number or an email
  /// address — a search space small enough to brute-force offline. Left in place, they let the next
  /// person on the device confirm which identifiers the previous one looked up. That is the
  /// departing user's search history, and sign-out is the moment they are entitled to expect it
  /// gone.
  ///
  /// ## Why this is the client's business, given that a cache can be shared
  ///
  /// `cache` is injectable, so two clients can be handed the same store, and clearing here empties
  /// rows the other one put there. That is the argument against, and it is a real one — it is why
  /// this used to be left to the caller.
  ///
  /// It loses on the shape of the two failures. Over-clearing costs money: the surviving client
  /// re-fetches and re-pays for checks it had already bought. That is bounded, visible in the
  /// billing, and recoverable by simply not sharing one store between clients. Under-clearing costs
  /// a privacy leak that nothing reports, on a device the SDK has no further contact with, for as
  /// long as the rows live. A default that fails silently in the expensive direction is the wrong
  /// default even when the loud one is occasionally wasteful.
  ///
  /// The sharing case is also weaker than it looks. `CheckCacheKey` carries no user and no client
  /// id, so a store shared by two clients is *already* serving one user's rows to another — sharing
  /// one is the thing that needs justifying, not clearing one. Give each client its own store if you
  /// want independent lifetimes.
  ///
  /// A caller who deliberately wants a warm cache to survive a re-login on a single-user device can
  /// keep the rows by not routing that flow through `signOut()` — call `oauth?.signOut()` directly,
  /// which drops the grant and touches nothing else.
  ///
  /// A failing `clear()` cannot fail the sign-out. The tokens are already gone by then, and refusing
  /// to sign a user out because SQLite would not open would be the worse of the two outcomes; the
  /// rows remain subject to `CachePolicy` expiry either way.
  ///
  /// Kotlin, Flutter and React Native clear on sign-out for the same reason.
  public func signOut() async {
    await oauth?.signOut()
    try? cache.clear()
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

  /// The key the *caller* supplied, or `nil` when they supplied none. A blank string is none.
  ///
  /// Three rules turn on this one answer — whether the check may be retried, which key goes on the
  /// wire, and whether the check may share a flight with another — so they read it from here rather
  /// than each re-deriving it. A caller passing `""` must not end up with a private latch that no
  /// other unkeyed caller can meet on.
  ///
  /// **Blank means whitespace-only, not merely empty**, and the difference is not cosmetic because
  /// of what each of those three rules then does with `"   "`. It earns a retry budget: the SDK
  /// cannot tell whether a repeated attempt was billed, so it retries only when the caller's own key
  /// gives the server something to deduplicate the charge on, and three spaces gives it nothing. It
  /// takes a latch of its own, which no ordinary unkeyed check can meet on, so two overlapping
  /// checks of one identifier become two requests and two charges. And `Idempotency-Key:    ` goes
  /// on the wire in place of the generated key that would otherwise let the SDK's own post-refresh
  /// replay collapse.
  ///
  /// A blank key is never a considered choice — it is an unread configuration value, or an empty
  /// field arriving where a transaction id was meant to be — so reading it as "no key" is what the
  /// caller meant in every case where it occurs. Kotlin tests blankness and Flutter trims; this was
  /// the only one of the four SDKs still testing emptiness.
  ///
  /// A key that is **not** blank is passed through byte for byte, surrounding whitespace included.
  /// Only this SDK's reading of "is there a key here at all" changes: the string the caller chose is
  /// what the server deduplicates on and what the partner has recorded against the transaction, so
  /// quietly sending a trimmed version of it would be answering a different question than the one
  /// that was asked.
  private static func callerIdempotencyKey(_ supplied: String?) -> String? {
    supplied.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
  }

  /// Runs `fetchAndStore` **single-flight**, because here the unit is currency.
  ///
  /// Two overlapping checks for the same identifier both read the cache, both missed, both POSTed
  /// and both were charged: the cache write is the only serialisation point in the flow and it
  /// happens after both requests have already left the device. A double-tapped button, or a list
  /// screen rendering the same identifier in two cells, doubled the bill — silently, because two
  /// correct answers arrive and nothing anywhere reports that one of them was paid for twice.
  /// `TraciveOAuth.refreshTokens` has had the right shape all along; this is the same latch in the
  /// one place where the cost of missing it is money rather than latency.
  ///
  /// **The key is the record key plus the detail level, the locale, and the caller's own
  /// idempotency key when there is one** — not the record key alone. A `.minimal` result must never
  /// be handed to a caller who asked for `.full` — it carries no `topChronologies` and no
  /// `comments`, which reads as "the server answered in full and there is nothing on file" — and a
  /// `.full` answer in one language must never satisfy a request for another, since `tags` and
  /// `disclaimer` come back in the language that was asked for. Only a `.full` request sends a
  /// locale, so the empty string stands for "none sent" and cannot collide with a real BCP-47 tag.
  ///
  /// The caller's key is in there because supplying one is a statement of intent, and collapsing
  /// across it overrides that statement in two directions. Two concurrent checks carrying
  /// *different* caller keys are the caller saying "these are two billable transactions"; sharing
  /// one flight makes them one, and it is the first caller's key that goes on the wire. And a
  /// caller who supplied a key, joining a flight started by one who did not, silently loses the
  /// retry budget — `isRetryable` keys off the caller's own key, so the flight it joined will not
  /// retry a 5xx or a timeout however carefully it was keyed. `generatedIdempotencyKey` states the
  /// neighbouring rule for the same reason: a key the SDK invents must never be derived from the
  /// query, since that would collapse two deliberate re-checks of one identifier into one. The
  /// latch did exactly that through another door.
  ///
  /// **A generated key is deliberately *not* in the latch key.** It is unique per call, so
  /// including it would give every check a latch of its own and disable the feature outright.
  /// Leaving it out is what keeps the case the latch exists for: a double-tapped button and a list
  /// rendering one identifier in two cells both go through one call site with one set of options,
  /// so they still share a flight and are still billed once.
  ///
  /// The lookup and the insert happen with no `await` between them, which is the whole point: the
  /// actor cannot interleave there, so a second caller either finds the flight above or starts the
  /// only other one. Getting that wrong reintroduces exactly the race this exists to close.
  ///
  /// ## What this deliberately does not cover
  ///
  /// **A caller whose task is already cancelled neither joins a flight nor starts one.** It runs
  /// its own request, exactly as before, so the transport still observes the cancellation and the
  /// call fails the way it does today. Joining would make a caller that has been told to stop wait
  /// on somebody else's round trip; starting one would file a flight in the map on behalf of a
  /// caller who is not going to consume it, and the next caller would then join work begun by a
  /// task already on its way out.
  ///
  /// **A shared flight is not cancelled by any of its participants**, and that is a real change
  /// from running the request inline. `Task.value` does not forward the waiting task's
  /// cancellation, and an unstructured `Task` does not inherit it, so once a check is latched it
  /// runs to completion whoever walks away from it. That is the right trade rather than merely the
  /// convenient one: one caller's cancellation must never cancel another caller's check, and a POST
  /// already on the wire may already have been billed — abandoning it discards an answer that was
  /// paid for, while letting it finish warms the cache and makes the next check free. Cancellation
  /// of a check has never been part of this SDK's contract and no `.full` or `.minimal` path
  /// depended on it.
  ///
  /// The cache write lives inside the flight rather than in each caller, so a collapsed check is
  /// stored once. Kotlin does the same; React Native and Flutter latch the network call only and
  /// write per caller. The observable behaviour is the same either way, and the request count — the
  /// thing that is billed — is identical.
  private func latchedFetch(
    _ query: TraciveQuery,
    detail: Detail,
    locale: String?,
    idempotencyKey: String?,
    key: CheckCacheKey,
    cacheApplies: Bool
  ) async throws -> CheckResult {
    guard !Task.isCancelled else {
      return try await fetchAndStore(
        query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key,
        cacheApplies: cacheApplies)
    }

    // The caller's key is appended only when there is one, so an unkeyed check produces exactly the
    // key it always did and two unkeyed callers still meet on it. Normalised through the same
    // helper `fetchAndStore` uses, so "the caller gave us a key" cannot mean one thing to the latch
    // and another to the retry rule that key exists to unlock.
    let base = "\(key.hex)|\(detail.rawValue)|\(locale ?? "")"
    let latchKey = Self.callerIdempotencyKey(idempotencyKey).map { "\(base)|\($0)" } ?? base
    if let inFlight = inFlightChecks[latchKey] {
      return try await inFlight.value
    }

    let task = Task<CheckResult, Error> { [self] in
      defer { clearInFlightCheck(latchKey) }
      return try await fetchAndStore(
        query, detail: detail, locale: locale, idempotencyKey: idempotencyKey, key: key,
        cacheApplies: cacheApplies)
    }
    inFlightChecks[latchKey] = task
    return try await task.value
  }

  /// Releases a latch. Isolated to the actor, so the removal cannot interleave with a lookup.
  private func clearInFlightCheck(_ latchKey: String) {
    inFlightChecks[latchKey] = nil
  }

  /// - Parameter cacheApplies: whether this response may be persisted. `false` for `detail: .full`,
  ///   decided once in `checkScammer` and passed down rather than re-derived here, so the read side
  ///   and the write side of the rule cannot drift apart.
  private func fetchAndStore(
    _ query: TraciveQuery,
    detail: Detail,
    locale: String?,
    idempotencyKey: String?,
    key: CheckCacheKey,
    cacheApplies: Bool
  ) async throws -> CheckResult {
    let body = ScammerCheckRequestBody(query: query, detail: detail, locale: locale)
    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(body)
    } catch {
      throw TraciveError.sdk("invalid_request_body", "The check request could not be encoded.")
    }

    let callerKey = Self.callerIdempotencyKey(idempotencyKey)

    // Every check carries an `Idempotency-Key`, whether the caller supplied one or not.
    //
    // The SDK re-sends this exact POST after a 401 refresh (see `sendAuthorized`). Without a key
    // the two attempts are indistinguishable to the server, so any billing that happens before or
    // during authorisation is charged twice, with no way for the caller to detect it. This code
    // used to justify that with "a 401 is rejected before billing" — an assumption about the
    // server's ordering that nothing on the client can verify, and the one premise this SDK
    // otherwise refuses to make anywhere.
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

    // A full-detail answer is never written — `cacheApplies` is `false` for it, decided once in
    // `checkScammer` so the read gate and this write gate cannot drift apart.
    //
    // The reason here is *not* the one that governs the read. `cacheableCopy()` keeps `tags` and
    // `disclaimer`, and the row key is `SHA-256(searchQueryIndex)` with no locale in it. Only a
    // full-detail request carries a `locale`, so storing its projection would file a localized
    // `disclaimer` under a locale-less key, and the next `.minimal` caller — which sends no locale
    // at all — would read it straight back. `disclaimer` is the one string this SDK asks every
    // integrator to put on screen, so the failure is a partner rendering a legal notice in the
    // wrong language with nothing to indicate it.
    //
    // Do not "optimise" this back into an unconditional write: skipping the read does not prevent
    // it, because the row is poisoned on the way IN and collected by a later `.minimal` call that
    // is reading the cache quite legitimately. Relaxing either half requires the key to become
    // (query, detail, locale) first.
    //
    // The store persists `cacheableCopy()` itself, dropping checkId/billing/chronologies/comments.
    // A failed write must never fail a check that already succeeded — it costs one credit next
    // time, nothing more.
    if cacheApplies {
      cache.writeIgnoringFailures(result, for: key)
    }

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
        // Refresh on **any 401 that is not terminal**, rather than on an exact `expired_token` body.
        //
        // The old condition required the response to carry precisely `code: "expired_token"`. A
        // bare `401 Unauthorized` — no body at all, or a `WWW-Authenticate` header and nothing else
        // — is what CDNs, API gateways and misconfigured reverse proxies emit, and this SDK is
        // explicitly designed to sit behind a partner gateway in phase 2; the proxy contract exists
        // for that. In that state the SDK never refreshed at all: every call failed identically,
        // for as long as the app ran, until something happened to call `authorize()` again. Not a
        // degraded path — a permanently stuck client.
        //
        // Two codes stay terminal, for the same reason at one remove: the server is not saying the
        // credential is stale, it is saying it is not a credential, so obtaining a fresh one earns
        // nothing.
        switch info.code {
        case "grant_revoked":
          // Usually the server's refresh-token reuse detection firing. The grant is gone; keeping
          // the tokens would only produce more failures. Do not retry.
          await oauth.clearStoredTokens()
          throw TraciveError.grantRevoked(info)

        case "invalid_token":
          // Malformed, foreign, or structurally rejected. Rotating ours does not make it ours.
          break

        default:
          guard !didRefresh else { break }
          didRefresh = true
          // Single-flight: concurrent 401s funnel into one `POST /oauth/token`. Getting this wrong
          // trips the server's reuse detection, which revokes the whole grant.
          _ = try await oauth.refreshTokens(staleAccessToken: token)
          // Re-send the identical request. It carries an `Idempotency-Key` — `fetchAndStore`
          // attaches one even when the caller did not — so if the first attempt was billed after
          // all, the server can collapse the two into a single charge. That property is what makes
          // widening this branch safe: the replay is now reached by many more responses than
          // before, and every one of them is collapsible. This replay deliberately does not consume
          // the retry budget: it is a re-authentication, not a retry of a failed check.
          continue
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
