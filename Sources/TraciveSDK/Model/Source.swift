import Foundation

/// Cache-versus-network strategy for a single check.
///
/// This is a client-side switch only — it is never sent on the wire.
///
/// - `cacheFirst`: answer from a fresh cache entry when there is one, otherwise call the server.
/// - `server`: always call the server; the response still refreshes the cache.
/// - `serverFirst`: call the server, but fall back to a cache entry if the call fails.
/// - `cache`: cache only. A miss surfaces `TraciveError.cacheMiss` — never a silent empty result.
///
/// `Detail.full` takes the cache out of all of this in both directions. No cached row can *answer*
/// such a request without silently returning `comments` and `topChronologies` as `nil`, and no
/// full-detail response may be *stored*, because it is the only kind that carries a `locale` while
/// the row key has none. So `cacheFirst` skips the read, `serverFirst` does not fall back, `cache`
/// raises `TraciveError.cacheMiss`, and nothing is written on any of them. See `Docs/caching.md`.
public enum Source: String, Codable, CaseIterable, Hashable, Sendable {
  case cacheFirst = "CACHE_FIRST"
  case server = "SERVER"
  case serverFirst = "SERVER_FIRST"
  case cache = "CACHE"
}
