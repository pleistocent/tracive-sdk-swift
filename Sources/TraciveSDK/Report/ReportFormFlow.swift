import Foundation

/// What the system "Open in" sheet reported back.
enum OpenInMenuOutcome: Equatable, Sendable {
  /// `willBeginSendingToApplication`: the user picked an app, named by its bundle id.
  case sending(toApplication: String?)
  /// Closed with no app picked. "Save to Files" lands here too: it fires no `willBegin`.
  case dismissed
  /// The sheet never appeared.
  case notPresented(reason: String)
}

/// Shows the "Open in" sheet for a file and answers what the user did. The production conformer
/// wraps `UIDocumentInteractionController`; tests supply a fake, so nothing here needs UIKit.
@MainActor
protocol OpenInMenuPresenting {
  func presentOpenInMenu(for file: URL) async -> OpenInMenuOutcome
}

/// Turns the sheet's delegate callbacks into one `OpenInMenuOutcome`, delivered once.
///
/// iOS calls them in the order `willBeginSendingToApplication`, `didDismissOpenInMenu`,
/// `didEndSendingToApplication`. The answer is settled on `willBegin`; the dismissal that follows
/// it must not turn a delivery into a cancel. A dismissal with no `willBegin` before it is the user
/// closing the sheet or choosing "Save to Files".
@MainActor
final class OpenInMenuResolution {

  private var onResolve: ((OpenInMenuOutcome) -> Void)?
  private var sendingBegan = false

  /// Whether the controller may be let go. Not the same moment as the answer: after `willBegin` the
  /// file is still being handed over, so the controller lives until `didEndSending`.
  private(set) var isFinished = false

  init(onResolve: @escaping (OpenInMenuOutcome) -> Void) {
    self.onResolve = onResolve
  }

  func notPresented(reason: String) {
    isFinished = true
    resolve(.notPresented(reason: reason))
  }

  func willBeginSending(toApplication application: String?) {
    sendingBegan = true
    resolve(.sending(toApplication: application))
  }

  func didDismissMenu() {
    guard !sendingBegan else { return }
    isFinished = true
    resolve(.dismissed)
  }

  func didEndSending(toApplication application: String?) {
    isFinished = true
    resolve(.sending(toApplication: application))
  }

  private func resolve(_ outcome: OpenInMenuOutcome) {
    guard let onResolve else { return }
    self.onResolve = nil
    onResolve(outcome)
  }
}

/// Notices the "Open in" sheet has gone without a word to its delegate. iPadOS takes it down when
/// the device rotates and calls no delegate method at all, so a call waiting on the delegate would
/// never return, and the gate below would refuse every later call.
///
/// Polled. The sheet must be seen gone on two checks in a row, so that a delegate answer already on
/// its way still decides the outcome.
@MainActor
final class VanishedSheetWatch {

  private let isGone: @MainActor () -> Bool
  private let onVanished: @MainActor () -> Void
  private var goneChecks = 0
  private(set) var hasFired = false

  init(isGone: @escaping @MainActor () -> Bool, onVanished: @escaping @MainActor () -> Void) {
    self.isGone = isGone
    self.onVanished = onVanished
  }

  func check() {
    guard !hasFired else { return }
    goneChecks = isGone() ? goneChecks + 1 : 0
    guard goneChecks >= 2 else { return }
    hasFired = true
    onVanished()
  }
}

/// One report at a time, process-wide. Each call clears the package folder before writing its own,
/// so a second call while a sheet is still up would delete the file that sheet is about to hand
/// over, and the first call would still answer `.opened(attachmentsDelivered: true)`.
@MainActor
final class ReportFormGate {
  static let shared = ReportFormGate()
  var isBusy = false
}

/// Where packages are written. Each call deletes whatever earlier calls left, then writes into a
/// fresh folder: the package holds a receipt and an account number, and the system temp directory
/// is only purged when iOS gets round to it.
struct ReportPackageStore: Sendable {

  let root: URL

  static let `default` = ReportPackageStore(
    root: FileManager.default.temporaryDirectory
      .appendingPathComponent("tracive-sdk", isDirectory: true)
      .appendingPathComponent("report", isDirectory: true)
  )

  func replaceAll(with package: Data, fileExtension: String) throws -> URL {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: root.path) {
      try? fileManager.removeItem(at: root)
    }
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("report").appendingPathExtension(fileExtension)
    try package.write(to: file, options: .atomic)
    return file
  }
}

/// `openReportForm`, minus UIKit: validate, then hand over the package, the link or the install
/// page, whichever the device can take.
@MainActor
struct ReportFormFlow {

  let target: ReportFormTarget
  let installURL: URL
  let launcher: any TraciveAppLauncher
  let store: ReportPackageStore
  let gate: ReportFormGate

  func run(
    searchQueryIndex: String,
    incidentDate: ReportIncidentDate?,
    attachments: [ReportAttachment],
    today: ReportIncidentDate,
    presenter: any OpenInMenuPresenting
  ) async -> ReportFormResult {
    guard !gate.isBusy else {
      return .failed(.platform(reason: "already_in_progress"))
    }
    gate.isBusy = true
    defer { gate.isBusy = false }

    // Off the main actor: encoding a package near the 20 MiB cap takes long enough to drop frames.
    let built = await Task.detached(priority: .userInitiated) {
      ReportPackage.build(
        searchQueryIndex: searchQueryIndex,
        incidentDate: incidentDate,
        attachments: attachments,
        today: today
      )
    }.value
    let package: Data
    switch built {
    case .success(let data): package = data
    case .failure(let error): return .failed(error)
    }

    if await canOpen(target.capabilityProbeURL) {
      return await handOver(package, presenter: presenter)
    }

    if await canOpen(target.appProbeURL) {
      guard let link = target.reportLink(for: searchQueryIndex) else {
        return .failed(.platform(reason: "report_link_invalid"))
      }
      // `false` here is mostly the user tapping Cancel on iOS's "Open in Tracive?" prompt.
      return await launcher.open(link) ? .opened(attachmentsDelivered: false) : .cancelled
    }

    return await launcher.open(installURL)
      ? .installPageOpened : .failed(.platform(reason: "install_link_refused"))
  }

  private func handOver(_ package: Data, presenter: any OpenInMenuPresenting) async
    -> ReportFormResult
  {
    let store = self.store
    let fileExtension = target.fileExtension
    let written = await Task.detached(priority: .userInitiated) {
      try? store.replaceAll(with: package, fileExtension: fileExtension)
    }.value
    guard let file = written else {
      return .failed(.platform(reason: "package_write_failed"))
    }

    switch await presenter.presentOpenInMenu(for: file) {
    case .sending(let application) where application == target.bundleIdentifier:
      return .opened(attachmentsDelivered: true)
    case .sending, .dismissed:
      return .cancelled
    case .notPresented(let reason):
      return .failed(.platform(reason: reason))
    }
  }

  private func canOpen(_ url: URL?) async -> Bool {
    guard let url else { return false }
    return await launcher.canOpen(url)
  }
}
