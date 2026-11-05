import XCTest

@testable import TraciveSDK

/// `openReportForm` behind its two seams: which of package, link or install page each device state
/// gets, how the "Open in" sheet's callbacks become a result, and the date, file and concurrency
/// rules around them. No UIKit, no network, no Keychain.
@MainActor
final class ReportFormTests: XCTestCase {

  private static let now = Date(timeIntervalSince1970: 1_793_768_400)  // 2026-11-04T05:00:00Z
  private static let jakarta = TimeZone(identifier: "Asia/Jakarta")!
  private static let productionBundle = "com.pleistocent.tracive"
  private static let sandboxBundle = "com.pleistocent.tracive.sandbox"

  private var storeRoot: URL!

  override func setUp() async throws {
    storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tracive-report-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: storeRoot)
  }

  private func phoneQuery() throws -> TraciveQuery { try .phone(e164: "+6281234567890") }

  private func png() -> ReportAttachment {
    .image(
      Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01]), mimeType: "image/png")
  }

  private func open(
    _ client: TraciveClient,
    query: TraciveQuery? = nil,
    incidentDate: ReportIncidentDate? = nil,
    attachments: [ReportAttachment]? = nil,
    target: ReportFormTarget? = nil,
    presenter: any OpenInMenuPresenting,
    launcher: (any TraciveAppLauncher)? = nil,
    gate: ReportFormGate? = nil,
    timeZone: TimeZone? = nil
  ) async throws -> ReportFormResult {
    await client.openReportForm(
      try query ?? phoneQuery(),
      incidentDate: incidentDate,
      attachments: attachments ?? [png()],
      target: target,
      presenter: presenter,
      launcher: launcher,
      store: ReportPackageStore(root: storeRoot),
      gate: gate ?? ReportFormGate(),
      timeZone: timeZone ?? Self.jakarta
    )
  }

  // MARK: - Which hand-over the device gets

  func testTheTargetAppPickedInTheSheetGetsThePackage() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let presenter = FakeOpenInMenuPresenter(outcome: .sending(toApplication: Self.productionBundle))
    let client = makeReportClient(launcher: launcher, now: Self.now)

    let result = try await open(client, presenter: presenter)

    XCTAssertEqual(result, .opened(attachmentsDelivered: true))
    XCTAssertEqual(launcher.probed.map(\.absoluteString), ["tracive-report://"])
    XCTAssertEqual(launcher.opened, [], "a delivered package must not also open a link")
    XCTAssertEqual(presenter.presentedFiles.count, 1)
  }

  func testAnOlderAppGetsTheLinkWithTheIdentifierOnly() async throws {
    // Also the host app that lists `tracive` but forgot `tracive-report`: canOpenURL answers no for
    // an undeclared scheme, which lands here.
    let launcher = ScriptedAppLauncher(openable: ["tracive"])
    let presenter = FakeOpenInMenuPresenter(outcome: .sending(toApplication: Self.productionBundle))
    let client = makeReportClient(launcher: launcher, now: Self.now)

    let result = try await open(client, presenter: presenter)

    XCTAssertEqual(result, .opened(attachmentsDelivered: false))
    XCTAssertEqual(
      launcher.opened.map(\.absoluteString),
      ["tracive://report/create?media=PHONE_%2B6281234567890"])
    XCTAssertTrue(presenter.presentedFiles.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.path), "no package needed")
  }

  func testDecliningTheOpenPromptForTheLinkIsCancelled() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive"], acceptsOpen: false)
    let client = makeReportClient(launcher: launcher, now: Self.now)

    let result = try await open(client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed))

    XCTAssertEqual(result, .cancelled)
    XCTAssertEqual(launcher.opened.count, 1)
  }

  func testNoAppOpensTheInstallPageCarryingNothingFromTheReport() async throws {
    let launcher = ScriptedAppLauncher(openable: [])
    let presenter = FakeOpenInMenuPresenter(outcome: .sending(toApplication: Self.productionBundle))
    let client = makeReportClient(launcher: launcher, now: Self.now)

    let result = try await open(
      client, incidentDate: ReportIncidentDate(year: 2026, month: 11, day: 3), presenter: presenter)

    XCTAssertEqual(result, .installPageOpened)
    XCTAssertEqual(launcher.opened, [TraciveAppPresence.installURL(clientId: "test-client")])
    let opened = try XCTUnwrap(launcher.opened.first?.absoluteString)
    for leak in ["6281234567890", "PHONE", "2026-11-03", "media"] {
      XCTAssertFalse(opened.contains(leak), "the install link carries \(leak)")
    }
    XCTAssertTrue(presenter.presentedFiles.isEmpty)
  }

  func testTheInstallLinkOverrideGivenToTheOAuthDriverIsUsed() async throws {
    let override = URL(string: "https://apps.partner.example/tracive")!
    let launcher = ScriptedAppLauncher(openable: [])
    let client = makeReportClient(launcher: launcher, installURL: override, now: Self.now)

    let result = try await open(client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed))

    XCTAssertEqual(result, .installPageOpened)
    XCTAssertEqual(launcher.opened, [override])
  }

  func testAnInstallLinkTheSystemRefusesIsAPlatformFailure() async throws {
    let launcher = ScriptedAppLauncher(openable: [], acceptsOpen: false)
    let client = makeReportClient(launcher: launcher, now: Self.now)

    let result = try await open(client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed))

    XCTAssertEqual(result, .failed(.platform(reason: "install_link_refused")))
  }

  // MARK: - What the sheet reported

  func testAnotherAppPickedInTheSheetIsCancelled() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(launcher: launcher, now: Self.now)

    for picked in ["com.example.impostor", Self.sandboxBundle, Self.productionBundle.uppercased()] {
      let presenter = FakeOpenInMenuPresenter(outcome: .sending(toApplication: picked))
      let result = try await open(client, presenter: presenter)
      XCTAssertEqual(result, .cancelled, picked)
    }
    let unnamed = FakeOpenInMenuPresenter(outcome: .sending(toApplication: nil))
    let result = try await open(client, presenter: unnamed)
    XCTAssertEqual(result, .cancelled, "an unnamed app is not the target")
    XCTAssertEqual(launcher.opened, [], "a cancel must not fall back to a link")
  }

  func testDismissingTheSheetIsCancelled() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(launcher: launcher, now: Self.now)

    let result = try await open(client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed))

    XCTAssertEqual(result, .cancelled)
    XCTAssertEqual(launcher.opened, [])
  }

  func testASheetThatNeverAppearedIsAPlatformFailure() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(launcher: launcher, now: Self.now)
    let presenter = FakeOpenInMenuPresenter(outcome: .notPresented(reason: "anchor_not_in_window"))

    let result = try await open(client, presenter: presenter)

    XCTAssertEqual(result, .failed(.platform(reason: "anchor_not_in_window")))
  }

  func testWillBeginSettlesTheAnswerAndTheFollowingDismissDoesNotUndoIt() {
    var outcomes: [OpenInMenuOutcome] = []
    let resolution = OpenInMenuResolution { outcomes.append($0) }

    resolution.willBeginSending(toApplication: Self.productionBundle)
    XCTAssertFalse(resolution.isFinished, "the file is still being handed over")
    resolution.didDismissMenu()
    XCTAssertFalse(resolution.isFinished, "dismiss after willBegin must keep the controller alive")
    resolution.didEndSending(toApplication: Self.productionBundle)
    XCTAssertTrue(resolution.isFinished)

    XCTAssertEqual(outcomes, [.sending(toApplication: Self.productionBundle)])
  }

  func testADismissWithNoWillBeginIsTheAnswer() {
    var outcomes: [OpenInMenuOutcome] = []
    let resolution = OpenInMenuResolution { outcomes.append($0) }

    resolution.didDismissMenu()
    resolution.willBeginSending(toApplication: Self.productionBundle)

    XCTAssertEqual(outcomes, [.dismissed], "answered once, by the first event that decides it")
    XCTAssertTrue(resolution.isFinished)
  }

  func testWillBeginNamingAnotherAppIsReportedAsThatApp() {
    var outcomes: [OpenInMenuOutcome] = []
    let resolution = OpenInMenuResolution { outcomes.append($0) }

    resolution.willBeginSending(toApplication: "com.example.impostor")
    resolution.didDismissMenu()

    XCTAssertEqual(outcomes, [.sending(toApplication: "com.example.impostor")])
  }

  func testANotPresentedSheetIsAnsweredAndFinished() {
    var outcomes: [OpenInMenuOutcome] = []
    let resolution = OpenInMenuResolution { outcomes.append($0) }

    resolution.notPresented(reason: "menu_not_presented")

    XCTAssertEqual(outcomes, [.notPresented(reason: "menu_not_presented")])
    XCTAssertTrue(resolution.isFinished)
  }

  func testASheetGoneOnTwoChecksInARowIsReportedOnce() {
    var gone = false
    var fired = 0
    let watch = VanishedSheetWatch(isGone: { gone }, onVanished: { fired += 1 })

    watch.check()
    gone = true
    watch.check()
    XCTAssertEqual(fired, 0, "one sighting leaves room for a delegate answer on its way")
    watch.check()
    watch.check()

    XCTAssertEqual(fired, 1)
  }

  func testASheetBackOnScreenStartsTheCountAgain() {
    var sightings = [true, false, true, false, true]
    var fired = 0
    let watch = VanishedSheetWatch(isGone: { sightings.removeFirst() }, onVanished: { fired += 1 })

    for _ in 0..<5 { watch.check() }

    XCTAssertEqual(fired, 0)
  }

  // MARK: - Which build

  func testASandboxClientHandsOverToTheSandboxBuildOnly() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracivesandbox-report", "tracivesandbox"])
    let client = makeReportClient(environment: .sandbox, launcher: launcher, now: Self.now)

    let delivered = FakeOpenInMenuPresenter(outcome: .sending(toApplication: Self.sandboxBundle))
    let result = try await open(client, presenter: delivered)
    XCTAssertEqual(result, .opened(attachmentsDelivered: true))
    XCTAssertEqual(
      delivered.presentedFiles.map(\.lastPathComponent), ["report.tracivesandboxreport"])
    XCTAssertEqual(launcher.probed.map(\.absoluteString), ["tracivesandbox-report://"])

    let wrongBuild = FakeOpenInMenuPresenter(
      outcome: .sending(toApplication: Self.productionBundle))
    let picked = try await open(client, presenter: wrongBuild)
    XCTAssertEqual(picked, .cancelled, "the production app is not the sandbox client's target")
  }

  func testASandboxClientsLinkUsesTheSandboxScheme() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracivesandbox", "tracive-report", "tracive"])
    let client = makeReportClient(environment: .sandbox, launcher: launcher, now: Self.now)

    let result = try await open(client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed))

    XCTAssertEqual(result, .opened(attachmentsDelivered: false))
    XCTAssertEqual(
      launcher.opened.map(\.absoluteString),
      ["tracivesandbox://report/create?media=PHONE_%2B6281234567890"])
  }

  func testACustomEnvironmentTargetsTheProductionBuild() {
    XCTAssertEqual(
      ReportFormTarget.for(.custom(baseUrl: URL(string: "https://x.example/v1")!)), .production)
    XCTAssertEqual(ReportFormTarget.for(.production), .production)
    XCTAssertEqual(ReportFormTarget.for(.sandbox), .sandbox)
  }

  func testTheTargetTableIsTheContract() {
    XCTAssertEqual(
      ReportFormTarget.production,
      ReportFormTarget(
        bundleIdentifier: "com.pleistocent.tracive", scheme: "tracive",
        capabilityScheme: "tracive-report", fileExtension: "tracivereport"))
    XCTAssertEqual(
      ReportFormTarget.sandbox,
      ReportFormTarget(
        bundleIdentifier: "com.pleistocent.tracive.sandbox", scheme: "tracivesandbox",
        capabilityScheme: "tracivesandbox-report", fileExtension: "tracivesandboxreport"))
  }

  func testAnExplicitTargetWinsOverTheEnvironment() async throws {
    let dev = ReportFormTarget(
      bundleIdentifier: "com.pleistocent.tracive.dev", scheme: "tracivedev",
      capabilityScheme: "tracivedev-report", fileExtension: "tracivedevreport")
    let launcher = ScriptedAppLauncher(openable: ["tracivedev-report", "tracive-report"])
    let presenter = FakeOpenInMenuPresenter(outcome: .sending(toApplication: dev.bundleIdentifier))
    let client = makeReportClient(environment: .production, launcher: launcher, now: Self.now)

    let result = try await open(client, target: dev, presenter: presenter)

    XCTAssertEqual(result, .opened(attachmentsDelivered: true))
    XCTAssertEqual(launcher.probed.map(\.absoluteString), ["tracivedev-report://"])
    XCTAssertEqual(presenter.presentedFiles.map(\.lastPathComponent), ["report.tracivedevreport"])
  }

  // MARK: - Modes

  func testAConfidentialClientWithNoGrantOpensTheFormWithoutTouchingTheNetwork() async throws {
    let transport = FakeHTTPTransport { _, _ in HTTPResponse(status: 500) }
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(
      clientType: .confidential, launcher: launcher, transport: transport, now: Self.now)
    let presenter = FakeOpenInMenuPresenter(outcome: .sending(toApplication: Self.productionBundle))

    let authorized = await client.isAuthorized
    let result = try await open(client, presenter: presenter)

    XCTAssertFalse(authorized)
    XCTAssertEqual(result, .opened(attachmentsDelivered: true))
    XCTAssertEqual(transport.callCount, 0)
  }

  func testProxyModeStillOpensTheForm() async throws {
    let launcher = ScriptedAppLauncher(openable: [])
    let client = TraciveClient(
      mode: .proxy(baseUrl: URL(string: "https://proxy.partner.example")!),
      transport: FakeHTTPTransport { _, _ in HTTPResponse(status: 500) },
      clock: RecordingClock(now: Self.now),
      cache: NoOpCheckCache()
    )

    let result = try await open(
      client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed), launcher: launcher)

    XCTAssertEqual(result, .installPageOpened)
    XCTAssertEqual(launcher.opened, [TraciveAppPresence.installURL(clientId: nil)])
  }

  // MARK: - Validation comes first

  func testAValidationFailureProbesNothingAndOpensNothing() async throws {
    let launcher = ScriptedAppLauncher(openable: [])
    let client = makeReportClient(launcher: launcher, now: Self.now)
    let gif = ReportAttachment.image(Data("GIF89a".utf8), mimeType: "image/gif")

    let result = try await open(
      client, attachments: [png(), gif], presenter: FakeOpenInMenuPresenter(outcome: .dismissed))

    XCTAssertEqual(result, .failed(.unsupportedType(index: 1)))
    XCTAssertEqual(launcher.probed, [])
    XCTAssertEqual(launcher.opened, [], "no install page for a report that would be refused anyway")
  }

  func testTodayIsTheDevicesLocalDay() async throws {
    // 2026-11-03T18:00Z is already 4 November in Jakarta and still 3 November in UTC.
    let evening = Date(timeIntervalSince1970: 1_793_728_800)
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(launcher: launcher, now: evening)
    let fourth = ReportIncidentDate(year: 2026, month: 11, day: 4)
    let fifth = ReportIncidentDate(year: 2026, month: 11, day: 5)
    func delivered() -> FakeOpenInMenuPresenter {
      FakeOpenInMenuPresenter(outcome: .sending(toApplication: Self.productionBundle))
    }

    let today = try await open(client, incidentDate: fourth, presenter: delivered())
    XCTAssertEqual(today, .opened(attachmentsDelivered: true), "today is not the future")

    let tomorrow = try await open(client, incidentDate: fifth, presenter: delivered())
    XCTAssertEqual(tomorrow, .failed(.incidentDateInFuture))

    let utc = try await open(
      client, incidentDate: fourth, presenter: delivered(), timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertEqual(utc, .failed(.incidentDateInFuture), "in UTC the 4th has not started yet")
  }

  // MARK: - Files and concurrency

  func testThePackageAnEarlierCallLeftIsDeletedOnTheNextCall() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(launcher: launcher, now: Self.now)
    let first = FakeOpenInMenuPresenter(outcome: .dismissed)
    let second = FakeOpenInMenuPresenter(outcome: .dismissed)

    _ = try await open(client, presenter: first)
    let firstFile = try XCTUnwrap(first.presentedFiles.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))

    _ = try await open(client, presenter: second)
    let secondFile = try XCTUnwrap(second.presentedFiles.first)

    XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: firstFile.deletingLastPathComponent().path),
      "the earlier call's folder is gone too")
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
    XCTAssertNotEqual(firstFile.deletingLastPathComponent(), secondFile.deletingLastPathComponent())
  }

  func testASecondCallWhileTheSheetIsUpIsRefusedAndLeavesTheFirstFileAlone() async throws {
    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let client = makeReportClient(launcher: launcher, now: Self.now)
    let gate = ReportFormGate()
    let held = HeldOpenInMenuPresenter()

    let first = Task { try await open(client, presenter: held, gate: gate) }
    for _ in 0..<10_000 where held.presentedFile == nil { await Task.yield() }
    guard held.presentedFile != nil else {
      first.cancel()
      return XCTFail("the first call never showed its sheet: \(try await first.value)")
    }

    let second = try await open(
      client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed), gate: gate)
    XCTAssertEqual(second, .failed(.platform(reason: "already_in_progress")))
    let firstFile = try XCTUnwrap(held.presentedFile)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))

    held.finish(with: .sending(toApplication: Self.productionBundle))
    let firstResult = try await first.value
    XCTAssertEqual(firstResult, .opened(attachmentsDelivered: true))

    let third = try await open(
      client, presenter: FakeOpenInMenuPresenter(outcome: .dismissed), gate: gate)
    XCTAssertEqual(third, .cancelled, "the gate opens again once the first call returns")
  }

  /// The base64 alone is checked first, as a cheap lower bound; the encoded package is checked
  /// after. Sizes chosen so the base64 fits and the JSON around it is what crosses 20 MiB.
  func testThePackageCapCountsTheWholeEncodedFileNotJustTheBase64() throws {
    func build(_ count: Int) -> Result<Data, ReportFormError> {
      var bytes = Data(count: count)
      bytes.replaceSubrange(0..<8, with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      return ReportPackage.build(
        searchQueryIndex: "BANK_IDN_BCA_1234567890", incidentDate: nil,
        attachments: [.image(bytes, mimeType: "image/png")],
        today: ReportIncidentDate(year: 2026, month: 11, day: 4)!)
    }
    let small = try build(9).get()
    let overhead = small.count - 12  // 9 bytes are 12 base64 characters
    let cap = ReportPackage.packageMaxBytes
    let fitting = (cap - overhead) / 4 * 3  // the most bytes, in whole base64 quanta, that fit

    XCTAssertEqual(try build(fitting).get().count, overhead + fitting / 3 * 4)
    XCTAssertLessThanOrEqual(overhead + fitting / 3 * 4, cap)
    XCTAssertLessThanOrEqual((fitting + 3) / 3 * 4, cap, "the base64 alone still fits")
    XCTAssertEqual(build(fitting + 3), .failure(.packageTooLarge(max: cap)))
  }

  // MARK: - Types

  func testDescriptionsCarryNoBytes() {
    let secret = Data("BCA 1234567890 Budi".utf8)
    let attachment = ReportAttachment.pdf(secret)
    for text in [attachment.description, attachment.debugDescription, "\(attachment)"] {
      XCTAssertFalse(text.contains("1234567890"))
      XCTAssertFalse(text.contains(secret.base64EncodedString()))
      XCTAssertTrue(text.contains("application/pdf"))
    }
    XCTAssertEqual(ReportFormError.pdfTooLarge(index: 2).description, "PDF_TOO_LARGE(index: 2)")
    XCTAssertEqual(
      ReportFormError.packageTooLarge(max: 20_971_520).description,
      "PACKAGE_TOO_LARGE(max: 20971520)")
    XCTAssertEqual(
      ReportFormResult.failed(.incidentDateInFuture).description, "failed(INCIDENT_DATE_IN_FUTURE)")
    XCTAssertEqual(
      ReportFormError.platform(reason: "install_link_refused").description,
      "PLATFORM_FAILURE(install_link_refused)")
  }

  func testErrorCodesAreTheContractSpellings() {
    let codes: [(ReportFormError, String)] = [
      (.incidentDateInFuture, "INCIDENT_DATE_IN_FUTURE"),
      (.tooManyAttachments(max: 5), "TOO_MANY_ATTACHMENTS"),
      (.unsupportedType(index: 0), "UNSUPPORTED_TYPE"),
      (.contentMismatch(index: 0), "CONTENT_MISMATCH"),
      (.pdfTooLarge(index: 0), "PDF_TOO_LARGE"),
      (.packageTooLarge(max: 1), "PACKAGE_TOO_LARGE"),
      (.platform(reason: "x"), "PLATFORM_FAILURE"),
    ]
    for (error, code) in codes { XCTAssertEqual(error.code, code) }
  }

  func testIncidentDateRefusesDaysThatDoNotExist() {
    XCTAssertNotNil(ReportIncidentDate(year: 2028, month: 2, day: 29))
    XCTAssertNil(ReportIncidentDate(year: 2026, month: 2, day: 29))
    XCTAssertNil(ReportIncidentDate(year: 2100, month: 2, day: 29))
    XCTAssertNotNil(ReportIncidentDate(year: 2000, month: 2, day: 29))
    XCTAssertNil(ReportIncidentDate(year: 2026, month: 4, day: 31))
    XCTAssertNil(ReportIncidentDate(year: 2026, month: 13, day: 1))
    XCTAssertNil(ReportIncidentDate(year: 2026, month: 0, day: 1))
    XCTAssertNil(ReportIncidentDate(year: 2026, month: 1, day: 0))
    XCTAssertNil(ReportIncidentDate(year: 0, month: 1, day: 1))
    XCTAssertNil(ReportIncidentDate(year: 10_000, month: 1, day: 1))
  }

  func testIncidentDateParsesAndWritesExactlyYYYYMMDD() {
    XCTAssertEqual(ReportIncidentDate(iso8601: "2026-11-03")?.iso8601, "2026-11-03")
    XCTAssertEqual(ReportIncidentDate(year: 5, month: 1, day: 9)?.iso8601, "0005-01-09")
    for bad in [
      "2026-1-03", "2026-11-3", "26-11-03", "2026/11/03", "2026-11-03T00:00:00Z", " 2026-11-03",
      "2026-11-31", "２０２６-11-03", "+026-11-03", "",
    ] {
      XCTAssertNil(ReportIncidentDate(iso8601: bad), bad)
    }
  }

  func testIncidentDateFromAnInstantTakesTheDayInTheGivenZone() {
    let evening = Date(timeIntervalSince1970: 1_793_728_800)  // 2026-11-03T18:00Z
    XCTAssertEqual(ReportIncidentDate(evening, timeZone: Self.jakarta).iso8601, "2026-11-04")
    XCTAssertEqual(
      ReportIncidentDate(evening, timeZone: TimeZone(identifier: "UTC")!).iso8601, "2026-11-03")
  }

  func testIncidentDatesOrderByDay() throws {
    let a = try XCTUnwrap(ReportIncidentDate(year: 2026, month: 1, day: 31))
    let b = try XCTUnwrap(ReportIncidentDate(year: 2026, month: 2, day: 1))
    let c = try XCTUnwrap(ReportIncidentDate(year: 2027, month: 1, day: 1))
    XCTAssertLessThan(a, b)
    XCTAssertLessThan(b, c)
    XCTAssertFalse(b < b)
  }
}

/// A sheet that stays up until the test closes it.
@MainActor
final class HeldOpenInMenuPresenter: OpenInMenuPresenting {

  private(set) var presentedFile: URL?
  private var continuation: CheckedContinuation<OpenInMenuOutcome, Never>?

  func presentOpenInMenu(for file: URL) async -> OpenInMenuOutcome {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      presentedFile = file
    }
  }

  func finish(with outcome: OpenInMenuOutcome) {
    continuation?.resume(returning: outcome)
    continuation = nil
  }
}
