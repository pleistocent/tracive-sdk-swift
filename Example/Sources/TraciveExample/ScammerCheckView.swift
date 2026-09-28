import SwiftUI
import TraciveSDK

/// A single-screen demonstration of a Tracive check.
///
/// Runs entirely offline. Every result comes from `SampleChecker`; the SDK's real encrypted cache sits
/// in front of it, so checking the same number twice returns `origin == .cache` and — in a real
/// integration — costs nothing.
///
/// The three things this screen is trying to show, none of which are cosmetic:
///
/// 1. **The disclaimer is always visible.** Tracive's data is community-submitted, and a UI that
///    presents it as established fact misrepresents it.
/// 2. **Provenance is visible.** A cached answer says so, and says how old it is. "We checked and
///    found nothing" and "we did not check" must never look the same.
/// 3. **The verdict is advice, not a ruling.** Even `HIGH` says "do not send money", not
///    "this is a scammer".
public struct ScammerCheckView: View {

  @StateObject private var model: ScammerCheckModel
  private let isOfflineDemo: Bool

  /// Builds the screen with the SDK's real cache in front of a canned offline "server".
  ///
  /// This initialiser is the demo, not the integration: a real composition root builds a
  /// `TraciveClient` and passes a `LiveChecker` to `init(checker:)` below.
  public init() {
    // TODO(partner): replace this whole body with a real client, and use `init(checker:)`:
    //
    //   let client = TraciveClient(
    //     mode: .oauth(
    //       clientId: "<the client id you were issued>",
    //       redirectUri: "https://<a host you own>/oauth/callback",
    //       partnerUserId: "<your own stable, opaque id for this user>",
    //       scopes: [TraciveScopes.scammerCheck]
    //     )
    //   )
    //   ScammerCheckView(checker: LiveChecker(client: client))
    //
    // That redirect needs a Universal Link — an `applinks:` entitlement and an
    // apple-app-site-association file on the host — and Info.plist needs
    // `LSApplicationQueriesSchemes` containing `tracive`. Docs/integration.md has both.

    // TODO(partner): `SQLiteCheckCache` on disk, not in memory. A cache that does not survive a
    // relaunch buys nothing; in-memory here only so the demo leaves nothing behind.
    let cache: any CheckCache = (try? SQLiteCheckCache.inMemory()) ?? NoOpCheckCache()
    // TODO(partner): both of these go. `SampleChecker` is a canned offline server, and
    // `CacheFirstChecker` spells out by hand what `Source.cacheFirst` already does inside
    // `TraciveClient`.
    let sample = SampleChecker()
    let checker = CacheFirstChecker(cache: cache) { try await sample.check($0) }
    _model = StateObject(wrappedValue: ScammerCheckModel(checker: checker))
    isOfflineDemo = true
  }

  /// Bring your own checker — this is the initialiser a host app would use, passing something that
  /// calls `TraciveClient.checkScammer`.
  ///
  /// `isOfflineDemo` shows the note that results are canned. Leave it false for a real checker, or
  /// the screen tells the user its live answers are fake.
  public init(checker: any ScammerChecking, isOfflineDemo: Bool = false) {
    _model = StateObject(wrappedValue: ScammerCheckModel(checker: checker))
    self.isOfflineDemo = isOfflineDemo
  }

  public var body: some View {
    NavigationView {
      content
    }
    // `.stack` is iOS-only; on macOS `NavigationView` already behaves this way.
    #if os(iOS)
      .navigationViewStyle(.stack)
    #endif
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        inputSection
        resultSection
        Spacer(minLength: 8)
        if isOfflineDemo {
          footer
        }
      }
      .padding(20)
      .frame(maxWidth: 560, alignment: .leading)
    }
    .navigationTitle("Tracive")
  }

  // MARK: - Input

  private var inputSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Check a phone number")
        .font(.title2.weight(.semibold))

      Text("Try a number ending in 1, 2, 3, 9, or anything else.")
        .font(.footnote)
        .foregroundColor(.secondary)

      phoneField

      Button {
        Task { await model.check() }
      } label: {
        HStack {
          if model.state == .checking {
            ProgressView().controlSize(.small)
          }
          Text(model.state == .checking ? "Checking…" : "Check")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.canCheck)
    }
  }

  private var phoneField: some View {
    let field = TextField("+62 812 3456 7891", text: $model.input)
      .textFieldStyle(.roundedBorder)
      .disableAutocorrection(true)
    #if os(iOS)
      return field.keyboardType(.phonePad)
    #else
      return field
    #endif
  }

  // MARK: - Result

  @ViewBuilder
  private var resultSection: some View {
    switch model.state {
    case .idle, .checking:
      EmptyView()
    case .failure(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(12)
    case .result(let result):
      resultCard(result)
    }
  }

  private func resultCard(_ result: CheckResult) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Circle().fill(color(for: result.riskTier)).frame(width: 12, height: 12)
        Text(result.riskTier.exampleTitle).font(.headline)
        Spacer()
        provenanceBadge(result)
      }

      Text(result.riskTier.exampleAdvice)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if result.found {
        Divider()
        counts(result)

        if !result.tags.isEmpty {
          tags(result.tags)
        }

        if let amount = result.fraudAmount.first {
          statRow("Reported loss", "\(amount.key) \(Int(amount.value).formatted())")
        }
        // A count, never a list: the SDK cannot walk the scammer graph, so do not build UI that
        // expects to.
        if result.relatedScammerCount > 0 {
          statRow("Linked accounts", "\(result.relatedScammerCount)")
        }
        if let last = result.lastReportOn {
          statRow("Last report", monthYear(last))
        }
      }

      // Not decoration, and not optional. Show it wherever you show the verdict.
      if let disclaimer = result.disclaimer {
        Text(disclaimer)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color(for: result.riskTier).opacity(0.10))
    .cornerRadius(14)
  }

  private func provenanceBadge(_ result: CheckResult) -> some View {
    let cached = result.origin == .cache
    return Text(cached ? "Cached · \(relative(result.fetchedAt))" : "Just checked")
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.secondary.opacity(0.15))
      .cornerRadius(6)
  }

  private func counts(_ result: CheckResult) -> some View {
    HStack(spacing: 24) {
      stat("\(result.reportTotal)", "reports")
      stat("\(result.credibleReports)", "credible")
      stat("\(result.ambiguousReports)", "ambiguous")
    }
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.weight(.semibold))
      Text(label).font(.caption).foregroundColor(.secondary)
    }
  }

  private func statRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).font(.caption).foregroundColor(.secondary)
      Spacer()
      Text(value).font(.caption.weight(.medium))
    }
  }

  private func tags(_ tags: [String]) -> some View {
    HStack(spacing: 6) {
      ForEach(tags.prefix(4), id: \.self) { tag in
        Text(tag)
          .font(.caption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.15))
          .cornerRadius(6)
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Offline demo")
        .font(.caption.weight(.semibold))
      Text(
        "Results are canned: this screen is wired to a stub, so it runs with no credentials and "
          + "no network. Phase 1 supports OAuth mode only — Proxy mode arrives in phase 2."
      )
      .font(.caption2)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Formatting

  private func color(for tier: RiskTier) -> Color {
    switch tier {
    case .high: return .red
    case .elevated: return .orange
    case .caution: return .yellow
    case .none: return .green
    }
  }

  /// `"2026-07"` → `"Jul 2026"`, built from month symbols so no day is ever invented.
  private func monthYear(_ yearMonth: String) -> String {
    let parts = yearMonth.split(separator: "-")
    let symbols = DateFormatter().shortMonthSymbols ?? []
    guard parts.count == 2, let month = Int(parts[1]), symbols.indices.contains(month - 1) else {
      return yearMonth
    }
    return "\(symbols[month - 1]) \(parts[0])"
  }

  private func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

#if DEBUG
  struct ScammerCheckView_Previews: PreviewProvider {
    static var previews: some View {
      ScammerCheckView()
    }
  }
#endif
