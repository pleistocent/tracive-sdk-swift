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

  /// What reaches disk is `cacheableCopy()`, never the response as it arrived.
  ///
  /// This used to be observed by issuing a `.full` request and reading the row back, which no longer
  /// works for the best of reasons: a `.full` answer is not persisted at all now (see
  /// `testAFullDetailAnswerIsNeverWrittenToTheCache`). So it is driven through the one detail
  /// level that still writes. `checkId` and `billing` are on any real billed check, `.minimal`
  /// included, and both must be dropped: a cache hit is neither a server-side check nor a charge, so
  /// replaying either would report something that did not happen.
  func testOnlyTheProjectionOfAResponseIsCachedNeverTheResponse() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in
      .ok(
        json: #"""
          {"checkId":"chk_min","found":true,"riskTier":"HIGH","reportTotal":12,
           "credibleReports":9,"billing":{"creditSource":"USER","unitsCharged":1}}
          """#)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    let live = try await client.checkScammer(TestQueries.phone, detail: .minimal)
    XCTAssertEqual(live.checkId, "chk_min")
    XCTAssertNotNil(live.billing)

    let cached = try await client.checkScammer(TestQueries.phone, source: .cache)
    XCTAssertNil(cached.checkId)
    XCTAssertNil(cached.billing)
    // …along with the two full-detail fields, which the projection nils unconditionally.
    XCTAssertNil(cached.comments)
    XCTAssertNil(cached.topChronologies)
    // The invariant fields survive.
    XCTAssertEqual(cached.riskTier, live.riskTier)
    XCTAssertEqual(cached.reportTotal, live.reportTotal)
    XCTAssertEqual(cached.credibleReports, live.credibleReports)
  }

  func testFullDetailRequestBypassesTheCacheReadAndAsksTheServer() async throws {
    // Pins the rule that resolves a trade-off this suite used to pin the other way, so record both
    // sides — the old reasoning is why it is easy to get wrong again in any of the three SDKs.
    //
    // The cache key is `SHA-256(searchQueryIndex)` — the query **alone**, not
    // `(query, detail, locale)` — and full-detail content is never stored. The earlier version of
    // this test therefore asserted that a `.cacheFirst` request with `detail: .full` hit whatever
    // minimal row existed and came back with `comments` and `topChronologies` nil, and it called
    // that deliberate: the spec freezes the key as the query alone, so making `.full` route
    // differently looked like inventing a fourth routing rule that Kotlin and Flutter did not have.
    //
    // That reasoning weighed the wrong two things against each other. `nil` comments on a `.full`
    // answer is not a caching subtlety — it is byte-identical to "the server answered in full and
    // there are no incidents on file", which is a *wrong fraud answer* about an identifier that may
    // have four of them, delivered silently, on the default source. Surface symmetry across the
    // SDKs is worth less than that, and it costs nothing anyway: all three SDKs now carry this same
    // rule, so the 1:1 surface is intact. Nothing public changed — no new source, no new parameter.
    //
    // The rule: **a cache row can never satisfy a full-detail request.** `.cacheFirst` skips the
    // cache read and goes to the server; the response still writes the minimal projection back, so
    // later `.minimal` requests are as free as they ever were.
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, index in
      index == 0 ? .ok(json: Fixtures.minimalCheckJSON) : .ok(json: Fixtures.fullCheckJSON)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .cacheFirst, detail: .minimal)
    XCTAssertEqual(transport.callCount, 1)

    // A fresh row for this exact query is now cached, and the `.full` request must ignore it.
    let full = try await client.checkScammer(
      TestQueries.phone, source: .cacheFirst, detail: .full, locale: "id")

    XCTAssertEqual(full.origin, .server)
    XCTAssertEqual(transport.callCount, 2, "the cached minimal row must not have answered `.full`")
    // The narrative content is the whole point of `.full`: it must come from the server, not be
    // nil because a stripped row was dressed up as a full answer.
    XCTAssertEqual(full.comments?.count, 1)
    XCTAssertEqual(full.topChronologies?.count, 1)

    // …and the minimal projection of that response is still written back, so the cache keeps
    // working for the requests it can legitimately serve.
    let minimal = try await client.checkScammer(
      TestQueries.phone, source: .cacheFirst, detail: .minimal)
    XCTAssertEqual(minimal.origin, .cache)
    XCTAssertEqual(transport.callCount, 2)
  }

  /// With the cache read skipped for `.full`, `comments == nil` on a full-detail answer has exactly
  /// one meaning again: the server was asked and there is nothing on file.
  ///
  /// This test used to prove the opposite — that `origin` was the *only* thing separating "never
  /// fetched" from "none on file", because both shapes were reachable. Making `origin` a reliable
  /// discriminator was a real remedy, but it was one the caller had to remember to apply, and the
  /// failure mode for forgetting was a bank screen telling someone an active scammer is clean. The
  /// ambiguity is now removed at the source instead of being made detectable.
  func testFullDetailAnswersAlwaysComeFromTheServerSoNilMeansNoneOnFile() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    // Every response is minimal-shaped, i.e. carries no comments and no chronologies. That is what
    // a genuine "full detail, nothing on file" answer looks like on the wire.
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    let fromServer = try await client.checkScammer(
      TestQueries.phone, source: .server, detail: .full, locale: "id")
    XCTAssertNil(fromServer.comments)
    XCTAssertEqual(fromServer.origin, .server)

    // The same call on the default source, with the row the first call just stored sitting in the
    // cache. It must still reach the network, and it must still report `.server`.
    let onDefaultSource = try await client.checkScammer(
      TestQueries.phone, detail: .full, locale: "id")
    XCTAssertEqual(onDefaultSource.origin, .server)
    XCTAssertEqual(transport.callCount, 2)
    XCTAssertNil(onDefaultSource.comments)
    XCTAssertNil(onDefaultSource.topChronologies)

    // No `.full` result can carry `origin == .cache`, so a caller who never inspects `origin` at
    // all still cannot misread these fields.
    XCTAssertNotEqual(onDefaultSource.origin, .cache)
  }

  /// `.cache` is easy to overlook here, because its documented contract ("a miss throws rather than
  /// answering empty") sounds like it already protects against an empty answer. It did not: a *hit*
  /// on a minimal row is not a miss, so a `.full` request was answered from it with the full-detail
  /// fields nil and nothing was thrown.
  ///
  /// A cache row cannot satisfy a full-detail request, so for `.full` there is no such thing as a
  /// hit — the answer is the same `.cacheMiss` the caller already handles, and never a stripped row
  /// dressed up as a full answer. `.cache` still makes no network call, exactly as promised.
  func testCacheOnlySourceRefusesAFullDetailRequestWithACacheMiss() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server, detail: .minimal)
    XCTAssertEqual(transport.callCount, 1)

    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .cache, detail: .full)
    }

    XCTAssertEqual(error?.kind, .cacheMiss)
    XCTAssertEqual(transport.callCount, 1, "`.cache` must still never call the network")

    // The row is untouched: the same query at `.minimal` is still served from it.
    let minimal = try await client.checkScammer(TestQueries.phone, source: .cache)
    XCTAssertEqual(minimal.origin, .cache)
  }

  /// A full-detail answer must not be WRITTEN either, not merely skipped on read.
  ///
  /// The read gate and the write gate close different holes. `cacheableCopy()` keeps `tags` and
  /// `disclaimer`, and both vary by locale, while `CheckCacheKey` is the query alone with no locale
  /// in it. Only a `.full` request sends a `locale`, so storing its projection files locale-specific
  /// text under a locale-less key — and a later `.minimal` caller, which sends no locale at all,
  /// reads it back as though it were the default. `disclaimer` is the one string this SDK requires
  /// every integrator to render, so the visible failure is a legal notice in the wrong language.
  ///
  /// Gating only the read cannot prevent that: the row is poisoned on the way IN, by the `.full`
  /// call, and collected by a `.minimal` call that is reading the cache quite legitimately.
  func testAFullDetailAnswerIsNeverWrittenToTheCache() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    // The full-detail response carries the Indonesian text, because that is what `locale: "id"`
    // asks for; the later minimal response carries the default-locale text. Scripting both is what
    // makes the wrong-language outcome observable rather than merely argued for.
    let transport = FakeHTTPTransport { _, index in
      index == 0
        ? .ok(
          json: #"""
            {"found":true,"riskTier":"HIGH","reportTotal":12,"tags":["olshop-fiktif"],
             "disclaimer":"Indikatif, bukan vonis hukum."}
            """#)
        : .ok(
          json: #"""
            {"found":true,"riskTier":"HIGH","reportTotal":12,"tags":["fake-shop"],
             "disclaimer":"Indicative, not a legal ruling."}
            """#)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    let full = try await client.checkScammer(
      TestQueries.phone, source: .server, detail: .full, locale: "id")
    XCTAssertEqual(full.disclaimer, "Indikatif, bukan vonis hukum.")
    XCTAssertEqual(transport.callCount, 1)

    // Nothing was stored, so a cache-only minimal read finds no row rather than a localized one.
    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .cache)
    }
    XCTAssertEqual(
      error?.kind, .cacheMiss,
      "a full-detail answer carries locale-dependent tags and disclaimer; storing it would serve "
        + "them to a later minimal caller that asked for no locale")

    // The failure this prevents, stated as an outcome: the minimal caller must get the server's
    // default-locale text, never the Indonesian text a stored full-detail projection would supply.
    // Without this assertion the test still passes if someone reinstates the write and merely
    // strips one of the two fields, which would leave the same bug behind the other.
    let minimal = try await client.checkScammer(TestQueries.phone, detail: .minimal)
    XCTAssertEqual(minimal.disclaimer, "Indicative, not a legal ruling.")
    XCTAssertEqual(minimal.tags, ["fake-shop"])
    XCTAssertEqual(minimal.origin, .server)

    // …and *that* answer is cached, because a response that sent no locale is one the locale-less
    // key can safely hold. The cache is bypassed for full detail, not disabled by it.
    let cached = try await client.checkScammer(TestQueries.phone, source: .cache)
    XCTAssertEqual(cached.disclaimer, "Indicative, not a legal ruling.")
    XCTAssertEqual(transport.callCount, 2)
  }

  /// `.serverFirst`'s fallback shares the defect the cache read had: falling back to a stored
  /// minimal row on a network failure answers a `.full` request with `comments` nil, which reads as
  /// "none on file". A degraded answer is acceptable for `.minimal` — the risk tier is the same
  /// fact whether it is an hour old or fresh — but there is no degraded version of narrative
  /// content, only a missing one that looks like an empty one. So `.full` surfaces the network
  /// error and lets the caller decide.
  func testServerFirstDoesNotFallBackToACachedRowForFullDetail() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { _, index in
      if index == 0 { return .ok(json: Fixtures.minimalCheckJSON) }
      throw URLError(.notConnectedToInternet)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server, detail: .minimal)

    let error = await expectTraciveError {
      try await client.checkScammer(
        TestQueries.phone, source: .serverFirst, detail: .full, locale: "id")
    }
    XCTAssertEqual(error?.kind, .network)

    // The very same call at `.minimal` still degrades to the cache, so the fallback itself is
    // intact — it is only full detail that refuses to be faked.
    let degraded = try await client.checkScammer(TestQueries.phone, source: .serverFirst)
    XCTAssertEqual(degraded.origin, .cache)
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

  /// Sign-out takes the verdicts with it, not only the tokens.
  ///
  /// The rows were fetched under the departing user's grant and are keyed by `SHA-256` of a phone
  /// number or an email address — a search space small enough to brute-force offline. Leaving them
  /// behind lets the next person on the device confirm which identifiers the previous one looked
  /// up, and nothing about that failure is visible from inside the app.
  ///
  /// Asserted through a `.cache` read as well as through `count()`, because the property that
  /// matters is that the data is no longer *readable*, not that a counter reached zero.
  func testSignOutEmptiesTheResultCache() async throws {
    let clock = RecordingClock()
    let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock.provider)
    let transport = FakeHTTPTransport { request, _ in
      request.url.path.hasSuffix("oauth/revoke")
        ? HTTPResponse(status: 200)
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport, clock: clock, cache: cache)

    _ = try await client.checkScammer(TestQueries.phone, source: .server)
    XCTAssertEqual(try cache.count(), 1, "the check should have been cached in the first place")

    await client.signOut()

    XCTAssertEqual(try cache.count(), 0, "the departing user's verdicts survived sign-out")
    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .cache)
    }
    XCTAssertEqual(error?.kind, .cacheMiss)
  }

  /// A store that cannot be emptied must not keep a user signed in.
  ///
  /// `clear()` throws, and the tokens are already gone by the time it runs, so a propagating failure
  /// would report a sign-out that half happened. The rows stay subject to `CachePolicy` expiry.
  func testSignOutStillDropsTheGrantWhenTheCacheCannotBeCleared() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in HTTPResponse(status: 200) }
    let client = makeClient(
      transport: transport,
      cache: UnclearableCheckCache(),
      tokenStore: store
    )

    await client.signOut()

    XCTAssertNil(try store.load(), "a failing cache clear blocked the sign-out")
    let authorized = await client.isAuthorized
    XCTAssertFalse(authorized)
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

  /// Cold start: the first call of a session, with a stored token that expired while the app was
  /// closed.
  ///
  /// This is the least-exercised corner of the reactive path, and it is the one with nothing in
  /// front of it. Every other refresh test starts from a token the session has already used
  /// successfully; here the very first request carries a token that is already dead, and the 401 is
  /// the only thing that can discover it. In a sibling SDK a pre-emptive expiry check meant this
  /// request never reached the server with a dead token at all — that check is being removed
  /// everywhere, so this path becomes the only one, and it is worth pinning rather than assuming.
  ///
  /// The assertion that matters is the *first* outbound header: the SDK must send `access-1` even
  /// though it is holding an `expiresAt` in the past. Sending it is the design, not an oversight.
  func testAnExpiredStoredTokenIsRefreshedOnTheFirstCallOfASession() async throws {
    let clock = RecordingClock()
    let expired = TraciveTokens(
      accessToken: "access-1",
      refreshToken: "refresh-1",
      tokenType: "Bearer",
      // An hour past its deadline: the ordinary state of a token after an overnight close.
      expiresAt: clock.now.addingTimeInterval(-3600),
      scopes: ["scammer.check", "credits.read"]
    )
    let store = InMemoryTokenStore(tokens: expired)
    XCTAssertTrue(expired.isExpired(at: clock.now), "the fixture must actually be expired")

    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("oauth/token") {
        return .ok(json: Fixtures.refreshedTokenJSON)
      }
      return request.header("Authorization") == "Bearer access-1"
        ? .error(status: 401, code: "expired_token")
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport, clock: clock, tokenStore: store)

    let result = try await client.checkScammer(TestQueries.phone, source: .server)

    XCTAssertEqual(result.riskTier, .high)
    // The expired token went out rather than being pre-empted, and the 401 it earned drove exactly
    // one refresh and one replay.
    XCTAssertEqual(transport.requests.first?.header("Authorization"), "Bearer access-1")
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 1)
    XCTAssertEqual(transport.count(pathSuffix: "scammer-checks"), 2)
    XCTAssertEqual(transport.requests.last?.header("Authorization"), "Bearer access-2")
    XCTAssertEqual(try store.load()?.accessToken, "access-2")
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

  // MARK: - A blank stored access token

  /// A stored grant whose access token is blank but whose refresh token is intact.
  ///
  /// Reachable from a partial write, a Keychain save interrupted by a termination, or a restored
  /// backup: `TraciveTokens.accessToken` is a plain `String`, so a record holding `""` decodes as
  /// cleanly as any other. The refresh token beside it is untouched, and that is the grant — so the
  /// SDK renews rather than sending `Bearer ` or discarding a credential that still works.
  ///
  /// The 401 path cannot stand in for this. An empty bearer is malformed, not expired: the server
  /// answers `invalid_token`, and this SDK treats that as terminal — see
  /// `testInvalidTokenIsSurfacedWithoutAttemptingARefresh`. So the damaged record would fail
  /// permanently rather than heal, one wasted round trip at a time.
  func testABlankStoredAccessTokenIsRefreshedInsteadOfBeingSent() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.damagedTokens)
    let transport = FakeHTTPTransport { request, _ in
      request.url.path.hasSuffix("oauth/token")
        ? .ok(json: Fixtures.refreshedTokenJSON)
        : .ok(json: Fixtures.minimalCheckJSON)
    }
    let client = makeClient(transport: transport, tokenStore: store)

    let result = try await client.checkScammer(TestQueries.phone)

    // The caller never sees the damage at all.
    XCTAssertEqual(result.riskTier, .high)
    // One refresh, and the check goes out **once** — the recovery happens before the first send,
    // so no round trip is spent discovering it.
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 1)
    XCTAssertEqual(transport.count(pathSuffix: "scammer-checks"), 1)
    XCTAssertEqual(transport.requests.last?.header("Authorization"), "Bearer access-2")
    Self.assertNoEmptyBearerReachedTheTransport(transport)
    // Rotation landed, so the record is whole again rather than repaired for one call.
    XCTAssertEqual(try store.load()?.accessToken, "access-2")
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
  }

  /// The same damaged record with nothing to renew it. There is no credential left here, so this
  /// is terminal — and it fails without spending a request, exactly as the no-grant path does.
  ///
  /// It is reported as `.invalidToken`, not `.grantRevoked`. Nothing reached the server on this
  /// path, so nothing could have been revoked; saying otherwise sent a partner watching for
  /// revocation to look for a server-side event that never took place.
  func testABlankStoredAccessTokenWithNoRefreshTokenFailsBeforeAnyNetworkIO() async throws {
    let unusable = TraciveTokens(
      accessToken: "",
      refreshToken: nil,
      tokenType: "Bearer",
      expiresAt: nil,
      scopes: ["scammer.check", "credits.read"]
    )
    let store = InMemoryTokenStore(tokens: unusable)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .invalidToken)
    XCTAssertEqual(error?.serverCode, "unusable_grant")
    // Neither the check nor a refresh was attempted: nothing on the wire could have helped.
    XCTAssertEqual(transport.callCount, 0)
    Self.assertNoEmptyBearerReachedTheTransport(transport)
    // The record is left exactly as it was found. Reading damage is not a reason to erase it, and
    // every subsequent call reports the same thing rather than a second, different failure.
    XCTAssertEqual(try store.load(), unusable)
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

  /// Asserts that no request carried an `Authorization` header with an empty token.
  ///
  /// Written against the header's *value* rather than against a request count, because a count
  /// proves only that some request was skipped — this proves that whatever did go out was
  /// authenticated. A bare `Bearer` with no trailing space is caught too: `setHeader` is given
  /// `"Bearer " + token`, so an empty token produces the trailing-space form, but a future
  /// refactor that trimmed would produce the other one and it would be no more valid.
  private static func assertNoEmptyBearerReachedTheTransport(
    _ transport: FakeHTTPTransport,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let empties = transport.requests
      .compactMap { $0.header("Authorization") }
      .filter { $0.trimmingCharacters(in: .whitespaces) == "Bearer" }
    XCTAssertEqual(
      empties, [],
      "an empty bearer reached the transport", file: file, line: line
    )
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

/// A cache whose `clear()` always throws — a locked database file, a full disk, a store the app no
/// longer has permission to write. Everything else behaves like `NoOpCheckCache`.
final class UnclearableCheckCache: CheckCache {

  struct Failure: Error {}

  let policy: CachePolicy

  init(policy: CachePolicy = .default) {
    self.policy = policy
  }

  func read(_ key: CheckCacheKey) throws -> CheckResult? { nil }
  func write(_ result: CheckResult, for key: CheckCacheKey) throws {}
  func remove(_ key: CheckCacheKey) throws {}
  func clear() throws { throw Failure() }

  @discardableResult
  func prune() throws -> Int { 0 }

  func count() throws -> Int { 0 }
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

  /// `storedTokens` with the access token blanked and the refresh token left intact.
  ///
  /// Not a contrived value: `TraciveTokens.accessToken` is a plain `String`, so a stored record
  /// whose `access_token` is `""` decodes as cleanly as any other — which is what a partial write,
  /// a Keychain save interrupted by a termination, or a restored backup can leave behind.
  static let damagedTokens = TraciveTokens(
    accessToken: "",
    refreshToken: "refresh-1",
    tokenType: "Bearer",
    expiresAt: nil,
    scopes: ["scammer.check", "credits.read"]
  )
}

// MARK: - The shared retry defaults

/// The five default retry parameters, pinned as literals.
///
/// These numbers are the shared cross-SDK contract, and nothing enforced them. The four Tracive SDKs
/// shipped three different initial backoffs and two jitter ratios, with no reason recorded anywhere
/// for any of them — which is exactly how a value nobody chose survives review in four repositories
/// at once. `RetryPolicy` now carries the reasoning for each number; this pins the numbers, so a
/// change has to be a deliberate one that shows up in a diff rather than an unexamined tweak.
///
/// Asserted against literals rather than against `RetryPolicy()` or against each other, because a
/// test that compares a symbol to itself passes through any redefinition of it.
final class RetryPolicyTests: XCTestCase {

  func testTheDefaultPolicyIsTheSharedCrossSDKSet() {
    let policy = RetryPolicy.default

    XCTAssertEqual(policy.maxAttempts, 3)
    XCTAssertEqual(policy.initialBackoff, 0.5, accuracy: 0)
    XCTAssertEqual(policy.multiplier, 2.0, accuracy: 0)
    XCTAssertEqual(policy.maxBackoff, 8.0, accuracy: 0)
    XCTAssertEqual(policy.jitter, 0.2, accuracy: 0)
    XCTAssertTrue(policy.respectsRetryAfter)
  }

  /// The schedule those numbers actually produce, which is the thing an integrator experiences.
  /// Jitter is switched off so the assertion is on the curve rather than on a random draw.
  func testTheDefaultScheduleIsHalfASecondThenOne() {
    var policy = RetryPolicy.default
    policy.jitter = 0

    XCTAssertEqual(policy.delay(forRetry: 1), 0.5, accuracy: 1e-9)
    XCTAssertEqual(policy.delay(forRetry: 2), 1.0, accuracy: 1e-9)
    // Two retries is all `maxAttempts: 3` allows, so the ceiling is never reached by default.
    XCTAssertFalse(policy.allowsAnotherAttempt(after: 3))
  }

  /// `maxBackoff` binds only when a caller asks for more attempts than the default allows. Pinned
  /// because a ceiling that is never exercised is a number nobody notices going wrong.
  func testTheCeilingBindsOnceACallerRaisesMaxAttempts() {
    var policy = RetryPolicy(maxAttempts: 10)
    policy.jitter = 0

    // 0.5, 1, 2, 4, 8, then held at 8 rather than continuing to 16.
    XCTAssertEqual(policy.delay(forRetry: 5), 8.0, accuracy: 1e-9)
    XCTAssertEqual(policy.delay(forRetry: 6), 8.0, accuracy: 1e-9)
  }

  /// Jitter only ever shortens a delay. If it could lengthen one, `maxBackoff` would stop being a
  /// ceiling and the worst case would no longer be the one documented.
  func testJitterOnlyEverShortensADelay() {
    let policy = RetryPolicy.default
    // Derived rather than written as a literal, so this test measures the jitter band alone and
    // does not also re-assert the schedule that `testTheDefaultScheduleIsHalfASecondThenOne` pins.
    var undithered = policy
    undithered.jitter = 0
    let base = undithered.delay(forRetry: 2)

    for _ in 0..<200 {
      let delay = policy.delay(forRetry: 2)
      XCTAssertLessThanOrEqual(delay, base)
      XCTAssertGreaterThanOrEqual(delay, base * (1 - policy.jitter))
    }
  }

  /// A server asking for a specific window wins outright, including past `maxBackoff`: a server that
  /// says 60 s means it, and second-guessing it is how a client turns a rate limit into a ban.
  func testRetryAfterWinsOverTheComputedBackoffAndTheCeiling() {
    let policy = RetryPolicy.default

    XCTAssertEqual(policy.delay(forRetry: 1, retryAfter: 60), 60, accuracy: 0)
  }
}
