import CryptoKit
import Security
import Foundation
import XCTest

@testable import TraciveSDK

/// Exercises the local encrypted result cache.
///
/// Nothing here touches the network — the Tracive Open API does not exist yet — and nothing here
/// touches the real Keychain. Every store is built with `EphemeralCacheKeyStore`, because a
/// `swift test` binary is unsigned: reaching the Keychain from one either fails with
/// `errSecMissingEntitlement` or prompts a human, and a test that can prompt is a test that hangs CI.
///
/// Time is injected. There is no `sleep` in this file, so the 30-day TTL is asserted as precisely as
/// the 1-hour one.
final class CacheTests: XCTestCase {

  // MARK: - Fixtures

  /// Whole seconds, because `CheckResult` round-trips instants through ISO-8601 at second
  /// precision. A fractional `fetchedAt` would come back rounded and every boundary assertion below
  /// would be off by a fraction — a flake that looks like a TTL bug.
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("TraciveCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    temporaryDirectory = nil
    try super.tearDownWithError()
  }

  private func storeURL(_ name: String = "cache.sqlite3") -> URL {
    temporaryDirectory.appendingPathComponent(name, isDirectory: false)
  }

  private func makeResult(
    tier: RiskTier = .high,
    fetchedAt: Date = CacheTests.t0,
    cacheTtlSeconds: Int64? = nil,
    checkId: String? = "chk_123",
    found: Bool = true,
    reportTotal: Int = 7,
    topChronologies: [Chronology]? = nil,
    comments: [Comment]? = nil,
    billing: Billing? = nil,
    disclaimer: String? = "Tracive reports are user-submitted."
  ) -> CheckResult {
    CheckResult(
      checkId: checkId,
      found: found,
      riskTier: tier,
      reportTotal: reportTotal,
      credibleReports: 5,
      ambiguousReports: 2,
      firstReportOn: Date(timeIntervalSince1970: 1_700_000_000),
      lastReportOn: Date(timeIntervalSince1970: 1_790_000_000),
      fraudAmount: ["IDR": 12_500_000],
      tags: ["investment", "telegram"],
      relatedScammerCount: 3,
      topChronologies: topChronologies,
      comments: comments,
      billing: billing,
      cacheTtlSeconds: cacheTtlSeconds,
      disclaimer: disclaimer,
      origin: .server,
      fetchedAt: fetchedAt
    )
  }

  private func makeQuery(_ e164: String = "+6281234567891") throws -> TraciveQuery {
    try TraciveQuery.phone(e164: e164)
  }

  // MARK: - Key derivation (SHA-256 of the folded query)

  func testCacheKeyIsSha256OfTheFoldedQuery() throws {
    let query = try makeQuery()
    XCTAssertEqual(query.searchQueryIndex, "PHONE_+6281234567891")

    // Derived independently of the SUT: if `CheckCacheKey` ever changed algorithm or encoding, this
    // is what catches it. A drifted key silently empties the cache and every check gets billed again.
    let expected = SHA256.hash(data: Data(query.searchQueryIndex.utf8))
      .map { String(format: "%02x", $0) }
      .joined()

    let key = CheckCacheKey(query: query)
    XCTAssertEqual(key.hex, expected)
    XCTAssertEqual(key.hex.count, 64)
    XCTAssertEqual(key, CheckCacheKey(searchQueryIndex: "PHONE_+6281234567891"))
    XCTAssertNotEqual(key, CheckCacheKey(searchQueryIndex: "PHONE_+6281234567892"))
  }

  func testCacheKeyNeverPrintsTheDigest() throws {
    let key = CheckCacheKey(query: try makeQuery())
    XCTAssertFalse(key.description.contains(key.hex))
    XCTAssertFalse(String(reflecting: key).contains(key.hex))
    // A SHA-256 of an E.164 number is brute-forceable, so even a prefix in a log would confirm a
    // guess. `hex` stays available for callers who ask for it explicitly.
    XCTAssertFalse(key.description.contains(key.hex.prefix(8)))
  }

  func testCacheKeyFromHexRejectsAnythingThatIsNotADigest() {
    XCTAssertNotNil(CheckCacheKey(hex: String(repeating: "a", count: 64)))
    XCTAssertNotNil(CheckCacheKey(hex: String(repeating: "A", count: 64)))  // normalised to lower
    XCTAssertEqual(CheckCacheKey(hex: String(repeating: "A", count: 64))?.hex,
                   String(repeating: "a", count: 64))
    XCTAssertNil(CheckCacheKey(hex: String(repeating: "a", count: 63)))
    XCTAssertNil(CheckCacheKey(hex: String(repeating: "z", count: 64)))
    XCTAssertNil(CheckCacheKey(hex: ""))
  }

  // MARK: - Round trip

  func testWriteThenReadReturnsTheResultStampedAsCache() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    XCTAssertNil(try cache.read(query), "a cold cache must miss")

    try cache.write(makeResult(), for: query)
    let hit = try XCTUnwrap(try cache.read(query))

    XCTAssertEqual(hit.origin, .cache, "a cache hit must declare itself as one")
    XCTAssertEqual(hit.found, true)
    XCTAssertEqual(hit.riskTier, .high)
    XCTAssertEqual(hit.reportTotal, 7)
    XCTAssertEqual(hit.credibleReports, 5)
    XCTAssertEqual(hit.ambiguousReports, 2)
    XCTAssertEqual(hit.fraudAmount, ["IDR": 12_500_000])
    XCTAssertEqual(hit.tags, ["investment", "telegram"])
    XCTAssertEqual(hit.relatedScammerCount, 3)
    XCTAssertEqual(hit.disclaimer, "Tracive reports are user-submitted.")
    XCTAssertEqual(hit.firstReportOn, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(hit.lastReportOn, Date(timeIntervalSince1970: 1_790_000_000))

    // `fetchedAt` is the age of the *data*, not of the answer: it must survive the round trip
    // unchanged, or every TTL below is measured from the wrong instant.
    XCTAssertEqual(hit.fetchedAt, CacheTests.t0)
  }

  func testMissIsNilRatherThanAnError() throws {
    let cache = try SQLiteCheckCache.inMemory(now: TestClock(CacheTests.t0).provider)
    // `Source.cache` must surface `TraciveError.cacheMiss` — but that is the *client's*
    // decision, since only it knows the requested source. The store reports a plain absence.
    XCTAssertNil(try cache.read(try makeQuery()))
    XCTAssertEqual(try cache.count(), 0)
  }

  // MARK: - TTL per tier

  func testDefaultTtlPerTier() throws {
    let day: TimeInterval = 24 * 60 * 60
    let cases: [(RiskTier, TimeInterval)] = [
      (.high, 30 * day),
      (.elevated, 7 * day),
      (.caution, day),
      (.none, 60 * 60),
    ]

    for (tier, ttl) in cases {
      let clock = TestClock(CacheTests.t0)
      let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
      let query = try makeQuery()
      try cache.write(makeResult(tier: tier), for: query)

      clock.now = CacheTests.t0.addingTimeInterval(ttl - 1)
      XCTAssertNotNil(
        try cache.read(query),
        "\(tier) must still be fresh one second before its \(Int(ttl))s TTL elapses"
      )

      // Exactly at the TTL is already stale: `CachePolicy.isFresh` is a strict `<`.
      clock.now = CacheTests.t0.addingTimeInterval(ttl)
      XCTAssertNil(try cache.read(query), "\(tier) must be stale at exactly its TTL")
    }
  }

  /// A tier's TTL must not leak into another tier's. Written as a cross-check because the four
  /// values live in one struct and a copy-paste there would otherwise pass every single-tier test.
  func testTiersDoNotShareATtl() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)

    let high = try makeQuery("+6281111111111")
    let none = try makeQuery("+6282222222222")
    try cache.write(makeResult(tier: .high), for: high)
    try cache.write(makeResult(tier: .none), for: none)

    // Two hours: past NONE's 1 h, far inside HIGH's 30 d.
    clock.now = CacheTests.t0.addingTimeInterval(2 * 60 * 60)
    XCTAssertNotNil(try cache.read(high), "HIGH must survive two hours")
    XCTAssertNil(try cache.read(none), "NONE must expire after one hour")
  }

  func testExpiredEntryIsDeletedOnRead() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()
    let key = CheckCacheKey(query: query)

    try cache.write(makeResult(tier: .none), for: query)
    XCTAssertTrue(try cache.containsRow(for: key))

    clock.now = CacheTests.t0.addingTimeInterval(3600)
    XCTAssertNil(try cache.read(query))
    XCTAssertFalse(
      try cache.containsRow(for: key),
      "a stale row must be dropped on read, not merely hidden — otherwise the file grows forever"
    )
  }

  // MARK: - Server-driven TTL override (the fleet-wide invalidation lever)

  func testServerTtlOverridesTheTierDefault() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    // HIGH would normally be held for 30 days. The server says 60 seconds; that must win, because it
    // is how Tracive invalidates a bad verdict across every installed app without shipping a release.
    try cache.write(makeResult(tier: .high, cacheTtlSeconds: 60), for: query)

    clock.now = CacheTests.t0.addingTimeInterval(59)
    XCTAssertNotNil(try cache.read(query))

    clock.now = CacheTests.t0.addingTimeInterval(61)
    XCTAssertNil(try cache.read(query), "cacheTtlSeconds must override the 30-day HIGH default")
  }

  /// The override can also *extend* a TTL — a NONE verdict the server is confident about.
  func testServerTtlCanExtendAsWellAsShorten() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    try cache.write(makeResult(tier: .none, cacheTtlSeconds: 7 * 24 * 60 * 60), for: query)

    clock.now = CacheTests.t0.addingTimeInterval(3 * 24 * 60 * 60)
    XCTAssertNotNil(try cache.read(query), "NONE's 1-hour default must yield to a longer server TTL")
  }

  /// `cacheTtlSeconds = 0` means "do not reuse this". It must not read as "no override".
  func testZeroServerTtlMakesTheEntryImmediatelyStale() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    try cache.write(makeResult(tier: .high, cacheTtlSeconds: 0), for: query)
    XCTAssertNil(try cache.read(query), "a zero TTL must not fall back to the 30-day tier default")
  }

  func testServerTtlIsIgnoredWhenTheOverrideIsTurnedOff() throws {
    let clock = TestClock(CacheTests.t0)
    let policy = CachePolicy(honorsServerTtlOverride: false)
    let cache = try SQLiteCheckCache.inMemory(policy: policy, now: clock.provider)
    let query = try makeQuery()

    try cache.write(makeResult(tier: .high, cacheTtlSeconds: 60), for: query)

    clock.now = CacheTests.t0.addingTimeInterval(120)
    XCTAssertNotNil(
      try cache.read(query),
      "with the override disabled the 30-day tier default applies instead"
    )
  }

  /// Freshness is decided on read from the *current* policy, not from whatever was in force when the
  /// row was written. That is what lets a host app tighten its policy and have it take effect on
  /// rows that are already stored.
  func testFreshnessFollowsTheCurrentPolicyNotTheWriteTimePolicy() throws {
    let clock = TestClock(CacheTests.t0)
    let url = storeURL()
    let keyStore = EphemeralCacheKeyStore()
    let query = try makeQuery()

    let generous = try SQLiteCheckCache(
      path: url.path, policy: .default, keyStore: keyStore, now: clock.provider)
    try generous.write(makeResult(tier: .high), for: query)

    clock.now = CacheTests.t0.addingTimeInterval(2 * 60 * 60)
    let strict = try SQLiteCheckCache(
      path: url.path,
      policy: CachePolicy(highTtl: 60 * 60),
      keyStore: keyStore,
      now: clock.provider
    )
    XCTAssertNil(try strict.read(query), "the tightened one-hour policy must apply to the old row")
  }

  // MARK: - Full detail is never cached

  func testFullDetailFieldsAreNeverStored() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    let full = makeResult(
      topChronologies: [
        Chronology(chronology: "Paid 5jt for an investment that never returned.", riskLevel: 4,
                   incidentDate: "2026-05-02")
      ],
      comments: [Comment(date: "2026-05-03", text: "Same modus operandi.", fromCredibleReport: true)],
      billing: Billing(creditSource: .user, unitsCharged: 1, partnerBalanceRemaining: 998)
    )
    XCTAssertNotNil(full.topChronologies)

    try cache.write(full, for: query)
    let hit = try XCTUnwrap(try cache.read(query))

    // The cache key is the query alone. If full-detail content were stored, this row would later be
    // served to a `detail = .minimal` request — and worse, a `locale = "id"` row would be served to
    // an `en` caller. Caching only the detail/locale-invariant fields is what keeps one key correct.
    XCTAssertNil(hit.topChronologies, "topChronologies must never be cached")
    XCTAssertNil(hit.comments, "comments must never be cached")
    XCTAssertNil(hit.billing, "billing describes one charge and must never be replayed")
    XCTAssertNil(hit.checkId, "checkId identifies one server-side check; a cache hit is not one")

    // The invariant fields still made it.
    XCTAssertEqual(hit.riskTier, .high)
    XCTAssertEqual(hit.reportTotal, 7)
  }

  /// The exclusion must hold in the *bytes*, not just in the decoded object: a store that persisted
  /// the full payload and stripped it on read would pass the test above and still leave comment text
  /// on the user's disk.
  func testFullDetailTextIsAbsentFromTheStoredPayload() throws {
    let clock = TestClock(CacheTests.t0)
    let keyStore = EphemeralCacheKeyStore()
    let cipher = CachePayloadCipher(
      keyStore: keyStore, schemaVersion: SQLiteCheckCache.schemaVersion)
    let key = CheckCacheKey(query: try makeQuery())

    let secret = "Paid 5jt for an investment that never returned."
    let sealed = try cipher.seal(
      makeResult(
        topChronologies: [Chronology(chronology: secret, riskLevel: 4, incidentDate: "2026-05-02")]
      ),
      for: key
    )

    // Decrypt with the same key and look at the actual plaintext the store would hold.
    let plaintext = try JSONEncoder().encode(try cipher.open(sealed, for: key))
    let json = String(decoding: plaintext, as: UTF8.self)
    XCTAssertFalse(json.contains(secret))
    XCTAssertFalse(json.contains("chk_123"))
    XCTAssertTrue(json.contains("HIGH"), "the invariant verdict must still be there")
    _ = clock
  }

  // MARK: - Privacy: nothing identifying reaches the disk

  func testTheDatabaseFileContainsNeitherTheIdentifierNorTheVerdict() throws {
    let clock = TestClock(CacheTests.t0)
    let url = storeURL()
    let query = try makeQuery("+6281234567891")

    do {
      let cache = try SQLiteCheckCache(
        path: url.path, keyStore: EphemeralCacheKeyStore(), now: clock.provider)
      try cache.write(makeResult(disclaimer: "Tracive reports are user-submitted."), for: query)
      XCTAssertNotNil(try cache.read(query))
      // Force a WAL checkpoint by releasing the connection, so the assertion below sees the data.
    }

    var bytes = try Data(contentsOf: url)
    for sidecar in ["-wal", "-shm"] {
      let path = url.path + sidecar
      if let extra = try? Data(contentsOf: URL(fileURLWithPath: path)) { bytes.append(extra) }
    }
    let haystack = String(decoding: bytes, as: UTF8.self)

    // The identifier itself, in every form it could plausibly have been written in.
    XCTAssertFalse(haystack.contains("+6281234567891"), "the raw phone number reached the disk")
    XCTAssertFalse(haystack.contains("6281234567891"), "the phone number reached the disk unprefixed")
    XCTAssertFalse(haystack.contains("PHONE_"), "the folded lookup key reached the disk")
    // And the verdict, which the AES-GCM payload is there to protect.
    XCTAssertFalse(haystack.contains("Tracive reports are user-submitted."))
    XCTAssertFalse(haystack.contains("investment"))
    XCTAssertFalse(haystack.contains("chk_123"))

    // Sanity: the digest *is* on disk, which is what proves the search above could have failed.
    XCTAssertTrue(
      haystack.contains(CheckCacheKey(query: query).hex),
      "the hashed key should be present — if it is not, this test is not reading the right file"
    )
  }

  // MARK: - Encryption

  func testPayloadIsBoundToItsRowAndCannotBeSwapped() throws {
    let keyStore = EphemeralCacheKeyStore()
    let cipher = CachePayloadCipher(
      keyStore: keyStore, schemaVersion: SQLiteCheckCache.schemaVersion)

    let cleanKey = CheckCacheKey(searchQueryIndex: "PHONE_+6280000000000")
    let scammerKey = CheckCacheKey(searchQueryIndex: "PHONE_+6289999999999")
    let cleanPayload = try cipher.seal(makeResult(tier: .none, found: false), for: cleanKey)

    // The attack: move the "clean" payload onto the scammer's row so the app reports them as safe.
    // The AAD binds the ciphertext to its key, so this must not authenticate.
    XCTAssertThrowsError(try cipher.open(cleanPayload, for: scammerKey), "row swap must fail") {
      assertPayloadUnreadable($0)
    }
    XCTAssertNoThrow(try cipher.open(cleanPayload, for: cleanKey))
  }

  func testEveryRecordGetsAFreshNonce() throws {
    let cipher = CachePayloadCipher(
      keyStore: EphemeralCacheKeyStore(), schemaVersion: SQLiteCheckCache.schemaVersion)
    let key = CheckCacheKey(query: try makeQuery())
    let result = makeResult()

    // Sealing identical plaintext under the same key twice must produce different bytes. A repeated
    // nonce in GCM is the one mistake that loses both confidentiality and integrity at once.
    let first = try cipher.seal(result, for: key)
    let second = try cipher.seal(result, for: key)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first.prefix(12).count, 12)
    XCTAssertNotEqual(first.prefix(12), second.prefix(12), "the 96-bit nonce must be per-record")
  }

  func testATamperedPayloadIsRejectedRatherThanDecoded() throws {
    let cipher = CachePayloadCipher(
      keyStore: EphemeralCacheKeyStore(), schemaVersion: SQLiteCheckCache.schemaVersion)
    let key = CheckCacheKey(query: try makeQuery())
    var sealed = try cipher.seal(makeResult(), for: key)

    sealed[sealed.count - 1] ^= 0x01  // flip one bit of the tag
    XCTAssertThrowsError(try cipher.open(sealed, for: key)) { assertPayloadUnreadable($0) }
  }

  /// A rotated or destroyed data key must degrade to a cold cache, not to a throwing SDK.
  func testARotatedDataKeyTurnsRowsIntoMissesAndDropsThem() throws {
    let clock = TestClock(CacheTests.t0)
    let url = storeURL()
    let keyStore = EphemeralCacheKeyStore()
    let query = try makeQuery()
    let key = CheckCacheKey(query: query)

    let first = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
    try first.write(makeResult(), for: query)
    XCTAssertNotNil(try first.read(query))

    // Simulates an app reinstall, a Keychain reset, or a restore onto another device.
    try keyStore.destroyDataKey()

    XCTAssertNil(try first.read(query), "an undecryptable row must read as a miss, not throw")
    XCTAssertFalse(
      try first.containsRow(for: key),
      "an undecryptable row must be dropped; it can never become readable again"
    )
  }

  // MARK: - Schema version invalidation

  func testBumpingTheSchemaVersionInvalidatesEverything() throws {
    let clock = TestClock(CacheTests.t0)
    let url = storeURL()
    let keyStore = EphemeralCacheKeyStore()
    let query = try makeQuery()

    do {
      let cache = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
      try cache.write(makeResult(), for: query)
      XCTAssertEqual(try cache.count(), 1)
    }

    // Rewrite the stored version to something the current build does not recognise. This is exactly
    // what an app upgrade looks like from the store's point of view, with the roles reversed.
    do {
      let connection = try SQLiteConnection(path: url.path)
      let statement = try connection.prepare(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '0');")
      try statement.step()
    }

    let reopened = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
    XCTAssertEqual(try reopened.count(), 0, "a version mismatch must drop every row")
    XCTAssertNil(try reopened.read(query))

    // …and the store must be usable again immediately, at the new version.
    try reopened.write(makeResult(), for: query)
    XCTAssertNotNil(try reopened.read(query))
  }

  func testAnUnchangedSchemaVersionKeepsRowsAcrossReopen() throws {
    let clock = TestClock(CacheTests.t0)
    let url = storeURL()
    let keyStore = EphemeralCacheKeyStore()
    let query = try makeQuery()

    do {
      let cache = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
      try cache.write(makeResult(), for: query)
    }

    let reopened = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
    XCTAssertNotNil(
      try reopened.read(query),
      "persistence is the whole point — a cache that empties on relaunch bills every cold start"
    )
  }

  // MARK: - Prune, clear, eviction

  func testPruneDeletesOnlyExpiredRows() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)

    let shortLived = try makeQuery("+6281111111111")
    let longLived = try makeQuery("+6282222222222")
    try cache.write(makeResult(tier: .none), for: shortLived)  // 1 h
    try cache.write(makeResult(tier: .high), for: longLived)  // 30 d
    XCTAssertEqual(try cache.count(), 2)

    clock.now = CacheTests.t0.addingTimeInterval(2 * 60 * 60)
    XCTAssertEqual(try cache.prune(), 1)
    XCTAssertEqual(try cache.count(), 1)
    XCTAssertNotNil(try cache.read(longLived))
  }

  func testPruneRunsOnOpen() throws {
    let clock = TestClock(CacheTests.t0)
    let url = storeURL()
    let keyStore = EphemeralCacheKeyStore()

    do {
      let cache = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
      try cache.write(makeResult(tier: .none), for: try makeQuery())
      XCTAssertEqual(try cache.count(), 1)
    }

    clock.now = CacheTests.t0.addingTimeInterval(2 * 60 * 60)
    let reopened = try SQLiteCheckCache(path: url.path, keyStore: keyStore, now: clock.provider)
    XCTAssertEqual(
      try reopened.count(), 0,
      "expired rows must be swept on open; lazy expiry alone never reclaims space for keys that are "
        + "never queried again"
    )
  }

  func testMaxEntriesEvictsTheRowsClosestToExpiring() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(
      policy: CachePolicy(maxEntries: 2), now: clock.provider)

    let none = try makeQuery("+6281111111111")  // 1 h
    let caution = try makeQuery("+6282222222222")  // 24 h
    let high = try makeQuery("+6283333333333")  // 30 d

    try cache.write(makeResult(tier: .none), for: none)
    try cache.write(makeResult(tier: .caution), for: caution)
    try cache.write(makeResult(tier: .high), for: high)

    XCTAssertEqual(try cache.count(), 2, "the cap must be enforced on write")
    XCTAssertNil(try cache.read(none), "the soonest-to-expire row is the one to drop")
    XCTAssertNotNil(try cache.read(caution))
    XCTAssertNotNil(try cache.read(high))
  }

  func testClearEmptiesTheStore() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    try cache.write(makeResult(), for: try makeQuery("+6281111111111"))
    try cache.write(makeResult(), for: try makeQuery("+6282222222222"))
    XCTAssertEqual(try cache.count(), 2)

    try cache.clear()

    XCTAssertEqual(try cache.count(), 0)
    XCTAssertNil(try cache.read(try makeQuery("+6281111111111")))
    // Still usable afterwards — `clear` empties, it does not close.
    try cache.write(makeResult(), for: try makeQuery("+6281111111111"))
    XCTAssertEqual(try cache.count(), 1)
  }

  func testRemoveDeletesOneEntryAndToleratesAnAbsentKey() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let kept = try makeQuery("+6281111111111")
    let dropped = try makeQuery("+6282222222222")

    try cache.write(makeResult(), for: kept)
    try cache.write(makeResult(), for: dropped)
    try cache.remove(dropped)

    XCTAssertNil(try cache.read(dropped))
    XCTAssertNotNil(try cache.read(kept))
    XCTAssertNoThrow(try cache.remove(try makeQuery("+6283333333333")))
  }

  func testWriteReplacesRatherThanDuplicating() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let query = try makeQuery()

    try cache.write(makeResult(tier: .caution, reportTotal: 1), for: query)
    try cache.write(
      makeResult(tier: .high, fetchedAt: CacheTests.t0.addingTimeInterval(10), reportTotal: 9),
      for: query
    )

    XCTAssertEqual(try cache.count(), 1)
    let hit = try XCTUnwrap(try cache.read(query))
    XCTAssertEqual(hit.riskTier, .high)
    XCTAssertEqual(hit.reportTotal, 9)
    XCTAssertEqual(hit.fetchedAt, CacheTests.t0.addingTimeInterval(10))
  }

  // MARK: - Disabled policy

  func testADisabledPolicyStoresNothingAndServesNothing() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(policy: .disabled, now: clock.provider)
    let query = try makeQuery()

    try cache.write(makeResult(), for: query)

    XCTAssertEqual(try cache.count(), 0, "a disabled cache must not quietly accumulate rows")
    XCTAssertNil(try cache.read(query))
  }

  func testNoOpCacheSatisfiesTheProtocolWithoutStoring() throws {
    let cache = NoOpCheckCache()
    let query = try makeQuery()

    XCTAssertFalse(cache.policy.isEnabled)
    XCTAssertNoThrow(try cache.write(makeResult(), for: query))
    XCTAssertNil(try cache.read(query))
    XCTAssertEqual(try cache.count(), 0)
    XCTAssertEqual(try cache.prune(), 0)
    XCTAssertNoThrow(try cache.clear())
  }

  // MARK: - Failure tolerance

  func testReadAndWriteIgnoringFailuresNeverThrow() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let key = CheckCacheKey(query: try makeQuery())

    XCTAssertNil(cache.readIgnoringFailures(key))
    cache.writeIgnoringFailures(makeResult(), for: key)
    XCTAssertNotNil(cache.readIgnoringFailures(key))
  }

  // MARK: - Concurrency

  func testConcurrentReadsAndWritesAreSerialisedSafely() throws {
    let clock = TestClock(CacheTests.t0)
    let cache = try SQLiteCheckCache.inMemory(now: clock.provider)
    let queries = try (0..<32).map { try makeQuery(String(format: "+628%010d", $0)) }

    // One shared SQLite handle plus one lock. If the locking is wrong this either corrupts the file
    // or trips SQLITE_MISUSE; either way it fails loudly here rather than intermittently in a host
    // app.
    DispatchQueue.concurrentPerform(iterations: queries.count) { index in
      let query = queries[index]
      try? cache.write(makeResult(reportTotal: index), for: query)
      _ = try? cache.read(query)
      _ = try? cache.count()
    }

    XCTAssertEqual(try cache.count(), queries.count)
    for (index, query) in queries.enumerated() {
      XCTAssertEqual(try cache.read(query)?.reportTotal, index)
    }
  }

  // MARK: - Errors

  func testCacheErrorsLiftIntoTheSdkErrorFamilyWithoutClaimingToBeTransient() {
    let error = CheckCacheError.storageFailure(code: 11, message: "database disk image is malformed")
    let lifted = error.asTraciveError

    XCTAssertEqual(lifted.kind, .unknown)
    XCTAssertEqual(lifted.serverCode, "cache_storage_error")
    // A local disk problem must not tell a caller to retry a *network* call.
    XCTAssertFalse(lifted.isTransient)
  }

  func testOpeningAnUnwritableLocationFailsCleanly() {
    XCTAssertThrowsError(
      try SQLiteCheckCache(
        path: "/dev/null/definitely-not-a-directory/cache.sqlite3",
        keyStore: EphemeralCacheKeyStore()
      )
    ) { error in
      guard case .cannotOpenStore = error as? CheckCacheError else {
        return XCTFail("expected cannotOpenStore, got \(error)")
      }
    }
  }

  /// A key store that is *temporarily* unavailable must not cost the user their whole cache.
  ///
  /// The distinction this pins down: an undecryptable row is dropped (it can never be read again),
  /// but a Keychain that will not answer right now is a transient environment fault. Deleting the
  /// table in response would turn a locked device into a permanently cold cache — and every cold
  /// read is a billed check.
  func testAKeyStoreFaultPropagatesInsteadOfDeletingRows() throws {
    let clock = TestClock(CacheTests.t0)
    let keyStore = SwitchableCacheKeyStore()
    let cache = try SQLiteCheckCache.inMemory(keyStore: keyStore, now: clock.provider)
    let query = try makeQuery()
    let key = CheckCacheKey(query: query)

    try cache.write(makeResult(), for: query)
    keyStore.isAvailable = false

    XCTAssertThrowsError(try cache.read(query)) { error in
      guard case .dataKeyUnavailable = error as? CheckCacheError else {
        return XCTFail("expected dataKeyUnavailable, got \(error)")
      }
    }
    XCTAssertTrue(
      try cache.containsRow(for: key),
      "the row must survive a key-store outage — it is still perfectly readable once the key returns"
    )

    keyStore.isAvailable = true
    XCTAssertNotNil(try cache.read(query), "and it must be served again afterwards")
  }

  // MARK: - Data-key recovery
  //
  // These drive `KeychainCacheKeyStore` through an injected item store, so they exercise the real
  // recovery logic without touching the Keychain — which an unsigned `swift test` binary cannot do,
  // and which is why this type previously had no coverage at all.

  /// A stored key that can no longer produce a usable AES key must be replaced, not thrown on
  /// forever.
  ///
  /// The realistic trigger is a Secure Enclave blob whose key this device can no longer use — a
  /// restore onto another device, or the Enclave being reset. Nothing deleted the unusable item and
  /// nothing made a replacement, so `dataKey()` threw on every subsequent call for the lifetime of
  /// the install. On the `.cacheFirst` path `TraciveClient` reads through `readIgnoringFailures`,
  /// which swallows it, so the only visible symptom was that every check went to the server and was
  /// billed. Forever, silently.
  func testAnUnusableStoredKeyIsReplacedRatherThanThrownOnForever() throws {
    // A blob with an unrecognised marker: `deriveKey` cannot make a key from it, exactly as it
    // cannot from an Enclave blob belonging to another device.
    let items = FakeCacheKeyItemStore(stored: Data([0xEE, 0x01, 0x02, 0x03]))
    let store = KeychainCacheKeyStore(items: items, usesSecureEnclaveWhenAvailable: false)

    let key = try store.dataKey()

    XCTAssertEqual(key.bitCount, 256)
    XCTAssertEqual(items.deleteCount, 1, "the unusable item must be removed")
    XCTAssertEqual(items.addCount, 1, "a replacement must be written")
    XCTAssertNotNil(items.stored)
    XCTAssertNotEqual(items.stored, Data([0xEE, 0x01, 0x02, 0x03]))

    // And the replacement is now the stable key: a second call neither re-heals nor re-derives.
    let again = try KeychainCacheKeyStore(items: items, usesSecureEnclaveWhenAvailable: false)
      .dataKey()
    XCTAssertEqual(again, key, "the replacement key must be stable across store instances")
    XCTAssertEqual(items.deleteCount, 1, "recovery must not run again")
  }

  /// The transient case must keep propagating untouched. Deleting a perfectly good key because the
  /// device happened to be locked would destroy the user's cache for no reason, and this is the
  /// distinction the whole fix turns on.
  func testAKeychainOutageStillPropagatesAndDoesNotDestroyTheKey() throws {
    let items = FakeCacheKeyItemStore(stored: Data([0x01]) + Data(repeating: 0x07, count: 32))
    items.readError = CheckCacheError.dataKeyUnavailable(status: errSecInteractionNotAllowed)
    let store = KeychainCacheKeyStore(items: items, usesSecureEnclaveWhenAvailable: false)

    XCTAssertThrowsError(try store.dataKey()) { error in
      guard case .dataKeyUnavailable = error as? CheckCacheError else {
        return XCTFail("expected dataKeyUnavailable, got \(error)")
      }
    }
    XCTAssertEqual(items.deleteCount, 0, "a transient outage must not delete the stored key")
    XCTAssertEqual(items.addCount, 0)
  }

  /// Recovery makes exactly one attempt and does not loop.
  ///
  /// It cannot loop on the derive step by construction — `replaceUnusableKey` derives from the blob
  /// it just generated, not from a re-read — so the way to probe the bound is to fail the *write*.
  /// The error must then propagate rather than being retried, and the caller is left with the same
  /// cold-cache outcome it had before, not a spin.
  func testRecoveryMakesOneAttemptAndPropagatesAWriteFailure() throws {
    let items = FakeCacheKeyItemStore(stored: Data([0xEE]))
    items.addError = CheckCacheError.dataKeyUnavailable(status: errSecInteractionNotAllowed)
    let store = KeychainCacheKeyStore(items: items, usesSecureEnclaveWhenAvailable: false)

    XCTAssertThrowsError(try store.dataKey()) { error in
      guard case .dataKeyUnavailable = error as? CheckCacheError else {
        return XCTFail("expected dataKeyUnavailable, got \(error)")
      }
    }
    XCTAssertEqual(items.deleteCount, 1, "exactly one recovery attempt, not a loop")
    XCTAssertEqual(items.addCount, 1, "and exactly one write attempt")
  }

  /// The ordinary first-run path still works through the seam: no item, so one is created.
  func testAnEmptyStoreCreatesAndPersistsAKey() throws {
    let items = FakeCacheKeyItemStore(stored: nil)
    let store = KeychainCacheKeyStore(items: items, usesSecureEnclaveWhenAvailable: false)

    let key = try store.dataKey()

    XCTAssertEqual(key.bitCount, 256)
    XCTAssertEqual(items.addCount, 1)
    XCTAssertEqual(items.deleteCount, 0, "nothing was unusable, so nothing should be deleted")
  }

  /// `CheckCacheError` carries an `any Error` in one case, so it is not `Equatable`; match the case.
  private func assertPayloadUnreadable(
    _ error: any Error,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .payloadUnreadable = error as? CheckCacheError else {
      return XCTFail("expected payloadUnreadable, got \(error)", file: file, line: line)
    }
  }
}

// MARK: - Test doubles

/// A key store that can be made to fail on demand, standing in for a locked device or a Keychain
/// that briefly refuses to answer.
final class SwitchableCacheKeyStore: CacheKeyStore, @unchecked Sendable {

  private let lock = NSLock()
  private var key = SymmetricKey(size: .bits256)
  private var available = true

  var isAvailable: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return available
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      available = newValue
    }
  }

  func dataKey() throws -> SymmetricKey {
    lock.lock()
    defer { lock.unlock() }
    guard available else { throw CheckCacheError.dataKeyUnavailable(status: -25308) }
    return key
  }

  func destroyDataKey() throws {
    lock.lock()
    defer { lock.unlock() }
    key = SymmetricKey(size: .bits256)
  }
}

// MARK: - Test clock

/// A clock you move by hand.
///
/// The alternative — `sleep` — would make the 30-day HIGH TTL untestable and every other assertion
/// slow and flaky. `SQLiteCheckCache` takes its `now` as a closure precisely so this can exist.
final class TestClock: @unchecked Sendable {

  private let lock = NSLock()
  private var current: Date

  init(_ start: Date) {
    self.current = start
  }

  var now: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return current
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      current = newValue
    }
  }

  func advance(by interval: TimeInterval) {
    now = now.addingTimeInterval(interval)
  }

  /// Pass this straight into `SQLiteCheckCache(now:)`.
  var provider: @Sendable () -> Date {
    { [self] in self.now }
  }
}

/// An in-memory `CacheKeyItemStore`, so the data-key recovery path can be exercised without the
/// Keychain. Counts its operations, because "was the unusable item actually deleted?" is the whole
/// question — a recovery that silently left the old item behind would still return a usable key.
final class FakeCacheKeyItemStore: CacheKeyItemStore, @unchecked Sendable {

  private let lock = NSLock()
  private var blob: Data?
  private var deletes = 0
  private var adds = 0

  /// Thrown by `read()` instead of answering. Used for the transient-outage case.
  var readError: Error?
  /// Thrown by `add()` instead of storing. Used to bound the recovery attempt.
  var addError: Error?

  init(stored: Data?) {
    self.blob = stored
  }

  func read() throws -> Data? {
    if let readError { throw readError }
    lock.lock()
    defer { lock.unlock() }
    return blob
  }

  func add(_ blob: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    adds += 1
    if let addError { throw addError }
    self.blob = blob
  }

  func delete() throws {
    lock.lock()
    defer { lock.unlock() }
    deletes += 1
    blob = nil
  }

  var stored: Data? {
    lock.lock()
    defer { lock.unlock() }
    return blob
  }

  var deleteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return deletes
  }

  var addCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return adds
  }
}
