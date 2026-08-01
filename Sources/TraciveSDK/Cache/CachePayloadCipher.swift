import CryptoKit
import Foundation

/// Encrypts and decrypts one cached row.
///
/// ## The design, and why it is not SQLCipher
/// The Kotlin and Flutter SDKs get whole-file encryption from their storage layers. Swift does not,
/// and adopting SQLCipher would cost the one property this SDK is sold on — **zero third-party
/// dependencies**. So the encryption happens a layer up: the row's JSON payload is sealed
/// with AES-GCM from CryptoKit, a system framework, and the database file itself stays a plain
/// SQLite file whose only readable columns are a digest and two timestamps.
///
/// This is not a downgrade for the thing we actually care about. SQLCipher protects the *file* from
/// being read; it does not protect a row from being moved. Per-row AEAD does both, because the
/// additional authenticated data binds each ciphertext to the exact row it belongs to (see below).
///
/// ## Format
/// `AES.GCM.SealedBox.combined`: a fresh random 96-bit nonce ‖ ciphertext ‖ 128-bit tag. CryptoKit
/// generates the nonce per `seal` call, so no counter is persisted and no nonce is ever reused under
/// a key — which for GCM is the one mistake that loses everything.
///
/// ## Additional authenticated data
/// `tracive.cache.v<schemaVersion>|<cacheKeyHex>`, authenticated but not encrypted. It makes two
/// attacks fail loudly instead of silently:
///
/// 1. **Row swapping.** Someone with write access to the file copies the sealed payload from a known
///    clean number onto the row of a `HIGH` scammer, so the app reports the scammer as safe. The tag
///    is computed over the destination key, so the moved payload will not authenticate.
/// 2. **Schema confusion.** A payload written under an older schema cannot be opened under a newer
///    one even if the version wipe were somehow skipped.
struct CachePayloadCipher {

  private let keyStore: any CacheKeyStore
  private let schemaVersion: Int

  init(keyStore: any CacheKeyStore, schemaVersion: Int) {
    self.keyStore = keyStore
    self.schemaVersion = schemaVersion
  }

  /// Encodes and seals a result for storage under `key`.
  ///
  /// `cacheableCopy()` is applied here as well as at the call site. It is idempotent, and this is
  /// the single point where bytes destined for disk are produced — enforcing "full detail is never
  /// cached" here means no future caller can route around it.
  func seal(_ result: CheckResult, for key: CheckCacheKey) throws -> Data {
    let cacheable = result.cacheableCopy()
    let plaintext: Data
    do {
      plaintext = try Self.encoder.encode(cacheable)
    } catch {
      throw CheckCacheError.encryptionFailed(underlying: error)
    }

    do {
      let sealed = try AES.GCM.seal(
        plaintext,
        using: try keyStore.dataKey(),
        authenticating: additionalData(for: key)
      )
      guard let combined = sealed.combined else {
        // `combined` is only nil for a nonce that is not 96 bits, and we never supply one — CryptoKit
        // generates it. Handled rather than force-unwrapped because a crash in a fraud SDK is worse
        // than any error it could report.
        throw CheckCacheError.encryptionFailed(underlying: SealedBoxNotCombinable())
      }
      return combined
    } catch let error as CheckCacheError {
      throw error
    } catch {
      throw CheckCacheError.encryptionFailed(underlying: error)
    }
  }

  /// Opens and decodes a stored payload.
  ///
  /// - Throws: `CheckCacheError.payloadUnreadable` for a bad tag, a rotated key or a payload that no
  ///   longer decodes. The caller deletes the row and reports a miss — a cache that cannot be read is
  ///   a cold cache, not a broken SDK.
  func open(_ combined: Data, for key: CheckCacheKey) throws -> CheckResult {
    let dataKey: SymmetricKey
    do {
      dataKey = try keyStore.dataKey()
    } catch let error as CheckCacheError {
      // A missing key is a *key store* fault, not a corrupt row: propagate it so the caller does not
      // respond by deleting every row in the database.
      throw error
    }

    do {
      let box = try AES.GCM.SealedBox(combined: combined)
      let plaintext = try AES.GCM.open(
        box,
        using: dataKey,
        authenticating: additionalData(for: key)
      )
      return try Self.decoder.decode(CheckResult.self, from: plaintext)
    } catch {
      throw CheckCacheError.payloadUnreadable
    }
  }

  private func additionalData(for key: CheckCacheKey) -> Data {
    Data("tracive.cache.v\(schemaVersion)|\(key.hex)".utf8)
  }

  // JSON rather than a hand-rolled binary format: `CheckResult` already owns a lenient `Codable`
  // conformance that ignores unknown keys, so a payload written by an older SDK build still decodes
  // after an upgrade that adds a field. Sorted keys make a stored row byte-reproducible, which makes
  // the round-trip tests deterministic.
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static let decoder = JSONDecoder()
}

/// Unreachable in practice; see the `guard` in `seal`. Declared rather than force-unwrapped so the
/// impossible case is an error, not a trap.
private struct SealedBoxNotCombinable: Error, CustomStringConvertible {
  var description: String { "AES-GCM sealed box had no combined representation" }
}
