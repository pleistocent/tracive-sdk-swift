import Foundation

/// Everything the SDK can fail with.
///
/// The server's error envelope is `{"error":{"code","message","checkId"}}`; `TraciveError.from`
/// turns an HTTP status plus that `code` into one of these cases. An **unrecognised** code never
/// crashes and is never swallowed — it maps to `.server` (5xx) or `.unknown` (anything else)
/// carrying the raw code, so a future-version error code shipped after this SDK still reaches the caller
/// intact.
public enum TraciveError: Error, @unchecked Sendable, CustomStringConvertible, LocalizedError {

  /// A surface that exists but is not wired up yet — today, only Proxy mode (phase 2).
  case notImplemented(String)

  // 400
  case invalidRequest(TraciveErrorInfo)
  case unsupportedInputType(TraciveErrorInfo)
  case unsupportedCreditSource(TraciveErrorInfo)

  // 401
  case invalidToken(TraciveErrorInfo)
  /// The access token expired. Handled internally by the single-flight refresh; it only
  /// reaches a caller when the refresh itself fails.
  case expiredToken(TraciveErrorInfo)
  /// The whole grant was revoked — often by the server's refresh-token reuse detection. Stored
  /// tokens are cleared and the flow must restart from consent. **Do not retry.**
  case grantRevoked(TraciveErrorInfo)
  /// Defined by the server contract for API-key callers. The SDK never sends an API key,
  /// so seeing this means a proxy in front of Tracive sent a bad one.
  case invalidApiKey(TraciveErrorInfo)

  // 402
  case insufficientCredits(which: InsufficientCreditsKind, info: TraciveErrorInfo)

  // 403
  case missingScope(TraciveErrorInfo)
  case detailNotPermitted(TraciveErrorInfo)
  case credentialMismatch(TraciveErrorInfo)
  case partnerSuspended(TraciveErrorInfo)

  // 409
  case idempotencyConflict(TraciveErrorInfo)

  // 429
  /// `retryAfter` comes from the `Retry-After` response header. It is a `TimeInterval` rather than
  /// `Duration` because `Duration` needs iOS 16 and this SDK supports iOS 15.
  case rateLimited(retryAfter: TimeInterval?, info: TraciveErrorInfo)

  /// Transport failure: no HTTP response at all (offline, DNS, TLS, timeout).
  case network(cause: any Error)

  /// 5xx, or any status whose code we do not recognise but which is clearly server-side.
  /// The server's `error.code`, if it sent one, is in `info.code`.
  case server(status: Int, info: TraciveErrorInfo)

  /// Anything else, carrying whatever the server did say.
  case unknown(status: Int?, info: TraciveErrorInfo)

  /// `source = .cache` was requested and there was no fresh entry. Surfaced explicitly rather than
  /// answering with a silent empty result.
  case cacheMiss

  /// The OAuth callback's `state` did not match the one we generated — a possible CSRF attempt, so
  /// the flow is abandoned rather than completed.
  case stateMismatch

  /// A query could not be built. Lifted from `TraciveQueryError` for call sites that catch one
  /// error family.
  case invalidQuery(TraciveQueryError)

  // MARK: - Convenience

  /// The exact message the spec requires Proxy-mode calls to fail with.
  public static let proxyModeNotImplemented = TraciveError.notImplemented(
    "Proxy mode arrives in phase 2"
  )

  /// Case discriminator, for switching, logging and test assertions without matching payloads.
  public var kind: TraciveErrorKind {
    switch self {
    case .notImplemented: return .notImplemented
    case .invalidRequest: return .invalidRequest
    case .unsupportedInputType: return .unsupportedInputType
    case .unsupportedCreditSource: return .unsupportedCreditSource
    case .invalidToken: return .invalidToken
    case .expiredToken: return .expiredToken
    case .grantRevoked: return .grantRevoked
    case .invalidApiKey: return .invalidApiKey
    case .insufficientCredits: return .insufficientCredits
    case .missingScope: return .missingScope
    case .detailNotPermitted: return .detailNotPermitted
    case .credentialMismatch: return .credentialMismatch
    case .partnerSuspended: return .partnerSuspended
    case .idempotencyConflict: return .idempotencyConflict
    case .rateLimited: return .rateLimited
    case .network: return .network
    case .server: return .server
    case .unknown: return .unknown
    case .cacheMiss: return .cacheMiss
    case .stateMismatch: return .stateMismatch
    case .invalidQuery: return .invalidQuery
    }
  }

  /// The server envelope that produced this error, when there was one.
  public var info: TraciveErrorInfo? {
    switch self {
    case .invalidRequest(let info), .unsupportedInputType(let info),
      .unsupportedCreditSource(let info), .invalidToken(let info), .expiredToken(let info),
      .grantRevoked(let info), .invalidApiKey(let info), .missingScope(let info),
      .detailNotPermitted(let info), .credentialMismatch(let info), .partnerSuspended(let info),
      .idempotencyConflict(let info):
      return info
    case .insufficientCredits(_, let info), .rateLimited(_, let info), .server(_, let info),
      .unknown(_, let info):
      return info
    case .notImplemented, .network, .cacheMiss, .stateMismatch, .invalidQuery:
      return nil
    }
  }

  /// The raw `error.code` the server sent, if any.
  public var serverCode: String? { info?.code }

  /// Whether the failure *could* succeed on a later attempt.
  ///
  /// This is not permission to auto-retry. A `checkScammer` retried on 5xx or a timeout **without**
  /// an `Idempotency-Key` risks a double charge, so a retrying caller must pass one.
  public var isTransient: Bool {
    switch self {
    case .network, .rateLimited: return true
    case .server(let status, _): return status >= 500
    default: return false
    }
  }

  // MARK: - Mapping

  /// Maps an HTTP status plus a parsed error envelope onto a typed error, per the table below.
  ///
  /// - Parameters:
  ///   - status: HTTP status code.
  ///   - code: `error.code` from the body, if the body parsed.
  ///   - message: `error.message` from the body.
  ///   - checkId: `error.checkId` from the body.
  ///   - retryAfter: parsed `Retry-After` header, seconds. See `retryAfterSeconds(from:now:)`.
  public static func from(
    status: Int,
    code: String?,
    message: String? = nil,
    checkId: String? = nil,
    retryAfter: TimeInterval? = nil
  ) -> TraciveError {
    let info = TraciveErrorInfo(code: code, message: message, checkId: checkId)

    switch (status, code) {
    case (400, "invalid_request"): return .invalidRequest(info)
    case (400, "unsupported_input_type"): return .unsupportedInputType(info)
    case (400, "unsupported_credit_source"): return .unsupportedCreditSource(info)

    case (401, "invalid_token"): return .invalidToken(info)
    case (401, "expired_token"): return .expiredToken(info)
    case (401, "grant_revoked"): return .grantRevoked(info)
    case (401, "invalid_api_key"): return .invalidApiKey(info)

    case (402, "insufficient_user_credits"):
      return .insufficientCredits(which: .userCredits, info: info)
    case (402, "insufficient_credits"):
      return .insufficientCredits(which: .credits, info: info)
    case (402, "insufficient_partner_balance"):
      return .insufficientCredits(which: .partnerBalance, info: info)

    case (403, "missing_scope"): return .missingScope(info)
    case (403, "detail_not_permitted"): return .detailNotPermitted(info)
    case (403, "credential_mismatch"): return .credentialMismatch(info)
    case (403, "partner_suspended"): return .partnerSuspended(info)

    case (409, "idempotency_conflict"): return .idempotencyConflict(info)

    case (429, "rate_limited"): return .rateLimited(retryAfter: retryAfter, info: info)

    default:
      // Unrecognised (status, code) pair. Never crash, never drop the code.
      if status == 429 { return .rateLimited(retryAfter: retryAfter, info: info) }
      if status >= 500 { return .server(status: status, info: info) }
      return .unknown(status: status, info: info)
    }
  }

  /// Parses a `Retry-After` header value: either a delay in seconds (`"120"`) or an HTTP-date
  /// (`"Wed, 21 Oct 2026 07:28:00 GMT"`), which is converted to a delay relative to `now`.
  /// Returns `nil` for anything else. A past date clamps to `0`.
  ///
  /// - Parameter now: injectable so the date branch is testable without a clock.
  public static func retryAfterSeconds(from header: String?, now: Date = Date()) -> TimeInterval? {
    guard let header else { return nil }
    let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let seconds = TimeInterval(trimmed) { return max(0, seconds) }
    guard let date = httpDateFormatter.date(from: trimmed) else { return nil }
    return max(0, date.timeIntervalSince(now))
  }

  private static let httpDateFormatter = HttpDateFormatterBox()

  // MARK: - Description

  public var description: String {
    switch self {
    case .notImplemented(let message):
      return "notImplemented(\(message))"
    case .insufficientCredits(let which, let info):
      return "insufficientCredits(\(which.rawValue)\(info.descriptionSuffix))"
    case .rateLimited(let retryAfter, let info):
      let after = retryAfter.map { "\($0)s" } ?? "unspecified"
      return "rateLimited(retryAfter: \(after)\(info.descriptionSuffix))"
    case .network(let cause):
      return "network(\(cause))"
    case .server(let status, let info):
      return "server(status: \(status)\(info.descriptionSuffix))"
    case .unknown(let status, let info):
      return "unknown(status: \(status.map(String.init) ?? "nil")\(info.descriptionSuffix))"
    case .cacheMiss:
      return "cacheMiss"
    case .stateMismatch:
      return "stateMismatch"
    case .invalidQuery(let error):
      return "invalidQuery(\(error.rawReason))"
    default:
      return "\(kind.rawValue)(\(info?.descriptionBody ?? ""))"
    }
  }

  public var errorDescription: String? {
    if let message = info?.message, !message.isEmpty { return message }
    switch self {
    case .notImplemented(let message): return message
    case .cacheMiss: return "No cached result for this query."
    case .stateMismatch: return "The OAuth callback state did not match."
    case .invalidQuery(let error): return error.errorDescription
    case .network(let cause): return (cause as NSError).localizedDescription
    default: return description
    }
  }
}

/// Flat discriminator over `TraciveError`, so callers can compare, log or switch on the case alone.
public enum TraciveErrorKind: String, CaseIterable, Hashable, Sendable {
  case notImplemented
  case invalidRequest
  case unsupportedInputType
  case unsupportedCreditSource
  case invalidToken
  case expiredToken
  case grantRevoked
  case invalidApiKey
  case insufficientCredits
  case missingScope
  case detailNotPermitted
  case credentialMismatch
  case partnerSuspended
  case idempotencyConflict
  case rateLimited
  case network
  case server
  case unknown
  case cacheMiss
  case stateMismatch
  case invalidQuery
}

/// Which balance ran out (HTTP 402).
public enum InsufficientCreditsKind: String, CaseIterable, Hashable, Sendable {
  /// `insufficient_user_credits` — the end user's own credits.
  case userCredits = "insufficient_user_credits"
  /// `insufficient_credits` — generic shortfall.
  case credits = "insufficient_credits"
  /// `insufficient_partner_balance` — the partner's prepaid balance.
  case partnerBalance = "insufficient_partner_balance"
}

/// The server's error envelope: `{"error":{"code","message","checkId"}}`.
public struct TraciveErrorInfo: Codable, Equatable, Hashable, Sendable {
  public let code: String?
  public let message: String?
  /// Present when the failure happened after a check id had been assigned; quote it in support
  /// tickets.
  public let checkId: String?

  public init(code: String? = nil, message: String? = nil, checkId: String? = nil) {
    self.code = code
    self.message = message
    self.checkId = checkId
  }

  public static let empty = TraciveErrorInfo()

  /// `code: …, checkId: …, message: …` for whichever parts are present.
  fileprivate var descriptionBody: String {
    var parts: [String] = []
    if let code { parts.append("code: \(code)") }
    if let checkId { parts.append("checkId: \(checkId)") }
    if let message { parts.append("message: \(message)") }
    return parts.joined(separator: ", ")
  }

  /// `descriptionBody` prefixed with a separator, for appending after an existing field.
  fileprivate var descriptionSuffix: String {
    let body = descriptionBody
    return body.isEmpty ? "" : ", " + body
  }
}

/// Decodable wrapper for the whole error body, so a transport can do
/// `JSONDecoder().decode(TraciveErrorEnvelope.self, from: data)` and hand the pieces to
/// `TraciveError.from(status:code:message:checkId:retryAfter:)`.
public struct TraciveErrorEnvelope: Decodable, Equatable, Sendable {
  public let error: TraciveErrorInfo

  public init(error: TraciveErrorInfo) {
    self.error = error
  }
}

/// RFC 7231 `IMF-fixdate` parser for `Retry-After`. `DateFormatter` is not `Sendable`, hence the
/// lock; the POSIX locale is mandatory or a user's calendar/locale can break parsing.
private final class HttpDateFormatterBox: @unchecked Sendable {
  private let lock = NSLock()
  private let formatter: DateFormatter

  init() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    self.formatter = formatter
  }

  func date(from string: String) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    return formatter.date(from: string)
  }
}
