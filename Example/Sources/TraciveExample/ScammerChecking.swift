import Foundation
import TraciveSDK

/// The one thing the example's UI needs: something that turns a query into a verdict.
///
/// The screen depends on this protocol rather than on `TraciveClient` directly, which is the same
/// shape you should use in your own app. It buys three things:
///
/// 1. **The example runs today.** The Tracive Open API is not deployed, so a demo wired straight to
///    the network would be a demo nobody can run.
/// 2. **Your UI tests do not need a network.** Swap in a stub and assert what the screen renders for
///    `HIGH`, for `NONE`, for a 402, for a timeout — none of which you can reliably provoke against
///    a real server.
/// 3. **Proxy mode (phase 2) is a one-line change** at the composition root instead of an edit to
///    every view.
///
/// In production the implementation is one line, and writing it is the one piece of this file a
/// partner has to supply:
///
/// ```swift
/// struct LiveChecker: ScammerChecking {
///   let client: TraciveClient
///   func check(_ query: TraciveQuery) async throws -> CheckResult {
///     try await client.checkScammer(query)
///   }
/// }
/// ```
public protocol ScammerChecking: Sendable {
  func check(_ query: TraciveQuery) async throws -> CheckResult
}

// MARK: - Cache-first

/// Demonstrates the cache-first pattern against the SDK's real encrypted cache.
///
/// A hit costs zero credits and does no network I/O, and comes back stamped `origin == .cache`. This
/// is what `Source.cacheFirst` does inside `TraciveClient`; it is spelled out here so the example can
/// show the behaviour with no server in the picture.
public struct CacheFirstChecker: ScammerChecking {

  private let cache: any CheckCache
  private let upstream: @Sendable (TraciveQuery) async throws -> CheckResult

  public init(
    cache: any CheckCache,
    upstream: @escaping @Sendable (TraciveQuery) async throws -> CheckResult
  ) {
    self.cache = cache
    self.upstream = upstream
  }

  public func check(_ query: TraciveQuery) async throws -> CheckResult {
    let key = CheckCacheKey(query: query)

    // A broken cache must never fail a check that could still be answered, so read failures are
    // treated as a miss rather than propagated.
    if let cached = cache.readIgnoringFailures(key) {
      return cached
    }

    let fresh = try await upstream(query)

    // A failed write costs one extra credit next time. It must never fail a check that already
    // succeeded and was already billed.
    cache.writeIgnoringFailures(fresh, for: key)
    return fresh
  }
}

// MARK: - Sample data

// TODO(partner): delete this type. Nothing in a real integration calls it — a `LiveChecker`
// wrapping `TraciveClient.checkScammer` takes its place. Keep its *shape* in your test target
// though: it is how you assert what your UI does for HIGH, for NONE and for a 402 with no server.
/// A stand-in "server" with a handful of canned verdicts, so the example is explorable offline.
///
/// Deliberately slow by a few hundred milliseconds: an instant answer hides the loading state, which
/// is exactly the state a real integration gets wrong.
public struct SampleChecker: ScammerChecking {

  public init() {}

  public func check(_ query: TraciveQuery) async throws -> CheckResult {
    try? await Task.sleep(nanoseconds: 400_000_000)

    let disclaimer =
      "Reports are submitted by Tracive users and are not verified by Tracive. "
      + "Treat them as signals, not as proof."

    // Keyed off the last digit purely so every tier is reachable from the demo UI.
    switch query.searchQueryIndex.last {
    case "1":
      return CheckResult(
        checkId: "chk_sample_high",
        found: true,
        riskTier: .high,
        reportTotal: 23,
        credibleReports: 19,
        ambiguousReports: 4,
        firstReportOn: Date(timeIntervalSince1970: 1_760_000_000),
        lastReportOn: Date(timeIntervalSince1970: 1_800_000_000),
        fraudAmount: ["IDR": 487_500_000],
        tags: ["investasi", "telegram", "impersonation"],
        relatedScammerCount: 6,
        billing: Billing(creditSource: .user, unitsCharged: 1),
        disclaimer: disclaimer,
        origin: .server,
        fetchedAt: Date()
      )

    case "2":
      return CheckResult(
        checkId: "chk_sample_elevated",
        found: true,
        riskTier: .elevated,
        reportTotal: 4,
        credibleReports: 2,
        ambiguousReports: 2,
        lastReportOn: Date(timeIntervalSince1970: 1_795_000_000),
        fraudAmount: ["IDR": 3_200_000],
        tags: ["olshop"],
        relatedScammerCount: 1,
        billing: Billing(creditSource: .user, unitsCharged: 1),
        disclaimer: disclaimer,
        origin: .server,
        fetchedAt: Date()
      )

    case "3":
      return CheckResult(
        checkId: "chk_sample_caution",
        found: true,
        riskTier: .caution,
        reportTotal: 1,
        credibleReports: 0,
        ambiguousReports: 1,
        lastReportOn: Date(timeIntervalSince1970: 1_799_000_000),
        tags: ["unverified"],
        billing: Billing(creditSource: .user, unitsCharged: 1),
        disclaimer: disclaimer,
        origin: .server,
        fetchedAt: Date()
      )

    case "9":
      // The 402 path. Handle this instead of calling credits() before every check — a pre-flight
      // balance call doubles your request volume and is still racy.
      throw TraciveError.insufficientCredits(
        which: .userCredits,
        info: TraciveErrorInfo(code: "insufficient_user_credits", message: "You are out of credits.")
      )

    default:
      return CheckResult(
        checkId: "chk_sample_none",
        found: false,
        riskTier: .none,
        billing: Billing(creditSource: .user, unitsCharged: 1),
        disclaimer: disclaimer,
        origin: .server,
        fetchedAt: Date()
      )
    }
  }
}
