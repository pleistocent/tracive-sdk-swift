import Foundation

/// A validated, folded lookup key for one identifier.
///
/// Build one with a factory — `TraciveQuery.phone(e164:)`, `.email(value:)`,
/// `.bankAccount(countryAlpha3:bankCode:account:)`, `.iban(iban:)`, `.crypto(chain:address:)`,
/// `.username(platform:handle:)` — and hand it to `checkScammer`.
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
/// PHONE / EMAIL / BANK / CRYPTO / USERNAME. A `DOMAIN_…` key could never hit, and the miss would
/// still be charged. Do not add one.
public struct TraciveQuery: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{

  /// Which of the five backend media categories this key belongs to.
  public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
    case phone = "PHONE"
    case email = "EMAIL"
    /// Covers both `bankAccount(countryAlpha3:bankCode:account:)` and `iban(iban:)`.
    case bank = "BANK"
    case crypto = "CRYPTO"
    case username = "USERNAME"
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

  // MARK: - Description

  /// Redacted on purpose: `searchQueryIndex` embeds the raw phone number / email / account number,
  /// and a `print`, an `os_log` interpolation or a crash report would otherwise leak it.
  public var description: String { "TraciveQuery(kind: \(kind.rawValue), key: <redacted>)" }

  public var debugDescription: String { description }
}
