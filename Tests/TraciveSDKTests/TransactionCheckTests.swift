import CryptoKit
import Foundation
import XCTest

@testable import TraciveSDK

/// The record of what a user was shown before they sent money, filed under the host's transaction id.
///
/// These rows answer a question the cache cannot. The cache holds the *latest* answer for an
/// identifier and expires it as soon as it stops being trustworthy; a transaction-detail screen has
/// to show the answer that was on screen **when the user decided**, months later, and it must not
/// change when that account is checked again. Everything here is one of those two properties.
///
/// Time is injected, as in `CacheTests`. There is no `sleep` in this file.
final class TransactionCheckTests: XCTestCase {

  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  private static let day: TimeInterval = 24 * 60 * 60

  private let firstTransfer = "TRF26090814320771"
  private let secondTransfer = "TRF26090910160442"

  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("TraciveRecordTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    temporaryDirectory = nil
    try super.tearDownWithError()
  }

  private func makeResult(
    tier: RiskTier = .high,
    fetchedAt: Date = TransactionCheckTests.t0,
    cacheTtlSeconds: Int64? = nil,
    origin: Origin = .server
  ) -> CheckResult {
    CheckResult(
      checkId: "chk_123",
      found: true,
      riskTier: tier,
      reportTotal: 12,
      credibleReports: 9,
      ambiguousReports: 3,
      firstReportOn: Date(timeIntervalSince1970: 1_700_000_000),
      lastReportOn: Date(timeIntervalSince1970: 1_790_000_000),
      fraudAmount: ["IDR": 87_400_000],
      tags: ["investment", "marketplace"],
      relatedScammerCount: 4,
      topChronologies: [
        Chronology(chronology: "Korban ditipu lewat investasi bodong.", riskLevel: 4,
                   incidentDate: "2026-05-11")
      ],
      comments: [
        Comment(date: "2026-05-12", text: "Saya juga kena, nomor yang sama.",
                fromCredibleReport: true)
      ],
      billing: Billing(creditSource: .user, unitsCharged: 1, partnerBalanceRemaining: 47),
      cacheTtlSeconds: cacheTtlSeconds,
      disclaimer: "Tracive reports are user-submitted.",
      origin: origin,
      fetchedAt: fetchedAt
    )
  }

  private func makeQuery() throws -> TraciveQuery {
    try TraciveQuery.bankAccount(countryAlpha3: "IDN", bankCode: "BCA", account: "7710442951")
  }

  // MARK: - Outliving the cache entry

  func testRecordOutlivesTheCacheEntryItWasTakenFrom() throws {
    // The failure this exists to prevent: a `NONE` answer is cached for an hour, so by the next
    // morning the transaction detail would have no card at all — for a transfer that was checked.
    let clock = TestClock(Self.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()
    let shown = makeResult(tier: .none)

    try cache.write(shown, for: query)
    try cache.writeTransactionCheck(shown, for: firstTransfer)

    clock.advance(by: 2 * 60 * 60)

    XCTAssertNil(try cache.read(query), "a NONE entry lives one hour; this asserts the premise")
    let record = try XCTUnwrap(try cache.readTransactionCheck(for: firstTransfer))
    XCTAssertEqual(record.riskTier, RiskTier.none)
    XCTAssertEqual(record.fetchedAt, Self.t0, "the card says when the check happened")
  }

  func testRetentionEndsTheRecordAndDropsTheRow() throws {
    let clock = TestClock(Self.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)

    try cache.writeTransactionCheck(makeResult(), for: firstTransfer)
    clock.advance(by: 90 * Self.day - 60)
    XCTAssertNotNil(try cache.readTransactionCheck(for: firstTransfer))

    clock.advance(by: 120)
    XCTAssertNil(try cache.readTransactionCheck(for: firstTransfer))
    XCTAssertEqual(try cache.count(), 0, "an expired record is deleted as it is found")
  }

  func testServerTtlOverrideDoesNotRetractARecord() throws {
    // `cacheTtlSeconds` is the backend's lever for un-trusting a verdict. Applied to a record it
    // would erase the evidence that a warning was shown — precisely what a partner needs when the
    // transfer is disputed.
    let clock = TestClock(Self.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()
    let retracted = makeResult(tier: .high, cacheTtlSeconds: 0)

    try cache.write(retracted, for: query)
    try cache.writeTransactionCheck(retracted, for: firstTransfer)

    XCTAssertNil(try cache.read(query), "a zero server TTL retracts the cached answer")
    let record = try XCTUnwrap(try cache.readTransactionCheck(for: firstTransfer))
    XCTAssertEqual(record.riskTier, .high)
  }

  func testZeroRetentionStoresNothingAndDropsWhatIsAlreadyThere() throws {
    let url = temporaryDirectory.appendingPathComponent("records.sqlite3", isDirectory: false)
    let keyStore = EphemeralCacheKeyStore()
    let clock = TestClock(Self.t0)

    let keeping = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
    try keeping.writeTransactionCheck(makeResult(), for: firstTransfer)
    XCTAssertEqual(try keeping.count(), 1)

    var policy = CachePolicy.default
    policy.transactionCheckRetention = 0
    let optedOut = try SQLiteCheckCache(
      path: url.path, policy: policy, keyStore: keyStore, now: clock.provider)
    try optedOut.writeTransactionCheck(makeResult(), for: firstTransfer)

    XCTAssertNil(try optedOut.readTransactionCheck(for: firstTransfer))
    XCTAssertEqual(
      try optedOut.count(), 0,
      "turning retention off must take the records already written with it")
  }

  // MARK: - One check, several transactions

  func testOneCheckServesSeveralTransactions() throws {
    // The everyday case: a user transfers to the same account twice. The second transfer is a cache
    // hit, so it is not billed again — and both transaction details still get their own card.
    let clock = TestClock(Self.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    try cache.write(makeResult(tier: .high), for: query)
    let shownFirst = try XCTUnwrap(try cache.read(query))
    try cache.writeTransactionCheck(shownFirst, for: firstTransfer)

    clock.advance(by: 7 * Self.day)

    let shownAgain = try XCTUnwrap(try cache.read(query), "a HIGH answer is still live after a week")
    try cache.writeTransactionCheck(shownAgain, for: secondTransfer)

    let first = try XCTUnwrap(try cache.readTransactionCheck(for: firstTransfer))
    let second = try XCTUnwrap(try cache.readTransactionCheck(for: secondTransfer))
    XCTAssertEqual(first.riskTier, .high)
    XCTAssertEqual(second.riskTier, .high)
    XCTAssertEqual(first.fetchedAt, second.fetchedAt, "both cards report the one check they shared")
    XCTAssertEqual(
      second.origin, .cache,
      "the second transfer spent no credit, and its record has to say so")
  }

  func testALaterCheckOfTheSameAccountLeavesAnEarlierTransactionAlone() throws {
    // The reason a record is a snapshot rather than a pointer into the cache. The account is clean
    // in September and reported by October; a pointer would rewrite September's card to say the user
    // was warned — an audit trail that blames them for a warning they were never shown.
    let clock = TestClock(Self.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    let clean = makeResult(tier: .none, fetchedAt: clock.now)
    try cache.write(clean, for: query)
    try cache.writeTransactionCheck(clean, for: firstTransfer)

    clock.advance(by: 30 * Self.day)

    let reported = makeResult(tier: .high, fetchedAt: clock.now)
    try cache.write(reported, for: query)
    try cache.writeTransactionCheck(reported, for: secondTransfer)

    let first = try XCTUnwrap(try cache.readTransactionCheck(for: firstTransfer))
    XCTAssertEqual(first.riskTier, RiskTier.none, "September's card must still say what it said")
    XCTAssertEqual(first.fetchedAt, Self.t0)

    let second = try XCTUnwrap(try cache.readTransactionCheck(for: secondTransfer))
    XCTAssertEqual(second.riskTier, .high)
  }

  // MARK: - What lands on disk

  func testTheTransactionIdIsNeverWrittenInCleartext() throws {
    let url = temporaryDirectory.appendingPathComponent("records.sqlite3", isDirectory: false)
    let cache = try SQLiteCheckCache(
      path: url.path, keyStore: EphemeralCacheKeyStore(), now: TestClock(Self.t0).provider)

    try cache.writeTransactionCheck(makeResult(), for: firstTransfer)

    // Every file the store produced, `-wal` and `-shm` included: a freshly committed row lives in
    // the write-ahead log before any checkpoint, so scanning the main file alone could pass while
    // the reference sat in cleartext beside it.
    let needle = Data(firstTransfer.utf8)
    let files = try FileManager.default.contentsOfDirectory(
      at: temporaryDirectory, includingPropertiesForKeys: nil)
    XCTAssertFalse(files.isEmpty)
    for file in files {
      let bytes = try Data(contentsOf: file)
      XCTAssertNil(
        bytes.range(of: needle),
        "the transaction reference appeared in cleartext in \(file.lastPathComponent)")
    }
  }

  func testTheRowKeyIsThePrefixedDigestOfTheTrimmedId() {
    let key = TransactionRecordKey(transactionId: " \(firstTransfer) ")
    let expected = SHA256.hash(data: Data(firstTransfer.utf8))
      .map { String(format: "%02x", $0) }
      .joined()

    XCTAssertEqual(key?.hex, expected)
    XCTAssertEqual(key?.rowKey, "txn:" + expected)
    // `:` is not a hex digit, which is what keeps the two key spaces in one table disjoint.
    XCTAssertNil(CheckCacheKey(hex: key!.rowKey))
    XCTAssertFalse(key!.description.contains(expected))
  }

  func testNarrativeContentIsDroppedButTheCallsOwnFieldsSurvive() throws {
    // The projection differs from the cache's on purpose. `checkId` and `billing` describe the one
    // call this record *is*, so they are what a dispute is reconciled against; the report narratives
    // are other people's prose and have no place in a record that lives 90 days.
    let cache = try SQLiteCheckCache.inMemory(now: TestClock(Self.t0).provider)

    try cache.writeTransactionCheck(makeResult(), for: firstTransfer)
    let record = try XCTUnwrap(try cache.readTransactionCheck(for: firstTransfer))

    XCTAssertNil(record.topChronologies, "report narratives must not be archived on the device")
    XCTAssertNil(record.comments, "nor the comments")
    XCTAssertEqual(record.checkId, "chk_123", "the check id is what a dispute is reconciled by")
    XCTAssertEqual(record.billing?.unitsCharged, 1)
    XCTAssertEqual(record.origin, .server, "a live check stays a live check on the record")
  }

  func testARecordCannotBeOpenedAsACacheEntry() throws {
    // Both kinds of row share one table, so the AEAD label is what stops a 90-day-old record being
    // served as a live answer to a check by anyone with write access to the file.
    let cipher = CachePayloadCipher(
      keyStore: EphemeralCacheKeyStore(), schemaVersion: SQLiteCheckCache.schemaVersion)
    let recordKey = try XCTUnwrap(TransactionRecordKey(transactionId: firstTransfer))
    let entryKey = try XCTUnwrap(CheckCacheKey(hex: recordKey.hex))

    let sealed = try cipher.sealRecord(makeResult(), for: recordKey)

    XCTAssertNoThrow(try cipher.openRecord(sealed, for: recordKey))
    XCTAssertThrowsError(try cipher.open(sealed, for: entryKey)) { error in
      guard case CheckCacheError.payloadUnreadable = error else {
        return XCTFail("expected payloadUnreadable, got \(error)")
      }
    }
  }

  // MARK: - Lifecycle

  func testRemovingOneSideLeavesTheOther() throws {
    let cache = try SQLiteCheckCache.inMemory(now: TestClock(Self.t0).provider)
    let query = try makeQuery()
    let shown = makeResult()

    try cache.write(shown, for: query)
    try cache.writeTransactionCheck(shown, for: firstTransfer)
    try cache.writeTransactionCheck(shown, for: secondTransfer)

    // Forcing a fresh check must not wipe the history that references the same account.
    try cache.remove(query)
    XCTAssertNil(try cache.read(query))
    XCTAssertNotNil(try cache.readTransactionCheck(for: firstTransfer))

    try cache.removeTransactionCheck(for: firstTransfer)
    XCTAssertNil(try cache.readTransactionCheck(for: firstTransfer))
    XCTAssertNotNil(
      try cache.readTransactionCheck(for: secondTransfer),
      "records are independent; dropping one must not touch another")
  }

  func testSignOutTakesTheRecordsWithIt() throws {
    let cache = try SQLiteCheckCache.inMemory(now: TestClock(Self.t0).provider)

    try cache.write(makeResult(), for: try makeQuery())
    try cache.writeTransactionCheck(makeResult(), for: firstTransfer)
    try cache.clear()

    XCTAssertNil(try cache.readTransactionCheck(for: firstTransfer), "clear() is what sign-out calls")
    XCTAssertEqual(try cache.count(), 0)
  }

  func testRecordsAreEvictedLastWhenTheEntryCapIsReached() throws {
    // Eviction takes the rows closest to expiring, and a record outlives every tier by default. The
    // ordering is the right way round: an evicted answer costs one credit to fetch again, an evicted
    // record cannot be recovered at all.
    var policy = CachePolicy.default
    policy.maxEntries = 2
    let clock = TestClock(Self.t0)
    let cache = try SQLiteCheckCache.inMemory(policy: policy, now: clock.provider)

    try cache.write(makeResult(tier: .none), for: try makeQuery())
    try cache.write(makeResult(tier: .none), for: try TraciveQuery.phone(e164: "+6287777777777"))
    try cache.writeTransactionCheck(makeResult(tier: .none), for: firstTransfer)

    XCTAssertEqual(try cache.count(), 2, "the write enforces the cap")
    XCTAssertNotNil(
      try cache.readTransactionCheck(for: firstTransfer), "the record must be the survivor")
  }

  // MARK: - The id as a key

  func testABlankTransactionIdIsRejectedRatherThanSharedByEveryTransaction() throws {
    let cache = try SQLiteCheckCache.inMemory(now: TestClock(Self.t0).provider)

    XCTAssertThrowsError(try cache.writeTransactionCheck(makeResult(), for: "  ")) { error in
      Self.assertIsInvalidTransactionId(error)
    }
    XCTAssertThrowsError(try cache.readTransactionCheck(for: "")) { error in
      Self.assertIsInvalidTransactionId(error)
    }
    XCTAssertThrowsError(try cache.removeTransactionCheck(for: "\t")) { error in
      Self.assertIsInvalidTransactionId(error)
    }
  }

  func testSurroundingWhitespaceIsFoldedAwayButNothingElseIs() throws {
    let cache = try SQLiteCheckCache.inMemory(now: TestClock(Self.t0).provider)

    try cache.writeTransactionCheck(makeResult(), for: " \(firstTransfer) ")

    XCTAssertNotNil(
      try cache.readTransactionCheck(for: firstTransfer), "a trimmed id finds its record")
    XCTAssertNil(
      try cache.readTransactionCheck(for: firstTransfer.lowercased()),
      "case is not folded: a host's reference format is not one this SDK can guess at")
  }

  /// `CheckCacheError` cannot be `Equatable` — one case carries `any Error` — so the assertion is a
  /// pattern match rather than a comparison.
  private static func assertIsInvalidTransactionId(
    _ error: any Error, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case CheckCacheError.invalidTransactionId = error else {
      return XCTFail("expected invalidTransactionId, got \(error)", file: file, line: line)
    }
  }

  func testADisabledCacheKeepsNoRecordsButStillRejectsABlankId() throws {
    // Worth pinning because it is the trap: a host that never wires a cache gets a working check
    // path and a transaction-detail card that is always empty, with nothing to say why.
    let cache = NoOpCheckCache()

    try cache.writeTransactionCheck(makeResult(), for: firstTransfer)
    XCTAssertNil(try cache.readTransactionCheck(for: firstTransfer))
    XCTAssertThrowsError(try cache.readTransactionCheck(for: " ")) { error in
      Self.assertIsInvalidTransactionId(error)
    }
  }
}
