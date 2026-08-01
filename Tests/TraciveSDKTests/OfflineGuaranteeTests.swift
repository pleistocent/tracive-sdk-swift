import Foundation
import XCTest

@testable import TraciveSDK

/// Enforces the README's claim that `swift test` is "100% offline: no network, no Keychain, no real
/// server".
///
/// The claim held when it was written, but nothing checked it, and the SDK's default arguments make
/// breaking it one omitted parameter away: `SQLiteCheckCache(path:)` without a `keyStore:` reaches
/// the real Keychain, and `TraciveClient(mode:)` without a `cache:` reaches both the Keychain and
/// Application Support. Either would turn a green suite into one that prompts a human or fails with
/// `errSecMissingEntitlement` on an unsigned CI binary — and the failure would look like a bug in
/// the code under test rather than in the test's own wiring.
///
/// This scans the test sources themselves. That is deliberate: the property being protected is
/// "no test *can* do real I/O", which cannot be observed by running the tests that already avoid it.
final class OfflineGuaranteeTests: XCTestCase {

  /// Constructors that always perform real I/O, whatever arguments they are given.
  private static let forbiddenConstructors = [
    // The only type in the package that opens a socket.
    "URLSessionHTTPTransport(",
    // The production Keychain key store. Note the empty parens: the internal
    // `KeychainCacheKeyStore(items:)` test seam takes an injected item store and touches nothing,
    // so it is deliberately not matched here.
    "KeychainCacheKeyStore()",
  ]

  /// Constructors that are safe *only* when the given argument is supplied explicitly, because the
  /// default reaches the Keychain or the filesystem.
  private static let requiredArguments = [
    ("SQLiteCheckCache(", "keyStore:"),
    ("TraciveClient(", "cache:"),
  ]

  private static var testSourceFiles: [URL] {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    return contents.filter { $0.pathExtension == "swift" }
  }

  /// Blanks out string-literal contents, then strips `//` comments.
  ///
  /// Both steps matter. Without blanking literals first, a `//` inside a URL such as
  /// `URL(string: "https://…")` would truncate the rest of a line and hide a `cache:` argument that
  /// really is there — a false failure. Without stripping comments, prose that merely *names* one
  /// of these types would be reported as a call — a false failure of the other kind. A check that
  /// cries wolf gets suppressed, and then it protects nothing.
  private static func executableCode(of source: String) -> String {
    var text = source
    if let literals = try? NSRegularExpression(pattern: "\"(?:[^\"\\\\\n]|\\\\.)*\"") {
      text = literals.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\"\"")
    }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Substring in
        guard let comment = line.range(of: "//") else { return line }
        return line[line.startIndex..<comment.lowerBound]
      }
      .joined(separator: "\n")
  }

  /// The argument list of the call starting at `callSite`, found by balancing parentheses so a
  /// nested call or a multi-line invocation is read correctly.
  private static func argumentList(in text: String, startingAfter callSite: Range<String.Index>)
    -> String
  {
    var depth = 1
    var index = callSite.upperBound
    let start = index
    while index < text.endIndex, depth > 0 {
      switch text[index] {
      case "(": depth += 1
      case ")": depth -= 1
      default: break
      }
      if depth == 0 { return String(text[start..<index]) }
      index = text.index(after: index)
    }
    return String(text[start..<text.endIndex])
  }

  func testNoTestConstructsSomethingThatDoesRealIO() throws {
    let files = Self.testSourceFiles
    XCTAssertFalse(files.isEmpty, "scanned no test sources — this check would never fail")

    var offences: [String] = []

    for file in files {
      let code = Self.executableCode(of: try String(contentsOf: file, encoding: .utf8))

      for constructor in Self.forbiddenConstructors where code.contains(constructor) {
        offences.append("\(file.lastPathComponent): constructs \(constructor)")
      }

      for (constructor, required) in Self.requiredArguments {
        var searchFrom = code.startIndex
        while let call = code.range(of: constructor, range: searchFrom..<code.endIndex) {
          let arguments = Self.argumentList(in: code, startingAfter: call)
          if !arguments.contains(required) {
            offences.append(
              "\(file.lastPathComponent): \(constructor)…) with no \(required) — that default "
                + "reaches the real Keychain or Application Support")
          }
          searchFrom = call.upperBound
        }
      }
    }

    XCTAssertEqual(
      offences.sorted(), [],
      "a test would perform real network or Keychain I/O; the README promises the suite does neither"
    )
  }

  /// Guards the guard: if the scanner stopped finding the constructors it is supposed to police,
  /// it would pass vacuously forever. This asserts it still sees the real, legitimate call sites.
  func testTheScannerActuallyFindsTheCallSitesItPolices() throws {
    var sqliteCalls = 0
    var clientCalls = 0
    for file in Self.testSourceFiles {
      let code = Self.executableCode(of: try String(contentsOf: file, encoding: .utf8))
      sqliteCalls += code.components(separatedBy: "SQLiteCheckCache(").count - 1
      clientCalls += code.components(separatedBy: "TraciveClient(").count - 1
    }
    XCTAssertGreaterThan(sqliteCalls, 0, "the scanner no longer sees any SQLiteCheckCache( call")
    XCTAssertGreaterThan(clientCalls, 0, "the scanner no longer sees any TraciveClient( call")
  }
}
