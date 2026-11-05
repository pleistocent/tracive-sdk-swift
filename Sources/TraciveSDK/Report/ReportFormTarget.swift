import Foundation

/// Which Tracive build `openReportForm` hands the report to.
///
/// Normally chosen by the client's environment: `.production` for `.production` and `.custom`,
/// `.sandbox` for `.sandbox`. Each build claims its own file extension, so a device holding both
/// apps offers only the one that matches, and a sandbox report can never open a real report form.
///
/// Build one yourself only for testing against a build the SDK does not know about, such as an
/// internal QA build. Its two schemes then need entries in your `LSApplicationQueriesSchemes` too,
/// or the SDK cannot see it and sends the user to the install page.
public struct ReportFormTarget: Hashable, Sendable, CustomStringConvertible {

  /// The app the "Open in" sheet must hand the file to for the result to be
  /// `.opened(attachmentsDelivered: true)`. Any other app the user picks answers `.cancelled`.
  public let bundleIdentifier: String
  /// The app's existing URL scheme: whether it is installed, and the identifier-only fallback link.
  public let scheme: String
  /// Registered only by app versions that accept a report package.
  public let capabilityScheme: String
  /// The extension the package is written with. iOS offers whichever apps claim it.
  public let fileExtension: String

  public init(
    bundleIdentifier: String, scheme: String, capabilityScheme: String, fileExtension: String
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.scheme = scheme
    self.capabilityScheme = capabilityScheme
    self.fileExtension = fileExtension
  }

  public static let production = ReportFormTarget(
    bundleIdentifier: "com.pleistocent.tracive",
    scheme: TraciveAppPresence.productionScheme,
    capabilityScheme: "tracive-report",
    fileExtension: "tracivereport"
  )

  public static let sandbox = ReportFormTarget(
    bundleIdentifier: "com.pleistocent.tracive.sandbox",
    scheme: TraciveAppPresence.sandboxScheme,
    capabilityScheme: "tracivesandbox-report",
    fileExtension: "tracivesandboxreport"
  )

  /// The build for `environment`. A custom base URL is a partner proxy or a local server; the app
  /// on the device is still the production one, as `TraciveAppPresence.scheme(for:)` decides.
  public static func `for`(_ environment: TraciveEnvironment) -> ReportFormTarget {
    switch environment {
    case .sandbox: return .sandbox
    case .production, .custom: return .production
    }
  }

  public var description: String {
    "ReportFormTarget(\(bundleIdentifier), scheme: \(scheme), "
      + "capabilityScheme: \(capabilityScheme), fileExtension: \(fileExtension))"
  }

  var appProbeURL: URL? { URL(string: "\(scheme)://") }

  var capabilityProbeURL: URL? { URL(string: "\(capabilityScheme)://") }

  /// `<scheme>://report/create?media=<searchQueryIndex>`, which every released Tracive app opens as
  /// a prefilled report form.
  ///
  /// Everything outside RFC 3986's unreserved set is percent-encoded, `+` included: a `+` left bare
  /// reads as a space to a form decoder, and `PHONE_+62…` would arrive as `PHONE_ 62…`, an empty
  /// form.
  func reportLink(for searchQueryIndex: String) -> URL? {
    guard let media = searchQueryIndex.addingPercentEncoding(withAllowedCharacters: Self.unreserved)
    else { return nil }
    return URL(string: "\(scheme)://report/create?media=\(media)")
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )
}
