import Foundation
import Security

/// The production `TraciveTokenStore`: two Keychain generic-password items per OAuth client — the
/// grant, and the authorization currently waiting for its redirect.
///
/// `UserDefaults` and plain files are forbidden for these credentials, and the reason is concrete: a
/// refresh token in `UserDefaults` is in the app's unencrypted container, readable from any
/// unencrypted device backup and from any jailbreak-level file browse. The Keychain items written
/// here are protected by the device passcode-derived key and are excluded from iCloud sync. The
/// pending record is held to the same standard because it carries the PKCE `code_verifier`, which
/// is the secret half of the code exchange.
///
/// The two items differ only in their service name, so `clientId` still separates one OAuth client
/// from another and no client id can be crafted that collides with the other item's slot.
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
    return try read(TraciveTokens.self, from: baseQuery())
  }

  public func save(_ tokens: TraciveTokens) throws {
    let data = try JSONEncoder().encode(tokens)

    lock.lock()
    defer { lock.unlock() }
    try write(data, to: baseQuery())
  }

  /// Erases both items.
  ///
  /// The pending record goes too, and that is not housekeeping. `clear()` is what `signOut()` and
  /// the `grant_revoked` path call, and leaving a live `code_verifier` behind after either would
  /// keep a spendable half of an exchange on a device the user believes is disconnected.
  public func clear() throws {
    lock.lock()
    defer { lock.unlock() }

    // Both deletes are attempted whatever the first one answers, so a failure on one cannot leave
    // the other item behind; the first error is the one reported.
    let tokenResult = Result { try delete(baseQuery()) }
    let pendingResult = Result { try delete(pendingQuery()) }
    try tokenResult.get()
    try pendingResult.get()
  }

  public func loadPending() throws -> PendingAuthorization? {
    lock.lock()
    defer { lock.unlock() }
    return try read(PendingAuthorization.self, from: pendingQuery())
  }

  public func savePending(_ pending: PendingAuthorization?) throws {
    guard let pending else {
      lock.lock()
      defer { lock.unlock() }
      return try delete(pendingQuery())
    }
    let data = try JSONEncoder().encode(pending)

    lock.lock()
    defer { lock.unlock() }
    try write(data, to: pendingQuery())
  }

  // MARK: - Item access
  //
  // Every call below assumes `lock` is already held.

  private func read<Value: Decodable>(_ type: Value.Type, from base: [String: Any]) throws -> Value?
  {
    var query = base
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return nil }
      // A stored blob we can no longer decode (schema change, corruption) is treated as absent, not
      // as a hard failure: the recoverable outcome is re-consent, and throwing here would wedge the
      // host app on every launch with no way out.
      return try? JSONDecoder().decode(Value.self, from: data)
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError(operation: "read", status: status)
    }
  }

  private func write(_ data: Data, to base: [String: Any]) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: accessibility,
    ]

    let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError(operation: "update", status: updateStatus)
    }

    var insert = base
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = accessibility
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError(operation: "add", status: addStatus)
    }
  }

  private func delete(_ base: [String: Any]) throws {
    let status = SecItemDelete(base as CFDictionary)
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

  /// The pending authorization's item.
  ///
  /// Separated by **service**, not by a suffix on the account. The account is the caller's
  /// `clientId`, so decorating it would mean a client id ending in the suffix could address the
  /// other client's pending slot; the service is ours and no argument can steer it.
  ///
  /// `internal` for the same reason as `baseQuery()`.
  func pendingQuery() -> [String: Any] {
    KeychainItemQuery.base(
      service: service + ".pending", account: account, accessGroup: accessGroup)
  }
}
