import Foundation

/// A partner's own bank identifier → Tracive's `bankCode`, per ISO 3166-1 alpha-3 country.
///
/// The server translates a national bank code (`014`) or a BIC (`CENAIDJA`) to `bankCode` (`BCA`)
/// before it builds `BANK_<country>_<bankCode>_<account>`. This does the same on the device, from
/// the same table, because that key is also the local cache key: keyed on the untranslated code, a
/// check could never hit the cache and every one would be billed.
///
/// The table is `bank-codes.json`, vendored byte-identically from the Tracive API and embedded as
/// `BankCodes.json` (see `Scripts/embed-bank-codes.js`), so resolution works offline.
enum BankCodes {

  /// Country → folded code → `bankCode`. Swift dictionaries have no inherited members, so a code
  /// such as `constructor` or `__proto__` is an ordinary miss.
  struct Table: Sendable {
    var shortCode: [String: [String: String]] = [:]
    /// The all-digit short codes only, keyed without their leading zeros.
    var bareShortCode: [String: [String: String]] = [:]
    var bic: [String: [String: String]] = [:]
  }

  /// Parsed on first use: a `static let` is initialised lazily, once, and thread-safely, so neither
  /// importing the SDK nor creating a client pays for it.
  static let table: Table = parse(json)

  /// The `bankCode` for a national bank code, or nil when `country` does not list it.
  ///
  /// - Parameter country: already folded by `QueryFolding.foldCountryAlpha3`.
  static func bankCode(country: String, shortCode raw: String) -> String? {
    let code = QueryFolding.foldBankShortCode(raw)
    if let exact = table.shortCode[country]?[code], !exact.isEmpty { return exact }
    // National codes are fixed-width (`014`), but a partner storing them as numbers sends `14`.
    guard QueryFolding.isAsciiDigits(code) else { return nil }
    return table.bareShortCode[country]?[strippingLeadingZeros(code)]
  }

  /// The `bankCode` for an 8- or 11-character BIC, or nil when it is malformed or `country` does
  /// not list it. A BIC is looked up within `country` only.
  static func bankCode(country: String, bic raw: String) -> String? {
    guard let bic = QueryFolding.foldBic(raw) else { return nil }
    return table.bic[country]?[bic]
  }

  /// `code.replace(/^0+(?=\d)/, "")` for an all-digit code: the last digit always stays, so `000`
  /// becomes `0`.
  static func strippingLeadingZeros(_ digits: String) -> String {
    var rest = Substring(digits)
    while rest.count > 1, rest.first == "0" { rest = rest.dropFirst() }
    return String(rest)
  }

  private struct File: Decodable {
    struct Codes: Decodable {
      let shortCode: [String: String]
      let bic: [String: String]
    }
    let countries: [String: Codes]
  }

  static func parse(_ json: String) -> Table {
    // An empty table makes every code unknown, which is rejected locally and never billed. Crashing
    // the host app would be worse, and BankCodeTests decodes this exact constant on every run.
    guard let file = try? JSONDecoder().decode(File.self, from: Data(json.utf8)) else {
      return Table()
    }
    var table = Table()
    for (country, codes) in file.countries {
      table.shortCode[country] = codes.shortCode
      table.bic[country] = codes.bic
      // BankCodeTests proves no two all-digit codes of one country collide once stripped, so the
      // dictionary's iteration order can never choose between two banks here.
      var bare: [String: String] = [:]
      for (code, bankCode) in codes.shortCode where QueryFolding.isAsciiDigits(code) {
        bare[strippingLeadingZeros(code)] = bankCode
      }
      table.bareShortCode[country] = bare
    }
    return table
  }
}
