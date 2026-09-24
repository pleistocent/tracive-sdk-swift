import XCTest

@testable import TraciveSDK

/// Model-layer contract tests: wire decoding, forward compatibility, cache projection, TTL rules,
/// configuration surface and the error map.
///
/// No network: every payload here is a literal.
final class ModelTests: XCTestCase {

  // MARK: - Helpers

  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  private func instant(_ iso: String) throws -> Date {
    try XCTUnwrap(TraciveISO8601.date(from: iso))
  }

  // MARK: - CheckResult decoding

  func testFullDetailResponseDecodes() throws {
    let json = """
      {
        "checkId": "chk_123",
        "found": true,
        "riskTier": "HIGH",
        "reportTotal": 12,
        "credibleReports": 9,
        "ambiguousReports": 3,
        "firstReportOn": "2025-01-02T03:04:05Z",
        "lastReportOn": "2026-07-09T10:00:00.250Z",
        "fraudAmount": { "IDR": 12500000, "USD": 800.5 },
        "tags": ["investment", "telegram"],
        "relatedScammerCount": 4,
        "topChronologies": [
          { "chronology": "Asked for a deposit up front", "riskLevel": 3, "incidentDate": "2025-01" }
        ],
        "comments": [
          { "date": "2025-02-01", "text": "Lost money", "fromCredibleReport": true }
        ],
        "billing": { "creditSource": "USER", "unitsCharged": 1 },
        "cacheTtlSeconds": 3600,
        "disclaimer": "Informational only; verify independently."
      }
      """

    let result = try decode(CheckResult.self, json)

    XCTAssertEqual(result.checkId, "chk_123")
    XCTAssertTrue(result.found)
    XCTAssertEqual(result.riskTier, .high)
    XCTAssertEqual(result.reportTotal, 12)
    XCTAssertEqual(result.credibleReports, 9)
    XCTAssertEqual(result.ambiguousReports, 3)
    XCTAssertEqual(result.firstReportOn, try instant("2025-01-02T03:04:05Z"))
    XCTAssertEqual(result.lastReportOn, try instant("2026-07-09T10:00:00.250Z"))
    XCTAssertEqual(result.fraudAmount, ["IDR": 12_500_000, "USD": 800.5])
    XCTAssertEqual(result.tags, ["investment", "telegram"])
    XCTAssertEqual(result.relatedScammerCount, 4)
    XCTAssertEqual(result.topChronologies?.count, 1)
    XCTAssertEqual(result.topChronologies?.first?.riskLevel, 3)
    XCTAssertEqual(result.topChronologies?.first?.incidentDate, "2025-01")
    XCTAssertEqual(result.comments?.first?.fromCredibleReport, true)
    XCTAssertEqual(result.billing?.creditSource, .user)
    XCTAssertEqual(result.billing?.unitsCharged, 1)
    XCTAssertNil(result.billing?.partnerBalanceRemaining)
    XCTAssertEqual(result.disclaimer, "Informational only; verify independently.")

    // Provenance is SDK-side: a server payload carries neither field.
    XCTAssertEqual(result.origin, .server)
    XCTAssertLessThan(abs(result.fetchedAt.timeIntervalSinceNow), 10)
  }

  func testMinimalResponseDecodesWithDefaults() throws {
    let result = try decode(CheckResult.self, #"{ "found": false, "riskTier": "NONE" }"#)

    XCTAssertNil(result.checkId)
    XCTAssertFalse(result.found)
    XCTAssertEqual(result.riskTier, RiskTier.none)
    XCTAssertEqual(result.reportTotal, 0)
    XCTAssertEqual(result.credibleReports, 0)
    XCTAssertEqual(result.ambiguousReports, 0)
    XCTAssertNil(result.firstReportOn)
    XCTAssertNil(result.lastReportOn)
    XCTAssertEqual(result.fraudAmount, [:])
    XCTAssertEqual(result.tags, [])
    XCTAssertEqual(result.relatedScammerCount, 0)
    XCTAssertNil(result.topChronologies)
    XCTAssertNil(result.comments)
    XCTAssertNil(result.billing)
  }

  /// Forward compatibility: a future-version server may add fields; shipped apps must not break.
  func testUnknownFieldsAreIgnored() throws {
    let json = """
      {
        "found": true,
        "riskTier": "CAUTION",
        "futureScoreBreakdown": { "velocity": 0.8, "graph": [1, 2, 3] },
        "anotherNewScalar": 42,
        "aNewNull": null
      }
      """
    let result = try decode(CheckResult.self, json)
    XCTAssertEqual(result.riskTier, .caution)
    XCTAssertTrue(result.found)
  }

  /// The two load-bearing fields are decoded strictly, so a broken payload fails loudly instead of
  /// reading as a clean result.
  func testMissingLoadBearingFieldsThrow() {
    XCTAssertThrowsError(try decode(CheckResult.self, #"{ "riskTier": "HIGH" }"#))
    XCTAssertThrowsError(try decode(CheckResult.self, #"{ "found": true }"#))
  }

  /// An unrecognised tier throws rather than degrading. Quietly mapping a future tier onto `.none`
  /// would understate risk in a fraud warning — silent and expensive. A decode error is loud.
  func testUnknownRiskTierThrows() {
    XCTAssertThrowsError(try decode(CheckResult.self, #"{ "found": true, "riskTier": "SEVERE" }"#))
  }

  /// Counts sent as strings or doubles still read as numbers; an unparseable instant reads as
  /// absent rather than failing the whole response.
  func testLenientScalarDecoding() throws {
    let json = """
      {
        "found": true,
        "riskTier": "ELEVATED",
        "reportTotal": "7",
        "credibleReports": 4.0,
        "cacheTtlSeconds": "900",
        "firstReportOn": "not-a-date"
      }
      """
    let result = try decode(CheckResult.self, json)
    XCTAssertEqual(result.reportTotal, 7)
    XCTAssertEqual(result.credibleReports, 4)
    XCTAssertNil(result.firstReportOn)
    // `cacheTtlSeconds` is retired and no longer a property. It stays in the payload above because
    // a server or proxy may still send it, and `Codable` must skip an unmodelled key rather than
    // throw — if it threw, `decode` would have failed before any assertion here ran.
  }

  func testIso8601AcceptsWholeSecondsFractionsAndOffsets() throws {
    let whole = try instant("2026-07-09T10:00:00Z")
    let fractional = try instant("2026-07-09T10:00:00.000Z")
    let offset = try instant("2026-07-09T17:00:00+07:00")
    XCTAssertEqual(whole, fractional)
    XCTAssertEqual(whole, offset)
    XCTAssertEqual(TraciveISO8601.string(from: whole), "2026-07-09T10:00:00Z")
    XCTAssertNil(TraciveISO8601.date(from: ""))
    XCTAssertNil(TraciveISO8601.date(from: "9 July 2026"))
  }

  // MARK: - Cache projection

  func testCacheableCopyDropsRequestSpecificFields() throws {
    let result = CheckResult(
      checkId: "chk_1",
      found: true,
      riskTier: .high,
      reportTotal: 3,
      topChronologies: [Chronology(chronology: "c", riskLevel: 1)],
      comments: [Comment(date: "2026-01-01", text: "t", fromCredibleReport: true)],
      billing: Billing(creditSource: .user, unitsCharged: 1),
      disclaimer: "d",
      origin: .server,
      fetchedAt: try instant("2026-07-09T10:00:00Z")
    )

    let cached = result.cacheableCopy()

    // Dropped: they vary with `detail`/`locale`, or identify one specific server-side check.
    XCTAssertNil(cached.checkId)
    XCTAssertNil(cached.topChronologies)
    XCTAssertNil(cached.comments)
    XCTAssertNil(cached.billing)
    // Kept: invariant across detail/locale.
    XCTAssertEqual(cached.found, result.found)
    XCTAssertEqual(cached.riskTier, result.riskTier)
    XCTAssertEqual(cached.reportTotal, result.reportTotal)
    XCTAssertEqual(cached.disclaimer, result.disclaimer)
    XCTAssertEqual(cached.fetchedAt, result.fetchedAt)
    XCTAssertEqual(cached.origin, .cache)
  }

  func testWithOriginStampsProvenanceWithoutTouchingData() throws {
    let fetchedAt = try instant("2026-07-09T10:00:00Z")
    let result = CheckResult(found: true, riskTier: .elevated, fetchedAt: fetchedAt)

    let stamped = result.withOrigin(.cache)
    XCTAssertEqual(stamped.origin, .cache)
    XCTAssertEqual(stamped.fetchedAt, fetchedAt, "a cache hit reports the age of the data, not of the answer")

    let refetched = result.withOrigin(.server, fetchedAt: fetchedAt.addingTimeInterval(3600))
    XCTAssertEqual(refetched.fetchedAt, fetchedAt.addingTimeInterval(3600))
    XCTAssertEqual(refetched.riskTier, .elevated)
  }

  /// A cache record must survive encode → decode unchanged, provenance included.
  func testCacheRoundTripIsLossless() throws {
    let original = CheckResult(
      found: true,
      riskTier: .high,
      reportTotal: 5,
      credibleReports: 4,
      ambiguousReports: 1,
      firstReportOn: try instant("2025-01-02T03:04:05Z"),
      lastReportOn: try instant("2026-07-09T10:00:00Z"),
      fraudAmount: ["IDR": 5_000_000],
      tags: ["telegram"],
      relatedScammerCount: 2,
      disclaimer: "Informational only.",
      origin: .cache,
      fetchedAt: try instant("2026-07-09T11:22:33Z")
    ).cacheableCopy()

    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(CheckResult.self, from: data)

    XCTAssertEqual(restored, original)
    XCTAssertEqual(restored.origin, .cache)
    XCTAssertEqual(restored.fetchedAt, original.fetchedAt)
  }

  // MARK: - CachePolicy

  func testDefaultTtlsMatchTheSpec() {
    let policy = CachePolicy.default
    XCTAssertEqual(policy.ttl(for: .high), 30 * 24 * 60 * 60)
    XCTAssertEqual(policy.ttl(for: .elevated), 7 * 24 * 60 * 60)
    XCTAssertEqual(policy.ttl(for: .caution), 24 * 60 * 60)
    XCTAssertEqual(policy.ttl(for: RiskTier.none), 60 * 60)
    XCTAssertTrue(policy.isEnabled)
  }

  /// The default cap, pinned against a literal.
  ///
  /// It used to be `nil`. Nothing else bounds the file: lazy expiry only touches rows that are read
  /// again, and the prune pass only removes rows that have already expired, so a `HIGH` verdict's
  /// thirty days is thirty days of unbounded growth on someone's phone. The Flutter SDK bounds the
  /// same store at the same number, and asserting the literal rather than `CachePolicy().maxEntries`
  /// is what makes a change to it show up here instead of comparing a symbol with itself.
  func testTheDefaultPolicyBoundsTheStore() {
    XCTAssertEqual(CachePolicy.default.maxEntries, 5_000)
    XCTAssertEqual(CachePolicy.disabled.maxEntries, 5_000)
    XCTAssertNil(CachePolicy(maxEntries: nil).maxEntries, "unbounded stays available on request")
  }

  /// A host can zero a tier, and zero has a second meaning: the cache stores nothing at all.
  func testATierTtlCanBeZeroSoAHostCanRefuseToCacheThatTier() {
    var policy = CachePolicy.default
    policy.noneTtl = 0
    XCTAssertEqual(policy.ttl(for: RiskTier.none), 0)
    XCTAssertEqual(policy.ttl(for: .high), 30 * 24 * 60 * 60)
  }

  func testFreshnessUsesFetchedAtAndTheTierTtl() throws {
    let fetchedAt = try instant("2026-07-09T10:00:00Z")
    let result = CheckResult(found: true, riskTier: .caution, origin: .cache, fetchedAt: fetchedAt)

    XCTAssertTrue(CachePolicy.default.isFresh(result, now: fetchedAt.addingTimeInterval(23 * 3600)))
    XCTAssertFalse(CachePolicy.default.isFresh(result, now: fetchedAt.addingTimeInterval(25 * 3600)))
    XCTAssertFalse(
      CachePolicy.disabled.isFresh(result, now: fetchedAt),
      "a disabled cache must never report an entry as fresh")

    var shortLived = CachePolicy.default
    shortLived.cautionTtl = 60
    XCTAssertFalse(shortLived.isFresh(result, now: fetchedAt.addingTimeInterval(120)))
  }

  // MARK: - Wire vocabulary

  func testEnumRawValuesMatchTheWire() {
    XCTAssertEqual(RiskTier.allCases.map(\.rawValue), ["HIGH", "ELEVATED", "CAUTION", "NONE"])
    XCTAssertEqual(Origin.allCases.map(\.rawValue), ["CACHE", "SERVER"])
    // The request body literally carries lowercase: {"detail": "minimal"}.
    XCTAssertEqual(Detail.allCases.map(\.rawValue), ["minimal", "full"])
    XCTAssertEqual(
      Source.allCases.map(\.rawValue), ["CACHE_FIRST", "SERVER", "SERVER_FIRST", "CACHE"])
    XCTAssertEqual(ClientType.allCases.map(\.rawValue), ["PUBLIC", "CONFIDENTIAL"])
    XCTAssertEqual(
      TraciveQuery.Kind.allCases.map(\.rawValue),
      ["PHONE", "EMAIL", "BANK", "CRYPTO", "USERNAME"])
  }

  func testCreditSourceKeepsUnknownValuesInsteadOfFailing() throws {
    let billing = try decode(
      Billing.self, #"{ "creditSource": "FUTURE_POOL", "unitsCharged": 2, "partnerBalanceRemaining": 98 }"#)
    XCTAssertEqual(billing.creditSource, .other("FUTURE_POOL"))
    XCTAssertEqual(billing.creditSource.rawValue, "FUTURE_POOL")
    XCTAssertEqual(billing.unitsCharged, 2)
    XCTAssertEqual(billing.partnerBalanceRemaining, 98)

    let encoded = try JSONEncoder().encode(billing)
    XCTAssertEqual(try JSONDecoder().decode(Billing.self, from: encoded), billing)
  }

  // MARK: - credits / profile

  func testCreditsInfoDecodes() throws {
    let credits = try decode(
      CreditsInfo.self,
      #"{ "subscriptionCredits": 25, "tier": "PRO", "nextResetAt": "2026-08-01T00:00:00Z", "extra": 1 }"#
    )
    XCTAssertEqual(credits.subscriptionCredits, 25)
    XCTAssertEqual(credits.tier, "PRO")
    XCTAssertEqual(credits.nextResetAt, try instant("2026-08-01T00:00:00Z"))
  }

  func testProfileInfoDecodesAndRedactsIdentity() throws {
    let profile = try decode(
      ProfileInfo.self,
      #"{ "sub": "user_abc", "name": "Budi Santoso", "country": "IDN", "tier": "PRO", "memberSince": "2024-05-01T00:00:00Z" }"#
    )
    XCTAssertEqual(profile.sub, "user_abc")
    XCTAssertEqual(profile.name, "Budi Santoso")
    XCTAssertEqual(profile.memberSince, try instant("2024-05-01T00:00:00Z"))

    XCTAssertFalse(profile.description.contains("Budi"))
    XCTAssertFalse(profile.description.contains("user_abc"))
    XCTAssertTrue(profile.description.contains("IDN"))
  }

  /// `GET /v1/profile` sends `memberSince` as a plain date: the server truncates the account's
  /// creation timestamp, and its spec types the field `format: date`. Every real user has one, so
  /// dropping it silently emptied the field for everybody rather than in some edge case.
  ///
  /// The expected value is built from calendar components rather than from `TraciveISO8601`, so
  /// the assertion cannot agree with the parser it is checking.
  func testProfileInfoReadsADateOnlyMemberSince() throws {
    let profile = try decode(
      ProfileInfo.self,
      #"{ "sub": "user_abc", "name": "Nico", "country": "IDN", "tier": "plus", "memberSince": "2025-03-14" }"#
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let expected = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2025, month: 3, day: 14)))

    XCTAssertEqual(profile.memberSince, expected)
  }

  /// Tolerance adds a shape; it does not make the parser guess. A value that is neither an instant
  /// nor a date stays nil rather than becoming some nearby date.
  func testProfileInfoLeavesAnUnparseableMemberSinceNil() throws {
    let profile = try decode(
      ProfileInfo.self, #"{ "sub": "user_abc", "memberSince": "last Tuesday" }"#)
    XCTAssertNil(profile.memberSince)
  }

  /// A narrow OAuth grant legitimately returns only a subject id.
  func testProfileInfoToleratesAScopeLimitedResponse() throws {
    let profile = try decode(ProfileInfo.self, #"{ "sub": "user_abc" }"#)
    XCTAssertNil(profile.name)
    XCTAssertNil(profile.country)
    XCTAssertNil(profile.memberSince)
  }

  // MARK: - Configuration

  func testEnvironmentBaseUrls() throws {
    XCTAssertEqual(TraciveEnvironment.production.baseUrl.absoluteString, "https://api.tracive.id/v1")
    XCTAssertEqual(
      TraciveEnvironment.sandbox.baseUrl.absoluteString, "https://api-sandbox.tracive.id/v1")

    let custom = try XCTUnwrap(TraciveEnvironment.custom(baseUrlString: "http://127.0.0.1:8080/v1"))
    XCTAssertEqual(custom.baseUrl.absoluteString, "http://127.0.0.1:8080/v1")
    XCTAssertEqual(custom, .custom(baseUrl: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1"))))
  }

  func testPartnerUserIdRuleMatchesTheServer() {
    for refused in [
      "", "   ", String(repeating: "x", count: 201), "budi@example.com", "budi@localhost",
      "+6281234567890", "0812-3456-7890", "628123456789", "(0812) 3456 7890",
    ] {
      XCTAssertNotNil(OAuthConfiguration.partnerUserIdProblem(refused), refused)
    }
    for accepted in [
      String(repeating: "x", count: 200), "1234567890", "cif-00012345", "user-ñ-日本",
    ] {
      XCTAssertNil(OAuthConfiguration.partnerUserIdProblem(accepted), accepted)
    }
  }

  func testOAuthModeDefaultsToAPublicClient() throws {
    let redirect = try XCTUnwrap(URL(string: "https://partner.example/oauth/callback"))
    let mode = TraciveMode.oauth(
      clientId: "partner-123", redirectUri: redirect, partnerUserId: "partner-user-1")

    let configuration = try XCTUnwrap(mode.oauthConfiguration)
    XCTAssertEqual(configuration.clientId, "partner-123")
    XCTAssertEqual(configuration.redirectUri, redirect)
    XCTAssertEqual(configuration.scopes, [])
    XCTAssertEqual(configuration.partnerUserId, "partner-user-1")
    XCTAssertEqual(configuration.clientType, .public)
    XCTAssertNil(mode.proxyConfiguration)

    let confidential = TraciveMode.oauth(
      clientId: "partner-123",
      redirectUri: redirect,
      scopes: ["scammer.check", "profile.read"],
      partnerUserId: "u-9",
      clientType: .confidential
    )
    XCTAssertEqual(confidential.oauthConfiguration?.clientType, .confidential)
    XCTAssertEqual(confidential.oauthConfiguration?.scopes, ["scammer.check", "profile.read"])
  }

  func testProxyModeExistsButRedactsItsHeaders() throws {
    let baseUrl = try XCTUnwrap(URL(string: "https://partner.example/tracive"))
    let mode = TraciveMode.proxy(baseUrl: baseUrl, authHeaders: ["Authorization": "Bearer secret"])

    let configuration = try XCTUnwrap(mode.proxyConfiguration)
    XCTAssertEqual(configuration.baseUrl, baseUrl)
    XCTAssertEqual(configuration.authHeaders["Authorization"], "Bearer secret")
    XCTAssertFalse(configuration.description.contains("secret"))
    XCTAssertTrue(configuration.description.contains("Authorization"))

    // The exact message every SDK must fail Proxy-mode calls with, until phase 2.
    XCTAssertEqual(TraciveError.proxyModeNotImplemented.kind, .notImplemented)
    XCTAssertEqual(
      TraciveError.proxyModeNotImplemented.errorDescription, "Proxy mode arrives in phase 2")
  }

  // MARK: - AuthResult

  func testAuthResultRedactsCodeAndVerifier() {
    let result = AuthResult.codeReceived(
      code: "authcode-abc", codeVerifier: "verifier-xyz", redirectUri: "https://partner.example/cb")
    XCTAssertFalse(result.description.contains("authcode-abc"))
    XCTAssertFalse(result.description.contains("verifier-xyz"))
    XCTAssertTrue(result.description.contains("https://partner.example/cb"))

    XCTAssertEqual(
      AuthResult.authorized(grantedScopes: ["a", "b"]).description,
      "authorized(grantedScopes: [a b])")
    XCTAssertEqual(AuthResult.appNotInstalled.description, "appNotInstalled")

    if case .failed(let error) = AuthResult.failed(.stateMismatch) {
      XCTAssertEqual(error.kind, .stateMismatch)
    } else {
      XCTFail("expected .failed")
    }
  }

  // MARK: - Error mapping

  func testErrorMappingTable() {
    let cases: [(Int, String, TraciveErrorKind)] = [
      (400, "invalid_request", .invalidRequest),
      (400, "unsupported_input_type", .unsupportedInputType),
      (400, "unsupported_credit_source", .unsupportedCreditSource),
      (401, "invalid_token", .invalidToken),
      (401, "expired_token", .expiredToken),
      (401, "grant_revoked", .grantRevoked),
      (401, "invalid_api_key", .invalidApiKey),
      (402, "insufficient_user_credits", .insufficientCredits),
      (402, "insufficient_credits", .insufficientCredits),
      (402, "insufficient_partner_balance", .insufficientCredits),
      (403, "missing_scope", .missingScope),
      (403, "detail_not_permitted", .detailNotPermitted),
      (403, "credential_mismatch", .credentialMismatch),
      (403, "partner_suspended", .partnerSuspended),
      (403, "user_credit_not_permitted", .userCreditNotPermitted),
      (403, "translation_not_permitted", .translationNotPermitted),
      (409, "idempotency_conflict", .idempotencyConflict),
      (429, "rate_limited", .rateLimited),
    ]

    for (status, code, expected) in cases {
      let error = TraciveError.from(status: status, code: code, message: "m", checkId: "chk_1")
      XCTAssertEqual(error.kind, expected, "\(status) \(code)")
      XCTAssertEqual(error.serverCode, code)
      XCTAssertEqual(error.info?.checkId, "chk_1")
      XCTAssertEqual(error.errorDescription, "m")
    }
  }

  func testInsufficientCreditsCarriesWhichBalanceRanOut() {
    guard
      case .insufficientCredits(let which, _) = TraciveError.from(
        status: 402, code: "insufficient_partner_balance")
    else {
      return XCTFail("expected .insufficientCredits")
    }
    XCTAssertEqual(which, .partnerBalance)
  }

  /// An unrecognised code must never crash and must never lose the raw code.
  func testUnrecognisedCodesDegradeGracefully() {
    let futureClientError = TraciveError.from(status: 400, code: "future_new_rule")
    XCTAssertEqual(futureClientError.kind, .unknown)
    XCTAssertEqual(futureClientError.serverCode, "future_new_rule")

    let serverError = TraciveError.from(status: 503, code: "upstream_unavailable")
    XCTAssertEqual(serverError.kind, .server)
    XCTAssertEqual(serverError.serverCode, "upstream_unavailable")
    XCTAssertTrue(serverError.isTransient)

    let bodyless = TraciveError.from(status: 500, code: nil)
    XCTAssertEqual(bodyless.kind, .server)
    XCTAssertNil(bodyless.serverCode)

    // Any 429 is a rate limit even if the code is spelled differently.
    XCTAssertEqual(TraciveError.from(status: 429, code: "throttled").kind, .rateLimited)
  }

  func testTransienceDoesNotImplyPermissionToRetry() {
    // Retrying a checkScammer on any of these without an Idempotency-Key risks a double charge.
    XCTAssertTrue(TraciveError.network(cause: URLError(.timedOut)).isTransient)
    XCTAssertTrue(TraciveError.from(status: 429, code: "rate_limited").isTransient)
    XCTAssertFalse(TraciveError.from(status: 402, code: "insufficient_credits").isTransient)
    XCTAssertFalse(TraciveError.cacheMiss.isTransient)
    XCTAssertFalse(TraciveError.from(status: 409, code: "idempotency_conflict").isTransient)
  }

  func testRetryAfterHeaderParsing() throws {
    XCTAssertEqual(TraciveError.retryAfterSeconds(from: "120"), 120)
    XCTAssertEqual(TraciveError.retryAfterSeconds(from: "  90  "), 90)
    XCTAssertEqual(TraciveError.retryAfterSeconds(from: "-5"), 0)
    XCTAssertNil(TraciveError.retryAfterSeconds(from: nil))
    XCTAssertNil(TraciveError.retryAfterSeconds(from: ""))
    XCTAssertNil(TraciveError.retryAfterSeconds(from: "soon"))

    let httpDate = "Wed, 21 Oct 2026 07:28:00 GMT"
    XCTAssertEqual(
      TraciveError.retryAfterSeconds(from: httpDate, now: try instant("2026-10-21T07:27:00Z")), 60)
    XCTAssertEqual(
      TraciveError.retryAfterSeconds(from: httpDate, now: try instant("2026-10-21T08:00:00Z")), 0)

    let rateLimited = TraciveError.from(
      status: 429, code: "rate_limited", retryAfter: TraciveError.retryAfterSeconds(from: "30"))
    guard case .rateLimited(let retryAfter, _) = rateLimited else {
      return XCTFail("expected .rateLimited")
    }
    XCTAssertEqual(retryAfter, 30)
  }

  func testErrorEnvelopeDecodes() throws {
    let envelope = try decode(
      TraciveErrorEnvelope.self,
      #"{ "error": { "code": "missing_scope", "message": "scope 'scammer.check' not granted", "checkId": null }, "traceId": "t-1" }"#
    )
    XCTAssertEqual(envelope.error.code, "missing_scope")
    XCTAssertEqual(envelope.error.message, "scope 'scammer.check' not granted")
    XCTAssertNil(envelope.error.checkId)

    let mapped = TraciveError.from(
      status: 403, code: envelope.error.code, message: envelope.error.message,
      checkId: envelope.error.checkId)
    XCTAssertEqual(mapped.kind, .missingScope)
  }

  func testEveryErrorKindHasADescription() {
    let errors: [TraciveError] = [
      .notImplemented("x"),
      .invalidRequest(.empty),
      .unsupportedInputType(.empty),
      .unsupportedCreditSource(.empty),
      .invalidToken(.empty),
      .expiredToken(.empty),
      .grantRevoked(.empty),
      .invalidApiKey(.empty),
      .insufficientCredits(which: .credits, info: .empty),
      .missingScope(.empty),
      .detailNotPermitted(.empty),
      .credentialMismatch(.empty),
      .partnerSuspended(.empty),
      .userCreditNotPermitted(.empty),
      .translationNotPermitted(.empty),
      .idempotencyConflict(.empty),
      .rateLimited(retryAfter: nil, info: .empty),
      .network(cause: URLError(.notConnectedToInternet)),
      .server(status: 500, info: .empty),
      .unknown(status: nil, info: .empty),
      .cacheMiss,
      .stateMismatch,
      .invalidQuery(TraciveQueryError(.notE164)),
    ]

    XCTAssertEqual(
      Set(errors.map(\.kind)).count, TraciveErrorKind.allCases.count,
      "every TraciveErrorKind should be represented exactly once in this list")
    for error in errors {
      XCTAssertFalse(error.description.isEmpty)
      XCTAssertNotNil(error.errorDescription)
    }
  }
}
