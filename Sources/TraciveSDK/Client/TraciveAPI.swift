import Foundation

/// Path fragments for the Open API (§3.1), hung off `TraciveEnvironment.baseUrl` (which already
/// ends in `/v1`).
///
/// **None of these answer yet.** No `/v1/*` route is live as of
/// the Tracive API specification. They are the documented contract, and they exist here so that
/// exactly one file has to change when a path moves.
enum TraciveAPI {
  static let scammerChecks = "scammer-checks"
  static let credits = "credits"
  static let profile = "profile"
  static let oauthToken = "oauth/token"
  static let oauthRevoke = "oauth/revoke"

  static func url(_ path: String, in environment: TraciveEnvironment) -> URL {
    path.split(separator: "/").reduce(environment.baseUrl) { url, component in
      url.appendingPathComponent(String(component))
    }
  }
}

/// Request body for `POST /v1/scammer-checks` (§4).
///
/// Exactly four fields, and each one is deliberate:
///
/// - `creditSource` is always `"USER"` in phase 1. `PARTNER`/`AUTO` are phase 2 and the server
///   answers 400 `unsupported_credit_source` today.
/// - `query` rather than `input`: the SDK has already folded the key through the shared grammar,
///   and that same folded string is the cache key. Sending the structured `input` instead would
///   ask the server to fold it a second time, which is how the two sides drift apart.
/// - `locale` is omitted when `detail == .minimal`, because `minimal` is always English and the
///   server ignores the field there. Sending it anyway would make two identical requests look
///   different to an `Idempotency-Key` payload hash.
struct ScammerCheckRequestBody: Encodable, Equatable {
  let creditSource: String
  let detail: String
  let locale: String?
  let query: String

  init(query: TraciveQuery, detail: Detail, locale: String?) {
    self.creditSource = "USER"
    self.detail = detail.rawValue
    self.locale = detail == .minimal ? nil : locale
    self.query = query.searchQueryIndex
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(creditSource, forKey: .creditSource)
    try container.encode(detail, forKey: .detail)
    try container.encodeIfPresent(locale, forKey: .locale)
    try container.encode(query, forKey: .query)
  }

  private enum CodingKeys: String, CodingKey {
    case creditSource, detail, locale, query
  }
}

/// Turns an `HTTPResponse` into either a decoded model or a typed `TraciveError` (§7).
///
/// This is the only place in the SDK that reads an HTTP status. Everything upstream of it deals in
/// `TraciveError`, which is why an unrecognised server code can never crash a caller: it lands in
/// `.server`/`.unknown` carrying its raw spelling.
enum TraciveResponseMapper {

  /// Decodes a 2xx body, or maps any other status onto the §7 error table.
  ///
  /// - Parameter now: used only to resolve an HTTP-date `Retry-After` into a delay.
  static func decode<T: Decodable>(
    _ type: T.Type,
    from response: HTTPResponse,
    now: Date
  ) throws -> T {
    guard response.isSuccess else {
      throw error(from: response, now: now)
    }
    do {
      return try JSONDecoder().decode(T.self, from: response.body)
    } catch let decodingError as DecodingError {
      // A 2xx whose body we cannot read is a contract violation, not a caller error. The message
      // names the coding path only — never the body, which carries user-generated comments.
      throw TraciveError.unknown(
        status: response.status,
        info: TraciveErrorInfo(
          code: "invalid_response",
          message: "Malformed response body at \(location(of: decodingError))."
        )
      )
    } catch {
      throw TraciveError.unknown(
        status: response.status,
        info: TraciveErrorInfo(code: "invalid_response", message: "Malformed response body.")
      )
    }
  }

  /// Maps a non-2xx response onto the §7 table.
  static func error(from response: HTTPResponse, now: Date) -> TraciveError {
    let info = errorInfo(from: response.body)
    let retryAfter = TraciveError.retryAfterSeconds(from: response.header("Retry-After"), now: now)
    return TraciveError.from(
      status: response.status,
      code: info.code,
      message: info.message,
      checkId: info.checkId,
      retryAfter: retryAfter
    )
  }

  /// Parses an error body in either shape the backend can produce.
  ///
  /// The `/v1/*` routes answer with Tracive's envelope, `{"error":{"code","message","checkId"}}`
  /// (§7). The OAuth routes answer with RFC 6749's flat shape,
  /// `{"error":"invalid_grant","error_description":"…"}` — §3.5 lists `invalid_grant`,
  /// `unsupported_grant_type` and `invalid_client` explicitly as "RFC 6749" errors. Both are read
  /// here so a caller never has to care which endpoint it was talking to, and an unparseable body
  /// degrades to "no code" rather than to a thrown decoding error.
  static func errorInfo(from body: Data) -> TraciveErrorInfo {
    guard !body.isEmpty else { return .empty }
    if let envelope = try? JSONDecoder().decode(TraciveErrorEnvelope.self, from: body) {
      return envelope.error
    }
    if let flat = try? JSONDecoder().decode(FlatOAuthErrorBody.self, from: body) {
      return TraciveErrorInfo(code: flat.error, message: flat.errorDescription)
    }
    return .empty
  }

  /// Names *where* a body failed to decode, using field names only.
  ///
  /// Deliberately never includes a decoded value or the raw body: a `detail=full` response carries
  /// user-generated comments, and a diagnostic that quotes them turns a parse error into a PII
  /// leak in whatever the host app does with `errorDescription`.
  ///
  /// `keyNotFound` needs the missing key appended explicitly — its `codingPath` describes the
  /// *container*, so a top-level missing field would otherwise report as `<root>` and say nothing.
  private static func location(of error: DecodingError) -> String {
    var path: [String]
    switch error {
    case .keyNotFound(let key, let context):
      path = context.codingPath.map(\.stringValue) + [key.stringValue]
    case .typeMismatch(_, let context), .valueNotFound(_, let context),
      .dataCorrupted(let context):
      path = context.codingPath.map(\.stringValue)
    @unknown default:
      path = []
    }
    let joined = path.joined(separator: ".")
    return joined.isEmpty ? "<root>" : joined
  }
}

extension TraciveError {
  /// A failure that originated inside the SDK rather than at the server.
  ///
  /// It rides in `.unknown` with `status == nil` and a namespaced `code`, which is exactly the
  /// escape hatch §7 asks for ("an unrecognised code must map to a generic `Server`/`Unknown`
  /// carrying the raw code"). Callers can therefore switch on `serverCode` uniformly without
  /// caring whether a code came off the wire or from here.
  static func sdk(_ code: String, _ message: String) -> TraciveError {
    .unknown(status: nil, info: TraciveErrorInfo(code: code, message: message))
  }
}

/// RFC 6749 §5.2 error body, used by the OAuth token and revoke endpoints.
private struct FlatOAuthErrorBody: Decodable {
  let error: String
  let errorDescription: String?

  private enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}
