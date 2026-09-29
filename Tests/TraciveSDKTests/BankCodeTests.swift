import XCTest

@testable import TraciveSDK

/// The embedded bank-code table, and the `bankAccount` overloads that take a national bank code or
/// a BIC. The vendored vectors run in `QueryGrammarTests`; this covers what they leave out.
final class BankCodeTests: XCTestCase {

  private static func loadVendoredTable() throws -> Data {
    if let url = Bundle.module.url(forResource: "bank-codes", withExtension: "json")
      ?? Bundle.module.url(forResource: "Fixtures/bank-codes", withExtension: "json")
    {
      return try Data(contentsOf: url)
    }
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return try Data(
      contentsOf: sourceDirectory.appendingPathComponent("Fixtures").appendingPathComponent(
        "bank-codes.json"))
  }

  private func key(_ country: String, shortCode: String, account: String = "1234567890") throws
    -> String
  {
    try TraciveQuery.bankAccount(countryAlpha3: country, bankShortCode: shortCode, account: account)
      .searchQueryIndex
  }

  private func key(_ country: String, bic: String, account: String = "1234567890") throws -> String
  {
    try TraciveQuery.bankAccount(countryAlpha3: country, bic: bic, account: account)
      .searchQueryIndex
  }

  private func assertRejected(
    _ reason: QueryRejectionReason,
    _ build: @autoclosure () throws -> String,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try build(), message, file: file, line: line) { error in
      XCTAssertEqual((error as? TraciveQueryError)?.reason, reason, message, file: file, line: line)
    }
  }

  // MARK: - The embedded table

  func testTheEmbeddedTableIsTheVendoredFileByteForByte() throws {
    let vendored = try Self.loadVendoredTable()
    let embedded = Data(BankCodes.json.utf8)
    XCTAssertTrue(
      embedded == vendored,
      """
      BankCodesJSON.swift (\(embedded.count) bytes) differs from Fixtures/bank-codes.json \
      (\(vendored.count) bytes). Run `node Scripts/embed-bank-codes.js`; never edit either by hand.
      """
    )
  }

  /// Decoded here by a different parser, so an empty or partial `BankCodes.table` — which would
  /// reject real codes as unknown — cannot pass.
  func testTheParsedTableHoldsEveryEntryOfTheFile() throws {
    let root =
      try JSONSerialization.jsonObject(with: try Self.loadVendoredTable()) as? [String: Any]
    let countries = try XCTUnwrap(root?["countries"] as? [String: [String: [String: String]]])
    XCTAssertFalse(countries.isEmpty)

    XCTAssertEqual(Set(BankCodes.table.shortCode.keys), Set(countries.keys))
    XCTAssertEqual(Set(BankCodes.table.bic.keys), Set(countries.keys))
    for (country, codes) in countries {
      XCTAssertEqual(BankCodes.table.shortCode[country], codes["shortCode"], country)
      XCTAssertEqual(BankCodes.table.bic[country], codes["bic"], country)
    }
  }

  func testEveryListedCodeBuildsTheKeyItsBankCodeBuilds() throws {
    var checked = 0
    for (country, codes) in BankCodes.table.shortCode {
      for (shortCode, bankCode) in codes {
        XCTAssertEqual(
          QueryFolding.foldBankShortCode(shortCode), shortCode, "\(country) \(shortCode)")
        let expected = try TraciveQuery.bankAccount(
          countryAlpha3: country, bankCode: bankCode, account: "1234567890"
        ).searchQueryIndex
        XCTAssertEqual(Array(try key(country, shortCode: shortCode).utf8), Array(expected.utf8))
        checked += 1
      }
    }
    for (country, codes) in BankCodes.table.bic {
      for (bic, bankCode) in codes {
        XCTAssertEqual(QueryFolding.foldBic(bic), bic, "\(country) \(bic)")
        let expected = try TraciveQuery.bankAccount(
          countryAlpha3: country, bankCode: bankCode, account: "1234567890"
        ).searchQueryIndex
        XCTAssertEqual(Array(try key(country, bic: bic).utf8), Array(expected.utf8))
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 0, "an empty table would make this loop vacuous")
  }

  func testNoTwoAllDigitCodesCollideOnceTheirLeadingZerosAreGone() {
    for (country, codes) in BankCodes.table.shortCode {
      var seen: [String: String] = [:]
      for (code, bankCode) in codes where QueryFolding.isAsciiDigits(code) {
        let bare = BankCodes.strippingLeadingZeros(code)
        if let other = seen[bare] {
          XCTAssertEqual(other, bankCode, "\(country): two banks share the short code \(bare)")
        }
        seen[bare] = bankCode
        XCTAssertEqual(BankCodes.table.bareShortCode[country]?[bare], bankCode)
      }
    }
  }

  // MARK: - Lookups that must miss

  /// A plain JavaScript object would answer these from its prototype. Here they must be misses.
  func testPrototypeMemberNamesAreMisses() {
    for name in ["constructor", "__proto__", "toString", "hasOwnProperty", "valueOf", "prototype"] {
      assertRejected(.unknownBankCode, try key("IDN", shortCode: name), name)
      assertRejected(.unknownBankCode, try key("IDN", bic: name), name)
    }
  }

  func testACountryTheTableDoesNotListIsAMiss() {
    assertRejected(.unknownBankCode, try key("XXX", shortCode: "014"), "short code")
    assertRejected(.unknownBankCode, try key("XXX", bic: "CENAIDJA"), "BIC")
  }

  // MARK: - Leading zeros

  func testLeadingZerosAreOptionalOnEitherSide() throws {
    // Listed as 014.
    XCTAssertEqual(try key("IDN", shortCode: "14"), "BANK_IDN_BCA_1234567890")
    XCTAssertEqual(try key("IDN", shortCode: "00014"), "BANK_IDN_BCA_1234567890")
    // Listed as 143, with no leading zero.
    XCTAssertEqual(try key("ARG", shortCode: "0143"), "BANK_ARG_BRUBANK_1234567890")
    // Separators go before the digits check, so this is the exact code 014.
    XCTAssertEqual(try key("IDN", shortCode: "0-1.4"), "BANK_IDN_BCA_1234567890")
  }

  func testLeadingZeroRemovalKeepsTheLastDigit() {
    XCTAssertEqual(BankCodes.strippingLeadingZeros("000"), "0")
    XCTAssertEqual(BankCodes.strippingLeadingZeros("0"), "0")
    XCTAssertEqual(BankCodes.strippingLeadingZeros("014"), "14")
    XCTAssertEqual(BankCodes.strippingLeadingZeros("0100"), "100")
    XCTAssertEqual(BankCodes.strippingLeadingZeros("140"), "140")
  }

  func testLeadingZerosAreKeptOnACodeThatIsNotAllDigits() throws {
    XCTAssertEqual(try key("NPL", shortCode: "HBL"), "BANK_NPL_HIMALAYAN_1234567890")
    assertRejected(.unknownBankCode, try key("NPL", shortCode: "0HBL"), "0HBL")
    // Arabic-Indic digits are not ASCII digits, so they are neither stripped nor matched.
    assertRejected(.unknownBankCode, try key("IDN", shortCode: "\u{0660}\u{0661}\u{0664}"), "014")
  }

  // MARK: - JavaScript whitespace, not Foundation's

  func testWhitespaceIsTheJavaScriptClass() throws {
    // U+000B and U+FEFF are JS `\s`, and NSRegularExpression's `\s` omits both.
    XCTAssertEqual(try key("IDN", shortCode: "\u{0B}0 14\u{FEFF}"), "BANK_IDN_BCA_1234567890")
    XCTAssertEqual(try key("IDN", bic: "\u{FEFF}CENA IDJA\u{0B}XXX"), "BANK_IDN_BCA_1234567890")
    // U+200B and U+0085 are not JS `\s`: they stay in the code, which then misses.
    for stray in ["\u{200B}", "\u{0085}"] {
      assertRejected(.unknownBankCode, try key("IDN", shortCode: "014" + stray), "short code")
      assertRejected(.unknownBankCode, try key("IDN", bic: "CENAIDJA" + stray), "BIC")
    }
  }

  // MARK: - BIC shape

  func testBicMustBeEightOrElevenCharactersOfTheRightClass() throws {
    XCTAssertEqual(try key("IDN", bic: "CENAIDJA123"), "BANK_IDN_BCA_1234567890")
    let malformed = [
      "CENAIDJ",  // 7
      "CENAIDJAX",  // 9
      "CENAIDJAXX",  // 10
      "CENAIDJAXXXX",  // 12
      "CENAID1A",  // a digit in the country part
      "CENA-IDJA",  // '-' is not stripped from a BIC
      "CENA.IDJA",
      "",
    ]
    for bic in malformed {
      assertRejected(.unknownBankCode, try key("IDN", bic: bic), bic)
    }
  }

  // MARK: - Order of rejections

  func testCountryIsCheckedBeforeTheCodeAndTheCodeBeforeTheAccount() {
    assertRejected(.countryNotAlpha3, try key("ID", shortCode: "999"), "alpha-2, unknown code")
    assertRejected(.countryNotAlpha3, try key("ID", bic: "CENA"), "alpha-2, malformed BIC")
    assertRejected(
      .unknownBankCode, try key("IDN", shortCode: "999", account: " "), "empty account")
    assertRejected(.unknownBankCode, try key("IDN", bic: "CENA", account: " "), "empty account")
    assertRejected(.emptyAccountId, try key("IDN", shortCode: "014", account: " "), "known code")
    assertRejected(.emptyAccountId, try key("IDN", bic: "CENAIDJA", account: " "), "known BIC")
  }

  func testTheReasonTokenIsTheWireSpelling() {
    XCTAssertEqual(TraciveQueryError(.unknownBankCode).rawReason, "unknown_bank_code")
  }
}
