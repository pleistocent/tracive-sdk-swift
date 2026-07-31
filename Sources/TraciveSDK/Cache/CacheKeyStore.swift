import CryptoKit
import Foundation
import Security

/// Supplies the AES-256 data key that encrypts every cached payload (§5, §11.6).
///
/// The key is fetched lazily and may be cached in memory by an implementation, so this is called on
/// the hot path of every read and write.
public protocol CacheKeyStore: Sendable {

  /// The 256-bit data key, creating and persisting one on first use.
  func dataKey() throws -> SymmetricKey

  /// Destroys the stored key.
  ///
  /// Every existing cache row becomes permanently unreadable. That is the point: it is the panic
  /// button for "wipe this user's local check history" and is far cheaper than shredding rows.
  /// `SQLiteCheckCache` deletes rows it cannot decrypt, so the cache recovers as cold rather than
  /// broken.
  func destroyDataKey() throws
}

// MARK: - Keychain

/// The production key store: an AES-256 data key held in the Keychain, **Secure Enclave-backed when
/// the device has one** (§5).
///
/// ## What is actually stored
/// One `kSecClassGenericPassword` item, tagged with a one-byte format marker:
///
/// | Marker | Contents | When |
/// |---|---|---|
/// | `0x02` | `SecureEnclave.P256.KeyAgreement.PrivateKey.dataRepresentation` | `SecureEnclave.isAvailable` |
/// | `0x01` | 32 raw key bytes | Simulator, Intel Macs without a T2, anything else |
///
/// In the `0x02` case the blob is not the key — it is an opaque, device-bound wrapper that only this
/// device's Secure Enclave can use. The AES key is *derived* on demand:
///
/// ```
/// shared  = ECDH(sk, sk.publicKey)        // computed inside the Secure Enclave
/// dataKey = HKDF-SHA256(shared, salt: "tracive.cache.datakey.v1", info: <service>)
/// ```
///
/// Agreeing with our **own** public key looks odd, so: this is not a key exchange. We need a
/// deterministic 256-bit secret that cannot be extracted from a stolen device image, and ECDH is the
/// only operation the Secure Enclave exposes for a P-256 key-agreement key — it cannot store or
/// derive symmetric keys directly. `sk · (sk · G)` is stable across launches (verified: restoring the
/// key from `dataRepresentation` yields the same derived key) and computing it requires the private
/// key, which never leaves the Enclave. An attacker with the Keychain item and the database file
/// still cannot decrypt a single row off-device.
///
/// ## Accessibility
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// - *AfterFirstUnlock* because a background refresh or a share-extension check must be able to read
///   the cache while the phone is locked. `WhenUnlocked` would make the cache randomly unavailable.
/// - *ThisDeviceOnly* because the item must not travel in an iCloud or iTunes backup. For the
///   Secure Enclave blob that would be pointless anyway; for the raw-key fallback it would put the
///   key in the backup alongside the encrypted database, which defeats the encryption.
public struct KeychainCacheKeyStore: CacheKeyStore {

  /// `kSecAttrService`. Change it only if you deliberately want a second, independent cache key.
  public let service: String
  /// `kSecAttrAccount`. Carries a version so a future key-format change can coexist with the old
  /// item instead of silently reading it as garbage.
  public let account: String
  /// Optional `kSecAttrAccessGroup`, for sharing the cache with an app extension. Requires the
  /// matching keychain-sharing entitlement.
  public let accessGroup: String?
  /// Set to `false` to force the raw-key path even where a Secure Enclave exists. Present for
  /// diagnostics; leave it `true`.
  public let usesSecureEnclaveWhenAvailable: Bool

  public init(
    service: String = "id.tracive.sdk.cache",
    account: String = "check-cache-data-key-v1",
    accessGroup: String? = nil,
    usesSecureEnclaveWhenAvailable: Bool = true
  ) {
    self.service = service
    self.account = account
    self.accessGroup = accessGroup
    self.usesSecureEnclaveWhenAvailable = usesSecureEnclaveWhenAvailable
    self.cache = KeyBox()
  }

  /// In-memory memo. Deriving through the Secure Enclave costs a few milliseconds — trivial once,
  /// ruinous per row.
  private let cache: KeyBox

  private static let rawMarker: UInt8 = 0x01
  private static let secureEnclaveMarker: UInt8 = 0x02
  private static let hkdfSalt = Data("tracive.cache.datakey.v1".utf8)

  public func dataKey() throws -> SymmetricKey {
    if let memoised = cache.value { return memoised }

    let key: SymmetricKey
    if let stored = try readItem() {
      key = try deriveKey(fromStoredBlob: stored)
    } else {
      let blob = try makeNewBlob()
      // A concurrent first-use on another thread may have written first. `errSecDuplicateItem` is
      // therefore expected, not exceptional: re-read and use whatever won the race, so both threads
      // end up with the same key rather than one silently encrypting under a key that is about to be
      // overwritten.
      do {
        try addItem(blob)
        key = try deriveKey(fromStoredBlob: blob)
      } catch CheckCacheError.dataKeyUnavailable(let status) where status == errSecDuplicateItem {
        guard let winner = try readItem() else { throw CheckCacheError.dataKeyCorrupt }
        key = try deriveKey(fromStoredBlob: winner)
      }
    }

    cache.value = key
    return key
  }

  public func destroyDataKey() throws {
    cache.value = nil
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CheckCacheError.dataKeyUnavailable(status: status)
    }
  }

  // MARK: - Blob handling

  private func makeNewBlob() throws -> Data {
    #if canImport(CryptoKit)
      if usesSecureEnclaveWhenAvailable, SecureEnclave.isAvailable {
        // A failure here is not fatal: some devices report the Enclave as available and still refuse
        // key creation (a few Simulator/virtualisation combinations do). Fall through to raw.
        if let privateKey = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
          return Data([Self.secureEnclaveMarker]) + privateKey.dataRepresentation
        }
      }
    #endif
    let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    return Data([Self.rawMarker]) + raw
  }

  private func deriveKey(fromStoredBlob blob: Data) throws -> SymmetricKey {
    guard let marker = blob.first else { throw CheckCacheError.dataKeyCorrupt }
    let body = blob.dropFirst()

    switch marker {
    case Self.rawMarker:
      guard body.count == 32 else { throw CheckCacheError.dataKeyCorrupt }
      return SymmetricKey(data: body)

    case Self.secureEnclaveMarker:
      #if canImport(CryptoKit)
        guard
          let privateKey = try? SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: Data(body)
          ),
          let shared = try? privateKey.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        else {
          // The item was written by a Secure Enclave that is no longer reachable — a restore onto
          // another device, or the Enclave being reset. The key is gone for good.
          throw CheckCacheError.dataKeyCorrupt
        }
        return shared.hkdfDerivedSymmetricKey(
          using: SHA256.self,
          salt: Self.hkdfSalt,
          sharedInfo: Data(service.utf8),
          outputByteCount: 32
        )
      #else
        throw CheckCacheError.dataKeyCorrupt
      #endif

    default:
      throw CheckCacheError.dataKeyCorrupt
    }
  }

  // MARK: - Keychain plumbing

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    #if os(macOS)
      // Opt macOS into the iOS-style data-protection keychain. Without it the item lands in the
      // legacy file keychain, where `kSecAttrAccessible` is ignored and the user can be prompted.
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }

  private func readItem() throws -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, !data.isEmpty else { throw CheckCacheError.dataKeyCorrupt }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw CheckCacheError.dataKeyUnavailable(status: status)
    }
  }

  private func addItem(_ blob: Data) throws {
    var query = baseQuery()
    query[kSecValueData as String] = blob
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw CheckCacheError.dataKeyUnavailable(status: status)
    }
  }
}

/// Mutable memo box. `KeychainCacheKeyStore` is a `struct` so it can be passed around freely, but the
/// derived key has to be shared across copies; a reference type behind a lock is the cheapest way to
/// do that without making the whole store a class.
private final class KeyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: SymmetricKey?

  var value: SymmetricKey? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storage = newValue
    }
  }
}

// MARK: - Ephemeral

/// A data key that lives only in memory, for tests, SwiftUI previews and throwaway tooling.
///
/// **Not for production.** The key dies with the process, so a persistent database written under it
/// is unreadable on the next launch — every row fails to authenticate, is dropped as unreadable, and
/// the cache is permanently cold while still costing disk. It exists because unit tests must not
/// touch the real Keychain: a `swift test` binary is unsigned, and Keychain access from one either
/// fails with `errSecMissingEntitlement` or prompts a human, neither of which belongs in CI.
public final class EphemeralCacheKeyStore: CacheKeyStore, @unchecked Sendable {

  private let lock = NSLock()
  private var key: SymmetricKey

  /// - Parameter key: pass an explicit key to simulate two processes sharing one (or, by passing a
  ///   different one, a key rotation).
  public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
    self.key = key
  }

  public func dataKey() throws -> SymmetricKey {
    lock.lock()
    defer { lock.unlock() }
    return key
  }

  public func destroyDataKey() throws {
    lock.lock()
    defer { lock.unlock() }
    key = SymmetricKey(size: .bits256)
  }
}
