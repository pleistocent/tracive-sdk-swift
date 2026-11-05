import Foundation

/// A calendar date with no time and no time zone: the day the transaction happened, as the user's
/// own statement shows it. Sent as `YYYY-MM-DD`.
///
/// ```swift
/// ReportIncidentDate(year: 2026, month: 11, day: 3)   // nil for a day that does not exist
/// ReportIncidentDate(iso8601: "2026-11-03")           // nil unless exactly YYYY-MM-DD
/// ReportIncidentDate(transaction.timestamp)           // the device's local day of that instant
/// ```
///
/// It cannot hold an invalid date, so `openReportForm` has nothing to reject about its shape. A day
/// after the device's local today is refused there with `.incidentDateInFuture`.
public struct ReportIncidentDate: Hashable, Comparable, Sendable, CustomStringConvertible {

  public let year: Int
  public let month: Int
  public let day: Int

  /// `nil` when the day does not exist in the Gregorian calendar (30 February, month 13) or the
  /// year is outside 1...9999, which `YYYY-MM-DD` cannot write.
  public init?(year: Int, month: Int, day: Int) {
    guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
      day <= Self.daysIn(month: month, year: year)
    else { return nil }
    self.year = year
    self.month = month
    self.day = day
  }

  /// Parses exactly `YYYY-MM-DD`: four digits, two, two, ASCII only. `nil` for anything else,
  /// including a timestamp with a time part.
  public init?(iso8601 string: String) {
    let bytes = Array(string.utf8)
    guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else {
      return nil
    }
    func number(_ range: Range<Int>) -> Int? {
      var value = 0
      for byte in bytes[range] {
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
        value = value * 10 + Int(byte - UInt8(ascii: "0"))
      }
      return value
    }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10) else {
      return nil
    }
    self.init(year: year, month: month, day: day)
  }

  /// The day `date` falls on in `timeZone`, the device's own by default.
  public init(_ date: Date, timeZone: TimeZone = .current) {
    // Gregorian, never `Calendar.current`: on a device set to the Buddhist or Japanese calendar the
    // current calendar answers year 2569 or 8 for 2026.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    // Every instant a `Date` can hold lands on a real Gregorian day, so only a year outside
    // 1...9999 can miss, and that is clamped rather than trapped.
    let year = min(max(parts.year ?? 1, 1), 9999)
    self.year = year
    self.month = parts.month ?? 1
    self.day = min(parts.day ?? 1, Self.daysIn(month: parts.month ?? 1, year: year))
  }

  /// `YYYY-MM-DD`, zero-padded.
  public var iso8601: String {
    func padded(_ value: Int, _ width: Int) -> String {
      let digits = String(value)
      return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
    return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
  }

  public var description: String { iso8601 }

  public static func < (lhs: ReportIncidentDate, rhs: ReportIncidentDate) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  private static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2:
      let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }
}
