import Foundation

// Lenient readers used by the model layer.
//
// Rule from the spec: "Unknown JSON fields must be ignored, not fatal (forward compatibility
// with phase 2)." `Codable` already ignores unknown *keys*; these helpers extend the same tolerance
// to a known key whose value arrives in an unexpected-but-recoverable shape (an integer sent as a
// JSON string, a count sent as a double, an instant we cannot parse). Anything genuinely
// load-bearing (`found`, `riskTier`, `sub`, …) is still decoded strictly so a broken payload fails
// loudly instead of silently reading as "clean".
//
// The methods are prefixed `tracive` because this is an extension on a stdlib type: a plain
// `decodeIfPresent`-style name could collide with an extension declared elsewhere in the module.
extension KeyedDecodingContainer {

  /// Reads an optional string; a value of a different type reads as `nil`.
  func traciveStringIfPresent(_ key: Key) -> String? {
    (try? decodeIfPresent(String.self, forKey: key)) ?? nil
  }

  /// Reads an `Int`, tolerating a JSON double (truncated) or a numeric string.
  func traciveIntIfPresent(_ key: Key) -> Int? {
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
    if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
    return nil
  }

  /// Reads an `Int`, falling back to `defaultValue` when the key is absent or unusable.
  func traciveInt(_ key: Key, default defaultValue: Int) -> Int {
    traciveIntIfPresent(key) ?? defaultValue
  }

  /// Reads an `Int64` (used for `cacheTtlSeconds`), tolerating double/string encodings.
  func traciveInt64IfPresent(_ key: Key) -> Int64? {
    if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
    if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
    return nil
  }

  /// Reads a `Bool`, tolerating `0`/`1` and `"true"`/`"false"`.
  func traciveBool(_ key: Key, default defaultValue: Bool) -> Bool {
    if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
    if let value = try? decodeIfPresent(String.self, forKey: key) { return Bool(value) ?? defaultValue }
    return defaultValue
  }

  /// Reads an ISO-8601 instant. An unparseable or wrongly-typed value reads as `nil`.
  func traciveDateIfPresent(_ key: Key) -> Date? {
    guard let raw = traciveStringIfPresent(key) else { return nil }
    return TraciveISO8601.date(from: raw)
  }

  /// Reads `[String]`, defaulting to `defaultValue` when absent or unusable.
  func traciveStringArray(_ key: Key, default defaultValue: [String]) -> [String] {
    ((try? decodeIfPresent([String].self, forKey: key)) ?? nil) ?? defaultValue
  }

  /// Reads `currency -> amount`, defaulting to `defaultValue` when absent or unusable.
  func traciveDoubleMap(_ key: Key, default defaultValue: [String: Double]) -> [String: Double] {
    ((try? decodeIfPresent([String: Double].self, forKey: key)) ?? nil) ?? defaultValue
  }

  /// Reads a decodable value, tolerating a malformed element list by reading it as absent.
  func traciveDecodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
    (try? decodeIfPresent(T.self, forKey: key)) ?? nil
  }
}

extension KeyedEncodingContainer {

  /// Encodes an instant as ISO-8601 UTC, omitting the key when the instant is absent.
  mutating func traciveEncodeISO8601IfPresent(_ date: Date?, forKey key: Key) throws {
    guard let date else { return }
    try encode(TraciveISO8601.string(from: date), forKey: key)
  }

  /// Encodes an instant as ISO-8601 UTC.
  mutating func traciveEncodeISO8601(_ date: Date, forKey key: Key) throws {
    try encode(TraciveISO8601.string(from: date), forKey: key)
  }
}
