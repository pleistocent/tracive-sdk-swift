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
  let international = trimmedCanonically(phoneNumber).hasPrefix("+")
  if international, !digits.hasPrefix(dialCode) {
    throw TraciveQueryError(.countryConflict)
  }

  if digits.hasPrefix("00" + dialCode) {
    digits = String(digits.dropFirst(2 + dialCode.count))
  } else if digits.hasPrefix(dialCode), international || !isNationalNumber(dialCode, digits) {
    // Without a `+`, digits that are a national number merely starting with the dial code's own
    // digits keep them (Kazakh 701…).
    digits = String(digits.dropFirst(dialCode.count))
  }

  switch dialCode {
  // Russia and Kazakhstan: the trunk prefix is 8, and a local number is 10 digits.
  case "7":
    if digits.hasPrefix("8"), digits.count == 11 { digits = String(digits.dropFirst()) }
  // Italy and San Marino: the leading 0 IS part of the number for landlines.
  case "39", "378":
    break
  // Côte d'Ivoire, Benin and the Republic of the Congo have no trunk prefix, and their regulators
  // require the 0 after the country code (+225 07…, +229 01…, +242 06…).
  case "225", "229", "242":
    break
  // Hungary: the trunk prefix is 06. A national number may start with 6 (Szeged is 62), so the pair
  // is dropped, never a 0 and then a 6 on its own.
  case "36":
    if digits.hasPrefix("06") { digits = String(digits.dropFirst(2)) }
    digits = String(digits.drop(while: { $0 == "0" }))
  // A trunk 8 (Lithuania's until March 2024, 0 since). Some national numbers start with 8
  // themselves (Belarusian 801 and Lithuanian 800 freephone, Uzbek 88 mobile), so the 8 goes only
  // when exactly a national number's length follows it.
  case "375", "370", "992", "993", "998":
    if let afterTrunk = digitsAfterTrunk8[dialCode], digits.hasPrefix("8"),
      digits.count == afterTrunk + 1
    {
      digits = String(digits.dropFirst())
    }
    digits = String(digits.drop(while: { $0 == "0" }))
  // North America: the trunk prefix is 1, and a local number is 10 digits.
  case "1":
    if digits.hasPrefix("1"), digits.count == 11 { digits = String(digits.dropFirst()) }
  // Everywhere else, including Indonesia, the UK and Germany: the trunk prefix is 0.
  default:
    digits = String(digits.drop(while: { $0 == "0" }))
  }

  // A number that is nothing but zeros is refused here, not left to `phone()`. For most countries the
  // trunk-prefix rule strips the zeros away and the emptiness check above catches it — but Italy, San
  // Marino, Côte d'Ivoire, Benin, the Congo, North America and Russia do not strip leading zeros, so
  // `+390000000` survived, matched E.164, reached the network and was billed for a miss it could
  // only ever be. Refusing it here also makes the reason the same in every country instead of
  // `empty_phone_number` in Indonesia and `not_e164` in Italy for the identical input.
  if digits.isEmpty || digits.allSatisfy({ $0 == "0" }) {
    throw TraciveQueryError(.emptyPhoneNumber)
  }
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

/// Every length a national number can have, for the dial codes whose national numbers can start
/// with the dial code's own digits (libphonenumber 9.0.42 metadata, all number types). The same
/// table as `nationalNumberLengths` in `phone-normalization-vectors.json`, which the tests sweep.
private let nationalNumberLengths: [String: Set<Int>] = [
  "7": [10, 14],
  "20": [8, 9, 10],
  "27": [5, 6, 7, 8, 9, 10],
  "31": [5, 6, 7, 8, 9, 10, 11],
  "32": [8, 9],
  "33": [9],
  "36": [8, 9],
  "39": [6, 7, 8, 9, 10, 11, 12],
  "41": [9, 12],
  "43": [4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
  "45": [8],
  "46": [6, 7, 8, 9, 10, 12],
  "47": [5, 8],
  "48": [6, 7, 8, 9, 10],
  "49": [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  "51": [8, 9],
  "53": [6, 7, 8, 10],
  "55": [8, 9, 10, 11],
  "62": [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17],
  "63": [6, 8, 9, 10, 11, 12, 13],
  "65": [8, 10, 11],
  "66": [8, 9, 10, 13],
  "84": [7, 8, 9, 10],
  "90": [7, 10, 12, 13],
  "91": [8, 9, 10, 11, 12, 13],
  "92": [8, 9, 10, 11, 12],
  "95": [6, 7, 8, 9, 10],
  "213": [8, 9],
  "216": [8],
  "218": [9],
  "220": [7, 9],
  "222": [8],
  "230": [7, 8, 10],
  "231": [7, 8, 9],
  "233": [8, 9],
  "238": [7],
  "241": [7, 8],
  "243": [7, 8, 9, 10],
  "244": [9],
  "247": [5, 6],
  "250": [8, 9],
  "251": [9],
  "252": [6, 7, 8, 9],
  "255": [9],
  "262": [9],
  "266": [8],
  "267": [7, 8, 10],
  "290": [4, 5],
  "298": [6],
  "299": [6],
  "355": [6, 7, 8, 9],
  "358": [5, 6, 7, 8, 9, 10, 11, 12],
  "359": [6, 7, 8, 9, 12],
  "370": [8],
  "373": [8],
  "376": [6, 8, 9],
  "377": [8, 9],
  "379": [6, 7, 8, 9, 10, 11, 12],
  "380": [9, 10],
  "383": [8, 9, 10, 11, 12],
  "386": [5, 6, 7, 8],
  "387": [8, 9],
  "421": [6, 7, 9],
  "500": [5],
  "501": [7, 11],
  "502": [8, 11],
  "503": [7, 8, 11],
  "506": [8, 10],
  "507": [7, 8, 10, 11],
  "508": [6, 9],
  "590": [9],
  "594": [9],
  "596": [9],
  "677": [5, 7],
  "679": [7, 11],
  "680": [7],
  "683": [4, 7],
  "685": [5, 6, 7, 10],
  "850": [8, 10],
  "853": [7, 8],
  "855": [8, 9, 10],
  "886": [7, 8, 9, 10, 11],
  "960": [7, 10],
  "961": [7, 8],
  "962": [8, 9],
  "963": [8, 9],
  "965": [7, 8],
  "968": [7, 8, 9],
  "971": [5, 6, 7, 8, 9, 10, 11, 12],
  "972": [7, 8, 9, 10, 11, 12],
  "973": [8],
  "976": [8, 9, 10],
  "992": [9],
  "994": [9],
  "996": [9, 10],
  "998": [9],
]

/// Digits that start with `dialCode` are a national number when their length is a national length
/// and their length without the dial code is not. When both are (Indonesia's `62812…`, Italy's
/// `393…`), the dial code is stripped as before, so a number typed with its country code never
/// changes key.
private func isNationalNumber(_ dialCode: String, _ digits: String) -> Bool {
  guard let lengths = nationalNumberLengths[dialCode] else { return false }
  return lengths.contains(digits.count) && !lengths.contains(digits.count - dialCode.count)
}

/// Countries whose trunk prefix is 8, with how many digits follow that 8. Belarus counts the 0 it
/// writes after the 8 (`8 029 123 45 67`); the leading-zero strip removes it afterwards. Source: ITU
/// "Dialling procedures" and each country's numbering plan filed with the ITU.
private let digitsAfterTrunk8: [String: Int] = [
  "375": 10,  // Belarus
  "370": 8,  // Lithuania
  "992": 9,  // Tajikistan
  "993": 8,  // Turkmenistan
  "998": 9,  // Uzbekistan
]

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
