import Foundation

/// Why a query could not be built.
///
/// The raw values are the exact `reason` strings from `query-grammar-vectors.json` — or, for the
/// four `normalizePhoneNumber` reasons, from `phone-normalization-vectors.json` — which is the
/// cross-language anti-drift contract: Kotlin, Flutter, Swift and the backend all use these
/// spellings.
public enum QueryRejectionReason: String, CaseIterable, Hashable, Sendable {
  /// The phone number is not E.164 after folding. The server cannot up-convert a local number to
  /// E.164 (it does not know the dial code at that layer), so a local number would silently become
  /// a *different* entity — and the resulting miss is still billed.
  case notE164 = "not_e164"
  /// Country must be ISO 3166-1 **alpha-3**. The server would up-convert alpha-2, but then the
  /// local cache key would no longer match the server's key.
  case countryNotAlpha3 = "country_not_alpha3"
  /// `normalizePhoneNumber` was given a country or dial code with no letters and no digits.
  case emptyCountry = "empty_country"
  /// Something that looks like a country code but names no country. An alpha-2 code such as `ID`
  /// lands here: this SDK uses alpha-3 everywhere.
  case unknownCountry = "unknown_country"
  /// `normalizePhoneNumber` was given a number with no digits, or one that was only a trunk prefix.
  case emptyPhoneNumber = "empty_phone_number"
  /// The number carries a `+` whose dial code disagrees with the country named. Both cannot be
  /// right, and guessing which is would produce a key that can never match — billed as a miss.
  case countryConflict = "country_conflict"
  /// Empty account id. The write path drops rows with an empty account id, so such a key can never
  /// hit.
  case emptyAccountId = "empty_account_id"
  case emptyBankCode = "empty_bank_code"
  /// Empty value for a single-value input. Email is the only remaining user: an empty crypto
  /// address and an empty username platform have their own reasons below, so a caller can put the
  /// message on the field that is actually blank.
  case emptyValue = "empty_value"
  /// Empty crypto address. `CRYPTO_ETH_` can only miss, and a miss is billed.
  case emptyAddress = "empty_address"
  /// Empty username platform. `USERNAME__scammerx` cannot match any stored key.
  case emptyPlatform = "empty_platform"
  /// The email contains no `@`, so it cannot be an address. The server applies no shape validation
  /// of its own — `EMAIL_budi` is a legal record key, so it would be looked up, missed and billed.
  /// This rejection is the only thing that prevents the charge.
  case notAnEmail = "not_an_email"
  case emptyHandle = "empty_handle"
  case emptyChain = "empty_chain"
  /// The folded key is not a legal record key.
  case invalidDocumentId = "invalid_document_id"
}

/// Thrown by every `TraciveQuery` builder when the input cannot produce a key that could hit.
///
/// Validation runs **before** any network call: a key that cannot hit still costs a credit if it is
/// sent, so a rejected query is a saved credit.
///
/// The error deliberately carries **only** the reason — never the offending input. The rejected
/// values are phone numbers, emails and account numbers, and this type ends up in logs.
public struct TraciveQueryError: Error, Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, LocalizedError
{
  public let reason: QueryRejectionReason

  public init(_ reason: QueryRejectionReason) {
    self.reason = reason
  }

  /// The wire/fixture spelling of the reason, e.g. `"not_e164"`.
  public var rawReason: String { reason.rawValue }

  public var description: String { "TraciveQueryError(\(reason.rawValue))" }
  public var debugDescription: String { description }

  public var errorDescription: String? {
    switch reason {
    case .notE164:
      return "Phone numbers must be in E.164 form, e.g. +6281234567891."
    case .countryNotAlpha3:
      return "Country must be an ISO 3166-1 alpha-3 code, e.g. IDN."
    case .emptyCountry:
      return "A country or dial code is required, e.g. IDN or +62."
    case .unknownCountry:
      return "No country has that code. Use ISO 3166-1 alpha-3, e.g. IDN rather than ID."
    case .emptyPhoneNumber:
      return "The phone number has no digits."
    case .countryConflict:
      return
        "The number already carries a dial code that disagrees with the country given. Pass the "
        + "country the number actually belongs to, or drop the country and pass its own dial code."
    case .emptyAccountId:
      return "The account number is empty."
    case .emptyBankCode:
      return "The bank code is empty."
    case .emptyValue:
      return "The value is empty."
    case .emptyAddress:
      return "The crypto address is empty."
    case .emptyPlatform:
      return "The platform name is empty."
    case .notAnEmail:
      return "That is not an email address — it has no '@'."
    case .emptyHandle:
      return "The username handle is empty."
    case .emptyChain:
      return "The blockchain name is empty."
    case .invalidDocumentId:
      return "The resulting lookup key is not a valid document id."
    }
  }

  /// Lifts this into the SDK-wide error type, for call sites that catch a single error family.
  public var asTraciveError: TraciveError { .invalidQuery(self) }
}
