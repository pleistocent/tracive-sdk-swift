import Foundation

/// The string-folding grammar behind `searchQueryIndex`.
///
/// Every rule here is transcribed from `query-grammar-vectors.json` (`rules`), which is vendored
/// verbatim into all three SDK repos and is the anti-drift contract. **Do not "improve" a fold**:
/// the folded key is both the server's document id and the local cache key, so a client-side
/// deviation splits one entity into two — and a miss is billed.
///
/// The order of operations inside each fold is load-bearing and is stated per function.
///
/// ## Why this file hand-writes its character classes
/// The backend folds in **JavaScript**, so byte-identical output means reimplementing *JS*
/// semantics, not Foundation's. The two disagree in both directions, verified by running each
/// against the fixture's `crossLanguageSemantics` set:
///
/// - `trimmingCharacters(in: .whitespacesAndNewlines)` **strips U+200B**, which JS `trim()` keeps,
///   and **does not strip U+FEFF**, which JS `trim()` removes.
/// - `Character.isWhitespace` (Unicode `White_Space`) does not match U+FEFF, but JS regex `\s`
///   does — so an NBSP-and-BOM-bearing account number folded differently on the two sides.
/// - `CharacterSet.decimalDigits` matches Arabic-Indic digits; JS `\D` is exactly `[^0-9]`, so the
///   server *strips* those rather than converting them.
///
/// Case mapping is the one place the platforms already agree: Swift's `uppercased()`/`lowercased()`
/// (no locale argument) are locale-invariant full mappings, like JS — `ß` → `SS` and `İ` → `i` +
/// U+0307. Never introduce a locale-taking variant here.
enum QueryFolding {

  // MARK: - JavaScript string semantics
  //
  // ECMAScript `WhiteSpace ∪ LineTerminator`, which is *exactly* both the set that
  // `String.prototype.trim()` strips and the set that regex `\s` matches. Transcribed from
  // `crossLanguageSemantics.trimSet.codepoints` in the fixture; `QueryGrammarTests` asserts this
  // set against that list so the two cannot drift apart silently.
  //
  // U+200B (ZWSP) is deliberately **absent**: JS does not treat it as whitespace, so a key carrying
  // one keeps it — and then misses. Mirroring the server is the contract; guessing what the user
  // meant is not.

  static let javaScriptWhitespace: Set<Unicode.Scalar> = [
    "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{00A0}", "\u{1680}",
    "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}",
    "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}",
    "\u{FEFF}",
  ]

  /// `String.prototype.trim()`.
  ///
  /// Operates on Unicode *scalars*, not `Character`s: JS trims per code unit, so a leading space
  /// followed by a combining mark loses only the space. Trimming by grapheme cluster would drop
  /// the combining mark with it and produce a different key.
  static func jsTrim(_ raw: String) -> String {
    let scalars = Array(raw.unicodeScalars)
    var start = 0
    var end = scalars.count
    while start < end, javaScriptWhitespace.contains(scalars[start]) { start += 1 }
    while end > start, javaScriptWhitespace.contains(scalars[end - 1]) { end -= 1 }
    return String(String.UnicodeScalarView(scalars[start..<end]))
  }

  /// `value.replace(/[\s-]/g, "")` — the bank-account strip. Removes every JS-whitespace scalar and
  /// the ASCII hyphen anywhere in the string, not just at the ends.
  static func jsStripWhitespaceAndHyphen(_ raw: String) -> String {
    String(
      String.UnicodeScalarView(
        raw.unicodeScalars.filter { !javaScriptWhitespace.contains($0) && $0 != "-" }
      )
    )
  }

  // MARK: - PHONE

  /// `PHONE_<value>`: strip every character that is not an ASCII digit, preserving a single leading
  /// `+`. No case folding (digits only).
  ///
  /// Then reject anything that is not E.164 (`^\+[1-9]\d{6,14}$`). The server does **not** reconcile
  /// a local-format number against its E.164 form, so `081234567891` would index as a different
  /// entity than `+6281234567891` — and the resulting miss is still billed.
  static func foldPhone(_ raw: String) throws -> String {
    // Trim first so a leading `+` preceded by whitespace still counts as leading.
    let trimmed = jsTrim(raw)
    let hasLeadingPlus = trimmed.hasPrefix("+")
    let digits = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter(isAsciiDigit)))
    let folded = hasLeadingPlus ? "+" + digits : digits

    guard isE164(folded) else { throw TraciveQueryError(.notE164) }
    return folded
  }

  /// `^\+[1-9]\d{6,14}$` — a `+`, a non-zero country-code digit, then 6–14 more ASCII digits.
  static func isE164(_ value: String) -> Bool {
    guard value.hasPrefix("+") else { return false }
    let digits = value.dropFirst()
    guard digits.count >= 7, digits.count <= 15 else { return false }
    guard let first = digits.unicodeScalars.first, first != "0" else { return false }
    return digits.unicodeScalars.allSatisfy(isAsciiDigit)
  }

  // MARK: - EMAIL

  /// `EMAIL_<value>`: Unicode NFC, then lowercase, then trim — in that order.
  ///
  /// NFC matters: a decomposed `e` + U+0301 and a precomposed U+00E9 are the same address to a
  /// human but different byte strings to the server, so one address would index as two entities.
  static func foldEmail(_ raw: String) throws -> String {
    let folded = jsTrim(raw.precomposedStringWithCanonicalMapping.lowercased())
    guard !folded.isEmpty else { throw TraciveQueryError(.emptyValue) }
    return folded
  }

  // MARK: - BANK

  /// Account-id fold shared by `BANK_IBAN_<accountId>` and `BANK_<country>_<bankCode>_<accountId>`:
  /// uppercase, **then** remove every whitespace character and ASCII hyphen. NFC is deliberately
  /// **not** applied here — the server does not apply it either.
  static func foldAccountId(_ raw: String) throws -> String {
    let folded = jsStripWhitespaceAndHyphen(raw.uppercased())
    guard !folded.isEmpty else { throw TraciveQueryError(.emptyAccountId) }
    return folded
  }

  /// Country: uppercase + trim, and it must be ISO 3166-1 alpha-3.
  ///
  /// The alpha-3 test is "exactly three ASCII letters" rather than a membership test against a
  /// vendored country table: the fixture only requires that alpha-2 (`ID`) is rejected, and a
  /// hard-coded table would drift between the three SDKs the first time ISO adds a code.
  static func foldCountryAlpha3(_ raw: String) throws -> String {
    let folded = jsTrim(raw.uppercased())
    guard folded.count == 3, folded.unicodeScalars.allSatisfy(isAsciiUppercaseLetter) else {
      throw TraciveQueryError(.countryNotAlpha3)
    }
    return folded
  }

  /// Bank code: NFC, uppercase, trim, then remove every underscore.
  ///
  /// The underscore strip is not cosmetic: the document id is split on `_`, so a bank code
  /// containing one would corrupt the parse on the server side.
  static func foldBankCode(_ raw: String) throws -> String {
    let folded = jsTrim(raw.precomposedStringWithCanonicalMapping.uppercased())
      .filter { $0 != "_" }
    guard !folded.isEmpty else { throw TraciveQueryError(.emptyBankCode) }
    return folded
  }

  // MARK: - CRYPTO

  /// Chain: NFC, uppercase, trim.
  static func foldChain(_ raw: String) throws -> String {
    let folded = jsTrim(raw.precomposedStringWithCanonicalMapping.uppercased())
    guard !folded.isEmpty else { throw TraciveQueryError(.emptyChain) }
    return folded
  }

  /// Address: trim, then lowercase **if and only if** the trimmed value is an EVM address
  /// (`^0x[0-9a-fA-F]{40}$`).
  ///
  /// EIP-55 checksum casing is presentational, so EVM addresses fold. Base58 (BTC, TRX) is
  /// case-*sensitive* — lowercasing yields a different, invalid address — and bech32's grammar
  /// admits only the lowercase form, so neither is folded.
  static func foldCryptoAddress(_ raw: String) throws -> String {
    let trimmed = jsTrim(raw)
    guard !trimmed.isEmpty else { throw TraciveQueryError(.emptyValue) }
    return isEvmAddress(trimmed) ? trimmed.lowercased() : trimmed
  }

  /// `^0x[0-9a-fA-F]{40}$`. Note the literal lowercase `0x`: `0X…` does not match the server's
  /// regex, so it must not be folded either.
  static func isEvmAddress(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count == 42, scalars[0] == "0", scalars[1] == "x" else { return false }
    return scalars[2...].allSatisfy(isAsciiHexDigit)
  }

  // MARK: - USERNAME

  /// Platform: NFC, uppercase, trim.
  static func foldPlatform(_ raw: String) throws -> String {
    let folded = jsTrim(raw.precomposedStringWithCanonicalMapping.uppercased())
    guard !folded.isEmpty else { throw TraciveQueryError(.emptyValue) }
    return folded
  }

  /// Handle: NFC, lowercase, trim.
  ///
  /// A leading `@` is **kept**. The server preserves it, so stripping it client-side would build a
  /// key that misses every report filed with the `@`. Underscores are kept too: `USERNAME` ids are
  /// split on the *first* underscore only, so `scammer_x` round-trips.
  static func foldHandle(_ raw: String) throws -> String {
    let folded = jsTrim(raw.precomposedStringWithCanonicalMapping.lowercased())
    guard !folded.isEmpty else { throw TraciveQueryError(.emptyHandle) }
    return folded
  }

  // MARK: - Scalar predicates
  //
  // Deliberately ASCII-only. `CharacterSet.decimalDigits` would also match Arabic-Indic and other
  // Unicode digits, which the server's `\d`-based strip does not.

  private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 0x30 && scalar.value <= 0x39
  }

  private static func isAsciiUppercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 0x41 && scalar.value <= 0x5A
  }

  private static func isAsciiHexDigit(_ scalar: Unicode.Scalar) -> Bool {
    isAsciiDigit(scalar)
      || (scalar.value >= 0x41 && scalar.value <= 0x46)  // A-F
      || (scalar.value >= 0x61 && scalar.value <= 0x66)  // a-f
  }
}
