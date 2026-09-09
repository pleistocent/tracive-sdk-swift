import XCTest

@testable import TraciveSDK

/// The error contract, exercised through the pipeline a real response actually travels:
/// `HTTPResponse` → envelope parse → `Retry-After` parse → typed `TraciveError`.
///
/// The point is not that `TraciveError.from` has the right `switch` — it is that a *response* off
/// the wire produces the right error, including when the body is in the other shape, missing,
/// malformed, or carrying a code this SDK has never heard of. An unrecognised code must reach the
/// caller intact; it must never crash and must never be silently dropped, because that is how a
/// future-version failure would become invisible to a shipped app.
///
/// No network. Every response here is a literal.
final class ErrorMappingTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 1_760_000_000)

  // MARK: - The whole table

  func testEveryDocumentedErrorCodeMapsToItsType() {
    // One row per line of the error table. A code added to the backend without being added here is a
    // code that will reach partners as `.unknown`.
    let table: [(status: Int, code: String, expected: TraciveErrorKind)] = [
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
      (409, "idempotency_conflict", .idempotencyConflict),
      (429, "rate_limited", .rateLimited),
    ]

    for row in table {
      let error = TraciveResponseMapper.error(
        from: .error(status: row.status, code: row.code, message: "boom", checkId: "chk_1"),
        now: now
      )
      XCTAssertEqual(error.kind, row.expected, "\(row.status) \(row.code)")
      XCTAssertEqual(error.serverCode, row.code, "\(row.status) \(row.code)")
      XCTAssertEqual(error.info?.message, "boom", "\(row.status) \(row.code)")
      // `checkId` is what a partner quotes in a support ticket; losing it makes a 402 unarguable.
      XCTAssertEqual(error.info?.checkId, "chk_1", "\(row.status) \(row.code)")
    }
  }

  func testInsufficientCreditsCarriesWhichBalanceRanOut() {
    let cases: [(code: String, expected: InsufficientCreditsKind)] = [
      ("insufficient_user_credits", .userCredits),
      ("insufficient_credits", .credits),
      ("insufficient_partner_balance", .partnerBalance),
    ]

    for row in cases {
      let error = TraciveResponseMapper.error(from: .error(status: 402, code: row.code), now: now)
      guard case .insufficientCredits(let which, _) = error else {
        return XCTFail("Expected insufficientCredits for \(row.code), got \(error).")
      }
      // Which pot is empty decides the remedy: top up the user, or top up the partner balance.
      XCTAssertEqual(which, row.expected)
    }
  }

  // MARK: - Unrecognised codes

  func testUnknownCodeOnAClientErrorBecomesUnknownAndKeepsTheRawCode() {
    let error = TraciveResponseMapper.error(
      from: .error(status: 400, code: "future_phase_only", message: "not yet"),
      now: now
    )

    XCTAssertEqual(error.kind, .unknown)
    XCTAssertEqual(error.serverCode, "future_phase_only")
    XCTAssertEqual(error.info?.message, "not yet")
    XCTAssertFalse(error.isTransient)
  }

  func testUnknownCodeOnAServerErrorBecomesServerAndKeepsTheRawCode() {
    let error = TraciveResponseMapper.error(
      from: .error(status: 503, code: "downstream_unavailable"),
      now: now
    )

    XCTAssertEqual(error.kind, .server)
    XCTAssertEqual(error.serverCode, "downstream_unavailable")
    // A 5xx *could* succeed later — which is a fact about the failure, not permission to retry a
    // billed check without an `Idempotency-Key`.
    XCTAssertTrue(error.isTransient)
  }

  func testKnownCodeAtAnUnexpectedStatusStillDegradesSafely() {
    // The pairing, not just the code, decides the mapping — a `grant_revoked` arriving on a 500 is
    // a server bug, and guessing "revoke the grant" from it would log a user out for nothing.
    let error = TraciveResponseMapper.error(from: .error(status: 500, code: "grant_revoked"), now: now)

    XCTAssertEqual(error.kind, .server)
    XCTAssertEqual(error.serverCode, "grant_revoked")
  }

  func testUnlabelledRateLimitIsStillRateLimited() {
    let error = TraciveResponseMapper.error(
      from: .error(status: 429, code: nil, headers: ["Retry-After": "30"]),
      now: now
    )

    guard case .rateLimited(let retryAfter, _) = error else {
      return XCTFail("Expected rateLimited, got \(error).")
    }
    XCTAssertEqual(retryAfter, 30)
  }

  // MARK: - Envelope shapes

  func testTraciveEnvelopeIsParsed() {
    let response = HTTPResponse(
      status: 403,
      body: Data(#"{"error":{"code":"missing_scope","message":"need scammer.check"}}"#.utf8)
    )

    let error = TraciveResponseMapper.error(from: response, now: now)

    XCTAssertEqual(error.kind, .missingScope)
    XCTAssertEqual(error.info?.message, "need scammer.check")
  }

  func testRFC6749FlatEnvelopeIsParsed() {
    // The OAuth routes answer with `{"error":"…","error_description":"…"}`, not with Tracive's
    // nested envelope. Both shapes have to be readable or a token failure arrives blank.
    let response = HTTPResponse.oauthError(
      status: 400, error: "unsupported_grant_type", description: "only S256")

    let error = TraciveResponseMapper.error(from: response, now: now)

    XCTAssertEqual(error.serverCode, "unsupported_grant_type")
    XCTAssertEqual(error.info?.message, "only S256")
  }

  func testInvalidClientOnTheTokenEndpointKeepsItsCode() {
    let response = HTTPResponse.oauthError(status: 401, error: "invalid_client")

    let error = TraciveResponseMapper.error(from: response, now: now)

    XCTAssertEqual(error.serverCode, "invalid_client")
    XCTAssertEqual(error.kind, .unknown)
  }

  func testEmptyBodyStillMapsByStatus() {
    let error = TraciveResponseMapper.error(from: HTTPResponse(status: 500), now: now)

    XCTAssertEqual(error.kind, .server)
    XCTAssertNil(error.serverCode)
  }

  func testNonJSONBodyStillMapsByStatus() {
    // A gateway between the app and Tracive can answer with an HTML error page. That must produce
    // a typed error, not a decoding crash.
    let response = HTTPResponse(status: 502, body: Data("<html>bad gateway</html>".utf8))

    let error = TraciveResponseMapper.error(from: response, now: now)

    XCTAssertEqual(error.kind, .server)
    XCTAssertNil(error.serverCode)
  }

  func testEnvelopeWithUnknownExtraFieldsIsStillParsed() {
    let response = HTTPResponse(
      status: 409,
      body: Data(
        #"{"error":{"code":"idempotency_conflict","message":"m","traceId":"t"},"meta":{"x":1}}"#.utf8)
    )

    let error = TraciveResponseMapper.error(from: response, now: now)

    XCTAssertEqual(error.kind, .idempotencyConflict)
  }

  // MARK: - Retry-After

  func testRetryAfterAcceptsSeconds() {
    let error = TraciveResponseMapper.error(
      from: .error(status: 429, code: "rate_limited", headers: ["Retry-After": "120"]),
      now: now
    )

    guard case .rateLimited(let retryAfter, _) = error else {
      return XCTFail("Expected rateLimited, got \(error).")
    }
    XCTAssertEqual(retryAfter, 120)
  }

  func testRetryAfterAcceptsAnHTTPDate() {
    let deadline = now.addingTimeInterval(90)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

    let error = TraciveResponseMapper.error(
      from: .error(
        status: 429, code: "rate_limited",
        headers: ["Retry-After": formatter.string(from: deadline)]),
      now: now
    )

    guard case .rateLimited(let retryAfter, _) = error else {
      return XCTFail("Expected rateLimited, got \(error).")
    }
    XCTAssertEqual(try XCTUnwrap(retryAfter), 90, accuracy: 1)
  }

  func testRetryAfterIsReadCaseInsensitively() {
    // `URLSession` canonicalises header names, so a literal dictionary lookup would miss.
    let error = TraciveResponseMapper.error(
      from: .error(status: 429, code: "rate_limited", headers: ["retry-after": "15"]),
      now: now
    )

    guard case .rateLimited(let retryAfter, _) = error else {
      return XCTFail("Expected rateLimited, got \(error).")
    }
    XCTAssertEqual(retryAfter, 15)
  }

  func testUnparseableRetryAfterIsIgnoredRatherThanFatal() {
    let error = TraciveResponseMapper.error(
      from: .error(status: 429, code: "rate_limited", headers: ["Retry-After": "soon"]),
      now: now
    )

    guard case .rateLimited(let retryAfter, _) = error else {
      return XCTFail("Expected rateLimited, got \(error).")
    }
    XCTAssertNil(retryAfter)
  }

  // MARK: - Success bodies

  func testMalformedSuccessBodyBecomesAnInvalidResponseError() {
    let response = HTTPResponse.ok(json: #"{"found":true}"#)  // no riskTier

    let error = expectThrow {
      _ = try TraciveResponseMapper.decode(CheckResult.self, from: response, now: now)
    }

    XCTAssertEqual(error?.kind, .unknown)
    XCTAssertEqual(error?.serverCode, "invalid_response")
    // The message names the coding path, never the body: a `detail=full` response carries
    // user-generated comments.
    let message = error?.info?.message ?? ""
    XCTAssertTrue(message.contains("riskTier"), message)
    XCTAssertFalse(message.contains("found\":true"), message)
  }

  func testNonJSONSuccessBodyBecomesAnInvalidResponseError() {
    let response = HTTPResponse(status: 200, body: Data("not json".utf8))

    let error = expectThrow {
      _ = try TraciveResponseMapper.decode(CheckResult.self, from: response, now: now)
    }

    XCTAssertEqual(error?.serverCode, "invalid_response")
  }

  func testUnknownRiskTierIsRejectedRatherThanDowngraded() {
    // Forward compatibility applies to unknown *keys*, not to an unknown risk tier: quietly
    // reading a future `SEVERE` as something milder would understate danger in a fraud warning.
    let response = HTTPResponse.ok(json: #"{"found":true,"riskTier":"SEVERE"}"#)

    let error = expectThrow {
      _ = try TraciveResponseMapper.decode(CheckResult.self, from: response, now: now)
    }

    XCTAssertEqual(error?.serverCode, "invalid_response")
  }

  // MARK: - Transport failures

  func testTransportFailureBecomesNetwork() async throws {
    let transport = FakeHTTPTransport { _, _ in throw URLError(.cannotFindHost) }
    let client = makeClient(transport: transport)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .network)
    XCTAssertTrue(error?.isTransient ?? false)
    XCTAssertNil(error?.serverCode)
  }

  // MARK: - End to end through the client

  func testClientSurfacesTheTypedErrorForEachStatus() async throws {
    let cases: [(status: Int, code: String, expected: TraciveErrorKind)] = [
      (400, "unsupported_input_type", .unsupportedInputType),
      (402, "insufficient_user_credits", .insufficientCredits),
      (403, "detail_not_permitted", .detailNotPermitted),
      (409, "idempotency_conflict", .idempotencyConflict),
      (429, "rate_limited", .rateLimited),
      (500, "internal", .server),
    ]

    for row in cases {
      let transport = FakeHTTPTransport { _, _ in .error(status: row.status, code: row.code) }
      let client = makeClient(transport: transport)

      let error = await expectTraciveError {
        try await client.checkScammer(TestQueries.bank, idempotencyKey: nil)
      }

      XCTAssertEqual(error?.kind, row.expected, "\(row.status) \(row.code)")
      XCTAssertEqual(error?.serverCode, row.code, "\(row.status) \(row.code)")
    }
  }

  func testClientSurfacesAnUnknownCodeWithoutCrashing() async throws {
    let transport = FakeHTTPTransport { _, _ in .error(status: 418, code: "teapot") }
    let client = makeClient(transport: transport)

    let error = await expectTraciveError { try await client.checkScammer(TestQueries.phone) }

    XCTAssertEqual(error?.kind, .unknown)
    XCTAssertEqual(error?.serverCode, "teapot")
  }

  func testCacheStorageFaultUnderSourceCacheIsDistinguishableFromAMiss() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, cache: BrokenCache())

    let error = await expectTraciveError {
      try await client.checkScammer(TestQueries.phone, source: .cache)
    }

    // Not `.cacheMiss`: "the disk is broken" and "we have never seen this number" call for
    // different responses, and reporting the former as the latter would be an invented verdict.
    XCTAssertEqual(error?.kind, .unknown)
    XCTAssertEqual(error?.serverCode, "cache_storage_error")
    XCTAssertEqual(transport.callCount, 0)
  }

  func testCacheStorageFaultUnderCacheFirstFallsThroughToTheServer() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.minimalCheckJSON) }
    let client = makeClient(transport: transport, cache: BrokenCache())

    let result = try await client.checkScammer(TestQueries.phone, source: .cacheFirst)

    // A broken cache degrades to "no cache", never to a failed check.
    XCTAssertEqual(result.origin, .server)
    XCTAssertEqual(transport.callCount, 1)
  }

  // MARK: - Query rejection happens before the wire

  func testAnInvalidQueryNeverReachesTheNetwork() async throws {
    // A miss is billed, so a key that cannot hit must be rejected locally. The builder throws
    // before a client is even involved — this asserts the ordering that saves the credit.
    XCTAssertThrowsError(try TraciveQuery.phone(e164: "081234567891")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "not_e164")
    }
  }

  // MARK: - Helpers

  private func expectThrow(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Void
  ) -> TraciveError? {
    do {
      try operation()
      XCTFail("Expected a TraciveError, but the call succeeded.", file: file, line: line)
      return nil
    } catch let error as TraciveError {
      return error
    } catch {
      XCTFail("Expected a TraciveError, got \(error).", file: file, line: line)
      return nil
    }
  }
}

/// A cache whose every operation fails, standing in for a full disk or an unreachable Keychain.
final class BrokenCache: CheckCache {

  let policy = CachePolicy.default

  func read(_ key: CheckCacheKey) throws -> CheckResult? {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }

  func write(_ result: CheckResult, for key: CheckCacheKey) throws {
    throw CheckCacheError.storageFailure(code: 13, message: "database or disk is full")
  }

  func remove(_ key: CheckCacheKey) throws {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }

  func clear() throws {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }

  @discardableResult
  func prune() throws -> Int {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }

  func count() throws -> Int {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }

  func writeTransactionCheck(_ result: CheckResult, for transactionId: String) throws {
    throw CheckCacheError.storageFailure(code: 13, message: "database or disk is full")
  }

  func readTransactionCheck(for transactionId: String) throws -> CheckResult? {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }

  func removeTransactionCheck(for transactionId: String) throws {
    throw CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
  }
}
