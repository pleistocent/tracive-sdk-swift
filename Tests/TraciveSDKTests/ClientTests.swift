import XCTest

@testable import TraciveSDK

/// `TraciveClient` behaviour: request shape, cache routing, the retry rule that protects the
/// caller's credits, and the single-flight 401 refresh.
///
/// **Nothing here touches a network.** The Tracive Open API is not live yet — there is no
/// deployed `/v1/*` route — so every response is scripted through `FakeHTTPTransport`. That is
/// not a limitation of the suite; it is the only way this SDK can be specified at all right now,
/// and it stays true after the backend ships.
///
/// This file also carries the test doubles shared with `OAuthTests` and `ErrorMappingTests`.
final class ClientTests: XCTestCase {

  // MARK: - Mode

  func testProxyModeThrowsNotImplementedForEveryCall() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: "{}") }
    let client = TraciveClient(
      mode: .proxy(baseUrl: URL(string: "https://api.example.com/tracive")!),
      transport: transport,
      cache: NoOpCheckCache()
    )

    let checkError = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone)
    }
    XCTAssertEqual(checkError?.kind, .notImplemented)
    // The spec fixes this string so all three SDKs say the same thing.
    XCTAssertEqual(checkError?.errorDescription, "Proxy mode arrives in phase 2")

    let creditsError = await expectTraciveError { try await client.credits() }
    XCTAssertEqual(creditsError?.kind, .notImplemented)

    let profileError = await expectTraciveError { try await client.profile() }
    XCTAssertEqual(profileError?.kind, .notImplemented)

    // Not one request may leave: Proxy mode has no server to talk to yet.
    XCTAssertEqual(transport.callCount, 0)

    if case .failed(let error) = await client.authorize() {
      XCTAssertEqual(error.kind, .notImplemented)
    } else {
      XCTFail("Proxy mode must not start an OAuth flow.")
    }
  }

  func testProxyModeExposesNoOAuthDriver() {
    let client = TraciveClient(
      mode: .proxy(baseUrl: URL(string: "https://api.example.com")!),
      transport: FakeHTTPTransport { _, _ in .ok(json: "{}") },
      cache: NoOpCheckCache()
    )
    XCTAssertNil(client.oauth)
  }

  // MARK: - Request shape

  func testCheckRequestMatchesTheSpecifiedWireFormat() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone)

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.method, .post)
    XCTAssertEqual(request.url.absoluteString, "https://api.tracive.id/v1/scammer-checks")
    XCTAssertEqual(request.header("Authorization"), "Bearer access-1")
    XCTAssertEqual(request.header("Content-Type"), "application/json")
    // Present even though the caller passed no key: the SDK generates one so its own post-refresh
    // replay is collapsible server-side. Asserted as a prefixed, non-empty value rather than as
    // absent, which is what this line used to check.
    XCTAssertTrue(try XCTUnwrap(request.header("Idempotency-Key")).hasPrefix("sdk-"))

    let body = try Self.jsonObject(request.body)
    XCTAssertEqual(body["creditSource"] as? String, "USER")
    XCTAssertEqual(body["detail"] as? String, "minimal")
    XCTAssertEqual(body["query"] as? String, "PHONE_+6281234567891")
    // `input` is the server-normalised path; the SDK has already folded the key and that same
    // folded string is the cache key, so sending `input` would let the two sides drift.
    XCTAssertNil(body["input"])
    // Omitted at minimal detail: the server ignores it there, and a stray field changes the
    // payload behind an `Idempotency-Key`.
    XCTAssertNil(body["locale"])
  }

  func testLocaleIsSentOnlyWithFullDetail() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone, detail: .minimal, locale: "id")
    _ = try await client.checkScammer(TestQueries.email, detail: .full, locale: "id")

    let minimalBody = try Self.jsonObject(transport.requests[0].body)
    XCTAssertNil(minimalBody["locale"])

    let fullBody = try Self.jsonObject(transport.requests[1].body)
    XCTAssertEqual(fullBody["detail"] as? String, "full")
    XCTAssertEqual(fullBody["locale"] as? String, "id")
  }

  func testIdempotencyKeyIsSentWhenSupplied() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-42")

    XCTAssertEqual(transport.requests.first?.header("Idempotency-Key"), "txn-42")
  }

  /// Every check carries an `Idempotency-Key`, including the ones where the caller supplied none.
  ///
  /// The SDK re-sends the *same* non-idempotent POST after a 401 refresh. Without a key on both
  /// attempts the two are indistinguishable to the server, so anything that bills before or during
  /// authorisation double-charges with no way for the caller to detect it. The SDK cannot know the
  /// server's ordering — the server does not exist yet — so it must not depend on it.
  func testAGeneratedIdempotencyKeyIsAttachedWhenTheCallerSuppliesNone() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone)

    let key = try XCTUnwrap(transport.requests.first?.header("Idempotency-Key"))
    XCTAssertFalse(key.isEmpty)
  }

  /// The key must be per-call, not per-client: two distinct checks are two distinct charges, and
  /// reusing one key would let the server collapse them into one.
  func testEachCheckGetsItsOwnGeneratedIdempotencyKey() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone, source: .server)
    _ = try await client.checkScammer(TestQueries.email, source: .server)

    let keys = transport.requests.compactMap { $0.header("Idempotency-Key") }
    XCTAssertEqual(keys.count, 2)
    XCTAssertNotEqual(keys[0], keys[1], "two separate checks must not share one key")
  }

  /// The whole point: the post-refresh replay carries the *same* key as the first attempt, so the
  /// server can collapse the two into one charge.
  func testThe401ReplayReusesTheSameGeneratedIdempotencyKey() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("oauth/token") {
        return .ok(json: Fixtures.refreshedTokenJSON)
      }
      return request.header("Authorization") == "Bearer access-1"
        ? .error(status: 401, code: "expired_token")
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport, tokenStore: store)

    _ = try await client.checkScammer(TestQueries.phone)

    let checkKeys = transport.requests
      .filter { $0.url.path.hasSuffix("scammer-checks") }
      .map { $0.header("Idempotency-Key") }
    XCTAssertEqual(checkKeys.count, 2, "the check should have been sent twice")
    XCTAssertNotNil(checkKeys[0])
    XCTAssertEqual(
      checkKeys[0], checkKeys[1],
      "the replay must reuse the first attempt's key, or the server cannot deduplicate the charge"
    )
  }

  /// Attaching a generated key must not quietly buy the caller a retry budget they did not ask for.
  /// `isRetryable` still keys off a *caller-supplied* key: without one, a 5xx is surfaced
  /// immediately, exactly as README and SECURITY.md promise.
  func testAGeneratedKeyDoesNotMakeAnUnkeyedCheckRetryable() async throws {
    let transport = FakeHTTPTransport { _, _ in .error(status: 503, code: nil) }
    let client = makeClient(transport: transport)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .server)
    XCTAssertEqual(transport.callCount, 1, "an unkeyed check must not be retried on a 5xx")
  }

  func testCreditsAndProfileUseTheEnvironmentBaseURL() async throws {
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("credits") {
        return .ok(json: #"{"subscriptionCredits":23,"tier":"plus"}"#)
      }
      return .ok(json: #"{"sub":"ppid_abc","tier":"plus"}"#)
    }
    let client = makeClient(transport: transport, environment: .sandbox)

    let credits = try await client.credits()
    let profile = try await client.profile()

    XCTAssertEqual(credits.subscriptionCredits, 23)
    XCTAssertEqual(profile.sub, "ppid_abc")
    XCTAssertEqual(
      transport.requests[0].url.absoluteString, "https://api-sandbox.tracive.id/v1/credits")
    XCTAssertEqual(transport.requests[0].method, .get)
    XCTAssertEqual(
      transport.requests[1].url.absoluteString, "https://api-sandbox.tracive.id/v1/profile")
  }

  func testUnknownResponseFieldsAreIgnored() async throws {
    // Forward compatibility: a future-version server adding fields must not break a shipped app.
    let json = """
      {
        "found": true,
        "riskTier": "ELEVATED",
        "reportTotal": 3,
        "somethingFromFutureVersion": { "nested": [1, 2, 3] },
        "riskScore": 88.5
      }
      """
    let transport = FakeHTTPTransport { _, _ in .ok(json: json) }
    let client = makeClient(transport: transport)

    let result = try await client.checkScammer(TestQueries.phone)

    XCTAssertEqual(result.riskTier, .elevated)
    XCTAssertEqual(result.reportTotal, 3)
    XCTAssertEqual(result.origin, .server)
  }

  func testServerResultIsStampedWithTheInjectedClock() async throws {
    let clock = RecordingClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock)

    let result = try await client.checkScammer(TestQueries.phone)

    XCTAssertEqual(result.fetchedAt, clock.now)
    XCTAssertEqual(result.origin, .server)
  }

  // MARK: - Cache routing

  func testCacheFirstServesTheSecondCallWithoutNetworkIO() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    let first = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    let second = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)

    XCTAssertEqual(first.origin, .server)
    XCTAssertEqual(second.origin, .cache)
    // The whole economic point of the cache: the second check costs nothing.
    XCTAssertEqual(transport.callCount, 1)
    XCTAssertEqual(second.riskTier, first.riskTier)
  }

  func testSourceCacheRaisesCacheMissRatherThanAnEmptyResult() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(
      transport: transport,
      cache: try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore())
    )

    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .cache)
    }

    // A fabricated "no reports found" is the worst possible answer from a fraud SDK.
    XCTAssertEqual(error?.kind, .cacheMiss)
    XCTAssertEqual(transport.callCount, 0)
  }

  func testSourceServerAlwaysGoesToTheNetworkAndRefreshesTheCache() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server)
    _ = try await client.checkScammer(TestQueries.phone, source: .server)

    XCTAssertEqual(transport.callCount, 2)
    // …and the cache is still populated afterwards, so a later `.cacheFirst` is free.
    let cached = try await client.checkScammer(TestQueries.phone, source: .cache)
    XCTAssertEqual(cached.origin, .cache)
    XCTAssertEqual(transport.callCount, 2)
  }

  func testCachedEntryExpiresOnTheTierTTL() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    // riskTier NONE → 1 hour, the shortest window: today's clean number is tomorrow's
    // scammer, so a clean verdict must go stale fastest.
    let transport = FakeHTTPTransport { _, _ in
      .ok(json: #"{"found":false,"riskTier":"NONE","reportTotal":0}"#)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    clock.advance(by: 59 * 60)
    let stillFresh = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    XCTAssertEqual(stillFresh.origin, .cache)
    XCTAssertEqual(transport.callCount, 1)

    clock.advance(by: 2 * 60)
    let refetched = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    XCTAssertEqual(refetched.origin, .server)
    XCTAssertEqual(transport.callCount, 2)
  }

  func testServerTTLOverrideBeatsTheTierDefault() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    // HIGH would normally be cached for thirty days; the server says ten seconds. `cacheTtlSeconds`
    // is the fleet-wide invalidation lever — if this test fails, Tracive has lost its only way
    // to revoke a bad verdict without shipping an SDK release.
    let transport = FakeHTTPTransport { _, _ in
      .ok(json: #"{"found":true,"riskTier":"HIGH","reportTotal":9,"cacheTtlSeconds":10}"#)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    clock.advance(by: 30)
    let refetched = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)

    XCTAssertEqual(refetched.origin, .server)
    XCTAssertEqual(transport.callCount, 2)
  }

  func testFullDetailContentIsNeverCached() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.fullCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    let live = try await client.checkScammer(TestQueries.phone, detail: .full, locale: "id")
    XCTAssertEqual(live.comments?.count, 1)
    XCTAssertEqual(live.topChronologies?.count, 1)
    XCTAssertNotNil(live.billing)
    XCTAssertEqual(live.checkId, "chk_full")

    let cached = try await client.checkScammer(TestQueries.phone, source: .cache)
    // The key is the query alone, so anything that varies with detail/locale must not be stored —
    // otherwise a later `minimal` request would be served `full` content.
    XCTAssertNil(cached.comments)
    XCTAssertNil(cached.topChronologies)
    XCTAssertNil(cached.billing)
    XCTAssertNil(cached.checkId)
    // The invariant fields survive.
    XCTAssertEqual(cached.riskTier, live.riskTier)
    XCTAssertEqual(cached.reportTotal, live.reportTotal)
  }

  func testFullDetailRequestIsStillServedFromAMinimalCacheEntry() async throws {
    // Pins a trade-off that is deliberate but easy to trip over, so it cannot drift silently in any
    // of the three SDKs.
    //
    // The cache key is `SHA-256(searchQueryIndex)` — the query **alone**, not
    // `(query, detail, locale)`. A `.cacheFirst` request therefore hits on whatever was stored
    // for that query regardless of the `detail` asked for, and since full-detail content is never
    // cached, a `.full` request answered from cache comes back with `comments` and
    // `topChronologies` nil. That is indistinguishable from "full detail returned nothing".
    //
    // Callers who need full detail must pass `source: .server`. The alternative — making `.full`
    // bypass the cache — is *not* implemented here on purpose: the spec freezes the key as the query
    // alone and pins the remedy ("if a future version caches full detail, the key must become
    // `(query, detail, locale)`"), so inventing a fourth routing rule in Swift would break the 1:1
    // surface with Kotlin and Flutter.
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, index in
      index == 0 ? .ok(json: Fixtures.minimalCheckJSON) : .ok(json: Fixtures.fullCheckJSON)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst, detail: .minimal)
    let full = try await client.checkScammer(
      TestQueries.phone, source: .cacheFirst, detail: .full, locale: "id")

    XCTAssertEqual(full.origin, .cache)
    XCTAssertNil(full.comments)
    XCTAssertNil(full.topChronologies)
    XCTAssertEqual(transport.callCount, 1)

    // …and `.server` is the documented way to actually get it.
    let fetched = try await client.checkScammer(
      TestQueries.phone, source: .server, detail: .full, locale: "id")
    XCTAssertEqual(fetched.origin, .server)
    XCTAssertEqual(fetched.comments?.count, 1)
  }

  /// `origin` is the second documented remedy for the trade-off above, so it has to be a remedy
  /// that actually works — pinned here rather than left as prose in the README.
  ///
  /// The hazard is that `comments == nil` has two completely different meanings:
  ///
  /// - served from a minimal cache row → full detail was **never fetched**, and
  /// - served from the server → full detail *was* fetched and there genuinely is none on file.
  ///
  /// A partner UI that renders "no incident reports on file" for the first case is showing a wrong
  /// fraud answer about a real scammer. `origin` is the only thing in the payload that separates
  /// them, so this test asserts the two cases are byte-identical *except* for `origin`.
  func testOriginDistinguishesUnfetchedFullDetailFromGenuinelyEmptyFullDetail() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    // Every response is minimal-shaped, i.e. carries no comments and no chronologies. That is what
    // a genuine "full detail, nothing on file" answer looks like on the wire.
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    // Case 1: full detail really was requested of the server and came back empty.
    let fromServer = try await client.checkScammer(
      TestQueries.phone, source: .server, detail: .full, locale: "id")
    XCTAssertNil(fromServer.comments)
    XCTAssertNil(fromServer.topChronologies)
    XCTAssertEqual(fromServer.origin, .server)

    // Case 2: the same call on the default source is answered from the row case 1 just stored, so
    // full detail was never asked for at all.
    let fromCache = try await client.checkScammer(
      TestQueries.phone, source: .cacheFirst, detail: .full, locale: "id")
    XCTAssertNil(fromCache.comments)
    XCTAssertNil(fromCache.topChronologies)
    XCTAssertEqual(transport.callCount, 1, "the cache branch must not have gone to the network")

    // The payloads agree on every field a caller would look at…
    XCTAssertEqual(fromCache.riskTier, fromServer.riskTier)
    XCTAssertEqual(fromCache.reportTotal, fromServer.reportTotal)
    XCTAssertEqual(fromCache.credibleReports, fromServer.credibleReports)
    // …so `origin` is the sole discriminator, and a caller that ignores it cannot tell "not
    // fetched" from "none on file".
    XCTAssertEqual(fromCache.origin, .cache)
    XCTAssertNotEqual(fromCache.origin, fromServer.origin)
  }

  /// The `.cache` source has the same shape as `.cacheFirst` here and is easy to overlook, because
  /// its documented contract ("a miss throws rather than answering empty") sounds like it already
  /// protects against an empty answer. It does not: a *hit* on a minimal row is not a miss, so a
  /// `.full` request is answered from it with the full-detail fields nil and nothing is thrown.
  func testCacheOnlySourceAlsoAnswersFullDetailFromAMinimalRow() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server, detail: .minimal)

    let full = try await client.checkScammer(TestQueries.phone, source: .cache, detail: .full)

    XCTAssertEqual(full.origin, .cache)
    XCTAssertNil(full.comments)
    XCTAssertNil(full.topChronologies)
    XCTAssertEqual(transport.callCount, 1)
  }

  func testServerFirstFallsBackToCacheOnTransportFailure() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, index in
      if index == 0 { return .ok(json: Fixtures.minimalCheckJSON) }
      throw URLError(.notConnectedToInternet)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server)
    let offline = try await client.checkScammer(TestQueries.phone, source: .serverFirst)

    XCTAssertEqual(offline.origin, .cache)
  }

  func testServerFirstPropagatesWhenThereIsNothingCached() async throws {
    let transport = FakeHTTPTransport { _, _ in throw URLError(.notConnectedToInternet) }
    let client = makeClient(
      transport: transport,
      cache: try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore())
    )

    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .serverFirst)
    }
    XCTAssertEqual(error?.kind, .network)
  }

  func testServerFirstDoesNotHideABillingFailureBehindTheCache() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, index in
      if index == 0 { return .ok(json: Fixtures.minimalCheckJSON) }
      return .error(status: 402, code: "insufficient_user_credits")
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server)
    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .serverFirst)
    }

    // A 402 is a real answer about the caller's account. Serving a cached verdict instead would
    // hide the empty wallet until it became someone else's incident.
    XCTAssertEqual(error?.kind, .insufficientCredits)
  }

  func testClearCacheEmptiesTheStore() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    XCTAssertEqual(try cache.count(), 1)

    try await client.clearCache()

    XCTAssertEqual(try cache.count(), 0)
    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .cache)
    }
    XCTAssertEqual(error?.kind, .cacheMiss)
  }

  func testDisabledCachePolicyNeverServesAHit() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, cache: NoOpCheckCache())

    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)
    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)

    XCTAssertEqual(transport.callCount, 2)
  }

  func testDefaultSourceIsUsedWhenACallDoesNotNameOne() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(
      transport: transport,
      cache: try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore()),
      defaultSource: .cache
    )

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .cacheMiss)
    XCTAssertEqual(transport.callCount, 0)
  }

  // MARK: - Retry policy

  func testCheckIsNotRetriedOnFiveHundredWithoutAnIdempotencyKey() async throws {
    let transport = FakeHTTPTransport { _, _ in .error(status: 503, code: nil) }
    let client = makeClient(transport: transport, retryPolicy: .default)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .server)
    // The load-bearing assertion of this whole file: without a key the SDK cannot tell whether the
    // first attempt was charged, so it refuses to spend the caller's money on a guess.
    XCTAssertEqual(transport.callCount, 1)
  }

  func testCheckIsRetriedOnFiveHundredWithAnIdempotencyKey() async throws {
    let clock = RecordingClock()
    let transport = FakeHTTPTransport { _, index in
      index < 2 ? .error(status: 503, code: nil) : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maxAttempts: 3, initialBackoff: 0.5, multiplier: 2, jitter: 0)
    )

    let result = try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-1")

    XCTAssertEqual(result.riskTier, .high)
    XCTAssertEqual(transport.callCount, 3)
    XCTAssertEqual(clock.sleeps, [0.5, 1.0])
    // Every attempt must carry the *same* key, or the server cannot deduplicate the charge.
    XCTAssertEqual(transport.requests.map { $0.header("Idempotency-Key") }, ["txn-1", "txn-1", "txn-1"])
  }

  func testRetriesStopAtMaxAttempts() async throws {
    let clock = RecordingClock()
    let transport = FakeHTTPTransport { _, _ in .error(status: 500, code: nil) }
    let client = makeClient(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maxAttempts: 2, initialBackoff: 0.25, jitter: 0)
    )

    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-2")
    }

    XCTAssertEqual(error?.kind, .server)
    XCTAssertEqual(transport.callCount, 2)
    XCTAssertEqual(clock.sleeps, [0.25])
  }

  func testTimeoutIsNotRetriedWithoutAnIdempotencyKey() async throws {
    let transport = FakeHTTPTransport { _, _ in throw URLError(.timedOut) }
    let client = makeClient(transport: transport, retryPolicy: .default)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .network)
    XCTAssertEqual(transport.callCount, 1)
  }

  func testTimeoutIsRetriedWithAnIdempotencyKey() async throws {
    let clock = RecordingClock()
    let transport = FakeHTTPTransport { _, index in
      if index == 0 { throw URLError(.timedOut) }
      return .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maxAttempts: 3, initialBackoff: 0.1, jitter: 0)
    )

    _ = try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-3")

    XCTAssertEqual(transport.callCount, 2)
  }

  func testRateLimitedRetryHonoursRetryAfter() async throws {
    let clock = RecordingClock()
    let transport = FakeHTTPTransport { _, index in
      index == 0
        ? .error(status: 429, code: "rate_limited", headers: ["Retry-After": "4"])
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maxAttempts: 2, initialBackoff: 0.5, jitter: 0)
    )

    _ = try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-4")

    // The server's own window wins over the exponential curve.
    XCTAssertEqual(clock.sleeps, [4.0])
  }

  func testRateLimitedWithoutAKeyIsSurfacedRatherThanRetried() async throws {
    let transport = FakeHTTPTransport { _, _ in
      .error(status: 429, code: "rate_limited", headers: ["retry-after": "12"])
    }
    let client = makeClient(transport: transport, retryPolicy: .default)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .rateLimited)
    if case .rateLimited(let retryAfter, _) = error {
      // Header lookup is case-insensitive — `URLSession` canonicalises header names.
      XCTAssertEqual(retryAfter, 12)
    } else {
      XCTFail("Expected rateLimited, got \(String(describing: error))")
    }
    XCTAssertEqual(transport.callCount, 1)
  }

  func testGetRequestsAreRetriedWithoutAnyIdempotencyKey() async throws {
    let clock = RecordingClock()
    let transport = FakeHTTPTransport { _, index in
      index == 0
        ? .error(status: 500, code: nil)
        : .ok(json: #"{"subscriptionCredits":7,"tier":"free"}"#)
    }
    let client = makeClient(
      transport: transport,
      clock: clock,
      retryPolicy: RetryPolicy(maxAttempts: 2, initialBackoff: 0.2, jitter: 0)
    )

    // A GET has no side effects, so there is no charge to duplicate.
    let credits = try await client.credits()

    XCTAssertEqual(credits.subscriptionCredits, 7)
    XCTAssertEqual(transport.callCount, 2)
  }

  // MARK: - 401 handling

  func testExpiredTokenTriggersOneRefreshAndOneReplay() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("oauth/token") {
        return .ok(json: Fixtures.refreshedTokenJSON)
      }
      return request.header("Authorization") == "Bearer access-1"
        ? .error(status: 401, code: "expired_token")
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport, tokenStore: store)

    let result = try await client.checkScammer(TestQueries.phone)

    XCTAssertEqual(result.riskTier, .high)
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 1)
    XCTAssertEqual(transport.count(pathSuffix: "scammer-checks"), 2)
    XCTAssertEqual(transport.requests.last?.header("Authorization"), "Bearer access-2")
    XCTAssertEqual(try store.load()?.accessToken, "access-2")
    // Rotation: the new refresh token replaced the old one.
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
  }

  func testGrantRevokedClearsTokensAndDoesNotRefresh() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in .error(status: 401, code: "grant_revoked") }
    let client = makeClient(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .grantRevoked)
    // Clear the tokens and do not retry. Re-presenting a revoked grant is what reuse detection
    // is watching for.
    XCTAssertNil(try store.load())
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 0)
    XCTAssertEqual(transport.callCount, 1)
  }

  func testInvalidTokenIsSurfacedWithoutAttemptingARefresh() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in .error(status: 401, code: "invalid_token") }
    let client = makeClient(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    // Auto-refresh is on `expired_token` specifically. A malformed or foreign token is not
    // going to be fixed by rotating ours.
    XCTAssertEqual(error?.kind, .invalidToken)
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 0)
    XCTAssertNotNil(try store.load())
  }

  func testARefreshIsAttemptedAtMostOncePerRequest() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    // A server that keeps answering 401 `expired_token` even after a successful refresh would spin
    // this loop forever without the one-shot guard.
    let transport = FakeHTTPTransport { request, _ in
      request.url.path.hasSuffix("oauth/token")
        ? .ok(json: Fixtures.refreshedTokenJSON)
        : .error(status: 401, code: "expired_token")
    }
    let client = makeClient(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .expiredToken)
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 1)
    XCTAssertEqual(transport.count(pathSuffix: "scammer-checks"), 2)
  }

  func testConcurrentExpiredTokensProduceExactlyOneRefresh() async throws {
    // The failure this guards against is not a wasted request: presenting a rotated refresh token
    // a second time trips the server's **reuse detection**, which revokes the entire grant.
    // A racing refresh is therefore a logout for the user, not a retry.
    let concurrency = 6
    let gate = TestGate()
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("oauth/token") {
        // Hold the refresh open until every check has taken its 401, so the race is real rather
        // than hopefully-scheduled.
        await gate.wait()
        return .ok(json: Fixtures.refreshedTokenJSON)
      }
      return request.header("Authorization") == "Bearer access-1"
        ? .error(status: 401, code: "expired_token")
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport, tokenStore: store)

    let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
      for _ in 0..<concurrency {
        group.addTask {
          ((try? await client.checkScammer(TestQueries.phone, source: .server)) != nil)
        }
      }

      let sawEveryUnauthorized = await waitUntil {
        transport.count(pathSuffix: "scammer-checks") >= concurrency
      }
      XCTAssertTrue(sawEveryUnauthorized, "Not every concurrent check reached its 401.")
      await gate.open()

      var collected: [Bool] = []
      for await success in group { collected.append(success) }
      return collected
    }

    XCTAssertEqual(results.count, concurrency)
    XCTAssertTrue(results.allSatisfy { $0 }, "Every concurrent check should have succeeded.")
    XCTAssertEqual(
      transport.count(pathSuffix: "oauth/token"), 1,
      "Concurrent 401s must funnel into a single refresh."
    )
    XCTAssertEqual(transport.count(pathSuffix: "scammer-checks"), concurrency * 2)
  }

  func testCallWithoutAGrantFailsBeforeAnyNetworkIO() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, tokenStore: InMemoryTokenStore())

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .invalidToken)
    XCTAssertEqual(error?.serverCode, "no_grant")
    XCTAssertEqual(transport.callCount, 0)
  }

  // MARK: - Privacy

  func testRequestDescriptionLeaksNeitherTokenNorIdentifier() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-9")

    let description = String(describing: try XCTUnwrap(transport.requests.first))
    XCTAssertFalse(description.contains("access-1"))
    XCTAssertFalse(description.contains("+6281234567891"))
    XCTAssertTrue(description.contains("<redacted>"))
  }

  func testNoRequestOnAnyEndpointCarriesAnAPIKey() async throws {
    // The no-credential invariant, asserted at the wire rather than at the type level. There is no
    // API-key parameter in the public surface — but the check that matters to a bank's security
    // review is that nothing key-shaped actually leaves the device, on any route, in any mode.
    // A type-level absence can be re-introduced by one header line; this test is what catches that.
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("credits") {
        return .ok(json: #"{"subscriptionCredits":1,"tier":"free"}"#)
      }
      if request.url.path.hasSuffix("profile") { return .ok(json: #"{"sub":"ppid"}"#) }
      return .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport)

    _ = try await client.checkScammer(TestQueries.phone, idempotencyKey: "txn-x")
    _ = try await client.credits()
    _ = try await client.profile()

    XCTAssertEqual(transport.callCount, 3)
    for request in transport.requests {
      for name in request.headers.keys {
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "")
        XCTAssertFalse(normalized.contains("apikey"), "\(name) on \(request.url.path)")
        XCTAssertFalse(normalized.contains("secret"), "\(name) on \(request.url.path)")
      }
      // The only credential the SDK ever presents is the user's OAuth bearer token.
      if let authorization = request.header("Authorization") {
        XCTAssertTrue(authorization.hasPrefix("Bearer "), authorization)
      }
      let query = request.url.query ?? ""
      XCTAssertFalse(query.lowercased().contains("api_key"), query)
      XCTAssertFalse(query.lowercased().contains("secret"), query)
    }
  }

  // MARK: - Helpers

  private static func jsonObject(_ data: Data?) throws -> [String: Any] {
    let data = try XCTUnwrap(data)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

// MARK: - Shared test doubles
//
// Declared at file scope so `OAuthTests` and `ErrorMappingTests` can use them too — one fake
// transport for the whole suite keeps the "no test ever opens a socket" rule easy to audit.

/// Builds a client wired to fakes. Always pass a cache explicitly: the production default opens a
/// SQLite file in Application Support and reaches for the Keychain.
func makeClient(
  transport: FakeHTTPTransport,
  environment: TraciveEnvironment = .production,
  clock: RecordingClock = RecordingClock(),
  cache: (any CheckCache)? = nil,
  tokenStore: (any TraciveTokenStore)? = nil,
  retryPolicy: RetryPolicy = .disabled,
  defaultSource: Source = .cacheFirst,
  clientType: ClientType = .public
) -> TraciveClient {
  TraciveClient(
    mode: .oauth(
      clientId: "test-client",
      redirectUri: URL(string: "https://partner.example.com/tracive/callback")!,
      scopes: ["scammer.check", "credits.read"],
      partnerUserId: "partner-user-1",
      clientType: clientType
    ),
    environment: environment,
    defaultSource: defaultSource,
    transport: transport,
    clock: clock,
    cache: cache ?? NoOpCheckCache(),
    tokenStore: tokenStore ?? InMemoryTokenStore(tokens: Fixtures.storedTokens),
    retryPolicy: retryPolicy
  )
}

/// An `HTTPTransport` that answers from a closure and records everything it was asked.
///
/// The closure receives the request and a zero-based call index, which is enough to express every
/// scenario in this suite — "fail twice then succeed", "401 until the Authorization header
/// changes", "route by path" — without a scripting DSL.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {

  private let respond: @Sendable (HTTPRequest, Int) async throws -> HTTPResponse
  private let lock = NSLock()
  private var recorded: [HTTPRequest] = []

  init(respond: @escaping @Sendable (HTTPRequest, Int) async throws -> HTTPResponse) {
    self.respond = respond
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let index = record(request)
    return try await respond(request, index)
  }

  var requests: [HTTPRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var callCount: Int { requests.count }

  func count(pathSuffix: String) -> Int {
    requests.filter { $0.url.path.hasSuffix(pathSuffix) }.count
  }

  /// Locking lives in a synchronous method so `send` never holds an `NSLock` across a suspension.
  private func record(_ request: HTTPRequest) -> Int {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(request)
    return recorded.count - 1
  }
}

extension HTTPResponse {

  /// A 200 with a JSON body.
  static func ok(json: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(
      status: 200,
      headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
      body: Data(json.utf8)
    )
  }

  /// A failure carrying Tracive's error envelope, `{"error":{"code","message","checkId"}}`.
  static func error(
    status: Int,
    code: String?,
    message: String? = nil,
    checkId: String? = nil,
    headers: [String: String] = [:]
  ) -> HTTPResponse {
    var fields: [String] = []
    if let code { fields.append("\"code\":\(Self.quote(code))") }
    if let message { fields.append("\"message\":\(Self.quote(message))") }
    if let checkId { fields.append("\"checkId\":\(Self.quote(checkId))") }
    let json = "{\"error\":{\(fields.joined(separator: ","))}}"
    return HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
  }

  /// A failure carrying RFC 6749's flat body, which is what the OAuth endpoints use.
  static func oauthError(
    status: Int,
    error: String,
    description: String? = nil
  ) -> HTTPResponse {
    var fields = ["\"error\":\(Self.quote(error))"]
    if let description { fields.append("\"error_description\":\(Self.quote(description))") }
    return HTTPResponse(status: status, body: Data("{\(fields.joined(separator: ","))}".utf8))
  }

  private static func quote(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(text.dropFirst().dropLast())
  }
}

/// A `TraciveClock` you move by hand, which also records every backoff it was asked to wait.
///
/// Recording rather than sleeping is what makes the retry schedule assertable: a test can state
/// "0.5 s then 1.0 s" instead of taking 1.5 seconds to find out.
final class RecordingClock: TraciveClock, @unchecked Sendable {

  private let lock = NSLock()
  private var current: Date
  private var recordedSleeps: [TimeInterval] = []

  init(now: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
    self.current = now
  }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  var sleeps: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return recordedSleeps
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    current = current.addingTimeInterval(interval)
  }

  func sleep(for duration: TimeInterval) async throws {
    record(duration)
  }

  /// For `SQLiteCheckCache(now:)`, so cache TTL and client backoff share one timeline.
  var provider: @Sendable () -> Date {
    { [self] in self.now }
  }

  private func record(_ duration: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    recordedSleeps.append(duration)
  }
}

/// A latch used to hold a scripted response open until a test says otherwise, so a concurrency
/// assertion is deterministic instead of relying on the scheduler.
actor TestGate {

  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters = []
    for continuation in pending { continuation.resume() }
  }
}

/// Polls `condition` until it holds or the deadline passes. Returns whether it held.
func waitUntil(
  timeout: TimeInterval = 5,
  _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 1_000_000)
  }
  return condition()
}

/// A thread-safe one-shot slot for a value produced by a detached task.
///
/// Exists so a test can observe whether an `await` ever finished **without awaiting it**.
/// `TraciveOAuth.authorize()` suspends until a callback arrives, so a bug that drops its stored
/// continuation produces a task that never completes — and there is no safe way to await such a
/// task. A task group with a timeout does not work either: `withTaskGroup` will not return until
/// every child has finished, and `Task.value` on a non-throwing `Task` ignores cancellation, so the
/// "timeout" child cannot release the group. That mistake turns a clean assertion failure into a
/// hung CI job with no diagnostic, which is strictly worse than the bug it was meant to catch.
///
/// Polling this box sidesteps the whole problem: the stuck task is simply abandoned.
final class TestResultBox<T: Sendable>: @unchecked Sendable {

  private let lock = NSLock()
  private var stored: T?

  var value: T? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  var isSet: Bool { value != nil }

  func set(_ value: T) {
    lock.lock()
    defer { lock.unlock() }
    stored = value
  }

  /// Waits for the box to be filled, returning `nil` if it never is.
  func settled(within timeout: TimeInterval = 5) async -> T? {
    _ = await waitUntil(timeout: timeout) { [self] in isSet }
    return value
  }
}

/// Runs `operation`, expecting it to throw a `TraciveError`. Returns the error, or `nil` after
/// failing the test.
func expectTraciveError<T>(
  file: StaticString = #filePath,
  line: UInt = #line,
  _ operation: () async throws -> T
) async -> TraciveError? {
  do {
    _ = try await operation()
    XCTFail("Expected a TraciveError, but the call succeeded.", file: file, line: line)
    return nil
  } catch let error as TraciveError {
    return error
  } catch {
    XCTFail("Expected a TraciveError, got \(error).", file: file, line: line)
    return nil
  }
}

/// Queries used across the suite. Force-tried because the grammar itself is covered by
/// `QueryGrammarTests` against the vendored fixture — a failure here would be that suite's problem.
enum TestQueries {
  static let phone = try! TraciveQuery.phone(e164: "+6281234567891")
  static let email = try! TraciveQuery.email(value: "budi@example.com")
  static let bank = try! TraciveQuery.bankAccount(
    countryAlpha3: "IDN", bankCode: "BCA", account: "1234567890")
}

/// Canned wire payloads.
enum Fixtures {

  static let minimalCheckJSON = """
    {
      "checkId": "chk_min",
      "found": true,
      "riskTier": "HIGH",
      "reportTotal": 12,
      "credibleReports": 9,
      "ambiguousReports": 3,
      "fraudAmount": { "IDR": 152500000 },
      "tags": ["olshop-fiktif"],
      "relatedScammerCount": 3,
      "disclaimer": "Indikatif, bukan vonis hukum."
    }
    """

  static let fullCheckJSON = """
    {
      "checkId": "chk_full",
      "found": true,
      "riskTier": "HIGH",
      "reportTotal": 12,
      "credibleReports": 9,
      "ambiguousReports": 3,
      "relatedScammerCount": 3,
      "topChronologies": [
        { "chronology": "Minta transfer di muka", "riskLevel": 4, "incidentDate": "2026-05-11" }
      ],
      "comments": [
        { "date": "2026-06-01", "text": "Tidak pernah dikirim", "fromCredibleReport": true }
      ],
      "billing": { "creditSource": "USER", "unitsCharged": 1 },
      "disclaimer": "Indikatif, bukan vonis hukum."
    }
    """

  static let refreshedTokenJSON = """
    {
      "access_token": "access-2",
      "refresh_token": "refresh-2",
      "token_type": "Bearer",
      "expires_in": 3600,
      "scope": "scammer.check credits.read"
    }
    """

  static let storedTokens = TraciveTokens(
    accessToken: "access-1",
    refreshToken: "refresh-1",
    tokenType: "Bearer",
    expiresAt: nil,
    scopes: ["scammer.check", "credits.read"]
  )
}
