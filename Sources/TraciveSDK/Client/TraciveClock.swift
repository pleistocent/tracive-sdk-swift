import Foundation

/// The SDK's source of "now" and of "wait" — the `clock` test seam.
///
/// Two things in this SDK depend on the passage of time and both are otherwise untestable:
/// cache TTL (where the shortest window is an hour and the longest is thirty days) and retry
/// backoff. Injecting a clock turns a thirty-day expiry test into an assignment and a
/// four-second backoff into an assertion.
///
/// The name is prefixed rather than being plain `Clock` on purpose: the standard library declares
/// its own `Clock` protocol, and a same-named type in a widely-imported SDK module would force
/// every consumer to disambiguate. `Duration`/`ContinuousClock` are also avoided — they need
/// iOS 16 and this SDK supports iOS 15.
public protocol TraciveClock: Sendable {
  /// The current instant.
  var now: Date { get }

  /// Suspends for `duration` seconds. A non-positive duration must return immediately.
  ///
  /// A test clock overrides this to record the requested delay and return at once, so the retry
  /// tests assert on the backoff *schedule* without spending the wall-clock time.
  func sleep(for duration: TimeInterval) async throws
}

extension TraciveClock {
  /// Default: a real suspension. Conformers only have to supply `now`.
  public func sleep(for duration: TimeInterval) async throws {
    guard duration > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64((duration * 1_000_000_000).rounded()))
  }
}

/// The production clock: wall time and a real suspension.
public struct TraciveSystemClock: TraciveClock {
  public init() {}
  public var now: Date { Date() }
}
