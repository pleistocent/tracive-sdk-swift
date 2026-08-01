import Foundation

/// Where a `CheckResult` came from.
///
/// `.cache` means the SDK answered from its own encrypted store: zero credits spent and zero
/// network I/O. `.server` means the result came from `POST /scammer-checks`.
public enum Origin: String, Codable, CaseIterable, Hashable, Sendable {
  case cache = "CACHE"
  case server = "SERVER"
}
