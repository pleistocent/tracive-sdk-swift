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
  var digits = asciiDigits(of: phoneNumber)
  if digits.isEmpty { throw TraciveQueryError(.emptyPhoneNumber) }

  // A leading `+` is the caller stating "this is already international". If the code that follows
  // disagrees with the country they named, the two arguments contradict each other, and guessing
  // which one is right is exactly what costs a credit: ("IDN", "+64857…") used to yield
  // +626485718609079, a New Zealand number wearing an Indonesian dial code.
  //
  // Three deliberate departures from the Tracive app's normalizer live here, and they are not the
  // same kind of thing. A dial code that disagrees with the country named is safe to reject: every
  // such input produced an unusable key in the app too. `+00<dial>` is not — the app accepts it and
  // folds it correctly, so here the SDK is genuinely stricter. That is the intended trade: `+` and
  // `00` are alternative spellings, not stackable ones; what follows `+` must be a country code,
  // and `00` is none. An earlier version of this comment claimed the first reason covered both.
  //
  // A third, quieter one: emptiness is re-checked *after* the trunk prefix is stripped, so `000`,
  // `62` and `1` are refused. The app folds those to `+62` and `+1`, which cannot match any record,
  // so this belongs with the first kind — safe, not stricter.
  if trimmedCanonically(phoneNumber).hasPrefix("+"),
    !digits.hasPrefix(dialCode)
  {
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
  let trimmed = trimmedCanonically(countryOrDialCode)
  if trimmed.isEmpty { throw TraciveQueryError(.emptyCountry) }

  let digits = asciiDigits(of: trimmed)
  if !digits.isEmpty {
    let stripped = String(digits.drop(while: { $0 == "0" }))
    if stripped.isEmpty { throw TraciveQueryError(.emptyCountry) }
    return stripped
  }

  guard let country = Country.fromAlpha3(trimmed) else { throw TraciveQueryError(.unknownCountry) }
  return country.dialCode
}

/// The ASCII digits in `value`, per Unicode **scalar**.
///
/// Not `filter { $0.isASCII && $0.isNumber }`. `String.filter` yields `Character`s, and a Character
/// is a grapheme cluster: `"9" + U+FE0F` is one Character whose `isASCII` is false, so that spelling
/// silently *dropped* the digit. Kotlin iterates chars, Dart code units and JavaScript code points —
/// all three keep it. This SDK returned `+628571860909` where the other three returned
/// `+6285718609079`: one person, two record keys, no error, and the miss still billed.
private func asciiDigits(of value: String) -> String {
  String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }))
}

/// The characters trimmed from a country or dial code, defined here rather than delegated.
///
/// Not `trimmingCharacters(in: .whitespacesAndNewlines)`.
///
/// ASCII whitespace only, and deliberately **not** U+FEFF. A byte-order mark inside a data value
/// is an encoding fault upstream; swallowing it here would tell a partner their pipeline is clean
/// while the same mark waits to land in a phone number or an account id, where nothing trims it
/// and the key comes out wrong. Each platform's own trim() disagrees about this — Kotlin's follows
/// Unicode White_Space plus U+FEFF, JavaScript's strips a different set — which made one input
/// behave two ways across the four SDKs.
private let trimmedScalars: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"]

private func trimmedCanonically(_ value: String) -> String {
  var scalars = Array(value.unicodeScalars)
  while let first = scalars.first, trimmedScalars.contains(first) { scalars.removeFirst() }
  while let last = scalars.last, trimmedScalars.contains(last) { scalars.removeLast() }
  return String(String.UnicodeScalarView(scalars))
}
