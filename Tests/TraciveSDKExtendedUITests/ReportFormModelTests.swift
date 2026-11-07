#if os(iOS)
import SwiftUI
import TraciveSDK
import TraciveSDKExtended
import XCTest

@testable import TraciveSDKExtendedUI

final class ServerBox: @unchecked Sendable {
  var server: StubServer?
  var url: URL { server?.baseURL ?? URL(string: "http://127.0.0.1")! }
}

private let longStory = String(repeating: "kronologi kejadian ", count: 4)

@MainActor
final class ReportFormModelTests: XCTestCase {

  private var server: StubServer!
  private var box: ServerBox!

  override func setUp() async throws {
    box = ServerBox()
    let box = box!
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

  private func model(
    identifiers: [String] = ["PHONE_+6281234567891"],
    attachments: [ReportAttachment] = [],
    token: @escaping @Sendable (String?) async throws -> String = { _ in "token" }
  ) async throws -> ReportFormModel {
    let model = ReportFormModel(
      reports: reports(token: token),
      prefill: ReportPrefill(identifiers: identifiers, title: nil, attachments: attachments))
    try await eventually("requirements to load: \(model.load)") {
      if case .failed(let code) = model.load { XCTFail("the form failed to load: \(code)") }
      return model.load != .loading ? true : nil
    }
    return model
  }

  private func filled(attachments: Int = 1) async throws -> ReportFormModel {
    let model = try await model(
      attachments: (0..<attachments).map { _ in .pdf(pdfBytes()) })
    model.title = "Penipuan"
    model.chronology = longStory
    model.incidentDate = Date()
    try await ready(model)
    return model
  }

  private func ready(_ model: ReportFormModel) async throws {
    try await eventually("evidence to be ready") {
      model.evidence.allSatisfy {
        if case .ready = $0.state { return true }
        return false
      } ? true : nil
    }
  }

  private func pdfBytes(size: Int = 64) -> Data {
    Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: size - 9)
  }

  private func idle(_ model: ReportFormModel) async throws {
    try await eventually("the send to finish") { model.sending ? nil : true }
  }

  // MARK: - Sending

  func testDoubleTapFilesOnce() async throws {
    let model = try await filled()
    model.send()
    model.send()
    try await idle(model)
    XCTAssertEqual(model.sent?.reportId, "rep_1")
    let creates = server.requests("POST", "/v1/reports")
    XCTAssertEqual(creates.count, 1)
    XCTAssertEqual(creates[0].json?["language"] as? String, ReportText.language)
  }

  func testRetryAfterFailureKeepsTheKey() async throws {
    let failing = Toggle(on: true)
    let box = box!
    server.setHandler { request in
      if request.path == "/v1/reports", failing.isOn {
        return .apiError("something_broke", status: 400)
      }
      return openAPI(request, uploadBase: box.url)
    }
    let model = try await filled()
    model.send()
    try await idle(model)
    XCTAssertEqual(model.failure?.code, .server)

    failing.isOn = false
    model.send()
    try await idle(model)

    let keys = server.requests("POST", "/v1/reports").map { $0.headers["idempotency-key"] }
    XCTAssertEqual(keys.count, 2)
    XCTAssertEqual(keys[0], keys[1])
    XCTAssertNotNil(model.sent)
  }

  func testAnEditAfterAFailureIsANewDraftAndIsActuallySent() async throws {
    let failing = Toggle(on: true)
    let box = box!
    server.setHandler { request in
      if request.path == "/v1/reports", failing.isOn {
        return .apiError("invalid_report", status: 400)
      }
      return openAPI(request, uploadBase: box.url)
    }
    let model = try await filled()
    model.send()
    try await idle(model)

    failing.isOn = false
    model.title = "Judul baru"
    model.send()
    try await idle(model)

    let creates = server.requests("POST", "/v1/reports")
    XCTAssertEqual(creates.count, 2)
    XCTAssertNotEqual(
      creates[0].headers["idempotency-key"], creates[1].headers["idempotency-key"])
    XCTAssertEqual(creates[1].json?["title"] as? String, "Judul baru")
  }

  func testTermsOutdatedShowsNewTermsAndSendsThemWithANewKey() async throws {
    let outdated = Toggle(on: true)
    let box = box!
    server.setHandler { request in
      if request.path == "/v1/reports", outdated.isOn {
        outdated.isOn = false
        return .apiError("terms_outdated", status: 409)
      }
      if request.path == "/v1/report-requirements", !outdated.isOn {
        return .json(
          requirementsJSON.replacingOccurrences(of: #""version":"3""#, with: #""version":"4""#))
      }
      return openAPI(request, uploadBase: box.url)
    }
    let model = try await filled()
    model.send()
    try await eventually("the new terms") {
      model.requirements?.terms.first?.version == "4" ? true : nil
    }
    XCTAssertEqual(model.failure?.code, .termsOutdated)
    XCTAssertEqual(server.requests("POST", "/v1/reports").count, 1, "must wait for the next tap")

    try await eventually("the reload to finish") { model.canSend ? true : nil }
    model.send()
    try await eventually("the report to be sent") { model.sent != nil ? true : nil }

    let creates = server.requests("POST", "/v1/reports")
    XCTAssertEqual(creates.count, 2)
    XCTAssertNotEqual(
      creates[0].headers["idempotency-key"], creates[1].headers["idempotency-key"])
    let accepted = creates[1].json?["acceptedTerms"] as? [String: String]
    XCTAssertEqual(accepted?["TERMS_OF_SERVICE"], "4")
  }

  func testNeedsConsentFinishesTheForm() async throws {
    let revoked = Toggle(on: false)
    let model = try await model(
      attachments: [.pdf(pdfBytes())],
      token: { _ in
        if revoked.isOn {
          throw TraciveError.grantRevoked(TraciveErrorInfo(code: "grant_revoked", message: "no"))
        }
        return "token"
      })
    model.title = "Penipuan"
    model.chronology = longStory
    model.incidentDate = Date()
    try await ready(model)
    var finished = 0
    model.onFinish = { finished += 1 }

    revoked.isOn = true
    model.send()
    try await eventually("the form to finish") { finished > 0 ? true : nil }
    XCTAssertEqual(model.outcome, .needsConsent)
  }

  func testNoGrantWhileLoadingFinishesTheForm() async throws {
    let model = ReportFormModel(
      reports: reports(token: { _ in
        throw TraciveError.invalidToken(TraciveErrorInfo(code: "no_grant", message: "no"))
      }),
      prefill: ReportPrefill(identifiers: ["EMAIL_a@example.com"]))
    var finished = 0
    model.onFinish = { finished += 1 }
    try await eventually("the form to finish") { finished > 0 ? true : nil }
    XCTAssertEqual(model.outcome, .needsConsent)
  }

  func testClosingCancelsTheUploadInKotlin() async throws {
    let model = try await model(attachments: [.pdf(pdfBytes(size: 1_048_575))])
    model.title = "Penipuan"
    model.chronology = longStory
    model.incidentDate = Date()
    try await ready(model)
    server.stallUploads(true)

    model.send()
    let upload = try await eventually("the upload to start") { self.server.stalledUpload }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(upload.isClosed)

    model.close()

    upload.drain()
    _ = try await eventually("the connection to close") { upload.isClosed ? true : nil }
    try await idle(model)
    XCTAssertEqual(model.outcome, .cancelled)
    XCTAssertNil(model.sent)
    XCTAssertTrue(server.requests("POST", "/v1/reports").isEmpty)
  }

  func testClosingAfterSuccessStillReportsTheReport() async throws {
    let model = try await filled()
    model.send()
    try await idle(model)
    model.close()
    XCTAssertEqual(model.outcome, .submitted(reportId: "rep_1", status: .submitted))
    XCTAssertFalse(model.hasWork)
  }

  func testStatusIsShownWhenTheProbeAnswers() async throws {
    let model = try await filled()
    model.send()
    try await eventually("the probe to answer") { model.checkedStatus }
    XCTAssertEqual(model.checkedStatus, .inReview)
  }

  func testStatusStaysHiddenWithoutReportRead() async throws {
    let box = box!
    server.setHandler { request in
      request.path.hasPrefix("/v1/reports/")
        ? .apiError("missing_scope", status: 403)
        : openAPI(request, uploadBase: box.url)
    }
    let model = try await filled()
    model.send()
    try await idle(model)
    XCTAssertNotNil(model.sent)
    _ = try await eventually("the probe to be asked") {
      self.server.requests("GET", "/v1/reports/rep_1").first
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(model.checkedStatus)
    XCTAssertEqual(model.outcome, .submitted(reportId: "rep_1", status: .submitted))
  }

  // MARK: - Validation

  func testNothingIsSentWhileAFieldIsWrong() async throws {
    let model = try await model(attachments: [.pdf(pdfBytes())])
    try await ready(model)
    XCTAssertTrue(model.problems.isEmpty, "no problem shows before the first tap")

    model.send()

    XCTAssertEqual(
      Set(model.problems), [.titleMissing, .chronologyTooShort, .incidentDateInvalid])
    XCTAssertEqual(model.attentionRequests, 1)
    XCTAssertTrue(server.requests("POST", "/v1/report-uploads").isEmpty)
  }

  func testAFutureDateIsAProblem() async throws {
    let model = try await filled()
    model.incidentDate = Date().addingTimeInterval(3 * 86_400)
    model.send()
    XCTAssertEqual(model.problems, [.incidentDateInFuture])
  }

  func testAPrefillHasNoChronology() async throws {
    let model = try await model()
    XCTAssertEqual(model.chronology, "")
  }

  func testAFutureCalendarStillWritesGregorianDates() {
    let date = ReportIncidentDate(Date(timeIntervalSince1970: 1_793_000_000))
    XCTAssertTrue(date.iso8601.hasPrefix("2026"), date.iso8601)
  }

  // MARK: - Limits

  func testDisabledReportingBlocksSend() async throws {
    server.setHandler { _ in
      .json(
        requirementsJSON.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#))
    }
    let model = try await model()
    XCTAssertEqual(model.sendBlock, .reportingDisabled)
    XCTAssertFalse(model.canSend)
  }

  func testNoReportsLeftTodayBlocksSend() async throws {
    server.setHandler { _ in
      .json(
        requirementsJSON.replacingOccurrences(
          of: #""remainingToday":3"#, with: #""remainingToday":0"#))
    }
    let model = try await model()
    XCTAssertEqual(model.sendBlock, .dailyLimit)
    XCTAssertFalse(model.canSend)
  }

  func testDailyLimitAnswerBlocksFurtherSends() async throws {
    let box = box!
    server.setHandler { request in
      request.path == "/v1/reports"
        ? .apiError("daily_quota_exceeded", status: 429, headers: ["Retry-After": "7200"])
        : openAPI(request, uploadBase: box.url)
    }
    let model = try await filled()
    model.send()
    try await idle(model)
    XCTAssertEqual(model.sendBlock, .dailyLimit)
    XCTAssertEqual(model.failure, .init(code: .dailyLimitReached, retryAfterSeconds: 7200))
    XCTAssertFalse(model.canSend)
  }

  func testRoomComesFromTheLimits() async throws {
    let model = try await model(attachments: [.pdf(pdfBytes())])
    XCTAssertEqual(model.maxEvidence, 5)
    XCTAssertEqual(model.evidenceRoom, 4)

    let bank = try await self.model(identifiers: ["BANK_IDN_014_123"])
    XCTAssertEqual(bank.maxEvidence, 3)
  }

  func testPickingTooManyKeepsWhatFitsAndSaysSo() async throws {
    let model = try await model(identifiers: ["BANK_IDN_014_123"])
    let bytes = pdfBytes()
    let input = EvidenceInput.attachment(.pdf(bytes))
    model.addEvidence([input, input, input, input])
    XCTAssertEqual(model.evidence.count, 3)
    XCTAssertTrue(model.evidenceOverflow)
  }

  // MARK: - Evidence

  func testAFailedFileShowsItsErrorAndBlocksSend() async throws {
    let model = try await filled(attachments: 0)
    model.addEvidence([.attachment(.image(Data("not an image".utf8), mimeType: "image/png"))])
    try await eventually("the file to fail") {
      if case .failed(let code) = model.evidence.first?.state { return code }
      return nil
    }
    model.send()
    XCTAssertEqual(model.evidenceBlock, .fileFailed)
    XCTAssertTrue(server.requests("POST", "/v1/report-uploads").isEmpty)

    model.removeEvidence(id: model.evidence[0].id)
    XCTAssertTrue(model.evidence.isEmpty)
  }

  func testATooLargeDocumentIsRefusedBeforeItIsRead() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 1, count: 2_048).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      _ = try await EvidenceInput.document(at: url, maxBytes: 1_024).read()
      XCTFail("expected a throw")
    } catch let error as TraciveReportError {
      XCTAssertEqual(error.code, .fileTooLarge)
    }
  }

  func testADocumentOfExactlyTheLimitIsAccepted() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 1, count: 1_024).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try await EvidenceInput.document(at: url, maxBytes: 1_024).read()
    XCTAssertEqual(file.data.count, 1_024)
  }

  func testRemovingAFileCancelsItsPreparation() async throws {
    let model = try await filled(attachments: 0)
    let input = EvidenceInput {
      try await Task.sleep(nanoseconds: 30_000_000_000)
      return EvidenceFile(name: nil, data: Data(), mimeType: "image/png", thumbnail: nil)
    }
    model.addEvidence([input])
    model.removeEvidence(id: model.evidence[0].id)
    XCTAssertTrue(model.evidence.isEmpty)
    XCTAssertEqual(model.evidenceRoom, 5)
  }

  func testUnfinishedInputKeepsSwipeFromClosingTheForm() async throws {
    let model = try await model()
    XCTAssertFalse(model.hasWork)
    model.chronology = "a"
    XCTAssertTrue(model.hasWork)
  }
}

@MainActor
final class ReportStatusModelTests: XCTestCase {

  private var server: StubServer!

  override func setUp() async throws {
    let box = ServerBox()
    let server = StubServer { openAPI($0, uploadBase: box.url) }
    try await server.start()
    box.server = server
    self.server = server
  }

  private func model(
    token: @escaping @Sendable (String?) async throws -> String = { _ in "token" }
  ) -> ReportStatusModel {
    ReportStatusModel(
      reports: TraciveReports(environment: .custom(baseUrl: server.baseURL), accessToken: token),
      reportId: "rep_1")
  }

  func testLoadsTheStatus() async throws {
    let model = model()
    try await eventually("the status") { model.load == .loaded(.inReview) ? true : nil }
  }

  func testReportNotFoundIsItsOwnState() async throws {
    server.setHandler { _ in .apiError("report_not_found", status: 404) }
    let model = model()
    try await eventually("the failure") { model.load == .failed(.reportNotFound) ? true : nil }
  }

  func testNeedsConsentClosesTheScreen() async throws {
    server.setHandler { _ in .apiError("missing_scope", status: 403) }
    let model = model()
    var done = 0
    model.onDone = { done += 1 }
    try await eventually("the screen to close") { done > 0 ? true : nil }
    XCTAssertTrue(model.needsConsent)
  }

  func testRetryAfterANetworkFailure() async throws {
    server.setHandler { _ in .apiError("boom", status: 500) }
    let model = model()
    try await eventually("the failure") { model.load == .failed(.server) ? true : nil }
    server.setHandler { _ in .json(#"{"reportId":"rep_1","status":"REVIEWED"}"#) }
    model.retry()
    try await eventually("the status") { model.load == .loaded(.reviewed) ? true : nil }
  }
}

final class ReadableIdentifierTests: XCTestCase {

  private func check(_ key: String, _ kind: ReadableIdentifier.Kind, _ value: String) {
    let readable = ReadableIdentifier(key: key)
    XCTAssertEqual(readable.kind, kind, key)
    XCTAssertEqual(readable.value, value, key)
  }

  func testKeysBecomeReadable() {
    check("PHONE_+6281234567891", .phone, "+6281234567891")
    check("EMAIL_a_b@example.com", .email, "a_b@example.com")
    check("BANK_IDN_014_1234_567", .bank, "014 1234_567")
    check("BANK_IBAN_DE89370400440532013000", .bank, "DE89370400440532013000")
    check("CRYPTO_ETH_0xabc_def", .crypto, "ETH 0xabc_def")
    check("USERNAME_INSTAGRAM_@tukang_tipu", .socialMedia, "Instagram @tukang_tipu")
    check("USERNAME_TIKTOK_tukang", .socialMedia, "Tiktok @tukang")
  }

  func testAKeyThatDoesNotParseIsShownAsItIs() {
    check("SOMETHING_NEW", .other, "SOMETHING_NEW")
    check("BANK_IDN", .other, "BANK_IDN")
    check("PHONE_", .other, "PHONE_")
    check("nounderscore", .other, "nounderscore")
  }
}

final class ReportTextTests: XCTestCase {

  private func keys(_ language: String) throws -> [String: String] {
    let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
    let url = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
    return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
  }

  func testBothLanguagesHaveTheSameKeys() throws {
    XCTAssertEqual(Set(try keys("en").keys), Set(try keys("id").keys))
  }

  func testEveryCodeAndStatusHasText() {
    for code in TraciveReportError.Code.allCases {
      XCTAssertFalse(ReportText.error(code).hasPrefix("error_"), code.rawValue)
    }
    for status in ReportStatus.allCases {
      XCTAssertFalse(ReportText.statusTitle(status).hasPrefix("status_"), status.rawValue)
      XCTAssertFalse(ReportText.statusLine(status).hasPrefix("status_"), status.rawValue)
    }
  }

  func testRequiredWording() throws {
    let id = try keys("id")
    let en = try keys("en")
    XCTAssertEqual(id["terms_sentence"], "Dengan menekan Kirim, Anda menyetujui")
    XCTAssertEqual(en["terms_sentence"], "By tapping Send, you agree to")
    XCTAssertEqual(id["send"], "Kirim")
    XCTAssertEqual(en["send"], "Send")
    XCTAssertEqual(id["status_submitted"], "Laporan terkirim")
    XCTAssertEqual(id["status_in_review"], "Sedang ditinjau")
    XCTAssertEqual(id["status_reviewed"], "Sudah ditinjau")
    XCTAssertEqual(id["status_need_revision"], "Perlu perbaikan")
    XCTAssertEqual(id["open_in_tracive"], "Buka di Tracive")
    XCTAssertEqual(id["term_terms_of_service"], "Ketentuan Layanan")
    XCTAssertEqual(id["term_privacy_policy"], "Kebijakan Privasi")
  }

  func testReviewedLineGivesNoOutcomeAway() throws {
    for language in ["en", "id"] {
      let line = try XCTUnwrap(keys(language)["status_reviewed_line"]).lowercased()
      for word in ["approved", "rejected", "confirmed", "disetujui", "ditolak", "terbukti"] {
        XCTAssertFalse(line.contains(word), line)
      }
    }
  }

  func testUnknownTermIdIsPrettified() {
    XCTAssertEqual(ReportText.termName("COMMUNITY_GUIDELINES"), "Community Guidelines")
  }
}

final class ReportThemeTests: XCTestCase {

  func testAColourInvisibleOnTheBackgroundIsShifted() {
    let colors = [UIColor.white, .black, UIColor(red: 0, green: 0.412, blue: 0.361, alpha: 1)]
    for color in colors {
      let theme = ResolvedReportTheme(TraciveReportTheme(primaryColor: color))
      for style in [UIUserInterfaceStyle.light, .dark] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let primary = UIColor(theme.primary).resolvedColor(with: traits)
        let contrast = ResolvedReportTheme.contrast(primary, ResolvedReportTheme.surface(traits))
        XCTAssertGreaterThanOrEqual(contrast, 2.9, "\(color) in \(style.rawValue)")
      }
    }
  }

  func testRadiusIsClamped() {
    XCTAssertEqual(ResolvedReportTheme(TraciveReportTheme(cornerRadius: 99)).radius, 28)
    XCTAssertEqual(ResolvedReportTheme(TraciveReportTheme(cornerRadius: -1)).radius, 0)
    XCTAssertEqual(ResolvedReportTheme(TraciveReportTheme()).radius, 12)
  }
}

private final class Toggle: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(on: Bool) { value = on }

  var isOn: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }
}

struct TimedOut: Error {
  let what: String
}

@discardableResult
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
