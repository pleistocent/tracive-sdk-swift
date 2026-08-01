import Foundation
import Security

/// The production `TraciveTokenStore`: one Keychain generic-password item per OAuth client.
///
/// `UserDefaults` and plain files are forbidden for these credentials, and the reason is concrete: a
/// refresh token in `UserDefaults` is in the app's unencrypted container, readable from any
/// unencrypted device backup and from any jailbreak-level file browse. The Keychain item written
/// here is protected by the device passcode-derived key and is excluded from iCloud sync.
///
/// Uses Keychain Services directly — no third-party wrapper.
public final class KeychainTokenStore: TraciveTokenStore, @unchecked Sendable {

  /// A Keychain call failed. `status` is the raw `OSStatus`; look it up with
  /// `SecCopyErrorMessageString`.
  ///
  /// The error carries no token material — it is safe to log and safe to report.
  public struct KeychainError: Error, Equatable, Hashable, Sendable, CustomStringConvertible,
    LocalizedError
  {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
      self.operation = operation
      self.status = status
    }

    public var description: String { "KeychainError(\(operation), status: \(status))" }
    public var errorDescription: String? {
      "Keychain \(operation) failed with status \(status)."
    }
  }

  private let service: String
  private let account: String
  private let accessGroup: String?
  private let accessibility: CFString
  private let lock = NSLock()

  /// - Parameters:
  ///   - clientId: becomes the Keychain account, so two OAuth clients in the same host app keep
  ///     separate grants instead of overwriting each other.
  ///   - service: Keychain service name. The default namespaces this SDK's items away from the host
  ///     app's own.
  ///   - accessGroup: set only if the grant must be shared with an app extension or a sibling app.
  ///   - accessibility: defaults to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  ///     `AfterFirstUnlock` so a background refresh still works on a locked device;
  ///     `ThisDeviceOnly` so a bearer token is never carried into an iCloud Keychain or a device
  ///     migration.
  public init(
    clientId: String,
    service: String = "id.tracive.sdk.oauth",
    accessGroup: String? = nil,
    accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
  ) {
    self.service = service
    self.account = clientId
    self.accessGroup = accessGroup
    self.accessibility = accessibility
  }

  public func load() throws -> TraciveTokens? {
    lock.lock()
    defer { lock.unlock() }

    var query = baseQuery()
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return nil }
      // A stored blob we can no longer decode (schema change, corruption) is treated as "no
      // grant", not as a hard failure: the recoverable outcome is re-consent, and throwing here
      // would wedge the host app on every launch with no way out.
      return try? JSONDecoder().decode(TraciveTokens.self, from: data)
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError(operation: "read", status: status)
    }
  }

  public func save(_ tokens: TraciveTokens) throws {
    let data = try JSONEncoder().encode(tokens)

    lock.lock()
    defer { lock.unlock() }

    let query = baseQuery()
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: accessibility,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError(operation: "update", status: updateStatus)
    }

    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = accessibility
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError(operation: "add", status: addStatus)
    }
  }

  public func clear() throws {
    lock.lock()
    defer { lock.unlock() }

    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(operation: "delete", status: status)
    }
  }

  /// Shared with `KeychainCacheKeyStore` so the two stores cannot drift apart — see
  /// `KeychainItemQuery` for why that is not a theoretical concern.
  ///
  /// `internal` rather than `private` only so the test suite can assert on the query this store
  /// actually uses. Asserting on a re-derived copy would be a check that cannot fail.
  func baseQuery() -> [String: Any] {
    KeychainItemQuery.base(service: service, account: account, accessGroup: accessGroup)
  }
}
