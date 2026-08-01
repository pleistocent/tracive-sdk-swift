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
  private static func matchesReservedPattern(_ documentId: String) -> Bool {
    documentId.utf8.count >= 4 && documentId.hasPrefix("__") && documentId.hasSuffix("__")
  }
}
