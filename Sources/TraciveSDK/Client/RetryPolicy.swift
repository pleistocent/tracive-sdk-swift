import Foundation

/// When `TraciveClient` may send the same request twice, and how long it waits first (§7).
///
/// ## The rule that matters
///
/// > "Never auto-retry a `checkScammer` on 5xx/timeout without an `Idempotency-Key`; a blind retry
/// > risks a double charge."
///
/// A Tracive check is **billed on every call, including a miss** (§3.2), and a 5xx or a timeout is
/// precisely the case where the client cannot tell whether the charge landed. So the policy below
/// is applied only to requests that are safe to repeat:
///
/// - `GET /credits` and `GET /profile` — no side effects, always retryable.
/// - `POST /scammer-checks` — retryable **only** when the caller supplied an `Idempotency-Key`,
///   which lets the server return the first response instead of charging again.
///
/// A `checkScammer` without a key therefore fails fast on the first 5xx. That is not a limitation
/// to work around; it is the SDK refusing to spend the caller's money on a guess. Callers who want
/// retries pass a key, and the SDK reuses that same key on every attempt.
///
/// `retryAfter` on a 429 is honoured over the computed backoff — the server knows its own window
/// better than an exponential curve does.
public struct RetryPolicy: Equatable, Hashable, Sendable {

  /// Total sends, including the first. `1` disables retrying.
  public var maxAttempts: Int
  /// Delay before the first retry, in seconds.
  public var initialBackoff: TimeInterval
  /// Growth factor per retry.
  public var multiplier: Double
  /// Ceiling for a single wait, in seconds.
  public var maxBackoff: TimeInterval
  /// Fraction of the computed delay that is randomly shaved off, in `0...1`.
  ///
  /// Without jitter, a fleet of banking apps that all saw the same 503 retries in lockstep and
  /// re-creates the stampede that caused it. Set to `0` for a deterministic schedule.
  public var jitter: Double
  /// Whether a `Retry-After` header replaces the computed backoff. Leave this on.
  public var respectsRetryAfter: Bool

  public init(
    maxAttempts: Int = 3,
    initialBackoff: TimeInterval = 0.5,
    multiplier: Double = 2,
    maxBackoff: TimeInterval = 8,
    jitter: Double = 0.2,
    respectsRetryAfter: Bool = true
  ) {
    self.maxAttempts = max(1, maxAttempts)
    self.initialBackoff = max(0, initialBackoff)
    self.multiplier = max(1, multiplier)
    self.maxBackoff = max(0, maxBackoff)
    self.jitter = min(max(0, jitter), 1)
    self.respectsRetryAfter = respectsRetryAfter
  }

  /// Three attempts, 0.5 s → 1 s, capped at 8 s, 20% jitter.
  public static let `default` = RetryPolicy()

  /// One attempt: every failure is surfaced immediately.
  public static let disabled = RetryPolicy(maxAttempts: 1)

  /// Whether another send is allowed after `completedAttempts` sends have already failed.
  public func allowsAnotherAttempt(after completedAttempts: Int) -> Bool {
    completedAttempts < maxAttempts
  }

  /// How long to wait before retry number `retryIndex` (1 = the first retry).
  ///
  /// - Parameter retryAfter: parsed `Retry-After`, when the server sent one. It wins outright when
  ///   `respectsRetryAfter` is set — including when it is *longer* than `maxBackoff`, because a
  ///   server asking for 60 s means it.
  public func delay(forRetry retryIndex: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
    if respectsRetryAfter, let retryAfter, retryAfter > 0 {
      return retryAfter
    }
    let exponent = Double(max(0, retryIndex - 1))
    let raw = initialBackoff * pow(multiplier, exponent)
    let capped = min(raw, maxBackoff)
    guard jitter > 0, capped > 0 else { return capped }
    return capped * (1 - Double.random(in: 0...jitter))
  }
}
