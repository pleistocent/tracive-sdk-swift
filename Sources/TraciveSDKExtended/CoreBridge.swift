import Foundation
import TraciveReportCore
import TraciveSDK

/// Runs one `startX` call of the core and hands back its result.
///
/// Cancelling a Swift Task does not reach Kotlin by itself, so a closed form would keep uploading.
/// The continuation resumes from the core's completion alone, which it calls exactly once, also on
/// cancellation.
func bridged<Value, Output: Sendable>(
  _ convert: @escaping (Value) -> Output,
  start: (@escaping (Value?, KotlinThrowable?) -> Void) -> ReportCallHandle
) async throws -> Output {
  let cancellation = CallCancellation()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Output, Error>) in
      let handle = start { value, failure in
        if let value {
          continuation.resume(returning: convert(value))
        } else {
          continuation.resume(throwing: failure.map(swiftError) ?? emptyAnswer)
        }
      }
      cancellation.attach(handle)
    }
  } onCancel: {
    cancellation.cancel()
  }
}

private let emptyAnswer = TraciveReportError(code: .server, message: "The core gave no answer.")

/// `cancel()` can run before the handle exists: a Task cancelled while `startX` is still on the
/// stack would otherwise lose the signal.
private final class CallCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var handle: ReportCallHandle?
  private var cancelled = false

  func attach(_ handle: ReportCallHandle) {
    lock.lock()
    self.handle = handle
    let cancelNow = cancelled
    lock.unlock()
    if cancelNow { handle.cancel() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let handle = handle
    lock.unlock()
    handle?.cancel()
  }
}

private func swiftError(_ failure: KotlinThrowable) -> any Error {
  if SwiftBridgeKt.isCancellation(failure: failure) { return CancellationError() }
  if let report = failure as? TraciveReportException { return TraciveReportError(report) }
  do {
    try SwiftBridgeKt.rethrow(failure: failure)
    return emptyAnswer
  } catch {
    // A foreign error is the partner's own, from the token closure. One that started in Kotlin is a
    // bug or a response this version cannot read, which is what `.server` means.
    guard (error as NSError).kotlinException != nil else { return error }
    return TraciveReportError(code: .server, message: failure.message ?? "The call failed.")
  }
}

/// The token closure, as the core asks for it.
final class TokenBridge: NSObject, AccessTokenProvider, @unchecked Sendable {
  private let accessToken: @Sendable (String?) async throws -> String

  init(_ accessToken: @escaping @Sendable (String?) async throws -> String) {
    self.accessToken = accessToken
  }

  func accessToken(stale: String?) async throws -> String {
    do {
      return try await accessToken(stale)
    } catch let error as TraciveError {
      guard let report = TraciveReportError(base: error) else { throw error }
      throw report.core.asError()
    } catch let error as TraciveReportError {
      throw error.core.asError()
    }
  }
}

extension TraciveReportError {
  /// The base SDK's token errors, as the core's own `toReportException` maps Kotlin's. Nil for
  /// anything else, which reaches the caller unchanged.
  fileprivate init?(base error: TraciveError) {
    switch error {
    case .invalidToken, .expiredToken, .grantRevoked, .missingScope:
      self.init(
        code: .needsConsent,
        message: "This user has not granted the report permission. Authorize, then call again.",
        httpStatus: error.info?.code == nil ? nil : 401
      )
    case .network:
      self.init(code: .network, message: "The Tracive API could not be reached.")
    case .server(let status, _):
      self.init(code: .server, message: "The token call failed.", httpStatus: status)
    default:
      return nil
    }
  }
}

final class ProgressBridge: NSObject, ReportProgressListener, @unchecked Sendable {
  private let report: @Sendable (Double) -> Void

  init(_ report: @escaping @Sendable (Double) -> Void) {
    self.report = report
  }

  func onProgress(fraction: Float) {
    report(Double(fraction))
  }
}
