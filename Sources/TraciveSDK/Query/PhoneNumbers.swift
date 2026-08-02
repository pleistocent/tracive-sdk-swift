import Foundation

/// Turns a phone number written the way people in a country actually write it into E.164.
///
/// `TraciveQuery.phone` deliberately refuses a local format such as `081234567891`, and says why:
/// the SDK cannot know the caller's dial code, and a wrong guess still costs a credit. This function
/// is where that missing dial code comes from, so the strictness downstream stays intact:
///
/// ```swift
/// try TraciveQuery.phone(e164: try normalizePhoneNumber("IDN", "0857-1860-9079"))  // +6285718609079
/// try TraciveQuery.phone(e164: try normalizePhoneNumber("+62", "0857 1860 9079"))  // the same key
/// ```
///
/// It is a free function on purpose: a partner needs the E.164 form for their own records, logging
/// and outbound messaging, not only for a Tracive lookup.
///
/// The rules are a deliberate copy of the Tracive app's normalizer, heuristics included — if the app
/// folded a number one way and this SDK another, one person would become two record keys, and a
/// report filed in the app would be invisible to a check made here. `phone-normalization-vectors.json`
/// pins the agreement and is vendored byte-identically into all four SDK repositories.
///
/// - Parameters:
///   - countryOrDialCode: an ISO 3166-1 **alpha-3** code (`IDN`, `USA` — case-insensitive) or a dial
///     code with or without `+` (`+62`, `62`). Told apart by shape: letters mean alpha-3, digits mean
///     a dial code. Alpha-2 (`ID`) is refused, because this SDK speaks alpha-3 everywhere.
///   - phoneNumber: the number as written locally. Spaces, dashes, brackets and a leading `+` are all
///     fine.
/// - Returns: the number in E.164, e.g. `+6285718609079`. Never an empty string.
/// - Throws: `TraciveQueryError` with `.emptyCountry`, `.unknownCountry`, `.emptyPhoneNumber` or
///   `.countryConflict`.
public func normalizePhoneNumber(_ countryOrDialCode: String, _ phoneNumber: String) throws -> String {
  let dialCode = try resolveDialCode(countryOrDialCode)
  var digits = phoneNumber.filter { $0.isASCII && $0.isNumber }
  if digits.isEmpty { throw TraciveQueryError(.emptyPhoneNumber) }

  // A leading `+` is the caller stating "this is already international". If the code that follows
  // disagrees with the country they named, the two arguments contradict each other, and guessing
  // which one is right is exactly what costs a credit: ("IDN", "+64857…") used to yield
  // +626485718609079, a New Zealand number wearing an Indonesian dial code.
  //
  // This is the one place this function departs from the Tracive app's normalizer. It is safe to
  // depart here precisely because every input it rejects produced an unusable key in the app too.
  if phoneNumber.contains("+"), !digits.hasPrefix(dialCode) {
    throw TraciveQueryError(.countryConflict)
  }

  if digits.hasPrefix("00" + dialCode) {
    digits = String(digits.dropFirst(2 + dialCode.count))
  } else if digits.hasPrefix(dialCode) {
    digits = String(digits.dropFirst(dialCode.count))
  }

  switch dialCode {
  // Russia and Kazakhstan: the trunk prefix is 8, and a local number is 10 digits.
  case "7":
    if digits.hasPrefix("8"), digits.count == 11 { digits = String(digits.dropFirst()) }
  // Italy and San Marino: the leading 0 IS part of the number for landlines.
  case "39", "378":
    break
  // North America: the trunk prefix is 1, and a local number is 10 digits.
  case "1":
    if digits.hasPrefix("1"), digits.count == 11 { digits = String(digits.dropFirst()) }
  // Everywhere else, including Indonesia, the UK and Germany: the trunk prefix is 0.
  default:
    digits = String(digits.drop(while: { $0 == "0" }))
  }

  if digits.isEmpty { throw TraciveQueryError(.emptyPhoneNumber) }
  return "+" + dialCode + digits
}

/// Normalizes `phoneNumber` for a known `country`.
///
/// Prefer this over the string form when the country is known at compile time: a typo in `"IDN"` is
/// found at run time, a typo in `Country.idn` is not compiled.
public func normalizePhoneNumber(_ country: Country, _ phoneNumber: String) throws -> String {
  try normalizePhoneNumber(country.dialCode, phoneNumber)
}

/// Alpha-3 in, dial code out; or digits in, the same digits out.
private func resolveDialCode(_ countryOrDialCode: String) throws -> String {
  let trimmed = countryOrDialCode.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { throw TraciveQueryError(.emptyCountry) }

  let digits = trimmed.filter { $0.isASCII && $0.isNumber }
  if !digits.isEmpty {
    let stripped = String(digits.drop(while: { $0 == "0" }))
    if stripped.isEmpty { throw TraciveQueryError(.emptyCountry) }
    return stripped
  }

  guard let country = Country.fromAlpha3(trimmed) else { throw TraciveQueryError(.unknownCountry) }
  return country.dialCode
}
