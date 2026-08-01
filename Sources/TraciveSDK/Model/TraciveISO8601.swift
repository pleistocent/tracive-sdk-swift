import Foundation

/// The single ISO-8601 gateway used by every instant on the wire.
///
/// The spec describes `firstReportOn`, `lastReportOn`, `nextResetAt`, `memberSince` and
/// `fetchedAt` as "ISO-8601 UTC". All parsing and formatting goes through here so the three SDKs
/// agree byte-for-byte and so we allocate the (expensive) formatters exactly once.
///
/// Parsing accepts both the whole-second form (`2026-07-09T10:00:00Z`) and the fractional-second
/// form (`2026-07-09T10:00:00.123Z`), and any RFC 3339 offset (`+07:00`). Formatting always emits
/// UTC with whole seconds, so instants round-trip through the cache at **second** precision — which
/// is far below the smallest cache TTL (1 hour) and therefore harmless.
public enum TraciveISO8601 {

  /// Parses an ISO-8601 instant. Returns `nil` for anything unparseable — callers treat a bad
  /// instant as "absent" rather than failing the whole response (forward compatibility).
  public static func date(from string: String) -> Date? {
    shared.date(from: string)
  }

  /// Formats an instant as ISO-8601 UTC with whole seconds.
  public static func string(from date: Date) -> String {
    shared.string(from: date)
  }

  private static let shared = FormatterBox()
}

/// `ISO8601DateFormatter` is not `Sendable`, so the shared instances live behind a lock. This keeps
/// the type usable from Swift 6 strict-concurrency builds without forcing an allocation per call.
private final class FormatterBox: @unchecked Sendable {
  private let lock = NSLock()
  private let fractional: ISO8601DateFormatter
  private let whole: ISO8601DateFormatter

  init() {
    let fractional = ISO8601DateFormatter()
    fractional.timeZone = TimeZone(secondsFromGMT: 0)
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fractional = fractional

    let whole = ISO8601DateFormatter()
    whole.timeZone = TimeZone(secondsFromGMT: 0)
    whole.formatOptions = [.withInternetDateTime]
    self.whole = whole
  }

  func date(from string: String) -> Date? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return fractional.date(from: trimmed) ?? whole.date(from: trimmed)
  }

  func string(from date: Date) -> String {
    lock.lock()
    defer { lock.unlock() }
    return whole.string(from: date)
  }
}
