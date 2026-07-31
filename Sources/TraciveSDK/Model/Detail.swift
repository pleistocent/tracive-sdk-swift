import Foundation

/// How much of the report body to ask for (§4).
///
/// The raw values are lowercase because that is exactly what the request body carries:
/// `{ "creditSource": "USER", "detail": "minimal", … }`.
///
/// `.full` adds `topChronologies` and `comments`. Those two fields are never cached — see the note
/// on `CheckResult.cacheableCopy()`.
public enum Detail: String, Codable, CaseIterable, Hashable, Sendable {
  case minimal = "minimal"
  case full = "full"
}
