import Foundation

/// Something went wrong in the local encrypted cache.
///
/// These are **local storage** faults — a full disk, a corrupt file, a Keychain that will not hand
/// back the data key. They are deliberately a separate family from `TraciveError`, which describes
/// what the *server* said, because they carry a completely different remedy: nothing here is worth
/// showing to an end user, and none of it should abort a check that could still be answered over the
/// network.
///
/// ## How callers should treat these
/// - A **write** failure is never fatal. The check already succeeded; the only loss is that the next
///   identical check costs another credit. Log and continue.
/// - A **read** failure is never fatal either. Treat it as a miss and go to the server — except
///   under `Source.cache`, where the caller surfaces `TraciveError.cacheMiss` rather than
///   answering with a silent empty result.
///
/// Note what is *not* here: there is no `notFound`. A cache miss is `nil` from `read`, not an error;
/// turning a miss into `TraciveError.cacheMiss` is a policy decision that belongs to the client,
/// which is the only layer that knows the requested `Source`.
public enum CheckCacheError: Error, CustomStringConvertible, LocalizedError {

  /// SQLite refused an operation. `message` is `sqlite3_errmsg`; it names columns and constraints,
  /// never a stored value, and no raw identifier is ever bound to a statement in the first place.
  case storageFailure(code: Int32, message: String)

  /// The database file could not be opened or created at the requested location.
  case cannotOpenStore(path: String, code: Int32, message: String)

  /// The Keychain would not produce the data key. `status` is an `OSStatus`
  /// (`errSecMissingEntitlement` = -34018 when running an unsigned binary, for example).
  case dataKeyUnavailable(status: Int32)

  /// The Keychain item exists but is not a usable 256-bit key — someone or something wrote over it.
  case dataKeyCorrupt

  /// AES-GCM sealing failed. In practice this only happens if the key material is wrong.
  case encryptionFailed(underlying: any Error)

  /// A stored payload would not authenticate or would not decode.
  ///
  /// The row is unreadable, which is not the same as absent: it means the data key changed (app
  /// reinstall, Keychain reset, restore onto another device) or the file was tampered with. The
  /// store deletes the row and reports a miss rather than propagating this, so a rotated key
  /// degrades into "the cache is cold" instead of "every check now throws".
  case payloadUnreadable

  public var description: String {
    switch self {
    case .storageFailure(let code, let message):
      return "storageFailure(\(code): \(message))"
    case .cannotOpenStore(let path, let code, let message):
      return "cannotOpenStore(\(path), \(code): \(message))"
    case .dataKeyUnavailable(let status):
      return "dataKeyUnavailable(OSStatus \(status))"
    case .dataKeyCorrupt:
      return "dataKeyCorrupt"
    case .encryptionFailed(let underlying):
      return "encryptionFailed(\(underlying))"
    case .payloadUnreadable:
      return "payloadUnreadable"
    }
  }

  public var errorDescription: String? { description }

  /// Lifts this into the SDK-wide error family for call sites that catch one type.
  ///
  /// It maps to `.unknown` with a synthetic `cache_storage_error` code rather than to `.server`:
  /// no server was involved, and a caller inspecting `isTransient` must not be told to retry a
  /// network call because a local disk was full.
  public var asTraciveError: TraciveError {
    .unknown(
      status: nil,
      info: TraciveErrorInfo(code: "cache_storage_error", message: description)
    )
  }
}
