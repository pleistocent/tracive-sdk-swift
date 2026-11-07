import Foundation
import Network

/// A real HTTP/1.1 server on the loopback: the Kotlin core talks through its own URLSession, so
/// nothing short of a socket can stand in for the Open API or for a stalled upload.
final class StubServer: @unchecked Sendable {

  struct Request: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var json: [String: Any]? {
      (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
  }

  struct Reply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
      Reply(status: status, headers: headers, body: Data(text.utf8))
    }

    static func apiError(_ code: String, status: Int, headers: [String: String] = [:]) -> Reply {
      json(#"{"error":{"code":"\#(code)","message":"refused"}}"#, status: status, headers: headers)
    }
  }

  private let queue = DispatchQueue(label: "stub-server")
  private let lock = NSLock()
  private var listener: NWListener?
  private var handler: @Sendable (Request) -> Reply
  private var recorded: [Request] = []
  private var stallUploads = false
  private var stalled: StalledUpload?
  private var stalledCount = 0

  private(set) var port: UInt16 = 0

  init(handler: @escaping @Sendable (Request) -> Reply) {
    self.handler = handler
  }

  deinit {
    listener?.cancel()
  }

  var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

  var requests: [Request] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func requests(_ method: String, _ path: String) -> [Request] {
    requests.filter { $0.method == method && $0.path == path }
  }

  func setHandler(_ handler: @escaping @Sendable (Request) -> Reply) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  /// From now on a PUT is read a trickle at a time and never answered.
  func stallUploads(_ enabled: Bool) {
    lock.lock()
    stallUploads = enabled
    lock.unlock()
  }

  var stalledUpload: StalledUpload? {
    lock.lock()
    defer { lock.unlock() }
    return stalled
  }

  var stalledUploadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return stalledCount
  }

  func start() async throws {
    // Bound to 127.0.0.1 exactly. On `.any` the simulator shares the Mac's ports, and a service
    // already bound to 127.0.0.1 on the same port quietly answers in this server's place.
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = Once()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: once.run { continuation.resume() }
        case .failed(let error): once.run { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
    port = listener.port?.rawValue ?? 0
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    readHead(connection, buffer: Data())
  }

  private func readHead(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        self.route(connection, head: head, body: Data(buffer[end.upperBound...]))
      } else if !isComplete, error == nil {
        self.readHead(connection, buffer: buffer)
      } else {
        connection.cancel()
      }
    }
  }

  private func route(_ connection: NWConnection, head: String, body: Data) {
    let lines = head.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ").map(String.init)
    guard parts.count >= 2 else {
      connection.cancel()
      return
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
    }
    lock.lock()
    let stall = stallUploads && parts[0] == "PUT"
    lock.unlock()
    if stall {
      let upload = StalledUpload(initial: body.count)
      lock.lock()
      stalled = upload
      stalledCount += 1
      lock.unlock()
      trickle(connection, upload: upload)
      return
    }
    let length = Int(headers["content-length"] ?? "") ?? 0
    readBody(connection, length: length, buffer: body) { [weak self] full in
      self?.answer(
        connection, Request(method: parts[0], path: parts[1], headers: headers, body: full))
    }
  }

  private func readBody(
    _ connection: NWConnection,
    length: Int,
    buffer: Data,
    done: @escaping @Sendable (Data) -> Void
  ) {
    guard buffer.count < length else {
      done(buffer)
      return
    }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      if !isComplete, error == nil {
        self?.readBody(connection, length: length, buffer: buffer, done: done)
      } else {
        done(buffer)
      }
    }
  }

  private func answer(_ connection: NWConnection, _ request: Request) {
    lock.lock()
    recorded.append(request)
    let handler = handler
    lock.unlock()
    let reply = handler(request)
    var head = "HTTP/1.1 \(reply.status) Stub\r\nContent-Length: \(reply.body.count)\r\n"
    head += "Connection: close\r\n"
    for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    connection.send(
      content: Data(head.utf8) + reply.body,
      completion: .contentProcessed { _ in connection.cancel() }
    )
  }

  private func trickle(_ connection: NWConnection, upload: StalledUpload) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
      [weak self, queue] data, _, isComplete, error in
      upload.add(data?.count ?? 0)
      if isComplete || error != nil {
        upload.markClosed()
        connection.cancel()
        return
      }
      if upload.isDraining {
        self?.trickle(connection, upload: upload)
      } else {
        queue.asyncAfter(deadline: .now() + 0.05) { self?.trickle(connection, upload: upload) }
      }
    }
  }
}

/// What a stalled upload's connection has done so far.
final class StalledUpload: @unchecked Sendable {
  private let lock = NSLock()
  private var received: Int
  private var closed = false
  private var draining = false

  init(initial: Int) {
    received = initial
  }

  var bytesReceived: Int {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  var isDraining: Bool {
    lock.lock()
    defer { lock.unlock() }
    return draining
  }

  /// Reads the rest at full speed. The socket reports a closed peer only once its buffer is empty,
  /// and a client that is still sending never closes, so this cannot hide a running upload.
  func drain() {
    lock.lock()
    draining = true
    lock.unlock()
  }

  func add(_ count: Int) {
    lock.lock()
    received += count
    lock.unlock()
  }

  func markClosed() {
    lock.lock()
    closed = true
    lock.unlock()
  }
}

private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  func run(_ work: () -> Void) {
    lock.lock()
    let first = !done
    done = true
    lock.unlock()
    if first { work() }
  }
}

/// An Open API that accepts everything, with counters left to `StubServer.requests`.
func openAPI(
  _ request: StubServer.Request,
  uploadBase: @autoclosure () -> URL
) -> StubServer.Reply {
  switch (request.method, request.path) {
  case ("GET", "/v1/report-requirements"):
    return .json(requirementsJSON)
  case ("POST", "/v1/report-uploads"):
    let files = (request.json?["attachments"] as? [Any])?.count ?? 0
    let attachments = (0..<files).map {
      #"{"attachmentId":"att_\#($0)","url":"\#(uploadBase().absoluteString)/upload/\#($0)"}"#
    }
    return .json(
      #"{"uploadId":"upl_1","attachments":[\#(attachments.joined(separator: ","))]}"#)
  case ("PUT", _):
    return .json("")
  case ("POST", "/v1/reports"):
    return .json(#"{"reportId":"rep_1","status":"SUBMITTED"}"#, status: 202)
  default:
    if request.method == "GET", request.path.hasPrefix("/v1/reports/") {
      return .json(#"{"reportId":"rep_1","status":"IN_REVIEW"}"#)
    }
    return .apiError("not_found", status: 404)
  }
}

let requirementsJSON = """
  {"enabled":true,"remainingToday":3,"limits":{"titleMaxLength":50,"chronologyMinLength":50,
  "chronologyMaxLength":5000,"commentMaxLength":500,"maxIdentifiers":5,
  "attachmentsPerIdentifier":3,"extraAttachmentsWithPhone":2,"maxAttachmentBytes":1048576,
  "attachmentTypes":["image/avif","image/jpeg","application/pdf"]},
  "terms":[{"id":"TERMS_OF_SERVICE","version":"3","url":"https://tracive.id/terms"},
  {"id":"PRIVACY_POLICY","version":"2","url":"https://tracive.id/privacy"}]}
  """
