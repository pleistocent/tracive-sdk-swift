import XCTest

@testable import TraciveSDK

/// Drives the vendored `phone-normalization-vectors.json` — the app/SDK anti-drift contract.
///
/// Expected values came from executing the Tracive app's own normalizer. If this SDK disagrees with
/// a vector, this SDK is wrong: app and SDK must fold the same person to the same record key.
final class PhoneNormalizationTests: XCTestCase {

  private struct Fixture: Decodable {
    struct Vector: Decodable {
      let country: String
      let input: String
      let expected: String
    }
    struct Rejection: Decodable {
      let country: String
      let input: String
      let reason: String
    }
    struct CountryRow: Decodable {
      let dialCode: String
      let alpha2: String
      let alpha3: String
    }
    let countryCount: Int
    let vectors: [Vector]
    let rejected: [Rejection]
    let countries: [CountryRow]
    let nationalNumberLengths: [String: [Int]]
  }

  private func loadFixture() throws -> Fixture {
    let url =
      Bundle.module.url(forResource: "phone-normalization-vectors", withExtension: "json")
      ?? Bundle.module.url(forResource: "Fixtures/phone-normalization-vectors", withExtension: "json")
    let data = try Data(contentsOf: try XCTUnwrap(url, "fixture missing from the test bundle"))
    return try JSONDecoder().decode(Fixture.self, from: data)
  }

  func testEveryVectorFoldsByteForByte() throws {
    let fixture = try loadFixture()
    XCTAssertFalse(fixture.vectors.isEmpty, "a fixture with no vectors would pass vacuously")
    for vector in fixture.vectors {
      XCTAssertEqual(
        try normalizePhoneNumber(vector.country, vector.input),
        vector.expected,
        "\(vector.country) / \(vector.input) did not fold as the app folds it")
    }
  }

  func testEveryRejectionIsRefusedWithItsExactReason() throws {
    let fixture = try loadFixture()
    XCTAssertFalse(fixture.rejected.isEmpty)
    for rejection in fixture.rejected {
      XCTAssertThrowsError(
        try normalizePhoneNumber(rejection.country, rejection.input),
        "accepted an unusable input: \(rejection.country) / \(rejection.input)"
      ) { error in
        XCTAssertEqual((error as? TraciveQueryError)?.reason.rawValue, rejection.reason)
      }
    }
  }

  /// Every dial code and every length up to 17: a number typed without `+` that starts with its own
  /// dial code keeps those digits only as the fixture's `nationalNumberLengths` says. The 5s keep
  /// trunk rules out of it.
  func testANumberStartingWithItsDialCodeIsReadByTheLengthsTable() throws {
    let fixture = try loadFixture()
    XCTAssertFalse(fixture.nationalNumberLengths.isEmpty)
    let dialCodes = Set(fixture.countries.map(\.dialCode)).subtracting(["1"])
    for dialCode in dialCodes {
      let national = fixture.nationalNumberLengths[dialCode] ?? []
      for length in (dialCode.count + 1)...17 {
        let rest = String(repeating: "5", count: length - dialCode.count)
        let typed = dialCode + rest
        let keep = national.contains(length) && !national.contains(length - dialCode.count)
        XCTAssertEqual(
          try normalizePhoneNumber(dialCode, typed), "+" + dialCode + (keep ? typed : rest), typed)
      }
    }
  }

  func testTheCountryTableMatchesTheContract() throws {
    let fixture = try loadFixture()
    XCTAssertEqual(
      Country.allCases.count, fixture.countryCount, "the table drifted from the fixture")
    XCTAssertEqual(
      Set(Country.allCases.map(\.alpha3)).count, Country.allCases.count,
      "two countries share an alpha-3 code")
    for row in fixture.countries {
      let country = try XCTUnwrap(Country.fromAlpha3(row.alpha3), "\(row.alpha3) missing")
      XCTAssertEqual(country.dialCode, row.dialCode, "dial code drifted for \(row.alpha3)")
      XCTAssertEqual(country.alpha2, row.alpha2, "alpha-2 drifted for \(row.alpha3)")
    }
  }

  func testAlpha3LookupIgnoresCaseAndSurroundingSpace() {
    XCTAssertEqual(Country.fromAlpha3("idn"), .idn)
    XCTAssertEqual(Country.fromAlpha3("  IDN  "), .idn)
    XCTAssertNil(Country.fromAlpha3("ID"), "alpha-2 must not resolve; this SDK speaks alpha-3")
  }

  /// The whole point of the utility: what it returns is what `phone()` accepts.
  func testTheResultIsAcceptedByTheQueryBuilder() throws {
    let query = try TraciveQuery.phone(e164: try normalizePhoneNumber("IDN", "0857-1860-9079"))
    XCTAssertEqual(query.searchQueryIndex, "PHONE_+6285718609079")
    XCTAssertEqual(
      query.searchQueryIndex,
      try TraciveQuery.phone(e164: try normalizePhoneNumber(.idn, "0857 1860 9079")).searchQueryIndex,
      "alpha-3 and the enum must produce one key, not two")
  }
}
