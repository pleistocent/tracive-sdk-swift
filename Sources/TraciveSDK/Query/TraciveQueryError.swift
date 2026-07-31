import Foundation

/// Why a query could not be built (§3).
///
/// The raw values are the exact `reason` strings from `query-grammar-vectors.json`, which is the
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
  /// Empty account id. The write path drops rows with an empty account id, so such a key can never
  /// hit.
  case emptyAccountId = "empty_account_id"
  case emptyBankCode = "empty_bank_code"
  /// Empty value for a single-value input (email, crypto address, username platform).
  case emptyValue = "empty_value"
  case emptyHandle = "empty_handle"
  case emptyChain = "empty_chain"
  /// The folded key is not a legal record key.
  case invalidDocumentId = "invalid_document_id"
}

/// Thrown by every `TraciveQuery` builder when the input cannot produce a key that could hit.
///
/// Validation runs **before** any network call: a key that cannot hit still costs a credit if it is
/// sent (§3.2), so a rejected query is a saved credit.
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
    case .emptyAccountId:
      return "The account number is empty."
    case .emptyBankCode:
      return "The bank code is empty."
    case .emptyValue:
      return "The value is empty."
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
