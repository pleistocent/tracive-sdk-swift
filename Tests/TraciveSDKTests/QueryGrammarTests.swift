import CryptoKit
import XCTest

@testable import TraciveSDK

/// Drives the vendored `query-grammar-vectors.json` — the cross-language anti-drift contract.
///
/// Every `vectors[]` entry must fold to its `expected` string and every `rejected[]` entry must
/// throw with the stated `reason`. Kotlin, Flutter, Swift and the backend all run the same file, so
/// a failure here means this SDK would build keys that miss on the server — and a miss is
/// still billed.
///
/// Nothing in this file touches the network.
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

  /// The pinned digest, read from the sidecar `query-grammar-vectors.sha256`.
  ///
  /// The file is in `shasum -a 256` output format — `<digest>  <path>` — so CI can hand it straight
  /// to `shasum -a 256 -c` and both checks read the same value. Keeping the digest out of this
  /// source file is what stops the two from drifting: there is one place to update, and updating it
  /// is visible in the diff next to the fixture it describes.
  private static func loadPinnedFixtureDigest() throws -> String {
    let data: Data
    if let url = Bundle.module.url(forResource: "query-grammar-vectors", withExtension: "sha256")
      ?? Bundle.module.url(forResource: "Fixtures/query-grammar-vectors", withExtension: "sha256")
    {
      data = try Data(contentsOf: url)
    } else {
      let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      data = try Data(
        contentsOf: sourceDirectory
          .appendingPathComponent("Fixtures")
          .appendingPathComponent("query-grammar-vectors.sha256")
      )
    }
    let text = String(decoding: data, as: UTF8.self)
    guard let digest = text.split(whereSeparator: \.isWhitespace).first else {
      throw MalformedDigestPin(contents: text)
    }
    return String(digest).lowercased()
  }

  private struct MalformedDigestPin: Error { let contents: String }

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

  /// The fixture is pinned by content hash, and this is what notices when its bytes move.
  ///
  /// Every other test in this file reads the file's *meaning*: it decodes the JSON and drives the
  /// vectors through the folding code. That leaves a whole class of change invisible — reindenting,
  /// reordering keys, rewriting a number in an equivalent form, re-exporting through a tool that
  /// pretty-prints. An audit demonstrated exactly that here: it reformatted this fixture from
  /// 21 662 bytes to 32 533, a completely different file on disk, and all 259 tests stayed green.
  ///
  /// "Semantics-preserving, therefore harmless" is the reasoning to distrust. This file is vendored
  /// **byte-identically** into four SDK repositories, and that is the entire mechanism by which they
  /// are known to agree: one `shasum` per repository, four identical answers, no interpretation
  /// required. Reformat one copy and that question can no longer be asked — the next genuine grammar
  /// change then lands in a copy nobody can diff against the others, and the drift this fixture
  /// exists to prevent starts in the one place designed to prove it had not happened.
  ///
  /// So a changed digest is not an error to fix by re-pinning. It means the fixture moved, and a
  /// grammar change starts at the Tracive API and lands in all four SDKs together. See
  /// CONTRIBUTING.md.
  func testTheFixtureMatchesItsPinnedContentHash() throws {
    let data = try QueryGrammarTests.loadFixtureData()
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    // Read rather than inlined: CI's `shasum -a 256 -c` step checks the same sidecar, so the two
    // guards cannot disagree about what is pinned.
    let expected = try QueryGrammarTests.loadPinnedFixtureDigest()

    XCTAssertEqual(
      actual,
      expected,
      """
      query-grammar-vectors.json no longer matches its pinned digest.
      expected \(expected)
      actual   \(actual) (\(data.count) bytes)

      This file is vendored byte-identically into the Kotlin, Swift, Flutter and React Native SDKs.
      Do not re-pin to make this pass: a grammar change starts at the Tracive API and lands in all
      four together, and reformatting alone is not a change worth breaking that property for.
      """
    )
  }

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
    for entry in fixture.rejected {
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

    for entry in fixture.rejected {
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

    XCTAssertEqual(checked, fixture.rejected.count, "not every rejected input was asserted")
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

  /// An empty crypto address and an empty username platform each get their own reason token.
  ///
  /// They used to share the generic `empty_value` with an empty email, which made three different
  /// mistakes indistinguishable: a caller catching the error could not tell which of the two
  /// arguments it had just been handed was the blank one, so it could not put the message on the
  /// right field. The tokens are wire contract, so they are asserted literally here.
  func testEmptyAddressAndEmptyPlatformHaveTheirOwnReasons() {
    XCTAssertThrowsError(try TraciveQuery.crypto(chain: "ETH", address: "   ")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "empty_address")
    }
    XCTAssertThrowsError(try TraciveQuery.username(platform: "  ", handle: "scammerx")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "empty_platform")
    }

    // The neighbouring tokens are untouched: a blank chain and a blank handle keep theirs, and an
    // empty email keeps the generic one, which is now its only user.
    XCTAssertThrowsError(try TraciveQuery.crypto(chain: " ", address: "0xabc")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "empty_chain")
    }
    XCTAssertThrowsError(try TraciveQuery.username(platform: "TELEGRAM", handle: " ")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "empty_handle")
    }
    XCTAssertThrowsError(try TraciveQuery.email(value: "  ")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "empty_value")
    }
  }

  /// A value with no `@` is rejected before the request, because the server would happily look it
  /// up and bill the miss.
  ///
  /// The server applies **no** shape validation to an email: `EMAIL_budi` is a perfectly legal
  /// record key, so it is looked up, missed, and charged. Client-side rejection is the only thing
  /// standing between a caller's typo and a spent credit — the same job `phone()`'s E.164 check
  /// already does.
  func testEmailWithoutAnAtSignIsRejected() {
    XCTAssertThrowsError(try TraciveQuery.email(value: "budi")) { error in
      // The token, not the enum case: it is a cross-SDK wire contract, so a rename must fail here
      // rather than quietly redefine what Kotlin, Flutter and this SDK all agreed to emit.
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "not_an_email")
    }

    // Still rejected once the fold has run: trimming and lowercasing cannot introduce an `@`.
    XCTAssertThrowsError(try TraciveQuery.email(value: "  BUDI  ")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "not_an_email")
    }

    // An empty value keeps its own token. The two mistakes are different and a caller may want to
    // word them differently, so the emptiness check has to run first.
    XCTAssertThrowsError(try TraciveQuery.email(value: "   ")) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.rawReason, "empty_value")
    }
  }

  /// The check is deliberately only `@`-presence, not an address grammar.
  ///
  /// Over-validating is the worse failure: a client-side rejection of an address the server would
  /// have matched loses a real fraud answer, whereas a weird-but-plausible address costs at most
  /// one miss. So every shape below — no TLD, an IP-literal domain, a quoted local part, a plus
  /// tag, a bare `@` on either side — must build a key.
  func testEmailValidationDoesNotImposeAnAddressGrammar() throws {
    let accepted = [
      "budi@localhost",
      "budi@[192.168.0.1]",
      "\"budi something\"@example.com",
      "budi+tag@example.com",
      "budi@@example.com",
      "@example.com",
      "budi@",
    ]
    for value in accepted {
      XCTAssertNoThrow(
        try TraciveQuery.email(value: value),
        "'\(value)' contains an '@' and must not be rejected — the server would match it"
      )
    }
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

    for entry in fixture.documentIdGuard.cases {
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

  /// The reserved-key rule is `^__.*__$`, and that pattern does **not** span a line terminator.
  ///
  /// The server's regex carries no `s` flag, so `.` matches anything except a line terminator, and
  /// `^`/`$` anchor at the string's ends (there is no `m` flag either, so `$` does not match before
  /// a trailing newline). Every expectation below was taken from running that literal regex, not
  /// reasoned about: a guard written as `hasPrefix("__") && hasSuffix("__")` is stricter than the
  /// server and rejects keys it would have accepted.
  func testReservedPatternDoesNotSpanALineTerminator() {
    // Line terminators, so `.*` cannot cover the middle → not reserved → the server accepts these.
    let accepted = [
      "__a\nb__",  // LF, the fixture's own case
      "__\n__",
      "__a\rb__",  // CR
      "__a\u{2028}b__",  // LINE SEPARATOR
      "__a\u{2029}b__",  // PARAGRAPH SEPARATOR
      "__a__\n__",  // `.*` would have to cover "a__\n"
      "__ab__\n",  // `$` does not match before a trailing newline without `m`
      "\n__ab__",
      "___",  // three underscores are too few for `__` + `.*` + `__`
    ]
    for id in accepted {
      XCTAssertNoThrow(
        try DocumentIdGuard.validate(id),
        "'\(id.debugDescription)' is not reserved server-side and must not be rejected here"
      )
    }

    // U+0085 NEL is *not* a JavaScript line terminator, though ICU (and so `NSRegularExpression`)
    // treats it as one. A guard built on Foundation's regex would wrongly accept this.
    let reserved = ["__proto__", "____", "__a b__", "__a\u{0085}b__"]
    for id in reserved {
      XCTAssertThrowsError(
        try DocumentIdGuard.validate(id),
        "'\(id.debugDescription)' matches ^__.*__$ and must be rejected"
      ) { error in
        XCTAssertEqual((error as? TraciveQueryError)?.reason, .invalidDocumentId)
      }
    }
  }

  /// None of the reserved-pattern cases is reachable through a builder, for a subtler reason than
  /// one might guess: the guard runs on the *folded key*, which every builder prefixes with its
  /// kind. The string handed to the guard starts with `USERNAME_`, `BANK_` and so on — never with
  /// `__` — so it cannot match the reserved pattern however the caller's input is shaped. Not
  /// because folding strips newlines: an interior newline survives the fold, as asserted here.
  func testReservedPatternIsUnreachableThroughABuilder() throws {
    let query = try TraciveQuery.username(platform: "TELEGRAM", handle: "__a\nb__")
    XCTAssertTrue(query.searchQueryIndex.hasPrefix("USERNAME_TELEGRAM_"))
    XCTAssertFalse(query.searchQueryIndex.hasPrefix("__"))
    XCTAssertTrue(query.searchQueryIndex.contains("\n"), "the fold must not strip an inner newline")
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
