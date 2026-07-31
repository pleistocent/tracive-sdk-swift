import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The default `HTTPTransport`: `URLSession` and nothing else.
///
/// Zero third-party dependencies is this SDK's headline property for bank supply-chain review
/// (§11.6), so the network layer is the system one. There is no interceptor stack, no logging hook
/// and no request printing — a token and a `searchQueryIndex` pass through here, and the cheapest
/// way to guarantee they are never logged is to have nowhere for a log to happen.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {

  private let session: URLSession
  private let timeout: TimeInterval

  /// - Parameters:
  ///   - session: defaults to an ephemeral session — no URL cache, no cookie jar, no credential
  ///     storage. Tracive responses are cached by this SDK's own encrypted store (§5), so an HTTP
  ///     cache would keep a second, *unencrypted* copy of the same answers on disk.
  ///   - timeout: per-request timeout. A check that times out is the exact case §7 warns about: do
  ///     not blind-retry it without an `Idempotency-Key`.
  public init(session: URLSession? = nil, timeout: TimeInterval = 30) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.timeoutIntervalForRequest = timeout
      self.session = URLSession(configuration: configuration)
    }
    self.timeout = timeout
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = timeout
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await Self.perform(urlRequest, on: session)
    } catch {
      // No HTTP response at all: offline, DNS, TLS, timeout. §7 calls this `Network`.
      throw TraciveError.network(cause: error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw TraciveError.network(cause: URLError(.badServerResponse))
    }

    var headers: [String: String] = [:]
    headers.reserveCapacity(http.allHeaderFields.count)
    for (key, value) in http.allHeaderFields {
      guard let name = key as? String else { continue }
      headers[name] = value as? String ?? String(describing: value)
    }

    return HTTPResponse(status: http.statusCode, headers: headers, body: data)
  }

  /// `URLSession.data(for:)` needs iOS 15 / macOS 12. The SDK's floor is iOS 15, but the package is
  /// also built for macOS so its tests can run on a plain SwiftPM toolchain — and that macOS floor
  /// is set in `Package.swift`, which this file does not own. The delegate-free fallback keeps the
  /// transport compiling whatever floor is configured there.
  private static func perform(
    _ request: URLRequest,
    on session: URLSession
  ) async throws -> (Data, URLResponse) {
    if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
      return try await session.data(for: request)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let task = session.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, let response {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: URLError(.badServerResponse))
        }
      }
      task.resume()
    }
  }
}
