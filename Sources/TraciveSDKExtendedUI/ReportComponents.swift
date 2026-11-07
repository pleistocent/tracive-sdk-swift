import SwiftUI
import TraciveSDKExtended

struct ReportCard<Content: View>: View {
  let theme: ResolvedReportTheme
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.systemBackground))
      .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
  }
}

struct ReportSectionHeader: View {
  let title: String
  let description: String?

  init(_ title: String, description: String? = nil) {
    self.title = title
    self.description = description
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline.weight(.semibold))
      if let description {
        Text(description).font(.footnote).foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ReportFieldProblemText: View {
  let text: String?

  init(_ text: String?) { self.text = text }

  var body: some View {
    if let text {
      Text(text)
        .font(.footnote)
        .foregroundColor(Color(.systemRed))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct ReportCountedHint: View {
  let problem: String?
  let count: Int
  let max: Int

  var body: some View {
    HStack(alignment: .top) {
      ReportFieldProblemText(problem)
      Spacer(minLength: 8)
      Text(ReportText.text("count", count, max))
        .font(.caption)
        .monospacedDigit()
        .foregroundColor(.secondary)
    }
  }
}

struct ReportTextArea: View {
  @Binding var text: String
  let placeholder: String
  let minHeight: CGFloat
  let identifier: String
  let theme: ResolvedReportTheme

  var body: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .frame(minHeight: minHeight)
        .accessibilityIdentifier(identifier)
      if text.isEmpty {
        Text(placeholder)
          .foregroundColor(Color(.placeholderText))
          .padding(.top, 8)
          .padding(.leading, 5)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .padding(8)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
  }
}

struct ReportPrimaryButton: View {
  let title: String
  let theme: ResolvedReportTheme
  let action: () -> Void

  init(_ title: String, theme: ResolvedReportTheme, action: @escaping () -> Void) {
    self.title = title
    self.theme = theme
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.body.weight(.semibold))
        .foregroundColor(theme.onPrimary)
        .frame(maxWidth: .infinity, minHeight: 28)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.roundedRectangle(radius: theme.radius))
    .tint(theme.primary)
  }
}

struct ReportNotice: View {
  let text: String
  let theme: ResolvedReportTheme

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
      Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .foregroundColor(.primary)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
  }
}

struct ReportMessageView<Actions: View>: View {
  let systemImage: String
  let title: String
  let line: String
  let theme: ResolvedReportTheme
  @ViewBuilder let actions: Actions

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 48))
          .foregroundColor(theme.primary)
          .accessibilityHidden(true)
        Text(title)
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(line)
          .font(.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
        actions.padding(.top, 12)
      }
      .padding(24)
      .frame(maxWidth: 480)
      .frame(maxWidth: .infinity)
    }
  }
}

struct ReportEvidenceRow: View {
  let item: ReportFormModel.EvidenceItem
  let enabled: Bool
  let theme: ResolvedReportTheme
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      thumbnail
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name ?? ReportText.text("evidence_file"))
          .font(.subheadline)
          .lineLimit(1)
        status
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .accessibilityLabel(ReportText.text("remove"))
    }
    .padding(8)
    .background(Color(.systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
  }

  @ViewBuilder
  private var thumbnail: some View {
    Group {
      if let image = item.thumbnail {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: item.mimeType == "application/pdf" ? "doc.richtext" : "photo")
          .foregroundColor(.secondary)
      }
    }
    .frame(width: 44, height: 44)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: min(theme.radius, 8), style: .continuous))
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var status: some View {
    switch item.state {
    case .preparing:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(ReportText.text("evidence_preparing")).font(.caption).foregroundColor(.secondary)
      }
    case .ready(let prepared):
      Text(
        ByteCountFormatter.string(fromByteCount: Int64(prepared.byteCount), countStyle: .file)
      )
      .font(.caption)
      .foregroundColor(.secondary)
    case .failed(let code):
      Text(ReportText.error(code)).font(.caption).foregroundColor(Color(.systemRed))
    }
  }
}

extension View {
  @ViewBuilder
  func dismissesKeyboardOnScroll() -> some View {
    if #available(iOS 16, *) {
      scrollDismissesKeyboard(.interactively)
    } else {
      self
    }
  }
}
