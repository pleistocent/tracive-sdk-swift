import Foundation

/// Cache-versus-network strategy for a single check (§4, §5).
///
/// This is a client-side switch only — it is never sent on the wire.
///
/// - `cacheFirst`: answer from a fresh cache entry when there is one, otherwise call the server.
/// - `server`: always call the server; the response still refreshes the cache.
/// - `serverFirst`: call the server, but fall back to a cache entry if the call fails.
/// - `cache`: cache only. A miss surfaces `TraciveError.cacheMiss` — never a silent empty result.
public enum Source: String, Codable, CaseIterable, Hashable, Sendable {
  case cacheFirst = "CACHE_FIRST"
  case server = "SERVER"
  case serverFirst = "SERVER_FIRST"
  case cache = "CACHE"
}
