import Foundation

/// The QRIS folds: `QRIS_<NMID>` from a payload or a typed NMID, `QRIS_<PAN>` from a typed PAN.
///
/// Transcribed from `rules.QRIS_PAYLOAD`, `rules.QRIS_NMID` and `rules.QRIS_PAN` in
/// `query-grammar-vectors.json`. The server parses the payload in JavaScript, so the payload is
/// read as UTF-16 code units throughout and only turned back into a `String` where a value is
/// compared.
extension QueryFolding {

  // Exactly tab, LF, CR, space and U+00A0: not `javaScriptWhitespace`, which is JS `trim()`'s set.
  static let qrisSpaces: Set<Unicode.Scalar> = [
    "\u{0009}", "\u{000A}", "\u{000D}", "\u{0020}", "\u{00A0}",
  ]

  private static let qrisSpaceUnits: Set<UInt16> = Set(qrisSpaces.map { UInt16($0.value) })

  private static let indexedCriteria = ["UMI", "UKE"]
  private static let knownCriteria = ["UMI", "UKE", "UME", "UBE"]

  // MARK: - NMID and PAN

  /// `QRIS_NMID`: remove every QRIS space anywhere, upper-case, then `^ID[0-9]{13}$`.
  static func foldQrisNmid(_ raw: String) throws -> String {
    guard let nmid = normalizeNmid(raw) else { throw TraciveQueryError(.notAnNmid) }
    return nmid
  }

  /// `QRIS_PAN`: remove every QRIS space; 18 ASCII digits, or 19 whose Luhn check passes, folded
  /// to the first 18.
  static func foldQrisPan(_ raw: String) throws -> String {
    let digits = Array(removingQrisSpaces(raw).utf8)
    guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { throw TraciveQueryError(.notAPan) }
    if digits.count == 18 { return String(decoding: digits, as: UTF8.self) }
    if digits.count == 19, luhnValid(digits) {
      return String(decoding: digits.prefix(18), as: UTF8.self)
    }
    throw TraciveQueryError(.notAPan)
  }

  static func normalizeNmid(_ raw: String) -> String? {
    let nmid = removingQrisSpaces(raw).uppercased()
    let bytes = Array(nmid.utf8)
    guard bytes.count == 15, bytes[0] == UInt8(ascii: "I"), bytes[1] == UInt8(ascii: "D"),
      bytes[2...].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
    else { return nil }
    return nmid
  }

  private static func removingQrisSpaces(_ raw: String) -> String {
    String(String.UnicodeScalarView(raw.unicodeScalars.filter { !qrisSpaces.contains($0) }))
  }

  /// The check digit (the last) is not doubled; every second digit to its left is.
  private static func luhnValid(_ digits: [UInt8]) -> Bool {
    var sum = 0
    for (offset, byte) in digits.reversed().enumerated() {
      var digit = Int(byte - 0x30)
      if offset % 2 == 1 {
        digit *= 2
        if digit > 9 { digit -= 9 }
      }
      sum += digit
    }
    return sum % 10 == 0
  }

  // MARK: - Payload

  private typealias Units = ArraySlice<UInt16>

  /// `QRIS_PAYLOAD`. Checks run in the contract's order: not_a_qris, qris_crc_mismatch,
  /// qris_no_nmid, qris_not_indexed.
  static func foldQrisPayload(_ raw: String) throws -> String {
    // TLV lengths count UTF-16 code units, as JavaScript's String.length does. Measuring
    // Characters or unicodeScalars misreads any value holding an emoji or a combining mark.
    let units = Array(raw.utf16)
    var start = 0
    var end = units.count
    while start < end, qrisSpaceUnits.contains(units[start]) { start += 1 }
    while end > start, qrisSpaceUnits.contains(units[end - 1]) { end -= 1 }
    let payload = units[start..<end]

    guard payload.starts(with: "000201".utf16), let top = readTlv(payload),
      let crc = top.last, crc.tag == 63, crc.value.count == 4
    else { throw TraciveQueryError(.notAQris) }

    // The CRC covers UTF-8 bytes while the framing above counts UTF-16 units.
    let signed = String(decoding: payload.dropLast(4), as: UTF16.self)
    guard sameUnits(text(crc.value).uppercased(), crc16Hex(signed.utf8)) else {
      throw TraciveQueryError(.qrisCrcMismatch)
    }

    let first = firstByTag(top)
    let national = subTags(first[51])
    guard let nmidValue = national[2], let nmid = normalizeNmid(text(nmidValue)) else {
      throw TraciveQueryError(.qrisNoNmid)
    }

    // The acquirer is the first merchant account template, in tag order, that has a GUID.
    let acquirer = (26...45).lazy.compactMap { first[$0] }.map { subTags($0) }
      .first(where: { $0[0] != nil })
    let criteria = criteriaOf(national[3]) ?? acquirer.flatMap { criteriaOf($0[3]) }
    guard let criteria, indexedCriteria.contains(criteria) else {
      throw TraciveQueryError(.qrisNotIndexed)
    }
    return nmid
  }

  /// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final xor; 4 upper-case hex.
  static func crc16Hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
      crc ^= UInt16(byte) << 8
      for _ in 0..<8 {
        crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
      }
    }
    let hex = String(crc, radix: 16, uppercase: true)
    return String(repeating: "0", count: 4 - hex.count) + hex
  }

  private struct Tlv {
    let tag: Int
    let value: Units
  }

  /// A tag or length that is not two ASCII digits, or a value past the end, is not TLV.
  private static func readTlv(_ data: Units) -> [Tlv]? {
    var out: [Tlv] = []
    var index = data.startIndex
    while index < data.endIndex {
      guard data.endIndex - index >= 4,
        let tag = twoDigits(data[index], data[index + 1]),
        let length = twoDigits(data[index + 2], data[index + 3])
      else { return nil }
      let valueStart = index + 4
      guard data.endIndex - valueStart >= length else { return nil }
      out.append(Tlv(tag: tag, value: data[valueStart..<(valueStart + length)]))
      index = valueStart + length
    }
    return out
  }

  private static func twoDigits(_ high: UInt16, _ low: UInt16) -> Int? {
    guard (0x30...0x39).contains(high), (0x30...0x39).contains(low) else { return nil }
    return Int(high - 0x30) * 10 + Int(low - 0x30)
  }

  /// A repeated tag keeps its first value.
  private static func firstByTag(_ tlv: [Tlv]) -> [Int: Units] {
    var map: [Int: Units] = [:]
    for entry in tlv where map[entry.tag] == nil { map[entry.tag] = entry.value }
    return map
  }

  /// A template whose value is not TLV inside reads as having no sub-tags.
  private static func subTags(_ value: Units?) -> [Int: Units] {
    firstByTag(value.flatMap(readTlv) ?? [])
  }

  private static func criteriaOf(_ value: Units?) -> String? {
    guard let value else { return nil }
    let upper = text(value).uppercased()
    return knownCriteria.first { sameUnits($0, upper) }
  }

  private static func text(_ units: Units) -> String {
    String(decoding: units, as: UTF16.self)
  }

  // Swift's `==` on String is canonical equivalence; the server compares code units.
  private static func sameUnits(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
  }
}
