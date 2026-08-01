import Foundation

/// Record-key legality check, applied to every key a `TraciveQuery` builds.
///
/// The scammer index is keyed by document id, so an illegal key cannot hit — and a miss is
/// billed regardless. Rejecting locally is therefore a saved credit, not just tidiness.
///
/// Rules (from the fixture's `rejected[]` entries and the API's own constraints):
/// - must not be empty
/// - must not contain `/`
/// - must not match `__.*__` (the API reserves that shape, e.g. `__proto__`)
/// - must not be `.` or `..`
/// - must not exceed 1500 UTF-8 bytes
///
/// The fixture lists a sixth rule — *must not contain a lone/unpaired UTF-16 surrogate* — which is
/// deliberately **not** implemented here because it is unreachable in Swift, not because it was
/// overlooked. A `String` cannot hold a lone surrogate: ill-formed input is replaced with U+FFFD at
/// construction, and `Unicode.Scalar(0xD800)` returns `nil`. Both were verified on this toolchain,
/// and `QueryGrammarTests` pins them, so if that ever changes the omission becomes visible instead
/// of silent. The rule matters in the other SDKs, where a string can carry one.
enum DocumentIdGuard {

  /// The API's key size limit.
  static let maxUtf8ByteCount = 1500

  static func validate(_ documentId: String) throws {
    guard !documentId.isEmpty else {
      throw TraciveQueryError(.invalidDocumentId)
    }
    guard !documentId.contains("/") else {
      throw TraciveQueryError(.invalidDocumentId)
    }
    guard documentId != "." && documentId != ".." else {
      throw TraciveQueryError(.invalidDocumentId)
    }
    guard !matchesReservedPattern(documentId) else {
      throw TraciveQueryError(.invalidDocumentId)
    }
    guard documentId.utf8.count <= maxUtf8ByteCount else {
      throw TraciveQueryError(.invalidDocumentId)
    }
  }

  /// `__.*__` — leading and trailing double underscore with at least four characters total, so
  /// `__proto__` and `____` match while `___` (three underscores) does not.
  ///
  /// Knowingly slightly stricter than the server. The server's regex is `^__.*__$`, and in
  /// JavaScript `.` does not match a newline, so `"__a\nb__"` is accepted server-side and rejected
  /// here (confirmed by running that regex). The divergence is left in place: over-rejection is the
  /// safe direction — a rejected query costs nothing, whereas accepting a key the server refuses
  /// costs a credit for a request that cannot hit — and no builder can reach this branch anyway.
  /// Not because folding strips newlines (an interior newline survives the fold), but because the
  /// guard runs on the *folded key*, which every builder prefixes with its kind: the string reaching
  /// the guard starts with `USERNAME_`, `BANK_` and so on, so it can never begin with `__`.
  /// Matching JavaScript's newline quirk exactly would add a subtlety to all three SDKs in order to
  /// be *more* permissive about a key none of them can construct.
  private static func matchesReservedPattern(_ documentId: String) -> Bool {
    documentId.utf8.count >= 4 && documentId.hasPrefix("__") && documentId.hasSuffix("__")
  }
}
