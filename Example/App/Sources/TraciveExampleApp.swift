import SwiftUI
import TraciveExample
import TraciveSDK

/// Hosts `ScammerCheckView` so the example can actually be run on a simulator or a device.
///
/// Everything on screen comes from the `TraciveExample` library; this file is only the composition
/// root — the place a real app builds its dependencies and hands them to the UI.
@main
struct TraciveExampleApp: App {

  var body: some Scene {
    WindowGroup {
      ScammerCheckView(checker: Self.checker)
    }
  }

  /// Built once. `body` can be evaluated more than once, and opening a database per evaluation
  /// would be a new empty cache each time.
  private static let checker: any ScammerChecking = makeChecker()

  // TODO(partner): this is the seam. Build a `TraciveClient`, return your own `ScammerChecking` over
  // `client.checkScammer`, and drop `CacheFirstChecker` — `Source.cacheFirst` already does that
  // inside the client. Nothing in the UI changes. The stub stays the default so a fresh clone still
  // runs with no credentials.
  private static func makeChecker() -> any ScammerChecking {
    let sample = SampleChecker()
    return CacheFirstChecker(cache: makeCache()) { try await sample.check($0) }
  }

  /// Deliberately not `ScammerCheckView()`'s own in-memory cache.
  ///
  /// That initialiser passes `SQLiteCheckCache.inMemory()`, which defaults to
  /// `EphemeralCacheKeyStore` — so it never touches the Keychain and leaves no file behind, which is
  /// what a library target compiled by CI wants. On-disk plus `KeychainCacheKeyStore` is the pairing
  /// only an installed app can exercise: the app-sandbox Application Support directory, the file
  /// protection class applied to it, and a data key that has to survive a relaunch. Check the same
  /// number after a cold start and a "Cached" badge is the proof that it did.
  private static func makeCache() -> any CheckCache {
    do {
      return try SQLiteCheckCache()
    } catch {
      // Loud, because the degraded path is indistinguishable from a working one on screen: every
      // check would simply read "Just checked" and look like a cache miss rather than a refusal.
      print("[TraciveExample] on-disk cache unavailable — caching is off for this run: \(error)")
      return NoOpCheckCache()
    }
  }
}
