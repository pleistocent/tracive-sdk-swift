import CryptoKit
import XCTest

@testable import TraciveSDK

/// Drives the vendored `report-package-vectors.json`, the package contract shared byte for byte
/// with the Kotlin, Flutter and React Native SDKs and read by the Tracive app.
///
/// Every case goes through the whole of `openReportForm` with a Tracive app that accepts packages,
/// so a package case is checked on the file the sheet was handed, and an error case also proves
/// that nothing was probed, written or opened.
@MainActor
final class ReportPackageVectorTests: XCTestCase {

  private struct Fixture: Decodable {
    struct Limits: Decodable {
      let pdfMaxBytesExclusive: Int
      let maxAttachments: Int
      let maxAttachmentsPhone: Int
      let packageMaxBytes: Int
    }
    struct Attachment: Decodable {
      let mimeType: String
      let head: String
      let sizeBytes: Int
    }
    struct ExpectedAttachment: Decodable {
      let name: String
      let mimeType: String
    }
    struct ExpectedPackage: Decodable {
      let v: Int
      let query: String
      let incidentDate: String?
      let attachments: [ExpectedAttachment]
    }
    struct Expect: Decodable {
      let package: ExpectedPackage?
      let error: String?
      let index: Int?
      let max: Int?
    }
    struct Case: Decodable {
      let name: String
      let query: String
      let incidentDate: String?
      let attachments: [Attachment]
      let expect: Expect
    }
    struct ReportLink: Decodable {
      let scheme: String
      let query: String
      let url: String
    }
    let version: Int
    let limits: Limits
    let cases: [Case]
    let reportLinks: [ReportLink]
  }

  private static func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    if let url = Bundle.module.url(forResource: name, withExtension: ext)
      ?? Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext)
    {
      return url
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("\(name).\(ext)")
  }

  private func loadFixture() throws -> Fixture {
    let data = try Data(contentsOf: try Self.fixtureURL("report-package-vectors", "json"))
    return try JSONDecoder().decode(Fixture.self, from: data)
  }

  /// Day 2026-11-04 in Jakarta, so the fixture's 2026-11-03 is in the past whatever the machine's
  /// clock says.
  private static let now = Date(timeIntervalSince1970: 1_793_768_400)  // 2026-11-04T05:00:00Z
  private static let jakarta = TimeZone(identifier: "Asia/Jakarta")!

  private var storeRoot: URL!

  override func setUp() async throws {
    storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tracive-report-vectors-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: storeRoot)
  }

  // MARK: - The file itself

  /// Same rule as the grammar and phone fixtures: the four copies are compared by digest, so a
  /// reformatted copy breaks the cross-repo comparison even though every case below still passes.
  /// Do not re-pin to make this green; the canonical copy changes first and is copied to all four.
  func testTheFixtureMatchesItsPinnedContentHash() throws {
    let data = try Data(contentsOf: try Self.fixtureURL("report-package-vectors", "json"))
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let pin = String(
      decoding: try Data(contentsOf: try Self.fixtureURL("report-package-vectors", "sha256")),
      as: UTF8.self)
    let expected = try XCTUnwrap(pin.split(whereSeparator: \.isWhitespace).first).lowercased()
    XCTAssertEqual(actual, expected, "report-package-vectors.json moved (\(data.count) bytes)")
  }

  func testFixtureIsTheExpectedContract() throws {
    let fixture = try loadFixture()
    XCTAssertEqual(fixture.version, 1)
    XCTAssertEqual(fixture.cases.count, 19, "a case was added or removed — re-read the fixture")
    XCTAssertEqual(fixture.reportLinks.count, 5)
    XCTAssertEqual(fixture.limits.pdfMaxBytesExclusive, ReportPackage.pdfMaxBytesExclusive)
    XCTAssertEqual(fixture.limits.maxAttachments, ReportPackage.maxAttachments)
    XCTAssertEqual(fixture.limits.maxAttachmentsPhone, ReportPackage.maxAttachmentsForPhone)
    XCTAssertEqual(fixture.limits.packageMaxBytes, ReportPackage.packageMaxBytes)
  }

  // MARK: - Cases

  func testEveryCase() async throws {
    let fixture = try loadFixture()
    for testCase in fixture.cases {
      try await check(testCase)
    }
  }

  private func check(_ testCase: Fixture.Case) async throws {
    let label = testCase.name
    let query = try Self.query(from: testCase.query)
    XCTAssertEqual(query.searchQueryIndex, testCase.query, label)
    let incidentDate = try testCase.incidentDate.map {
      try XCTUnwrap(ReportIncidentDate(iso8601: $0), label)
    }
    let inputs = try testCase.attachments.map { try Self.generate($0) }
    let attachments = zip(testCase.attachments, inputs).map { spec, bytes in
      spec.mimeType == "application/pdf"
        ? ReportAttachment.pdf(bytes) : ReportAttachment.image(bytes, mimeType: spec.mimeType)
    }

    let launcher = ScriptedAppLauncher(openable: ["tracive-report", "tracive"])
    let presenter = FakeOpenInMenuPresenter(
      outcome: .sending(toApplication: "com.pleistocent.tracive"))
    let client = makeReportClient(launcher: launcher, now: Self.now)
    let root = storeRoot.appendingPathComponent(testCase.name, isDirectory: true)

    let result = await client.openReportForm(
      query,
      incidentDate: incidentDate,
      attachments: attachments,
      target: nil,
      presenter: presenter,
      store: ReportPackageStore(root: root),
      gate: ReportFormGate(),
      timeZone: Self.jakarta
    )

    if let expected = testCase.expect.package {
      XCTAssertEqual(result, .opened(attachmentsDelivered: true), label)
      XCTAssertEqual(
        presenter.presentedFiles.map(\.lastPathComponent), ["report.tracivereport"], label)
      let raw = try XCTUnwrap(presenter.presentedContents.first, label)
      XCTAssertFalse(
        String(decoding: raw, as: UTF8.self).contains("\\/"), "\(label): a '/' was escaped")
      try assertPackage(raw, matches: expected, inputs: inputs, label: label)
    } else {
      let code = try XCTUnwrap(testCase.expect.error, label)
      XCTAssertEqual(result, .failed(try Self.error(code, testCase.expect)), label)
      XCTAssertTrue(presenter.presentedFiles.isEmpty, "\(label): the sheet was shown")
      XCTAssertTrue(launcher.probed.isEmpty, "\(label): probed before validating")
      XCTAssertTrue(launcher.opened.isEmpty, "\(label): opened \(launcher.opened)")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.path), "\(label): a package was written")
    }
  }

  private func assertPackage(
    _ raw: Data, matches expected: Fixture.ExpectedPackage, inputs: [Data], label: String
  ) throws {
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any], label)
    XCTAssertEqual(object["v"] as? Int, expected.v, label)
    XCTAssertEqual(object["query"] as? String, expected.query, label)
    if let date = expected.incidentDate {
      XCTAssertEqual(object["incidentDate"] as? String, date, label)
    } else {
      XCTAssertNil(object["incidentDate"], "\(label): incidentDate must be absent, not null")
    }
    let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]], label)
    XCTAssertEqual(attachments.count, expected.attachments.count, label)
    for (index, pair) in zip(attachments, expected.attachments).enumerated() {
      let (actual, wanted) = pair
      XCTAssertEqual(actual["name"] as? String, wanted.name, "\(label) #\(index)")
      XCTAssertEqual(actual["mimeType"] as? String, wanted.mimeType, "\(label) #\(index)")
      let data = try XCTUnwrap(actual["data"] as? String, "\(label) #\(index)")
      // Standard alphabet, padded, no line breaks: exactly what the plain encoder writes.
      XCTAssertEqual(data, inputs[index].base64EncodedString(), "\(label) #\(index)")
      XCTAssertEqual(Data(base64Encoded: data), inputs[index], "\(label) #\(index)")
    }
  }

  func testEveryReportLink() throws {
    let fixture = try loadFixture()
    for vector in fixture.reportLinks {
      let target = ReportFormTarget(
        bundleIdentifier: "unused", scheme: vector.scheme, capabilityScheme: "unused",
        fileExtension: "unused")
      XCTAssertEqual(target.reportLink(for: vector.query)?.absoluteString, vector.url, vector.query)
    }
  }

  // MARK: - Helpers

  /// The fixture's byte rule: `head[i]` while `i < head.count`, else `i % 251`.
  private static func generate(_ spec: Fixture.Attachment) throws -> Data {
    var head: [UInt8] = []
    var hex = Substring(spec.head)
    while !hex.isEmpty {
      head.append(try XCTUnwrap(UInt8(hex.prefix(2), radix: 16), "bad head \(spec.head)"))
      hex = hex.dropFirst(2)
    }
    let cycle = Data((0..<251).map { UInt8($0) })
    var data = Data(capacity: spec.sizeBytes + cycle.count)
    while data.count < spec.sizeBytes { data.append(cycle) }
    data.count = spec.sizeBytes
    data.replaceSubrange(0..<min(head.count, spec.sizeBytes), with: head.prefix(spec.sizeBytes))
    return data
  }

  /// The two query shapes the cases use. Anything else fails here rather than being skipped.
  private static func query(from index: String) throws -> TraciveQuery {
    if index.hasPrefix("PHONE_") {
      return try .phone(e164: String(index.dropFirst("PHONE_".count)))
    }
    let parts = index.split(separator: "_", omittingEmptySubsequences: false)
    if parts.count == 4, parts[0] == "BANK" {
      return try .bankAccount(
        countryAlpha3: String(parts[1]), bankCode: String(parts[2]), account: String(parts[3]))
    }
    throw UnsupportedQueryShape(index: index)
  }

  private struct UnsupportedQueryShape: Error { let index: String }

  private static func error(_ code: String, _ expect: Fixture.Expect) throws -> ReportFormError {
    switch code {
    case "INCIDENT_DATE_IN_FUTURE": return .incidentDateInFuture
    case "TOO_MANY_ATTACHMENTS": return .tooManyAttachments(max: try XCTUnwrap(expect.max))
    case "UNSUPPORTED_TYPE": return .unsupportedType(index: try XCTUnwrap(expect.index))
    case "CONTENT_MISMATCH": return .contentMismatch(index: try XCTUnwrap(expect.index))
    case "PDF_TOO_LARGE": return .pdfTooLarge(index: try XCTUnwrap(expect.index))
    case "PACKAGE_TOO_LARGE": return .packageTooLarge(max: try XCTUnwrap(expect.max))
    default: throw UnknownErrorCode(code: code)
    }
  }

  private struct UnknownErrorCode: Error { let code: String }
}

// MARK: - Shared fakes

/// Answers `canOpen` for the schemes it was given, records every probe and every open, and accepts
/// or refuses opens as told.
final class ScriptedAppLauncher: TraciveAppLauncher, @unchecked Sendable {

  private let openable: Set<String>
  private let acceptsOpen: Bool
  private let lock = NSLock()
  private var probedURLs: [URL] = []
  private var openedURLs: [URL] = []

  init(openable: Set<String>, acceptsOpen: Bool = true) {
    self.openable = openable
    self.acceptsOpen = acceptsOpen
  }

  func canOpen(_ url: URL) async -> Bool {
    record(probe: url)
    return url.scheme.map(openable.contains) ?? false
  }

  @discardableResult
  func open(_ url: URL) async -> Bool {
    record(open: url)
    return acceptsOpen
  }

  private func record(probe: URL? = nil, open: URL? = nil) {
    lock.lock()
    defer { lock.unlock() }
    if let probe { probedURLs.append(probe) }
    if let open { openedURLs.append(open) }
  }

  var probed: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return probedURLs
  }

  var opened: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return openedURLs
  }
}

/// Stands in for the "Open in" sheet: records the file it was handed (and its bytes, since the next
/// call deletes it) and answers with a scripted outcome.
@MainActor
final class FakeOpenInMenuPresenter: OpenInMenuPresenting {

  private let outcome: OpenInMenuOutcome
  private(set) var presentedFiles: [URL] = []
  private(set) var presentedContents: [Data] = []

  init(outcome: OpenInMenuOutcome) {
    self.outcome = outcome
  }

  func presentOpenInMenu(for file: URL) async -> OpenInMenuOutcome {
    presentedFiles.append(file)
    presentedContents.append((try? Data(contentsOf: file)) ?? Data())
    return outcome
  }
}

/// A client whose OAuth driver carries `launcher`, so the test also proves `openReportForm` uses
/// the launcher `authorize()` uses.
@MainActor
func makeReportClient(
  environment: TraciveEnvironment = .production,
  clientType: ClientType = .public,
  launcher: ScriptedAppLauncher,
  installURL: URL? = nil,
  transport: FakeHTTPTransport = FakeHTTPTransport { _, _ in HTTPResponse(status: 500) },
  now: Date
) -> TraciveClient {
  let clock = RecordingClock(now: now)
  let configuration = makeOAuthConfiguration(clientType: clientType)
  let oauth = try! TraciveOAuth(
    configuration: configuration,
    environment: environment,
    transport: transport,
    tokenStore: InMemoryTokenStore(),
    appLauncher: launcher,
    clock: clock,
    installURL: installURL
  )
  return TraciveClient(
    mode: .oauth(configuration),
    environment: environment,
    transport: transport,
    clock: clock,
    cache: NoOpCheckCache(),
    tokenStore: InMemoryTokenStore(),
    oauth: oauth
  )
}
