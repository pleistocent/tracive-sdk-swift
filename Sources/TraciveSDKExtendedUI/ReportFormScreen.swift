import SwiftUI
import TraciveSDK
import TraciveSDKExtended

struct ReportFormScreen: View {
  @ObservedObject var model: ReportFormModel
  let theme: ResolvedReportTheme

  var body: some View {
    NavigationView {
      content
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
        .navigationTitle(ReportText.text("form_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(ReportText.text("close")) { model.done() }
              .accessibilityIdentifier("tracive.report.close")
          }
        }
    }
    .navigationViewStyle(.stack)
    .tint(theme.primary)
  }

  @ViewBuilder
  private var content: some View {
    if let sent = model.sent {
      SentContent(model: model, sent: sent, theme: theme)
    } else {
      switch model.load {
      case .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let code):
        ReportMessageView(
          systemImage: "exclamationmark.circle",
          title: ReportText.text("load_failed"),
          line: ReportText.error(code),
          theme: theme
        ) {
          ReportPrimaryButton(ReportText.text("retry"), theme: theme) { model.retryLoad() }
        }
      case .ready:
        if let limits = model.requirements?.limits {
          ReportFormContent(model: model, limits: limits, theme: theme)
        }
      }
    }
  }
}

private struct ReportFormContent: View {
  @ObservedObject var model: ReportFormModel
  let limits: ReportLimits
  let theme: ResolvedReportTheme

  @State private var pickingPhotos = false
  @State private var pickingPDF = false

  private var editable: Bool { !model.sending }

  var body: some View {
    ScrollViewReader { scroller in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let block = model.sendBlock {
            ReportNotice(text: blockText(block), theme: theme)
          }
          identifiers.id(Section.identifiers)
          date.id(Section.date)
          title.id(Section.title)
          chronology.id(Section.chronology)
          comment.id(Section.comment)
          evidence.id(Section.evidence)
          sendSection.id(Section.send)
        }
        .padding(16)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .dismissesKeyboardOnScroll()
      .onChange(of: model.attentionRequests) { _ in
        withAnimation { scroller.scrollTo(firstSectionWithProblem, anchor: .top) }
      }
    }
    .sheet(isPresented: $pickingPhotos) {
      PhotoPicker(limit: model.evidenceRoom) { model.addEvidence($0) }
    }
    .sheet(isPresented: $pickingPDF) {
      DocumentPicker(limit: model.evidenceRoom, maxBytes: limits.maxAttachmentBytes) {
        model.addEvidence($0)
      }
    }
  }

  private enum Section: Hashable {
    case identifiers, date, title, chronology, comment, evidence, send
  }

  private static let sectionProblems: [(Section, Set<ReportFieldProblem>)] = [
    (.identifiers, [.noIdentifier, .tooManyIdentifiers]),
    (.date, [.incidentDateInvalid, .incidentDateInFuture]),
    (.title, [.titleMissing, .titleTooLong]),
    (.chronology, [.chronologyTooShort, .chronologyTooLong]),
    (.comment, [.commentTooLong]),
  ]

  private var firstSectionWithProblem: Section {
    let problems = Set(model.problems)
    return Self.sectionProblems.first { !problems.isDisjoint(with: $0.1) }?.0 ?? .evidence
  }

  private func blockText(_ block: ReportFormModel.SendBlock) -> String {
    switch block {
    case .reportingDisabled:
      return ReportText.text("error_reporting_disabled")
    case .dailyLimit:
      return model.failure.map(ReportText.failure) ?? ReportText.text("error_daily_limit")
    }
  }

  private func problemText(_ wanted: [ReportFieldProblem]) -> String? {
    model.problems.first { wanted.contains($0) }.map {
      ReportText.problem($0, limits: limits, maxEvidence: model.maxEvidence)
    }
  }

  private var identifiers: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReportSectionHeader(ReportText.text("media_title"))
      ReportCard(theme: theme) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(model.identifiers, id: \.self) { key in
            let readable = ReadableIdentifier(key: key)
            VStack(alignment: .leading, spacing: 2) {
              Text(readable.label).font(.caption).foregroundColor(.secondary)
              Text(readable.value).font(.body).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
          }
        }
      }
      ReportFieldProblemText(problemText([.noIdentifier, .tooManyIdentifiers]))
    }
  }

  private var date: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReportSectionHeader(ReportText.text("date_label"))
      ReportCard(theme: theme) {
        if let selected = model.incidentDate {
          DatePicker(
            ReportText.text("date_label"),
            selection: Binding(get: { selected }, set: { model.incidentDate = $0 }),
            in: ...Date(),
            displayedComponents: .date
          )
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Button(ReportText.text("date_placeholder")) { model.incidentDate = Date() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("tracive.report.date")
        }
      }
      .disabled(!editable)
      ReportFieldProblemText(problemText([.incidentDateInvalid, .incidentDateInFuture]))
    }
  }

  private var title: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReportSectionHeader(ReportText.text("title_label"))
      ReportCard(theme: theme) {
        TextField(ReportText.text("title_placeholder"), text: $model.title)
          .textInputAutocapitalization(.sentences)
          .accessibilityIdentifier("tracive.report.title")
      }
      .disabled(!editable)
      ReportCountedHint(
        problem: problemText([.titleMissing, .titleTooLong]),
        count: model.title.utf16.count,
        max: limits.titleMaxLength
      )
    }
  }

  private var chronology: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReportSectionHeader(
        ReportText.text("chronology_label"),
        description: ReportText.text("chronology_description", limits.chronologyMinLength)
      )
      ReportTextArea(
        text: $model.chronology,
        placeholder: ReportText.text("chronology_placeholder"),
        minHeight: 140,
        identifier: "tracive.report.chronology",
        theme: theme
      )
      .disabled(!editable)
      ReportCountedHint(
        problem: problemText([.chronologyTooShort, .chronologyTooLong]),
        count: model.chronology.utf16.count,
        max: limits.chronologyMaxLength
      )
    }
  }

  private var comment: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReportSectionHeader(
        ReportText.text("comment_label"),
        description: ReportText.text("comment_description")
      )
      ReportTextArea(
        text: $model.comment,
        placeholder: "",
        minHeight: 80,
        identifier: "tracive.report.comment",
        theme: theme
      )
      .disabled(!editable)
      ReportCountedHint(
        problem: problemText([.commentTooLong]),
        count: model.comment.utf16.count,
        max: limits.commentMaxLength
      )
    }
  }

  private var evidence: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReportSectionHeader(
        ReportText.text("evidence_label"),
        description: ReportText.text("evidence_description", model.maxEvidence)
      )
      HStack(spacing: 8) {
        Button {
          pickingPhotos = true
        } label: {
          Label(ReportText.text("add_photos"), systemImage: "photo")
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("tracive.report.addPhotos")
        Button {
          pickingPDF = true
        } label: {
          Label(ReportText.text("add_pdf"), systemImage: "doc")
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("tracive.report.addPDF")
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.roundedRectangle(radius: theme.radius))
      .disabled(!editable || model.evidenceRoom == 0)

      ForEach(model.evidence) { item in
        ReportEvidenceRow(item: item, enabled: editable, theme: theme) {
          model.removeEvidence(id: item.id)
        }
      }
      if model.evidenceOverflow {
        ReportFieldProblemText(ReportText.text("problem_too_many_evidence", model.maxEvidence))
      }
      ReportFieldProblemText(problemText([.noEvidence, .tooManyEvidence]))
      switch model.evidenceBlock {
      case .stillPreparing:
        ReportFieldProblemText(ReportText.text("problem_evidence_preparing"))
      case .fileFailed:
        ReportFieldProblemText(ReportText.text("problem_evidence_failed"))
      case nil:
        EmptyView()
      }
    }
  }

  private var sendSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let failure = model.failure, model.sendBlock == nil, !model.sending {
        ReportNotice(text: ReportText.failure(failure), theme: theme)
      }
      if model.sending {
        ProgressView(value: model.progress).tint(theme.primary)
      }
      ReportTermsLine(terms: model.requirements?.terms ?? [])
      ReportPrimaryButton(
        model.sending
          ? ReportText.text("sending", Int((model.progress * 100).rounded()))
          : ReportText.text("send"),
        theme: theme,
        action: {
          // The keyboard would otherwise stay up over the success screen.
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
          model.send()
        }
      )
      .disabled(!model.canSend)
      .accessibilityIdentifier("tracive.report.send")
    }
  }
}

/// Uses neither the theme's colour nor its tint. A partner's colour must not be able to hide what
/// the user agrees to.
struct ReportTermsLine: View {
  let terms: [RequiredTerm]

  var body: some View {
    if !terms.isEmpty {
      Text(attributed)
        .font(.footnote)
        .foregroundColor(.primary)
        .tint(Color(.link))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("tracive.report.terms")
    }
  }

  private var attributed: AttributedString {
    var line = AttributedString(ReportText.text("terms_sentence") + " ")
    let lastIndex = terms.count - 1
    for (index, term) in terms.enumerated() {
      var name = AttributedString(ReportText.termName(term.id))
      name.link = URL(string: term.url)
      name.underlineStyle = .single
      line += name
      if index < lastIndex - 1 {
        line += AttributedString(", ")
      } else if index == lastIndex - 1 {
        line += AttributedString(" \(ReportText.text("terms_and")) ")
      }
    }
    return line + AttributedString(".")
  }
}

private struct SentContent: View {
  @ObservedObject var model: ReportFormModel
  let sent: ReportFormModel.SentReport
  let theme: ResolvedReportTheme

  var body: some View {
    ReportMessageView(
      systemImage: "paperplane.circle",
      title: ReportText.text("sent_title"),
      line: ReportText.text("sent_message"),
      theme: theme
    ) {
      VStack(spacing: 12) {
        if let status = model.checkedStatus {
          // .submitted would only repeat the title above it.
          if status != .submitted {
            Text(ReportText.text("sent_status", ReportText.statusTitle(status)))
              .font(.subheadline)
              .foregroundColor(.secondary)
              .accessibilityIdentifier("tracive.report.sentStatus")
          }
          NavigationLink(
            destination: ReportStatusContainer(
              reports: model.reports, reportId: sent.reportId, theme: theme)
          ) {
            Text(ReportText.text("view_status")).frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .buttonBorderShape(.roundedRectangle(radius: theme.radius))
          .accessibilityIdentifier("tracive.report.viewStatus")
        }
        ReportPrimaryButton(ReportText.text("done"), theme: theme) { model.done() }
          .accessibilityIdentifier("tracive.report.done")
      }
    }
  }
}
