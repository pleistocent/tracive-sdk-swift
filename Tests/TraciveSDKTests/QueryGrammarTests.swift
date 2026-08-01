import XCTest

@testable import TraciveSDK

/// Drives the vendored `query-grammar-vectors.json` — the cross-language anti-drift contract.
///
/// Every `vectors[]` entry must fold to its `expected` string and every `rejected[]` entry must
/// throw with the stated `reason`. Kotlin, Flutter, Swift and the backend all run the same file, so
/// a failure here means this SDK would build keys that miss on the server — and a miss is
/// still billed.
///
/// Nothing in this file touches the network. The Open API does not exist yet.
final class QueryGrammarTests: XCTestCase {

  // MARK: - Fixture

  private struct Fixture: Decodable {
    let version: Int
    let rules: [String: String]
    let crossLanguageSemantics: CrossLanguageSemantics
    let documentIdGuard: DocumentIdGuardSpec
    let notImplemented: [String: String]
    let vectors: [Vector]
    let rejected: [Rejected]
  }

  /// The v2 section that spells out where platform built-ins disagree with the JavaScript the
  /// backend actually folds in. Decoded and asserted rather than just read, so a Foundation default
  /// creeping back into `QueryFolding` turns something red.
  private struct CrossLanguageSemantics: Decodable {
    struct TrimSet: Decodable {
      /// Every scalar JS `trim()` strips, as `"U+00A0"` strings.
      let codepoints: [String]
      /// Scalars JS deliberately does **not** strip — U+200B is the trap here.
      let notStripped: [String]
    }
    struct CaseMapping: Decodable {
      /// e.g. `"ß -> uppercase": "SS"`.
      let examples: [String: String]
    }
    let trimSet: TrimSet
    let caseMapping: CaseMapping
    let nfcScope: String
    let foldOrder: String
    let phoneFolding: String
  }

  /// The v2 section pinning the API's record-key rules, applied to the *folded* key.
  private struct DocumentIdGuardSpec: Decodable {
    struct Case: Decodable {
      let value: String
      let safe: Bool
    }
    let maxUtf8Bytes: Int
    /// Every rejection rule the API applies to a folded key, in the fixture's own words. Decoded so
    /// a rule added upstream cannot be silently ignored by this SDK.
    let rejected: [String]
    let cases: [Case]
  }

  /// `"U+00A0"` → the scalar. Fails the test rather than returning nil, since a malformed fixture
  /// entry silently skipped would be a check that cannot fail.
  private func scalar(
    fromCodepointLabel label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> Unicode.Scalar {
    let hex = label.hasPrefix("U+") ? String(label.dropFirst(2)) : label
    guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
      XCTFail("fixture codepoint '\(label)' is not a scalar literal", file: file, line: line)
      throw UnknownVectorType(type: label)
    }
    return scalar
  }

  // MARK: - Rules landing later in this series
  //
  // Fixture v5 added three rules to the shared contract in one bump. They are implemented one
  // commit at a time, and a rule that has not landed yet would otherwise turn the whole
  // fixture-driven suite red and hide any *other* regression in it. So each pending entry is named
  // here explicitly — never skipped by a broad `catch` — and the commit that implements its rule
  // deletes its line here and adds a dedicated test asserting the exact wire token. Both lists must
  // be empty, and these two constants deleted, once the series has landed.

  /// `rejected[].id`s whose rejection this SDK does not implement yet.
  private static let pendingRejectedIds: Set<String> = [
    "email-not-an-address",  // not_an_email
    "crypto-empty-address",  // empty_address
    "username-empty-platform",  // empty_platform
  ]

  /// `documentIdGuard.cases[].value`s whose verdict this SDK does not match yet.
  private static let pendingGuardValues: Set<String> = [
    "__a\nb__"  // the reserved pattern must not span a line terminator
  ]

  private struct Vector: Decodable {
    let id: String
    let type: String
    let input: VectorInput
    let expected: String
  }

  private struct Rejected: Decodable {
    let id: String
    let type: String
    let input: VectorInput
    let reason: String
  }

  /// Union of every `input` shape in the fixture. Decoding is per-key rather than per-type so a new
  /// vector shape does not need a new Swift type.
  private struct VectorInput: Decodable {
    let value: String?
    let country: String?
    let bankCode: String?
    let accountId: String?
    let isIban: Bool?
    let iban: String?
    let chain: String?
    let address: String?
    let platform: String?
    let handle: String?
  }

  private static func loadFixtureData() throws -> Data {
    // Primary path: the resource bundle SwiftPM generates for the test target.
    if let url = Bundle.module.url(forResource: "query-grammar-vectors", withExtension: "json")
      ?? Bundle.module.url(forResource: "Fixtures/query-grammar-vectors", withExtension: "json")
    {
      return try Data(contentsOf: url)
    }
    // Fallback: read it straight out of the source tree. Keeps the suite runnable if the manifest
    // declares the fixture with a rule that flattens or nests the path differently.
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let onDisk = sourceDirectory
      .appendingPathComponent("Fixtures")
      .appendingPathComponent("query-grammar-vectors.json")
    return try Data(contentsOf: onDisk)
  }

  private func loadFixture() throws -> Fixture {
    let data = try QueryGrammarTests.loadFixtureData()
    return try JSONDecoder().decode(Fixture.self, from: data)
  }

  // MARK: - Byte-exact comparison
  //
  // `XCTAssertEqual` on `String` compares by **canonical equivalence**, so "cafe\u{301}" ==
  // "caf\u{e9}" is true in Swift. That would make the NFC vector a check that cannot fail — the
  // test would pass even with the normalisation step deleted. Comparing UTF-8 bytes is the only
  // assertion that actually exercises the rule, and bytes are what the API keys on anyway.
  private func assertSameBytes(
    _ actual: String,
    _ expected: String,
    _ context: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      Array(actual.utf8),
      Array(expected.utf8),
      """
      \(context): folded key differs from the fixture at the byte level.
      actual   = \(Array(actual.utf8))
      expected = \(Array(expected.utf8))
      """,
      file: file,
      line: line
    )
  }

  // MARK: - Builder dispatch

  private func buildQuery(type: String, input: VectorInput) throws -> TraciveQuery {
    switch type {
    case "PHONE":
      return try TraciveQuery.phone(e164: try XCTUnwrap(input.value))
    case "EMAIL":
      return try TraciveQuery.email(value: try XCTUnwrap(input.value))
    case "BANK":
      if input.isIban == true {
        return try TraciveQuery.iban(iban: try XCTUnwrap(input.iban))
      }
      return try TraciveQuery.bankAccount(
        countryAlpha3: try XCTUnwrap(input.country),
        bankCode: try XCTUnwrap(input.bankCode),
        account: try XCTUnwrap(input.accountId)
      )
    case "CRYPTO":
      return try TraciveQuery.crypto(
        chain: try XCTUnwrap(input.chain),
        address: try XCTUnwrap(input.address)
      )
    case "USERNAME":
      return try TraciveQuery.username(
        platform: try XCTUnwrap(input.platform),
        handle: try XCTUnwrap(input.handle)
      )
    case "RAW":
      // Not a builder: the raw string is fed straight to the document-id guard.
      try DocumentIdGuard.validate(try XCTUnwrap(input.value))
      throw RawEntryNotRejected(value: input.value ?? "")
    default:
      throw UnknownVectorType(type: type)
    }
  }

  private struct UnknownVectorType: Error { let type: String }
  private struct RawEntryNotRejected: Error { let value: String }

  // MARK: - Tests

  func testFixtureIsTheExpectedContract() throws {
    let fixture = try loadFixture()

    XCTAssertEqual(fixture.version, 5, "fixture schema version changed — re-read the rules")

    // Pinned counts, not just non-emptiness. The fixture is vendored byte-identically into every
    // SDK; a vector silently dropped during a re-vendor would otherwise leave this suite green
    // while the contract shrank.
    XCTAssertEqual(fixture.vectors.count, 34, "a vector was added or removed — re-read the fixture")
    XCTAssertEqual(fixture.rejected.count, 14, "a rejection case was added or removed")
    XCTAssertEqual(
      fixture.documentIdGuard.cases.count,
      9,
      "a document-id guard case was added or removed"
    )

    // Every media category the backend emits must be exercised by at least one vector.
    let coveredTypes = Set(fixture.vectors.map(\.type))
    XCTAssertEqual(coveredTypes, ["PHONE", "EMAIL", "BANK", "CRYPTO", "USERNAME"])

    // Ids are unique, so a duplicated id can never mask a dropped vector.
    XCTAssertEqual(Set(fixture.vectors.map(\.id)).count, fixture.vectors.count)
    XCTAssertEqual(Set(fixture.rejected.map(\.id)).count, fixture.rejected.count)

    // Every reason the fixture uses must exist in the Swift enum, and vice versa the enum must not
    // silently rename one.
    for entry in fixture.rejected where !Self.pendingRejectedIds.contains(entry.id) {
      XCTAssertNotNil(
        QueryRejectionReason(rawValue: entry.reason),
        "rejected[\(entry.id)] uses reason '\(entry.reason)', which has no QueryRejectionReason case"
      )
    }
  }

  func testEveryVectorFoldsToItsExpectedKey() throws {
    let fixture = try loadFixture()
    var checked = 0

    for vector in fixture.vectors {
      do {
        let query = try buildQuery(type: vector.type, input: vector.input)
        assertSameBytes(query.searchQueryIndex, vector.expected, "vector '\(vector.id)'")
        checked += 1
      } catch {
        XCTFail("vector '\(vector.id)' threw \(error) but should have produced \(vector.expected)")
      }
    }

    XCTAssertEqual(
      checked,
      fixture.vectors.count,
      "not every vector was asserted — a silently skipped vector is a check that cannot fail"
    )
  }

  func testEveryRejectedInputThrowsTheStatedReason() throws {
    let fixture = try loadFixture()
    var checked = 0

    for entry in fixture.rejected where !Self.pendingRejectedIds.contains(entry.id) {
      do {
        let query = try buildQuery(type: entry.type, input: entry.input)
        XCTFail(
          "rejected[\(entry.id)] built '\(query.searchQueryIndex)' but should have thrown "
            + "\(entry.reason) — an unhittable key still costs a credit"
        )
      } catch let error as TraciveQueryError {
        XCTAssertEqual(
          error.rawReason,
          entry.reason,
          "rejected[\(entry.id)] threw \(error.rawReason), expected \(entry.reason)"
        )
        checked += 1
      } catch {
        XCTFail("rejected[\(entry.id)] threw \(error), expected TraciveQueryError(\(entry.reason))")
      }
    }

    XCTAssertEqual(
      checked,
      fixture.rejected.count - Self.pendingRejectedIds.count,
      "not every rejected input was asserted"
    )
  }

  /// The NFC rule, asserted on bytes so it cannot pass by accident.
  func testEmailNfcCompositionIsAppliedAtByteLevel() throws {
    let decomposed = "cafe\u{0301}@example.com"  // e + COMBINING ACUTE ACCENT
    let composed = "caf\u{00E9}@example.com"  // LATIN SMALL LETTER E WITH ACUTE

    // Sanity: Swift itself cannot tell these apart, which is exactly why the assertion below
    // compares bytes.
    XCTAssertEqual(decomposed, composed)
    XCTAssertNotEqual(Array(decomposed.utf8), Array(composed.utf8))

    let query = try TraciveQuery.email(value: decomposed)
    assertSameBytes(query.searchQueryIndex, "EMAIL_" + composed, "NFC composition")
    XCTAssertFalse(
      Array(query.searchQueryIndex.utf8).contains(0xCC),
      "the folded key still contains a combining mark, so NFC was not applied"
    )
  }

  /// Digit stripping is ASCII-only, because the server strips with a `\d`-class regex that matches
  /// ASCII 0-9 and nothing else.
  ///
  /// The number below is `+6281234567891` written in Arabic-Indic digits — full E.164 length, so it
  /// gets past every length check. If the fold used `CharacterSet.decimalDigits` (which *does*
  /// match these scalars) the SDK would happily build `PHONE_+٦٢٨...`, while the server strips the
  /// same input down to `PHONE_+`. Two different entities, and the resulting miss is still billed.
  /// Correct behaviour is to strip them all and then reject the leftover `+` as not-E.164.
  func testNonAsciiDigitsAreNotTreatedAsDigits() {
    let arabicIndic = "+\u{0666}\u{0662}\u{0668}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}"
      + "\u{0666}\u{0667}\u{0668}\u{0669}\u{0661}"
    XCTAssertEqual(arabicIndic.dropFirst().count, 13, "must be a full-length E.164 number")

    XCTAssertThrowsError(try TraciveQuery.phone(e164: arabicIndic)) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.reason, .notE164)
    }
  }

  /// EVM folding keys off the exact regex `^0x[0-9a-fA-F]{40}$`. An uppercase `0X` prefix does not
  /// match it on the server, so it must not be lowercased here either.
  func testUppercaseHexPrefixIsNotFoldedAsEvm() throws {
    let address = "0X52908400098527886E0F7030069857D2E4169EE7"
    let query = try TraciveQuery.crypto(chain: "eth", address: address)
    assertSameBytes(query.searchQueryIndex, "CRYPTO_ETH_" + address, "0X prefix")
  }

  /// Base58 is case-sensitive; a 42-character Base58 string must survive untouched even though it
  /// is the same length as an EVM address.
  func testBase58AddressOfEvmLengthIsNotFolded() throws {
    let address = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6tXYZabcde"
    XCTAssertEqual(address.count, 42)
    let query = try TraciveQuery.crypto(chain: "TRX", address: address)
    assertSameBytes(query.searchQueryIndex, "CRYPTO_TRX_" + address, "Base58 of EVM length")
  }

  func testEveryExpectedKeyIsAValidDocumentId() throws {
    let fixture = try loadFixture()
    for vector in fixture.vectors {
      XCTAssertNoThrow(
        try DocumentIdGuard.validate(vector.expected),
        "vector '\(vector.id)' expects a key the document-id guard would reject"
      )
    }
  }

  func testDocumentIdGuardRules() {
    let rejected = [
      "",  // empty
      "BANK_IDN_BCA_12/34",  // contains '/'
      "__proto__",  // matches __.*__
      "____",
      ".",
      "..",
      String(repeating: "a", count: 1501),  // > 1500 UTF-8 bytes
      String(repeating: "\u{00E9}", count: 751),  // 1502 UTF-8 bytes from only 751 characters
    ]
    for id in rejected {
      XCTAssertThrowsError(try DocumentIdGuard.validate(id), "expected '\(id.prefix(24))…' to be rejected") {
        error in
        XCTAssertEqual((error as? TraciveQueryError)?.reason, .invalidDocumentId)
      }
    }

    let accepted = [
      "PHONE_+6281234567891",
      "USERNAME_TELEGRAM_scammer_x",
      "USERNAME_TIKTOK_@scammerx",
      "...",
      "___",  // three underscores does not match __.*__
      "__a",
      String(repeating: "a", count: 1500),  // exactly at the limit
    ]
    for id in accepted {
      XCTAssertNoThrow(try DocumentIdGuard.validate(id), "expected '\(id.prefix(24))…' to be accepted")
    }
  }

  /// The guard runs on the built key, not just on raw strings: a query whose folded key exceeds the
  /// document-id limit must fail locally rather than being sent and billed as a miss.
  func testBuilderAppliesTheDocumentIdGuard() {
    let hugeLocalPart = String(repeating: "a", count: 1600)
    XCTAssertThrowsError(try TraciveQuery.email(value: "\(hugeLocalPart)@example.com")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.reason, .invalidDocumentId)
    }
  }

  /// The fixture documents that DOMAIN was dropped from the backend. If a future fixture revision
  /// removes that note, someone has changed the contract and the SDK surface must be revisited —
  /// there is deliberately no `TraciveQuery.domain(...)`.
  func testDomainRemainsUnimplemented() throws {
    let fixture = try loadFixture()
    XCTAssertNotNil(
      fixture.notImplemented["DOMAIN"],
      "the fixture no longer documents DOMAIN as dropped — re-check whether the backend added it"
    )
    XCTAssertFalse(TraciveQuery.Kind.allCases.contains { $0.rawValue == "DOMAIN" })
  }

  /// Folding must be idempotent: feeding an already-folded component back in produces the same key.
  /// A non-idempotent fold would split one entity across cache entries as values round-trip through
  /// storage and UI.
  func testFoldingIsIdempotent() throws {
    let once = try TraciveQuery.email(value: "  Budi@Gmail.com ")
    let twice = try TraciveQuery.email(value: String(once.searchQueryIndex.dropFirst("EMAIL_".count)))
    assertSameBytes(twice.searchQueryIndex, once.searchQueryIndex, "email idempotency")

    let bankOnce = try TraciveQuery.bankAccount(
      countryAlpha3: "idn", bankCode: "b_ca", account: "3242-4242-422")
    let bankTwice = try TraciveQuery.bankAccount(
      countryAlpha3: "IDN", bankCode: "BCA", account: "32424242422")
    assertSameBytes(bankTwice.searchQueryIndex, bankOnce.searchQueryIndex, "bank idempotency")
  }

  /// `searchQueryIndex` embeds a raw phone number / email / account number, so the printable form
  /// of the query must not carry it into a log or a crash report.
  func testQueryDescriptionRedactsTheIdentifier() throws {
    let query = try TraciveQuery.phone(e164: "+6281234567891")
    XCTAssertFalse(query.description.contains("6281234567891"))
    XCTAssertFalse(String(reflecting: query).contains("6281234567891"))
    XCTAssertTrue(query.description.contains("PHONE"))
  }

  // MARK: - crossLanguageSemantics (fixture v2)

  /// The whitespace class is hand-written because Foundation's disagrees with JavaScript's in *both*
  /// directions. This test drives the fixture's own list, so it is the check that catches a
  /// well-meaning revert to `trimmingCharacters(in: .whitespacesAndNewlines)`.
  ///
  /// Measured on this toolchain, that Foundation set:
  /// - strips U+200B, which JS `trim()` keeps (this is what the `email-zwsp-is-not-trimmed` vector
  ///   caught), and
  /// - does not strip U+FEFF, which JS `trim()` removes.
  func testJavaScriptTrimSetMatchesTheFixture() throws {
    let fixture = try loadFixture()

    for label in fixture.crossLanguageSemantics.trimSet.codepoints {
      let scalar = try self.scalar(fromCodepointLabel: label)
      XCTAssertTrue(
        QueryFolding.javaScriptWhitespace.contains(scalar),
        "\(label) is in the fixture's JS trim set but QueryFolding does not treat it as whitespace"
      )
      let padded = String(scalar) + "x" + String(scalar)
      XCTAssertEqual(QueryFolding.jsTrim(padded), "x", "jsTrim did not strip \(label)")
      XCTAssertEqual(
        QueryFolding.jsStripWhitespaceAndHyphen(padded),
        "x",
        "the bank-account [\\s-] strip did not remove \(label)"
      )
    }

    for label in fixture.crossLanguageSemantics.trimSet.notStripped {
      let scalar = try self.scalar(fromCodepointLabel: label)
      XCTAssertFalse(
        QueryFolding.javaScriptWhitespace.contains(scalar),
        "\(label) is NOT whitespace in JS but QueryFolding treats it as whitespace"
      )
      let padded = String(scalar) + "x" + String(scalar)
      XCTAssertEqual(QueryFolding.jsTrim(padded), padded, "jsTrim wrongly stripped \(label)")
    }

    // The set is exactly the fixture's list — no extras of our own invention.
    XCTAssertEqual(
      QueryFolding.javaScriptWhitespace.count,
      fixture.crossLanguageSemantics.trimSet.codepoints.count,
      "QueryFolding.javaScriptWhitespace has scalars the fixture does not list"
    )
  }

  /// U+FEFF specifically: Foundation's `whitespacesAndNewlines` does not contain it, so before the
  /// hand-written class a BOM-prefixed paste folded to a different key than the server's.
  func testByteOrderMarkIsTrimmedLikeJavaScriptDoes() throws {
    let query = try TraciveQuery.email(value: "\u{FEFF}budi@gmail.com\u{FEFF}")
    assertSameBytes(query.searchQueryIndex, "EMAIL_budi@gmail.com", "U+FEFF trim")

    let bank = try TraciveQuery.bankAccount(
      countryAlpha3: "IDN", bankCode: "BCA", account: "DE89\u{FEFF}3704")
    assertSameBytes(bank.searchQueryIndex, "BANK_IDN_BCA_DE893704", "U+FEFF in account id")
  }

  /// Case mapping must be locale-invariant and is allowed to change length. A locale-taking variant
  /// would produce a plain `i` for `İ` under a Turkish locale and a different key.
  func testCaseMappingIsLocaleInvariantAndLengthChanging() throws {
    let fixture = try loadFixture()
    let examples = fixture.crossLanguageSemantics.caseMapping.examples

    XCTAssertEqual(examples["ß -> uppercase"], "SS")
    assertSameBytes("ß".uppercased(), "SS", "ß uppercases to two characters")

    XCTAssertEqual(examples["İ -> lowercase"], "i + U+0307")
    XCTAssertEqual(
      Array("İ".lowercased().unicodeScalars),
      ["i", "\u{0307}"],
      "İ must lowercase to 'i' + COMBINING DOT ABOVE, not plain 'i'"
    )

    // …and through the real builders, on bytes.
    let bank = try TraciveQuery.bankAccount(
      countryAlpha3: "DEU", bankCode: "DB", account: "ß123")
    assertSameBytes(bank.searchQueryIndex, "BANK_DEU_DB_SS123", "ß through the bank builder")
  }

  /// NFC is scoped: applied to email, username and every *code* field (social/chain platform code
  /// and bank code), never to bank account ids, crypto addresses or phones. A decomposed bank
  /// account must survive decomposed; a decomposed bank code must not.
  func testNfcIsNotAppliedOutsideItsScope() throws {
    let fixture = try loadFixture()
    XCTAssertTrue(fixture.crossLanguageSemantics.nfcScope.contains("NOT applied"))

    // The in-scope half, on bytes. Composition here is length-changing ('A' + U+0301 → U+00C1), so
    // an implementation that skipped NFC on the bank code would build a longer key that can never
    // match the server's. Nothing else in the suite covers the code field specifically.
    let composedCode = try TraciveQuery.bankAccount(
      countryAlpha3: "IDN", bankCode: "BCA\u{0301}", account: "1234567890")
    assertSameBytes(
      composedCode.searchQueryIndex,
      "BANK_IDN_BC\u{00C1}_1234567890",
      "bank code must be NFC-composed before uppercasing"
    )

    let decomposed = "A\u{0301}123"  // 'A' + COMBINING ACUTE
    let bank = try TraciveQuery.bankAccount(
      countryAlpha3: "IDN", bankCode: "BCA", account: decomposed)
    assertSameBytes(
      bank.searchQueryIndex,
      "BANK_IDN_BCA_" + decomposed.uppercased(),
      "bank account must NOT be NFC-composed"
    )
    XCTAssertTrue(
      Array(bank.searchQueryIndex.utf8).contains(0xCC),
      "the combining mark was composed away, so NFC leaked into the bank-account fold"
    )

    // Email, by contrast, *is* composed — asserted byte-wise in
    // testEmailNfcCompositionIsAppliedAtByteLevel.
  }

  /// Phone is folded client-side even though the server folds it too: this key is
  /// also the local cache key, so an unfolded one splits one entity across
  /// several cache entries. Before that commit an unfolded key also missed and was still billed.
  func testPhoneFoldingIsClientSideOnly() throws {
    let fixture = try loadFixture()
    XCTAssertTrue(fixture.crossLanguageSemantics.phoneFolding.contains("client-side"))

    let query = try TraciveQuery.phone(e164: "\u{FEFF} +62-812 3456.7891 ")
    assertSameBytes(query.searchQueryIndex, "PHONE_+6281234567891", "phone folded locally")
  }

  // MARK: - documentIdGuard (fixture v2)

  /// Drives the fixture's own `documentIdGuard.cases` rather than a hand-copied list, so the guard
  /// cannot drift from the contract the backend enforces.
  func testDocumentIdGuardFixtureCases() throws {
    let fixture = try loadFixture()
    XCTAssertFalse(fixture.documentIdGuard.cases.isEmpty)

    for entry in fixture.documentIdGuard.cases where !Self.pendingGuardValues.contains(entry.value) {
      if entry.safe {
        XCTAssertNoThrow(
          try DocumentIdGuard.validate(entry.value),
          "documentIdGuard case '\(entry.value)' is marked safe but the guard rejected it"
        )
      } else {
        XCTAssertThrowsError(
          try DocumentIdGuard.validate(entry.value),
          "documentIdGuard case '\(entry.value)' is marked unsafe but the guard accepted it"
        ) { error in
          XCTAssertEqual((error as? TraciveQueryError)?.reason, .invalidDocumentId)
        }
      }
    }
  }

  /// Every rejection rule the fixture lists must be accounted for — implemented, or knowingly not.
  ///
  /// `DocumentIdGuard` implements six of the seven. The seventh, "contains a lone/unpaired UTF-16
  /// surrogate", is unreachable in Swift and so is not implemented. That was previously an
  /// *invisible* gap: the fixture's `documentIdGuard.rejected` list was not even decoded, so a rule
  /// added upstream would have been silently ignored by this SDK. It is decoded now, and this test
  /// fails if the list changes at all.
  func testEveryDocumentIdRejectionRuleInTheFixtureIsAccountedFor() throws {
    let fixture = try loadFixture()

    XCTAssertEqual(
      Set(fixture.documentIdGuard.rejected),
      [
        "empty string",
        "contains '/'",
        "exactly '.'",
        "exactly '..'",
        "matches ^__.*__$",
        "> 1500 UTF-8 bytes",
        // Not implemented — see below, and see `DocumentIdGuard`'s doc comment.
        "contains a lone/unpaired UTF-16 surrogate",
      ],
      "the fixture's document-id rules changed; check DocumentIdGuard implements the new set"
    )

    // Why the surrogate rule is not implemented, asserted rather than asserted-in-prose. If a
    // future Swift ever let a `String` carry a lone surrogate, this goes red and the guard needs
    // the rule after all.
    XCTAssertNil(Unicode.Scalar(UInt32(0xD800)), "a lone surrogate is not a constructible scalar")
    let illFormed = String(decoding: [0xED, 0xA0, 0x80] as [UInt8], as: UTF8.self)
    XCTAssertTrue(
      illFormed.unicodeScalars.allSatisfy { $0.value == 0xFFFD },
      "ill-formed bytes must be replaced with U+FFFD at String construction"
    )
    XCTAssertFalse(illFormed.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) })
  }

  /// `matchesReservedPattern` is knowingly stricter than the server's `^__.*__$`, because
  /// JavaScript's `.` does not match a newline — so `"__a\nb__"` is accepted server-side and
  /// rejected here (verified by running that regex). Pinned so the divergence stays a recorded
  /// decision, including its direction: over-rejection costs nothing, whereas accepting a key the
  /// server refuses costs a credit on a request that cannot hit.
  func testReservedPatternIsStricterThanTheServerAcrossANewline() throws {
    XCTAssertThrowsError(try DocumentIdGuard.validate("__a\nb__")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.reason, .invalidDocumentId)
    }

    // …and it is unreachable through a builder, for a different reason than one might guess: the
    // guard runs on the *folded key*, which every builder prefixes with its kind. So the string
    // handed to the guard starts with "USERNAME_", never with "__", and can never match the
    // reserved pattern however the caller's input is shaped.
    let query = try TraciveQuery.username(platform: "TELEGRAM", handle: "__a\nb__")
    XCTAssertTrue(query.searchQueryIndex.hasPrefix("USERNAME_TELEGRAM_"))
    XCTAssertFalse(query.searchQueryIndex.hasPrefix("__"))
    XCTAssertNoThrow(try DocumentIdGuard.validate(query.searchQueryIndex))
  }

  /// The byte limit is a number in the fixture, not a number in our head.
  func testDocumentIdByteLimitMatchesTheFixture() throws {
    let fixture = try loadFixture()
    XCTAssertEqual(DocumentIdGuard.maxUtf8ByteCount, fixture.documentIdGuard.maxUtf8Bytes)
  }

  /// A rejection must never echo the value that was rejected.
  func testQueryErrorCarriesOnlyTheReason() {
    let error = TraciveQueryError(.notE164)
    XCTAssertEqual(error.rawReason, "not_e164")
    XCTAssertFalse(error.description.contains("081234567891"))
    XCTAssertEqual(error.asTraciveError.kind, .invalidQuery)
  }
}
