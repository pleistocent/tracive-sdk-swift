import Foundation

/// A validated, folded lookup key for one identifier.
///
/// Build one with a factory — `TraciveQuery.phone(e164:)`, `.email(value:)`,
/// `.bankAccount(countryAlpha3:bankCode:account:)` (or `bankShortCode:` / `bic:` in place of
/// `bankCode:`), `.iban(iban:)`, `.crypto(chain:address:)`, `.username(platform:handle:)`,
/// `.qris(payload:)` (or `nmid:` / `pan:`) — and hand it to `checkScammer`.
///
/// Two things happen at construction time, both before any network call can be made:
///
/// 1. **Folding.** The input is normalised into `searchQueryIndex` using the grammar in
///    `query-grammar-vectors.json`. That same folded string is the server's document id *and* the
///    local cache key, so an unfolded key would both miss on the server and split one entity into
///    several cache entries.
/// 2. **Validation.** Anything that cannot produce a key capable of hitting throws
///    `TraciveQueryError`. This matters commercially, not just hygienically: a miss is
///    billed, so sending a key that can never hit spends a credit for nothing.
///
/// ## There is no `domain()` builder
/// A `DOMAIN` input type does not exist: the Tracive API indexes only
/// PHONE / EMAIL / BANK / CRYPTO / USERNAME / QRIS. A `DOMAIN_…` key could never hit, and the miss
/// would still be charged. Do not add one.
public struct TraciveQuery: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{

  /// Which backend media category this key belongs to: its prefix before the first `_`.
  ///
  /// A struct rather than an enum so the next type the API adds breaks nobody. SwiftPM builds
  /// packages without library evolution, so a new enum case — even next to a `case unknown` —
  /// would fail every exhaustive `switch` in a partner's app. Switch over the constants you handle
  /// and keep a `default:`.
  public struct Kind: RawRepresentable, Hashable, Codable, Sendable, CaseIterable,
    CustomStringConvertible
  {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public static let phone = Kind(rawValue: "PHONE")
    public static let email = Kind(rawValue: "EMAIL")
    /// Covers every `bankAccount(countryAlpha3:…)` overload and `iban(iban:)`.
    public static let bank = Kind(rawValue: "BANK")
    public static let crypto = Kind(rawValue: "CRYPTO")
    public static let username = Kind(rawValue: "USERNAME")
    /// Covers `qris(payload:)`, `qris(nmid:)` and `qris(pan:)`.
    public static let qris = Kind(rawValue: "QRIS")

    /// The kinds this version of the SDK builds. A later API may answer with one not listed here.
    public static let allCases: [Kind] = [.phone, .email, .bank, .crypto, .username, .qris]

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
      self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  public let kind: Kind

  /// The folded lookup key, e.g. `PHONE_+6281234567891`.
  ///
  /// This contains the raw identifier. Never log it; hash it (SHA-256) before it is used as a cache
  /// key, and no raw identifier is ever written to disk.
  public let searchQueryIndex: String

  private init(kind: Kind, searchQueryIndex: String) throws {
    // Applied to every built key, no exceptions: an illegal document id cannot hit.
    try DocumentIdGuard.validate(searchQueryIndex)
    self.kind = kind
    self.searchQueryIndex = searchQueryIndex
  }

  // MARK: - Builders

  /// Phone number in E.164 form, e.g. `+6281234567891`.
  ///
  /// Formatting punctuation (spaces, dashes, dots, parentheses) is stripped, so every printed form
  /// of a number collapses onto one key. A local-format number (`081234567891`) is **rejected**:
  /// the server cannot up-convert it, so it would index as a different entity.
  public static func phone(e164: String) throws -> TraciveQuery {
    try TraciveQuery(kind: .phone, searchQueryIndex: "PHONE_" + QueryFolding.foldPhone(e164))
  }

  /// Email address. Folded with NFC, then lowercase, then trim.
  ///
  /// A value with no `@` is **rejected**: the server does not validate the shape of an email, so
  /// `EMAIL_budi` would be looked up, missed, and billed. Nothing stricter than `@`-presence is
  /// applied — rejecting an address the server would have matched loses a real fraud answer, which
  /// is worse than paying for one miss.
  public static func email(value: String) throws -> TraciveQuery {
    try TraciveQuery(kind: .email, searchQueryIndex: "EMAIL_" + QueryFolding.foldEmail(value))
  }

  /// Domestic bank account.
  ///
  /// - Parameters:
  ///   - countryAlpha3: ISO 3166-1 **alpha-3**, e.g. `IDN`. Alpha-2 is rejected so the local cache
  ///     key matches the server key exactly.
  ///   - bankCode: e.g. `BCA`. Underscores are stripped (the id is split on `_`).
  ///   - account: account number; spaces and hyphens are stripped, letters uppercased.
  public static func bankAccount(
    countryAlpha3: String,
    bankCode: String,
    account: String
  ) throws -> TraciveQuery {
    let country = try QueryFolding.foldCountryAlpha3(countryAlpha3)
    let code = try QueryFolding.foldBankCode(bankCode)
    let accountId = try QueryFolding.foldAccountId(account)
    return try TraciveQuery(kind: .bank, searchQueryIndex: "BANK_\(country)_\(code)_\(accountId)")
  }

  /// Domestic bank account, with the bank named by its national bank code.
  ///
  /// The code is translated to Tracive's `bankCode` through a table shipped inside the SDK, so this
  /// builds exactly the key `bankAccount(countryAlpha3:bankCode:account:)` builds for that bank —
  /// `IDN` + `014` gives the same key as `IDN` + `BCA`. Case, whitespace, `.` and `-` are ignored,
  /// and leading zeros are optional: `14` finds `014`.
  ///
  /// - Parameters:
  ///   - countryAlpha3: ISO 3166-1 **alpha-3**, e.g. `IDN`. Checked before the code is looked up.
  ///   - bankShortCode: the national bank code, e.g. `014`.
  ///   - account: as for `bankAccount(countryAlpha3:bankCode:account:)`.
  /// - Throws: `TraciveQueryError` with `.unknownBankCode` when the table does not list the code
  ///   for that country.
  public static func bankAccount(
    countryAlpha3: String,
    bankShortCode: String,
    account: String
  ) throws -> TraciveQuery {
    let country = try QueryFolding.foldCountryAlpha3(countryAlpha3)
    guard let bankCode = BankCodes.bankCode(country: country, shortCode: bankShortCode) else {
      throw TraciveQueryError(.unknownBankCode)
    }
    return try bankAccount(countryAlpha3: country, bankCode: bankCode, account: account)
  }

  /// Domestic bank account, with the bank named by its BIC.
  ///
  /// Translated like `bankAccount(countryAlpha3:bankShortCode:account:)`, from the same table, so
  /// this builds the key `bankAccount(countryAlpha3:bankCode:account:)` builds for that bank. An
  /// 11-character BIC is looked up by its first 8 (the branch is ignored); case and whitespace are
  /// ignored.
  ///
  /// - Parameters:
  ///   - countryAlpha3: ISO 3166-1 **alpha-3**, e.g. `IDN`. A BIC is looked up within this country
  ///     only.
  ///   - bic: e.g. `CENAIDJA` or `CENAIDJAXXX`.
  ///   - account: as for `bankAccount(countryAlpha3:bankCode:account:)`.
  /// - Throws: `TraciveQueryError` with `.unknownBankCode` when the BIC is malformed or the table
  ///   does not list it for that country.
  public static func bankAccount(
    countryAlpha3: String,
    bic: String,
    account: String
  ) throws -> TraciveQuery {
    let country = try QueryFolding.foldCountryAlpha3(countryAlpha3)
    guard let bankCode = BankCodes.bankCode(country: country, bic: bic) else {
      throw TraciveQueryError(.unknownBankCode)
    }
    return try bankAccount(countryAlpha3: country, bankCode: bankCode, account: account)
  }

  /// International bank account number. Printed grouping and case are presentational and are
  /// folded away.
  public static func iban(iban: String) throws -> TraciveQuery {
    try TraciveQuery(kind: .bank, searchQueryIndex: "BANK_IBAN_" + QueryFolding.foldAccountId(iban))
  }

  /// Crypto address.
  ///
  /// - Parameters:
  ///   - chain: e.g. `ETH`, `BTC`, `TRX`. Uppercased.
  ///   - address: lowercased **only** for EVM addresses (`0x…`), whose EIP-55 casing is a checksum
  ///     rather than data. Base58 and bech32 addresses are passed through with their case intact.
  public static func crypto(chain: String, address: String) throws -> TraciveQuery {
    let foldedChain = try QueryFolding.foldChain(chain)
    let foldedAddress = try QueryFolding.foldCryptoAddress(address)
    return try TraciveQuery(
      kind: .crypto,
      searchQueryIndex: "CRYPTO_\(foldedChain)_\(foldedAddress)"
    )
  }

  /// Social-media handle.
  ///
  /// - Parameters:
  ///   - platform: e.g. `INSTAGRAM`. Uppercased.
  ///   - handle: lowercased. A leading `@` is **kept** — the server keeps it too, so stripping it
  ///     here would miss every report filed with the `@`.
  public static func username(platform: String, handle: String) throws -> TraciveQuery {
    let foldedPlatform = try QueryFolding.foldPlatform(platform)
    let foldedHandle = try QueryFolding.foldHandle(handle)
    return try TraciveQuery(
      kind: .username,
      searchQueryIndex: "USERNAME_\(foldedPlatform)_\(foldedHandle)"
    )
  }

  /// A QRIS, from the text a QR decoder returned for it.
  ///
  /// The key is the merchant's NMID (tag 51), never the PAN or the merchant name. The payload must
  /// be intact (its CRC checks out), name an NMID, and belong to a micro or small business (UMI or
  /// UKE): no other QRIS is ever indexed, so a check on one could only be a billed miss. Static and
  /// dynamic QRIS are both accepted.
  ///
  /// Only for an organisation whose Tracive agreement covers QRIS. For any other, the check fails
  /// with `TraciveError.unsupportedInputType`. Show the result as a warning before the user pays;
  /// never block or hold a payment on it.
  ///
  /// - Throws: `TraciveQueryError` with `.notAQris`, `.qrisCrcMismatch`, `.qrisNoNmid` or
  ///   `.qrisNotIndexed`, checked in that order.
  public static func qris(payload: String) throws -> TraciveQuery {
    try TraciveQuery(kind: .qris, searchQueryIndex: "QRIS_" + QueryFolding.foldQrisPayload(payload))
  }

  /// A QRIS, by the NMID printed on the merchant's sticker: `ID` and 13 digits.
  ///
  /// Tab, LF, CR, space and U+00A0 are removed wherever they sit, and the value is upper-cased, so
  /// `id1020 0000 00033` is accepted.
  ///
  /// - Throws: `TraciveQueryError` with `.notAnNmid`.
  public static func qris(nmid: String) throws -> TraciveQuery {
    try TraciveQuery(kind: .qris, searchQueryIndex: "QRIS_" + QueryFolding.foldQrisNmid(nmid))
  }

  /// A QRIS, by the merchant PAN printed on a receipt: 18 digits, or 19 whose last digit is the
  /// Luhn check digit (dropped).
  ///
  /// The server maps a PAN to its NMID after the charge, so a PAN it has never seen is a billed
  /// miss. The local cache keeps this key apart from the NMID key: the same merchant checked by PAN
  /// and by NMID is two cache entries.
  ///
  /// - Throws: `TraciveQueryError` with `.notAPan`.
  public static func qris(pan: String) throws -> TraciveQuery {
    try TraciveQuery(kind: .qris, searchQueryIndex: "QRIS_" + QueryFolding.foldQrisPan(pan))
  }

  // MARK: - Description

  /// Redacted on purpose: `searchQueryIndex` embeds the raw phone number / email / account number,
  /// and a `print`, an `os_log` interpolation or a crash report would otherwise leak it.
  public var description: String { "TraciveQuery(kind: \(kind.rawValue), key: <redacted>)" }

  public var debugDescription: String { description }
}
