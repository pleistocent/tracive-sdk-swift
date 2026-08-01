import Foundation

/// Record-key legality check, applied to every key a `TraciveQuery` builds.
///
/// The scammer index is keyed by document id, so an illegal key cannot hit — and a miss is
/// billed regardless. Rejecting locally is therefore a saved credit, not just tidiness.
///
/// Rules (from the fixture's `rejected[]` entries and the API's own constraints):
/// - must not be empty
/// - must not contain `/`
/// - must not match `^__.*__$` (the API reserves that shape, e.g. `__proto__`). Matched with
///   JavaScript's semantics, which is not the obvious reading — see `matchesReservedPattern`.
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

  /// The line terminators JavaScript's `.` refuses to match.
  ///
  /// Exactly `LineTerminator` from the ECMAScript grammar. U+0085 NEL is deliberately **absent**:
  /// ICU treats it as a line terminator — so `NSRegularExpression` would — but JavaScript does not,
  /// and `"__a\u{0085}b__"` really is reserved server-side. Verified by running the pattern.
  private static let javaScriptLineTerminators: Set<Unicode.Scalar> = [
    "\u{000A}", "\u{000D}", "\u{2028}", "\u{2029}",
  ]

  /// `^__.*__$` — the API's reserved-key pattern, matched with JavaScript's semantics.
  ///
  /// Leading and trailing double underscore with at least four characters, so `__proto__` and
  /// `____` match while `___` does not. The subtle half is the middle: the pattern carries no `s`
  /// flag, so `.` does not match a line terminator and `.*` cannot cover a middle containing one.
  /// `"__a\nb__"` is therefore **accepted** by the server, and a guard written as
  /// `hasPrefix("__") && hasSuffix("__")` — which this one was — rejects it.
  ///
  /// This SDK used to keep that divergence deliberately, on the argument that over-rejection is the
  /// cheap direction and no builder can produce a key starting with `__` anyway (the guard runs on
  /// the *folded* key, which every builder prefixes with its kind). The shared fixture now pins the
  /// server's own answer, so the guard matches it instead: three SDKs quietly disagreeing with the
  /// contract they all vendor is the more expensive kind of wrong, and the argument for diverging
  /// was never that the divergence was *right*.
  ///
  /// There is no `m` flag either, so `$` does not match before a trailing newline — hence the
  /// suffix test, rather than any tolerance for a trailing terminator.
  private static func matchesReservedPattern(_ documentId: String) -> Bool {
    let scalars = Array(documentId.unicodeScalars)
    guard scalars.count >= 4,
      scalars[0] == "_", scalars[1] == "_",
      scalars[scalars.count - 2] == "_", scalars[scalars.count - 1] == "_"
    else {
      return false
    }
    // `^__` and `__$` are anchored, so `.*` must cover exactly the scalars between them.
    return !scalars[2..<(scalars.count - 2)].contains(where: javaScriptLineTerminators.contains)
  }
}
