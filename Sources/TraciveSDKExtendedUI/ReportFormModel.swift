import Foundation
import SwiftUI
import TraciveSDK
import TraciveSDKExtended
import UIKit

@MainActor
final class ReportFormModel: ObservableObject {

  enum Load: Equatable {
    case loading
    case failed(TraciveReportError.Code)
    case ready
  }

  enum EvidenceState {
    case preparing
    case ready(PreparedEvidence)
    case failed(TraciveReportError.Code)
  }

  struct EvidenceItem: Identifiable {
    let id: Int
    var state = EvidenceState.preparing
    var name: String?
    var mimeType: String?
    var thumbnail: UIImage?
  }

  /// Why Send cannot work at all right now, as opposed to a field that needs fixing.
  enum SendBlock: Equatable {
    case reportingDisabled
    case dailyLimit
  }

  /// Why the evidence stops a send, on top of the core's field problems.
  enum EvidenceBlock: Equatable {
    case stillPreparing
    case fileFailed
  }

  struct Failure: Equatable {
    let code: TraciveReportError.Code
    var retryAfterSeconds: Int?
  }

  struct SentReport: Equatable {
    let reportId: String
    let status: ReportStatus
  }

  let reports: TraciveReports
  let identifiers: [String]

  @Published private(set) var load = Load.loading
  @Published private(set) var requirements: ReportRequirements?
  @Published var title: String
  @Published var chronology = ""
  @Published var comment = ""
  @Published var incidentDate: Date?
  @Published private(set) var evidence: [EvidenceItem] = []
  /// The user picked more than the form can take, and the rest was left out.
  @Published private(set) var evidenceOverflow = false
  @Published private(set) var sending = false
  @Published private(set) var progress = 0.0
  @Published private(set) var failure: Failure?
  @Published private(set) var sent: SentReport?
  /// The status the server gave after sending. Nil hides it: `report.read` is optional.
  @Published private(set) var checkedStatus: ReportStatus?
  /// Moves each time a send stops at a field, so the screen can scroll to it.
  @Published private(set) var attentionRequests = 0

  @Published private var refused: SendBlock?
  @Published private var termsLoading = false
  @Published private var validated = false
  private var termsStale = false

  private(set) var outcome = ReportFormOutcome.cancelled
  var onFinish: (() -> Void)?

  private let prefill: [EvidenceInput]
  private var prefillStarted = false
  private var draft: ReportDraft?
  private var nextEvidenceId = 0
  private var evidenceTasks: [Int: Task<Void, Never>] = [:]
  private var tasks: [Task<Void, Never>] = []

  init(reports: TraciveReports, prefill: ReportPrefill) {
    self.reports = reports
    identifiers = prefill.identifiers
    title = prefill.title ?? ""
    incidentDate = prefill.incidentDate.flatMap(Self.date)
    self.prefill = prefill.attachments.map(EvidenceInput.attachment)
    loadRequirements()
  }

  /// Whether closing would throw away something the user made. Once sent, nothing is left to lose.
  var hasWork: Bool {
    sent == nil && (sending || !chronology.isEmpty || !comment.isEmpty || !evidence.isEmpty)
  }

  var sendBlock: SendBlock? {
    if let refused { return refused }
    guard let requirements else { return nil }
    if !requirements.enabled { return .reportingDisabled }
    return requirements.remainingToday <= 0 ? .dailyLimit : nil
  }

  var canSend: Bool {
    requirements != nil && sendBlock == nil && !sending && !termsLoading
  }

  var problems: [ReportFieldProblem] {
    guard validated, let requirements else { return [] }
    return problems(in: candidate(requirements), requirements)
  }

  var evidenceBlock: EvidenceBlock? {
    validated ? findEvidenceBlock() : nil
  }

  var maxEvidence: Int {
    requirements.map { candidate($0).maxEvidence(limits: $0.limits) } ?? 0
  }

  /// How many more files fit. A file that failed takes no place: it can never be sent.
  var evidenceRoom: Int {
    let held = evidence.filter {
      if case .failed = $0.state { return false }
      return true
    }
    return max(maxEvidence - held.count, 0)
  }

  func retryLoad() {
    load = .loading
    loadRequirements()
  }

  func addEvidence(_ inputs: [EvidenceInput]) {
    let room = evidenceRoom
    evidenceOverflow = inputs.count > room
    inputs.prefix(room).forEach(startEvidence)
  }

  func removeEvidence(id: Int) {
    evidenceTasks.removeValue(forKey: id)?.cancel()
    evidence.removeAll { $0.id == id }
    evidenceOverflow = false
  }

  func send() {
    guard let requirements, canSend else { return }
    if termsStale {
      refreshTerms()
      return
    }
    validated = true
    let next = candidate(requirements)
    if findEvidenceBlock() != nil || !problems(in: next, requirements).isEmpty {
      attentionRequests += 1
      return
    }
    // A retry must keep its idempotency key. An edited report cannot: the core sends the first body
    // again for a key it has seen, which would quietly drop the edit.
    let chosen = draft.flatMap { $0.isSameReport(as: next) ? $0 : nil } ?? next
    draft = chosen
    sending = true
    progress = 0
    failure = nil
    track { [weak self] in
      guard let self else { return }
      defer { self.sending = false }
      do {
        let result = try await self.reports.submit(chosen) { [weak self] fraction in
          Task { @MainActor [weak self] in self?.progress = fraction }
        }
        switch result {
        case .submitted(let reportId, let status):
          self.onSubmitted(SentReport(reportId: reportId, status: status))
        case .needsConsent:
          self.finish(.needsConsent)
        case .failed(let error):
          self.onSendFailed(error)
        }
      } catch is CancellationError {
        // The form is closing.
      } catch let error as TraciveReportError {
        self.onSendFailed(error)
      } catch {
        self.failure = Failure(code: .server)
      }
    }
  }

  /// Asks the host to take the screen away. `close()` follows from there.
  func done() {
    onFinish?()
  }

  func close() {
    tasks.forEach { $0.cancel() }
    evidenceTasks.values.forEach { $0.cancel() }
    tasks = []
    evidenceTasks = [:]
  }

  private func finish(_ result: ReportFormOutcome) {
    outcome = result
    onFinish?()
  }

  private func track(_ work: @escaping @MainActor () async -> Void) {
    tasks.append(Task { @MainActor in await work() })
  }

  private func loadRequirements() {
    track { [weak self] in
      guard let self else { return }
      do {
        self.requirements = try await self.reports.requirements()
        self.load = .ready
        self.startPrefill()
      } catch is CancellationError {
        // The form is closing.
      } catch let error as TraciveReportError {
        if error.code == .needsConsent {
          self.finish(.needsConsent)
        } else {
          self.load = .failed(error.code)
        }
      } catch {
        self.load = .failed(.server)
      }
    }
  }

  private func startPrefill() {
    guard !prefillStarted else { return }
    prefillStarted = true
    prefill.forEach(startEvidence)
  }

  private func startEvidence(_ input: EvidenceInput) {
    let id = nextEvidenceId
    nextEvidenceId += 1
    evidence.append(EvidenceItem(id: id))
    let reports = reports
    evidenceTasks[id] = Task { @MainActor [weak self] in
      do {
        let file = try await input.read()
        self?.update(id) {
          $0.name = file.name
          $0.mimeType = file.mimeType
          $0.thumbnail = file.thumbnail
        }
        let prepared = try await reports.prepare(file.data, mimeType: file.mimeType)
        self?.update(id) { $0.state = .ready(prepared) }
      } catch is CancellationError {
        // Removed, or the form is closing.
      } catch let error as TraciveReportError {
        self?.update(id) { $0.state = .failed(error.code) }
      } catch {
        self?.update(id) { $0.state = .failed(.imageUnreadable) }
      }
    }
  }

  private func update(_ id: Int, _ change: (inout EvidenceItem) -> Void) {
    guard let index = evidence.firstIndex(where: { $0.id == id }) else { return }
    change(&evidence[index])
  }

  private func onSubmitted(_ report: SentReport) {
    sent = report
    outcome = .submitted(reportId: report.reportId, status: report.status)
    track { [weak self] in
      guard let self else { return }
      // A partner without `report.read` gets `.needsConsent` here. Sending worked either way, so
      // the status line just stays hidden.
      self.checkedStatus = try? await self.reports.status(report.reportId)
    }
  }

  private func onSendFailed(_ error: TraciveReportError) {
    failure = Failure(code: error.code, retryAfterSeconds: error.retryAfterSeconds)
    switch error.code {
    case .termsOutdated:
      draft = nil
      termsStale = true
      refreshTerms()
    case .dailyLimitReached:
      refused = .dailyLimit
    case .reportingDisabled:
      refused = .reportingDisabled
    default:
      break
    }
  }

  private func refreshTerms() {
    termsLoading = true
    track { [weak self] in
      guard let self else { return }
      defer { self.termsLoading = false }
      do {
        self.requirements = try await self.reports.requirements()
        self.termsStale = false
      } catch is CancellationError {
        // The form is closing.
      } catch let error as TraciveReportError {
        if error.code == .needsConsent {
          self.finish(.needsConsent)
        } else {
          self.failure = Failure(code: error.code)
        }
      } catch {
        self.failure = Failure(code: .server)
      }
    }
  }

  private func candidate(_ requirements: ReportRequirements) -> ReportDraft {
    let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    return ReportDraft(
      identifiers: identifiers,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      chronology: chronology.trimmingCharacters(in: .whitespacesAndNewlines),
      comment: comment.isEmpty ? nil : comment,
      incidentDate: ReportIncidentDate(incidentDate ?? Date()),
      evidence: evidence.compactMap {
        if case .ready(let prepared) = $0.state { return prepared }
        return nil
      },
      acceptedTerms: requirements.terms,
      language: ReportText.language
    )
  }

  private func problems(
    in report: ReportDraft,
    _ requirements: ReportRequirements
  ) -> [ReportFieldProblem] {
    let found = report.problems(limits: requirements.limits)
    return incidentDate == nil ? found + [.incidentDateInvalid] : found
  }

  private func findEvidenceBlock() -> EvidenceBlock? {
    var preparing = false
    for item in evidence {
      switch item.state {
      case .failed: return .fileFailed
      case .preparing: preparing = true
      case .ready: break
      }
    }
    return preparing ? .stillPreparing : nil
  }

  private static func date(_ day: ReportIncidentDate) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
  }
}

extension ReportDraft {
  fileprivate func isSameReport(as other: ReportDraft) -> Bool {
    title == other.title && chronology == other.chronology && comment == other.comment
      && incidentDate == other.incidentDate && evidence == other.evidence
      && acceptedTerms == other.acceptedTerms
  }
}
