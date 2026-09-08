import Foundation
import TraciveSDK

/// Everything the check screen can be showing.
public enum ScammerCheckState: Equatable {
  case idle
  case checking
  case result(CheckResult)
  /// A message that is safe to put in front of a user. It never contains the identifier that was
  /// checked, and never a raw server payload.
  case failure(String)
}

/// The view model behind `ScammerCheckView`.
///
/// It exists mainly to keep two things out of the view: the E.164 normalisation that has to happen
/// *before* a query is built, and the error mapping. Both are where a real integration gets it wrong.
@MainActor
public final class ScammerCheckModel: ObservableObject {

  @Published public var input: String = ""
  @Published public private(set) var state: ScammerCheckState = .idle

  private let checker: any ScammerChecking
  // TODO(partner): read this from the user's SIM or their profile. A constant is wrong for anyone
  // outside that one country, and it fails quietly: it builds a valid-looking E.164 number for the
  // wrong region, which indexes as a different entity, misses, and is billed anyway.
  /// Dial code used to complete a local-format number, e.g. `62` for Indonesia. In a real app this
  /// comes from the user's SIM or their profile, not a constant.
  private let defaultDialCode: String

  public init(checker: any ScammerChecking, defaultDialCode: String = "62") {
    self.checker = checker
    self.defaultDialCode = defaultDialCode
  }

  public var canCheck: Bool {
    !input.trimmingCharacters(in: .whitespaces).isEmpty && state != .checking
  }

  public func check() async {
    guard canCheck else { return }
    state = .checking

    let query: TraciveQuery
    do {
      query = try TraciveQuery.phone(e164: Self.toE164(input, dialCode: defaultDialCode))
    } catch let error as TraciveQueryError {
      // Rejected locally, before any request left the device. Nothing was billed — which is the
      // entire point of validating in the builder.
      state = .failure(error.errorDescription ?? "That does not look like a phone number.")
      return
    } catch {
      state = .failure("That does not look like a phone number.")
      return
    }

    do {
      state = .result(try await checker.check(query))
    } catch let error as TraciveError {
      state = .failure(Self.message(for: error))
    } catch {
      state = .failure("Something went wrong. Please try again.")
    }
  }

  public func reset() {
    input = ""
    state = .idle
  }

  // MARK: - E.164

  /// Completes a locally-formatted number into E.164.
  ///
  /// This has to happen **here**, not in the SDK. `TraciveQuery.phone` rejects a local-format number
  /// on purpose: the server cannot up-convert `081234567891`, because it does not know the dial code
  /// at that layer. A local number would index as a different entity, miss — and a miss is still
  /// billed. Only the app knows the user's region, so only the app can do this.
  public static func toE164(_ raw: String, dialCode: String) -> String {
    let digits = raw.filter { $0.isASCII && $0.isNumber }
    let hasPlus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")

    if hasPlus { return "+" + digits }
    // A leading trunk zero is national notation and is dropped when the dial code is prefixed.
    if digits.hasPrefix("0") { return "+" + dialCode + digits.dropFirst() }
    if digits.hasPrefix(dialCode) { return "+" + digits }
    return "+" + dialCode + digits
  }

  // MARK: - Errors

  /// Maps an SDK error to something a user can act on.
  ///
  /// Note what is *not* here: no auto-retry. A `checkScammer` that failed on a 5xx or a timeout may
  /// already have been charged, so retrying it blind risks charging twice. A retry needs the same
  /// `Idempotency-Key` as the original attempt.
  public static func message(for error: TraciveError) -> String {
    switch error {
    // TODO(partner): send the user into your own top-up flow, not just this sentence.
    case .insufficientCredits:
      return "You are out of Tracive credits. Top up to keep checking."
    case .rateLimited(let retryAfter, _):
      let seconds = Int(retryAfter ?? 30)
      return "Too many checks. Try again in \(seconds)s."
    case .grantRevoked, .expiredToken, .invalidToken:
      return "Your Tracive connection expired. Connect again to continue."
    case .missingScope, .detailNotPermitted:
      return "This app is not allowed to run that check."
    case .cacheMiss:
      return "No saved result for this number, and the check was set to use the cache only."
    case .network:
      return "You appear to be offline. Check your connection and try again."
    case .notImplemented(let message):
      return message
    case .invalidQuery(let queryError):
      return queryError.errorDescription ?? "That does not look like a phone number."
    default:
      return "Tracive could not complete the check. Please try again."
    }
  }
}

// MARK: - Presentation helpers

extension RiskTier {

  /// Short label for the banner.
  public var exampleTitle: String {
    switch self {
    case .high: return "High risk"
    case .elevated: return "Elevated risk"
    case .caution: return "Be careful"
    case .none: return "No risk signals"
    }
  }

  /// One sentence a user can act on. Deliberately not "this is a scammer" — the data is
  /// community-submitted, and overstating it is both wrong and a liability.
  public var exampleAdvice: String {
    switch self {
    case .high:
      return "Multiple credible reports. Do not send money to this number."
    case .elevated:
      return "Several reports. Verify who you are dealing with before paying."
    case .caution:
      return "One unconfirmed report. Treat this as a reason to double-check, not as proof."
    case .none:
      return "Nothing reported. That is not a guarantee — most scams are reported after the fact."
    }
  }
}
