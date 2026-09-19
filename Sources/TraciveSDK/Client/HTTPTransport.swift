import Foundation

/// The one seam through which every byte of network traffic leaves this SDK.
///
/// **Why this exists.** Every behaviour in this SDK (request shape, cache routing, token refresh,
/// error mapping) is specified against an injected transport and verified against a fake, and no
/// unit test in this package opens a socket, so the suite never depends on either environment
/// being up. `URLSessionHTTPTransport` is the only part that talks to a real server.
///
/// A conformer must be safe to call from multiple tasks at once — `TraciveClient` is an actor, but
/// it deliberately does *not* hold the actor while awaiting a response, so two checks can be in
/// flight together.
public protocol HTTPTransport: Sendable {
  /// Performs one request. Throw for a transport-level failure (offline, DNS, TLS, timeout); return
  /// the response for **every** HTTP status, including 4xx and 5xx — status interpretation belongs
  /// to `TraciveClient`, not here.
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The HTTP verbs this SDK uses. `POST /v1/scammer-checks`, `GET /v1/credits`, `GET /v1/profile`,
/// `POST /v1/oauth/token`, `POST /v1/oauth/revoke` — that is the whole surface.
public enum HTTPMethod: String, Hashable, Sendable {
  case get = "GET"
  case post = "POST"
}

/// A transport-level request: no Tracive semantics, no auth knowledge, nothing to interpret.
///
/// `headers` already contains the `Authorization` header by the time a transport sees it. A
/// conformer must never log this value — see the redacted `description`.
public struct HTTPRequest: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var method: HTTPMethod
  public var url: URL
  public var headers: [String: String]
  public var body: Data?

  public init(
    method: HTTPMethod,
    url: URL,
    headers: [String: String] = [:],
    body: Data? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }

  /// Case-insensitive header read. HTTP header names are case-insensitive and `URLSession`
  /// canonicalises them, so a literal dictionary subscript is not enough.
  public func header(_ name: String) -> String? {
    HTTPHeaderLookup.value(for: name, in: headers)
  }

  /// Sets a header, replacing any existing entry whose name matches case-insensitively.
  public mutating func setHeader(_ name: String, to value: String?) {
    HTTPHeaderLookup.set(name, to: value, in: &headers)
  }

  /// Header **names** and the body's size only.
  ///
  /// The `Authorization` header carries a bearer token and the body carries `searchQueryIndex`,
  /// which embeds the raw phone number / account number being checked. Neither may reach a log,
  /// a `print`, or a crash report.
  public var description: String {
    "HTTPRequest(\(method.rawValue) \(url.absoluteString), "
      + "headers: [\(headers.keys.sorted().joined(separator: ", "))] = <redacted>, "
      + "body: \(body.map { "<redacted \($0.count) bytes>" } ?? "nil"))"
  }

  public var debugDescription: String { description }
}

/// A transport-level response. `status` is reported for every outcome that reached the server;
/// only a failure to reach it at all is thrown.
public struct HTTPResponse: Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var status: Int
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  /// Case-insensitive header read — this is how `Retry-After` is found.
  public func header(_ name: String) -> String? {
    HTTPHeaderLookup.value(for: name, in: headers)
  }

  public var isSuccess: Bool { (200..<300).contains(status) }

  /// Body size only: a `detail=full` response carries user-generated comments, which are PII-shaped.
  public var description: String {
    "HTTPResponse(status: \(status), "
      + "headers: [\(headers.keys.sorted().joined(separator: ", "))], "
      + "body: <redacted \(body.count) bytes>)"
  }

  public var debugDescription: String { description }
}

/// Case-insensitive lookups over a plain `[String: String]` header dictionary.
enum HTTPHeaderLookup {

  static func value(for name: String, in headers: [String: String]) -> String? {
    if let exact = headers[name] { return exact }
    let wanted = name.lowercased()
    for (key, value) in headers where key.lowercased() == wanted { return value }
    return nil
  }

  static func set(_ name: String, to value: String?, in headers: inout [String: String]) {
    let wanted = name.lowercased()
    for key in headers.keys where key.lowercased() == wanted {
      headers.removeValue(forKey: key)
    }
    if let value { headers[name] = value }
  }
}
