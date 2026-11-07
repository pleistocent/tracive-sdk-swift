import Foundation

struct ReadableIdentifier: Equatable {
  enum Kind {
    case phone
    case email
    case bank
    case crypto
    case socialMedia
    case other
  }

  let kind: Kind
  let value: String

  /// Splits on `_` the way the keys are built: bank, chain and platform codes hold none, while
  /// account numbers, addresses and handles may. A key that does not parse is shown as it is.
  init(key: String) {
    let parts = key.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
    let value = parts.count == 2 ? String(parts[1]) : ""
    let other = (Kind.other, key)

    func pieces(_ count: Int) -> [String] {
      value.split(separator: "_", maxSplits: count - 1, omittingEmptySubsequences: false)
        .map(String.init)
    }

    let parsed: (Kind, String)
    switch (value.isEmpty ? "" : String(parts[0])) {
    case "PHONE":
      parsed = (.phone, value)
    case "EMAIL":
      parsed = (.email, value)
    case "BANK":
      let bank = pieces(3)
      if bank[0] == "IBAN", bank.count >= 2 {
        parsed = (.bank, String(value.dropFirst("IBAN_".count)))
      } else if bank.count == 3 {
        parsed = (.bank, "\(bank[1]) \(bank[2])")
      } else {
        parsed = other
      }
    case "CRYPTO":
      let crypto = pieces(2)
      parsed = crypto.count == 2 ? (.crypto, "\(crypto[0]) \(crypto[1])") : other
    case "USERNAME":
      let username = pieces(2)
      if username.count == 2 {
        let handle = username[1].hasPrefix("@") ? String(username[1].dropFirst()) : username[1]
        parsed = (.socialMedia, "\(username[0].lowercased().capitalized) @\(handle)")
      } else {
        parsed = other
      }
    default:
      parsed = other
    }
    (kind, self.value) = parsed
  }

  var label: String {
    switch kind {
    case .phone: return ReportText.text("media_phone")
    case .email: return ReportText.text("media_email")
    case .bank: return ReportText.text("media_bank")
    case .crypto: return ReportText.text("media_crypto")
    case .socialMedia: return ReportText.text("media_social")
    case .other: return ReportText.text("media_other")
    }
  }
}
