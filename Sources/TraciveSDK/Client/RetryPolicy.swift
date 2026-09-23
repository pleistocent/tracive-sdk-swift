import Foundation

/// When `TraciveClient` may send the same request twice, and how long it waits first.
///
/// ## The rule that matters
///
/// > "Never auto-retry a `checkScammer` on 5xx/timeout without an `Idempotency-Key`; a blind retry
/// > risks a double charge."
///
/// A Tracive check is **billed on every call, including a miss**, and a 5xx or a timeout is
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
/// A 429 is never retried, whatever the request: its `Retry-After` can point at the next UTC
/// midnight, so it surfaces at once as `.rateLimited(retryAfter:)` and the caller decides whether
/// to wait. A `Retry-After` on a 5xx is honoured over the computed backoff — the server knows its
/// own window better than an exponential curve does.
///
/// ## The default numbers, and why each one is what it is
///
/// | Parameter | Default | Why |
/// |---|---|---|
/// | `maxAttempts` | `3` | Two retries after the first send. |
/// | `multiplier` | `2.0` | Binary exponential backoff. |
/// | `initialBackoff` | `500 ms` | Long enough to be a different moment; short enough to be unnoticed. |
/// | `jitter` | `0.2` | Breaks up a synchronised fleet without making the schedule unreadable. |
/// | `maxBackoff` | `8 s` | The ceiling that binds only if a caller raises `maxAttempts`. |
///
/// The four Tracive SDKs share this set exactly. They previously did not — three different initial
/// backoffs and two jitter ratios, with no reason recorded anywhere for any of them, which is how a
/// value nobody chose survives review in four repositories at once. So the numbers below are written
/// down as much to stop the next silent divergence as to justify themselves.
///
/// **None of it is measured.** The numbers were chosen before the API carried any traffic, so there
/// was no p99 to fit a curve to and no observed failure distribution to tune against. These are
/// defensible starting points with their reasoning attached, not tuned constants — and the first
/// real production data should be allowed to move them, in all four SDKs together.
///
/// - **`maxAttempts = 3`** is a ceiling on two things at once. It bounds worst-case latency to three
///   round trips plus roughly 1.5 s of waiting, on a screen where a user is usually waiting to send
///   money; and it bounds how many times one logical check can be *sent*, which matters because a
///   check is billed. Deduplication is the server's job and the `Idempotency-Key` is what asks for
///   it, and nobody has measured how the server honours it, so keeping the number of sends small
///   keeps the cost of being wrong about it small too.
/// - **`multiplier = 2.0`** because each retry should back off meaningfully rather than
///   incrementally, and doubling is the value every reader recognises on sight. There is nothing to
///   discover here; the reason it is recorded is that an unexplained `2.0` invites someone to
///   "improve" it to 1.5.
/// - **`initialBackoff = 500 ms`** is the one number the four SDKs disagreed hardest about. Too
///   short and the retry arrives while the server is still in whatever state produced the 5xx, which
///   spends an attempt to learn nothing. Too long and it is visible: half a second is under the
///   threshold at which a user starts suspecting the app has stalled, and two retries at 0.5 s and
///   1.0 s keep the whole schedule inside that budget.
/// - **`jitter = 0.2`** shaves up to 20% off each computed delay. The failure it prevents is a fleet
///   of banking apps that all saw the same 503 retrying in lockstep and re-creating the stampede.
///   Twenty percent is enough spread to break the synchronisation, and small enough that the
///   schedule is still recognisable in a support log — "about half a second, then about a second" —
///   rather than a smear. Deliberately one-sided: it only ever shortens, so `maxBackoff` stays a
///   real ceiling.
/// - **`maxBackoff = 8 s`** never binds at the default `maxAttempts`, where the schedule stops at
///   1.0 s. It exists for the caller who raises `maxAttempts`, and it is the point past which a
///   mobile user has already decided the app is broken, so waiting longer buys a result nobody is
///   still waiting for. A `Retry-After` on a 5xx overrides it even when it is longer — see
///   `delay(forRetry:retryAfter:)`.
public struct RetryPolicy: Equatable, Hashable, Sendable {

  /// Total sends, including the first. `1` disables retrying. Default `3`, which is also a ceiling
  /// on how many times one billable check can be sent.
  public var maxAttempts: Int
  /// Delay before the first retry, in seconds. Default `0.5`.
  public var initialBackoff: TimeInterval
  /// Growth factor per retry. Default `2`.
  public var multiplier: Double
  /// Ceiling for a single wait, in seconds. Default `8`, which the default `maxAttempts` never
  /// reaches — it binds only when a caller asks for more attempts.
  public var maxBackoff: TimeInterval
  /// Fraction of the computed delay that is randomly shaved off, in `0...1`. Default `0.2`.
  ///
  /// Without jitter, a fleet of banking apps that all saw the same 503 retries in lockstep and
  /// re-creates the stampede that caused it. Set to `0` for a deterministic schedule.
  ///
  /// One-sided on purpose: it only ever shortens a delay, never lengthens one, so `maxBackoff`
  /// remains a true ceiling and the worst case stays the one written on the tin.
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
  ///
  /// The same five numbers as the Kotlin, Flutter and React Native SDKs. Changing one here without
  /// changing it there is the divergence this set was assembled to end; `RetryPolicyTests` pins each
  /// value so the change has to be deliberate.
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
