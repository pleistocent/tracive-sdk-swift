#if os(iOS)
import TraciveSDK
import UIKit
import XCTest

@testable import TraciveSDKExtended

private actor TokenLog {
  private(set) var calls: [String?] = []
  func record(_ stale: String?) { calls.append(stale) }
}

private struct PartnerBackendDown: Error, Equatable {
  let attempt: Int
}

final class TraciveReportsTests: XCTestCase {

  private var server: StubServer!

  override func setUp() async throws {
    let box = ServerBox()
    let server = StubServer { openAPI($0, uploadBase: box.url) }
    try await server.start()
    box.server = server
    self.server = server
  }

  private func reports(
    token: @escaping @Sendable (String?) async throws -> String = { _ in "token" }
  ) -> TraciveReports {
    TraciveReports(environment: .custom(baseUrl: server.baseURL), accessToken: token)
  }

  private func pdf(size: Int = 64) -> Data {
    Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: size - 9)
  }

  private func png(side: Int = 64) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
  }

  private func draft(
    _ reports: TraciveReports,
    evidence: [PreparedEvidence]? = nil
  ) async throws -> ReportDraft {
    let requirements = try await reports.requirements()
    var attached = evidence
    if attached == nil {
      attached = [try await reports.prepare(pdf(), mimeType: "application/pdf")]
    }
    return ReportDraft(
      identifiers: ["PHONE_+6281234567891"],
      title: "Penipuan",
      chronology: String(repeating: "kronologi ", count: 6),
      incidentDate: ReportIncidentDate(year: 2026, month: 11, day: 1)!,
      evidence: attached ?? [],
      acceptedTerms: requirements.terms
    )
  }

  // MARK: - Token closure

  func testFirstCallPassesNoStaleToken() async throws {
    let log = TokenLog()
    let reports = reports { stale in
      await log.record(stale)
      return "first"
    }
    _ = try await reports.requirements()
    let calls = await log.calls
    XCTAssertEqual(calls, [nil])
    XCTAssertEqual(server.requests.first?.headers["authorization"], "Bearer first")
  }

  func testRefusedTokenIsPassedBackAsStaleAndTheCallRetries() async throws {
    server.setHandler { request in
      request.headers["authorization"] == "Bearer fresh"
        ? .json(requirementsJSON) : .apiError("expired_token", status: 401)
    }
    let log = TokenLog()
    let reports = reports { stale in
      await log.record(stale)
      return stale == nil ? "old" : "fresh"
    }
    let requirements = try await reports.requirements()
    XCTAssertEqual(requirements.remainingToday, 3)
    let calls = await log.calls
    XCTAssertEqual(calls, [nil, "old"])
    XCTAssertEqual(server.requests.count, 2)
  }

  func testTwoRefusalsInARowAreNeedsConsent() async throws {
    server.setHandler { _ in .apiError("invalid_token", status: 401) }
    do {
      _ = try await reports().requirements()
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .needsConsent)
    }
  }

  func testClientUsesItsGrantAndRefreshesThroughIt() async throws {
    server.setHandler { request in
      request.headers["authorization"] == "Bearer access-2"
        ? .json(requirementsJSON) : .apiError("expired_token", status: 401)
    }
    let store = InMemoryTokenStore(
      tokens: TraciveTokens(accessToken: "access-1", refreshToken: "refresh-1"))
    let client = TraciveClient(
      mode: .oauth(
        clientId: "client",
        redirectUri: URL(string: "partner://oauth/callback")!,
        partnerUserId: "user-1"),
      environment: .custom(baseUrl: server.baseURL),
      transport: FakeRefresh(),
      cache: NoOpCheckCache(),
      tokenStore: store
    )
    let reports = TraciveReports(client: client)
    let requirements = try await reports.requirements()
    XCTAssertEqual(requirements.terms.map(\.id), ["TERMS_OF_SERVICE", "PRIVACY_POLICY"])
    XCTAssertEqual(
      server.requests.map { $0.headers["authorization"] },
      ["Bearer access-1", "Bearer access-2"])
  }

  func testProxyClientThrowsWhatBaseThrows() async throws {
    let client = TraciveClient(
      mode: .proxy(baseUrl: URL(string: "https://bank.example")!),
      environment: .custom(baseUrl: server.baseURL),
      cache: NoOpCheckCache()
    )
    do {
      _ = try await TraciveReports(client: client).requirements()
      XCTFail("expected a throw")
    } catch let error as TraciveError {
      XCTAssertEqual(error.kind, .notImplemented)
    }
    XCTAssertTrue(server.requests.isEmpty)
  }

  // MARK: - Needs consent

  func testBaseGrantErrorsBecomeNeedsConsent() async throws {
    let info = TraciveErrorInfo(code: "no_grant", message: "no")
    let errors: [TraciveError] = [
      .invalidToken(info), .expiredToken(info), .grantRevoked(info), .missingScope(info),
    ]
    for failure in errors {
      let reports = reports { _ in throw failure }
      do {
        _ = try await reports.requirements()
        XCTFail("\(failure) did not throw")
      } catch let error as TraciveReportError {
        XCTAssertEqual(error.code, .needsConsent, "\(failure)")
      }
      let result = try await reports.submit(sentDraft())
      guard case .needsConsent = result else {
        XCTFail("\(failure) gave \(result)")
        continue
      }
    }
  }

  func testPartnerThrowingNeedsConsentEndsInNeedsConsent() async throws {
    let reports = reports { _ in
      throw TraciveReportError(code: .needsConsent, message: "ask again")
    }
    let result = try await reports.submit(sentDraft())
    guard case .needsConsent = result else {
      return XCTFail("gave \(result)")
    }
  }

  func testMissingScopeFromTheServerIsNeedsConsent() async throws {
    let draft = try await sentDraft()
    server.setHandler { _ in .apiError("missing_scope", status: 403) }
    let result = try await reports().submit(draft)
    guard case .needsConsent = result else {
      return XCTFail("gave \(result)")
    }
  }

  func testBaseNetworkErrorIsNetworkNotConsent() async throws {
    let cause = URLError(.notConnectedToInternet)
    let reports = reports { _ in throw TraciveError.network(cause: cause) }
    let result = try await reports.submit(sentDraft())
    guard case .failed(let error) = result else {
      return XCTFail("gave \(result)")
    }
    XCTAssertEqual(error.code, .network)
  }

  /// A draft built with a healthy client, for a client whose tokens are what is under test.
  private func sentDraft() async throws -> ReportDraft {
    try await draft(reports())
  }

  // MARK: - Swift errors

  func testSwiftErrorFromTheClosureReachesTheCaller() async throws {
    let reports = reports { _ in throw PartnerBackendDown(attempt: 7) }
    do {
      _ = try await reports.requirements()
      XCTFail("expected a throw")
    } catch let error as PartnerBackendDown {
      XCTAssertEqual(error, PartnerBackendDown(attempt: 7))
    }
    do {
      _ = try await reports.status("rep_1")
      XCTFail("expected a throw")
    } catch let error as PartnerBackendDown {
      XCTAssertEqual(error.attempt, 7)
    }
  }

  func testSwiftErrorInSubmitIsThrownNotReportedAsAResult() async throws {
    let draft = try await sentDraft()
    let reports = reports { _ in throw PartnerBackendDown(attempt: 2) }
    do {
      _ = try await reports.submit(draft)
      XCTFail("expected a throw")
    } catch let error as PartnerBackendDown {
      XCTAssertEqual(error.attempt, 2)
    }
  }

  // MARK: - Cancellation

  func testCancellingMidUploadStopsTheUpload() async throws {
    let reports = reports()
    let large = try await reports.prepare(pdf(size: 1_048_575), mimeType: "application/pdf")
    let draft = try await draft(reports, evidence: [large, large])
    server.stallUploads(true)

    let task = Task { try await reports.submit(draft) }
    let upload = try await eventually("the upload to start") { self.server.stalledUpload }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(upload.isClosed, "the stalled upload should still be running")
    XCTAssertLessThan(upload.bytesReceived, 1_048_575, "the upload finished before the cancel")

    task.cancel()

    let outcome = try await result(of: task, within: 5)
    guard case .failure(let error) = outcome else {
      return XCTFail("a cancelled call must not finish: \(outcome)")
    }
    XCTAssertTrue(error is CancellationError, "\(error)")

    upload.drain()
    _ = try await eventually("the connection to close") { upload.isClosed ? true : nil }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(server.stalledUploadCount, 1, "the next file started after the cancel")
    XCTAssertTrue(server.requests("POST", "/v1/reports").isEmpty)
  }

  func testCancellingBeforeTheCallStartsThrowsCancellationError() async throws {
    let reports = reports()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await reports.requirements()
    }
    let outcome = try await result(of: task, within: 5)
    guard case .failure(let error) = outcome else {
      return XCTFail("gave \(outcome)")
    }
    XCTAssertTrue(error is CancellationError, "\(error)")
  }

  func testACallAfterACancelledOneStillWorks() async throws {
    let reports = reports()
    let draft = try await draft(reports)
    server.stallUploads(true)
    let task = Task { try await reports.submit(draft) }
    _ = try await eventually("the upload to start") { self.server.stalledUpload }
    task.cancel()
    _ = try await result(of: task, within: 5)

    server.stallUploads(false)
    let retried = try await reports.submit(draft)
    guard case .submitted(let reportId, _) = retried else {
      return XCTFail("gave \(retried)")
    }
    XCTAssertEqual(reportId, "rep_1")
    XCTAssertEqual(server.requests("POST", "/v1/reports").count, 1)
  }

  // MARK: - Submit

  func testDoubleSubmitFilesOnce() async throws {
    let reports = reports()
    let draft = try await draft(reports)
    async let first = reports.submit(draft)
    async let second = reports.submit(draft)
    let results = try await [first, second]

    for result in results {
      guard case .submitted(let reportId, let status) = result else {
        return XCTFail("gave \(result)")
      }
      XCTAssertEqual(reportId, "rep_1")
      XCTAssertEqual(status, .submitted)
    }
    XCTAssertEqual(server.requests("POST", "/v1/reports").count, 1)
    XCTAssertEqual(server.requests("POST", "/v1/report-uploads").count, 1)
  }

  func testSubmittingAgainAfterItFinishedAnswersTheSameReport() async throws {
    let reports = reports()
    let draft = try await draft(reports)
    _ = try await reports.submit(draft)
    _ = try await reports.submit(draft)
    XCTAssertEqual(server.requests("POST", "/v1/reports").count, 1)
  }

  func testARetryKeepsTheIdempotencyKeyAndTheBody() async throws {
    let box = FailFirstCreate()
    let base = server.baseURL
    server.setHandler { request in
      if request.path == "/v1/reports", box.shouldFail() {
        return .apiError("invalid_report", status: 400)
      }
      return openAPI(request, uploadBase: base)
    }
    let reports = reports()
    let draft = try await draft(reports)

    guard case .failed = try await reports.submit(draft) else {
      return XCTFail("the first attempt should fail")
    }
    guard case .submitted = try await reports.submit(draft) else {
      return XCTFail("the retry should succeed")
    }
    let creates = server.requests("POST", "/v1/reports")
    XCTAssertEqual(creates.count, 2)
    XCTAssertEqual(creates[0].headers["idempotency-key"], draft.idempotencyKey)
    XCTAssertEqual(creates[1].headers["idempotency-key"], draft.idempotencyKey)
    XCTAssertEqual(creates[0].body, creates[1].body)
    XCTAssertEqual(server.requests("POST", "/v1/report-uploads").count, 1)
  }

  func testDraftsGetDifferentKeysOfThirtyTwoHexDigits() async throws {
    let reports = reports()
    let first = try await draft(reports)
    let second = try await draft(reports)
    XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey)
    XCTAssertNotNil(first.idempotencyKey.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
  }

  func testProgressReachesOne() async throws {
    let reports = reports()
    let draft = try await draft(reports)
    let seen = Recorder<Double>()
    _ = try await reports.submit(draft) { seen.add($0) }
    XCTAssertEqual(seen.values.last, 1)
  }

  // MARK: - Error mapping

  func testServerCodesMapToReportErrors() async throws {
    let table: [(String, Int, TraciveReportError.Code)] = [
      ("email_not_verified", 403, .emailNotVerified),
      ("report_not_found", 404, .reportNotFound),
      ("terms_outdated", 409, .termsOutdated),
      ("invalid_report", 400, .invalidReport),
      ("attachment_invalid", 400, .attachmentInvalid),
      ("daily_quota_exceeded", 429, .dailyLimitReached),
      ("reporting_disabled", 503, .reportingDisabled),
      ("something_new", 500, .server),
    ]
    for (wire, status, code) in table {
      server.setHandler { _ in .apiError(wire, status: status, headers: ["Retry-After": "120"]) }
      do {
        _ = try await reports().status("rep_1")
        XCTFail("\(wire) did not throw")
      } catch let error as TraciveReportError {
        XCTAssertEqual(error.code, code, wire)
        XCTAssertEqual(error.httpStatus, status, wire)
        XCTAssertEqual(error.retryAfterSeconds, 120, wire)
      }
    }
  }

  func testEveryCodeCrossesToKotlinAndBack() {
    for code in TraciveReportError.Code.allCases {
      let crossed = TraciveReportError(
        TraciveReportError(code: code, message: "m", httpStatus: 418, retryAfterSeconds: 9).core)
      XCTAssertEqual(crossed.code, code)
      XCTAssertEqual(crossed.message, "m")
      XCTAssertEqual(crossed.httpStatus, 418)
      XCTAssertEqual(crossed.retryAfterSeconds, 9)
    }
  }

  func testUnreachableServerIsNetwork() async throws {
    let reports = TraciveReports(
      environment: .custom(baseUrl: URL(string: "http://127.0.0.1:9/v1")!),
      accessToken: { _ in "token" })
    do {
      _ = try await reports.requirements()
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .network)
    }
  }

  func testUnreadableResponseIsServerNotAnNSError() async throws {
    server.setHandler { _ in .json("{not json") }
    do {
      _ = try await reports().requirements()
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .server)
    }
  }

  func testSubmitFailureComesBackAsAResult() async throws {
    server.setHandler { _ in .apiError("daily_quota_exceeded", status: 429) }
    let result = try await reports().submit(draftWithoutServer())
    guard case .failed(let error) = result else {
      return XCTFail("gave \(result)")
    }
    XCTAssertEqual(error.code, .dailyLimitReached)
  }

  private func draftWithoutServer() async throws -> ReportDraft {
    let evidence = try await reports().prepare(pdf(), mimeType: "application/pdf")
    return ReportDraft(
      identifiers: ["EMAIL_a@example.com"], title: "t", chronology: "c",
      incidentDate: ReportIncidentDate(year: 2026, month: 1, day: 1)!, evidence: [evidence],
      acceptedTerms: [])
  }

  // MARK: - Models

  func testRequirementsCrossIntoSwiftStructs() async throws {
    let requirements = try await reports().requirements()
    XCTAssertTrue(requirements.enabled)
    XCTAssertEqual(requirements.limits.chronologyMinLength, 50)
    XCTAssertEqual(requirements.limits.maxAttachmentBytes, 1_048_576)
    XCTAssertEqual(requirements.limits.attachmentTypes.count, 3)
    XCTAssertEqual(requirements.terms.last?.url, "https://tracive.id/privacy")
    XCTAssertEqual(requirements.terms.last?.version, "2")
  }

  func testEveryStatusAndAnUnknownOneMap() async throws {
    for (wire, expected) in [
      ("SUBMITTED", ReportStatus.submitted), ("IN_REVIEW", .inReview), ("REVIEWED", .reviewed),
      ("NEED_REVISION", .needRevision), ("NEW_STAGE", .inReview),
    ] {
      server.setHandler { _ in .json(#"{"reportId":"rep_1","status":"\#(wire)"}"#) }
      let status = try await reports().status("rep_1")
      XCTAssertEqual(status, expected, wire)
    }
  }

  func testProblemsComeFromTheCore() async throws {
    let reports = reports()
    let limits = try await reports.requirements().limits
    let empty = ReportDraft(
      identifiers: [],
      title: " ",
      chronology: "short",
      incidentDate: ReportIncidentDate(year: 2030, month: 1, day: 2)!,
      evidence: [],
      acceptedTerms: []
    )
    XCTAssertEqual(
      empty.problems(limits: limits, today: ReportIncidentDate(year: 2030, month: 1, day: 1)!),
      [.noIdentifier, .incidentDateInFuture, .titleMissing, .chronologyTooShort, .noEvidence])
    XCTAssertEqual(
      empty.problems(limits: limits, today: ReportIncidentDate(year: 2030, month: 1, day: 3)!),
      [.noIdentifier, .titleMissing, .chronologyTooShort, .noEvidence])
  }

  func testPhoneIdentifierAllowsExtraEvidence() async throws {
    let reports = reports()
    let limits = try await reports.requirements().limits
    let phone = ReportDraft(
      identifiers: ["PHONE_+6281234567891"], title: "t", chronology: "c",
      incidentDate: ReportIncidentDate(year: 2026, month: 1, day: 1)!, evidence: [],
      acceptedTerms: [])
    XCTAssertEqual(phone.maxEvidence(limits: limits), 5)
  }

  func testDetailsLinkEscapesTheReportId() {
    let reports = TraciveReports(
      environment: .sandbox, accessToken: { _ in "token" })
    XCTAssertEqual(
      reports.detailsLink("a b/c"), "tracivesandbox://report/details?id=a%20b%2Fc")
  }

  func testTargetChoosesTheApp() {
    let target = ReportFormTarget(
      bundleIdentifier: "com.example.build", scheme: "examplebuild",
      capabilityScheme: "examplebuild-report", fileExtension: "examplebuildreport")
    let reports = TraciveReports(
      environment: .sandbox, target: target, accessToken: { _ in "token" })
    XCTAssertEqual(reports.detailsLink("r"), "examplebuild://report/details?id=r")
  }

  // MARK: - Data

  func testPDFBytesRoundTripExactly() async throws {
    let reports = reports()
    var bytes = pdf(size: 4_096)
    bytes[100] = 0x00
    bytes[101] = 0xFF
    let prepared = try await reports.prepare(bytes, mimeType: "application/pdf")
    XCTAssertEqual(prepared.data, bytes)
    XCTAssertEqual(prepared.byteCount, 4_096)
    XCTAssertEqual(prepared.mimeType, "application/pdf")
  }

  func testUploadedBytesAreThePreparedBytes() async throws {
    let reports = reports()
    let prepared = try await reports.prepare(png(side: 256), mimeType: "image/png")
    let draft = try await draft(reports, evidence: [prepared])
    _ = try await reports.submit(draft)
    let put = try XCTUnwrap(server.requests.first { $0.method == "PUT" })
    XCTAssertEqual(put.body, prepared.data)
  }

  func testImageBecomesAVIFUnderTheCap() async throws {
    let prepared = try await reports().prepare(png(side: 1_500), mimeType: "image/png")
    XCTAssertEqual(prepared.mimeType, "image/avif")
    XCTAssertLessThanOrEqual(prepared.byteCount, 200 * 1024)
    XCTAssertEqual(String(decoding: prepared.data[4..<12], as: UTF8.self), "ftypavif")
  }

  func testPDFOfExactlyOneMebibyteIsRefused() async throws {
    do {
      _ = try await reports().prepare(pdf(size: 1_048_576), mimeType: "application/pdf")
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .fileTooLarge)
    }
  }

  func testTextFileIsUnsupported() async throws {
    do {
      _ = try await reports().prepare(Data("hello".utf8), mimeType: "text/plain")
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .unsupportedFile)
    }
  }

  func testGarbageImageThrowsInsteadOfCrashing() async throws {
    do {
      _ = try await reports().prepare(Data("not an image".utf8), mimeType: "image/png")
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .imageUnreadable)
    }
  }

  func testPrepareFromABackgroundTask() async throws {
    let reports = reports()
    let bytes = png()
    let prepared = try await Task.detached {
      try await reports.prepare(bytes, mimeType: "image/png")
    }.value
    XCTAssertFalse(prepared.data.isEmpty)
  }
}

final class ServerBox: @unchecked Sendable {
  var server: StubServer?
  var url: URL { server?.baseURL ?? URL(string: "http://127.0.0.1")! }
}

private final class FailFirstCreate: @unchecked Sendable {
  private let lock = NSLock()
  private var failed = false

  func shouldFail() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    defer { failed = true }
    return !failed
  }
}

final class Recorder<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Value] = []

  var values: [Value] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func add(_ value: Value) {
    lock.lock()
    stored.append(value)
    lock.unlock()
  }
}

/// Answers a token refresh the way the Open API does.
private struct FakeRefresh: HTTPTransport {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body = #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#
    return HTTPResponse(status: 200, body: Data(body.utf8))
  }
}

struct TimedOut: Error {
  let what: String
}

/// Not a task group: one waits for every child, and a call that ignores the cancel would hang here
/// instead of failing the test.
func result<Value: Sendable>(
  of task: Task<Value, Error>,
  within seconds: Double
) async throws -> Result<Value, Error> {
  let finished = Recorder<Result<Value, Error>>()
  Task { finished.add(await task.result) }
  return try await eventually("the task to finish", within: seconds) { finished.values.first }
}

func eventually<Value>(
  _ what: String,
  within seconds: Double = 5,
  _ check: () -> Value?
) async throws -> Value {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if let value = check() { return value }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  throw TimedOut(what: what)
}
#endif
