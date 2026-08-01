import Foundation
import Security

/// The one place that builds the identifying half of a Keychain query.
///
/// Two types in this package store a generic-password item: `KeychainTokenStore` (the OAuth grant)
/// and `KeychainCacheKeyStore` (the cache data key). Their queries must be identical in everything
/// except service and account, and for a while they were not — only the cache key store set
/// `kSecUseDataProtectionKeychain`, so on macOS the *more* sensitive of the two items, the refresh
/// token, was the one whose protection class was being ignored.
///
/// That is a bug this file makes unrepresentable rather than a bug to be re-fixed: there is now a
/// single definition, so the two stores cannot drift again, and any future attribute that belongs
/// on both is added once.
enum KeychainItemQuery {

  /// The class, identity and platform attributes shared by every read, write and delete.
  ///
  /// Callers layer their operation-specific keys (`kSecReturnData`, `kSecValueData`,
  /// `kSecAttrAccessible`, …) on top of this dictionary.
  static func base(service: String, account: String, accessGroup: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    #if os(macOS)
      // Opt macOS into the iOS-style data-protection keychain.
      //
      // Without this the item lands in the legacy file keychain, where `kSecAttrAccessible` is
      // **ignored** — so `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which both stores set
      // and which `SECURITY.md` promises, silently buys nothing — and the user can be prompted for
      // keychain access. `SecItemAdd` succeeds either way, which is what makes the weakened
      // protection invisible: there is no error, no log, and no observable difference until
      // someone inspects the keychain the item actually landed in.
      //
      // The package declares macOS 12 support, so this is not a hypothetical platform.
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }
}
