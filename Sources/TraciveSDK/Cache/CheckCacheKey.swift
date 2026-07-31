import CryptoKit
import Foundation

/// The primary key of a cached check: `SHA-256(searchQueryIndex)`, lowercase hex (§5).
///
/// ## Why the raw identifier is never the key
/// `TraciveQuery.searchQueryIndex` embeds the identifier itself — `PHONE_+6281234567891`,
/// `EMAIL_budi@example.com`, `BANK_IDN_BCA_32424242422`. Writing that into a database on the user's
/// device would turn the cache into a plaintext register of every phone number, email and bank
/// account the app has ever looked up, readable by anything that can reach the file. §11.3 forbids
/// it, so the SDK stores only the digest. The digest is enough to answer "have I seen this exact
/// query before" and useless for enumerating what was looked up.
///
/// The hash is **not** a secret in the information-theoretic sense — the input space of E.164 phone
/// numbers is small enough to brute-force — so the digest guards recovery-from-a-stolen-file, not
/// confirmation-of-a-guess. That is why the row *payload* is additionally encrypted (see
/// `CachePayloadCipher`) and why `description` below redacts even the hex.
public struct CheckCacheKey: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{

  /// Lowercase hex of the SHA-256 digest: 64 characters, always.
  public let hex: String

  /// Hashes an already-folded lookup key.
  ///
  /// - Parameter searchQueryIndex: the folded key, e.g. `PHONE_+6281234567891`. It is hashed
  ///   immediately and never retained.
  public init(searchQueryIndex: String) {
    var digest = SHA256()
    digest.update(data: Data(searchQueryIndex.utf8))
    self.hex = digest.finalize().traciveHexString
  }

  /// Hashes a built query. This is the normal entry point.
  public init(query: TraciveQuery) {
    self.init(searchQueryIndex: query.searchQueryIndex)
  }

  /// Reconstructs a key from a stored digest, e.g. when iterating rows. Returns `nil` unless the
  /// string is exactly 64 lowercase hex characters, so a malformed row can never become a key.
  public init?(hex: String) {
    let lowered = hex.lowercased()
    guard lowered.count == 64,
      lowered.allSatisfy({ $0.isHexDigit && $0.isASCII })
    else { return nil }
    self.hex = lowered
  }

  /// Deliberately redacted.
  ///
  /// Printing the digest would be *nearly* harmless, but a phone number has only a few billion
  /// plausible values: anyone holding a leaked log line and a rainbow table can confirm exactly
  /// which number was checked. The rule in this SDK is that no identifier — raw or hashed — reaches
  /// a log by accident. Reach for `hex` explicitly when you genuinely need it.
  public var description: String { "CheckCacheKey(<redacted>)" }

  public var debugDescription: String { description }
}

extension Digest {
  /// Lowercase hex, allocated once. `%02x` via `String(format:)` per byte is ~20x slower and pulls
  /// in the (locale-sensitive) formatting machinery for no benefit.
  var traciveHexString: String {
    let alphabet = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    // `Self.byteCount`, not `count`: on the `Digest` protocol the instance `count` now resolves to
    // `Sequence.count(where:)` and does not type-check as an `Int`.
    out.reserveCapacity(Self.byteCount * 2)
    for byte in makeIterator() {
      out.append(alphabet[Int(byte >> 4)])
      out.append(alphabet[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
  }
}
