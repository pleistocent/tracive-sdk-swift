import Foundation

/// The answer to a single scammer check.
///
/// The same type is used for a server response and for a cache hit; `origin` says which. Unknown
/// JSON keys are ignored so a future-version server can add fields without breaking shipped apps.
public struct CheckResult: Codable, Equatable, Hashable, Sendable {

  /// Server-assigned id for this check. `nil` on a cache hit — nothing was checked.
  public let checkId: String?
  /// Whether the identifier is present in Tracive's index at all.
  public let found: Bool
  public let riskTier: RiskTier
  public let reportTotal: Int
  public let credibleReports: Int
  public let ambiguousReports: Int
  /// The month of the earliest matching report, as `"YYYY-MM"` (e.g. `"2026-06"`).
  ///
  /// A **String** for the same reason as `Chronology.incidentDate`: the server never sends a day.
  /// Show the month and year only (e.g. "Jun 2026"), and nothing computed from a day such as
  /// "3 days ago": an exact date could help identify the reporter.
  public let firstReportOn: String?
  /// The month of the most recent matching report, as `"YYYY-MM"`, exactly like `firstReportOn`.
  public let lastReportOn: String?
  /// Currency code → reported fraud amount, e.g. `["IDR": 12_500_000]`.
  public let fraudAmount: [String: Double]
  public let tags: [String]
  /// A count, never a list — the SDK must not be able to walk the scammer graph.
  public let relatedScammerCount: Int
  /// `detail = .full` only.
  public let topChronologies: [Chronology]?
  /// `detail = .full` only.
  public let comments: [Comment]?
  /// Absent on a cache hit: a cache hit is free, so there is nothing to bill.
  public let billing: Billing?
  /// Legal text that must be surfaced in any UI built on the SDK.
  public let disclaimer: String?
  public let origin: Origin
  /// When the underlying data was fetched **from the server**. On a cache hit this stays at the
  /// original fetch instant — it is the age of the data, not the age of the answer.
  public let fetchedAt: Date

  public init(
    checkId: String? = nil,
    found: Bool,
    riskTier: RiskTier,
    reportTotal: Int = 0,
    credibleReports: Int = 0,
    ambiguousReports: Int = 0,
    firstReportOn: String? = nil,
    lastReportOn: String? = nil,
    fraudAmount: [String: Double] = [:],
    tags: [String] = [],
    relatedScammerCount: Int = 0,
    topChronologies: [Chronology]? = nil,
    comments: [Comment]? = nil,
    billing: Billing? = nil,
    disclaimer: String? = nil,
    origin: Origin = .server,
    fetchedAt: Date
  ) {
    self.checkId = checkId
    self.found = found
    self.riskTier = riskTier
    self.reportTotal = reportTotal
    self.credibleReports = credibleReports
    self.ambiguousReports = ambiguousReports
    self.firstReportOn = firstReportOn
    self.lastReportOn = lastReportOn
    self.fraudAmount = fraudAmount
    self.tags = tags
    self.relatedScammerCount = relatedScammerCount
    self.topChronologies = topChronologies
    self.comments = comments
    self.billing = billing
    self.disclaimer = disclaimer
    self.origin = origin
    self.fetchedAt = fetchedAt
  }

  // MARK: - Derived helpers

  /// The copy that is safe to persist — **provided the response it came from carried no `locale`**.
  ///
  /// `topChronologies`, `comments` and `billing` vary with the request, and `checkId` identifies one
  /// specific server-side check, so all four are dropped. `origin` is rewritten to `.cache` because
  /// that is what the entry will be when it is read back.
  ///
  /// What survives is invariant across `detail`, but **not** across `locale`: `tags` and
  /// `disclaimer` are localized strings. The cache key is `SHA-256(searchQueryIndex)` with no locale
  /// in it, so this projection is only safe to store for a response to a request that sent no
  /// `locale` — which in practice means `detail: .minimal`. `TraciveClient` enforces that by not
  /// writing full-detail responses at all; do not weaken it without first making the key
  /// `(query, detail, locale)`. Storing a localized `disclaimer` under a locale-less key means the
  /// next caller reads a legal notice in a language they did not ask for.
  ///
  /// The same key change is the precondition for ever caching full-detail *content*: otherwise a
  /// `minimal` request would serve `full` content and vice versa.
  public func cacheableCopy() -> CheckResult {
    CheckResult(
      checkId: nil,
      found: found,
      riskTier: riskTier,
      reportTotal: reportTotal,
      credibleReports: credibleReports,
      ambiguousReports: ambiguousReports,
      firstReportOn: firstReportOn,
      lastReportOn: lastReportOn,
      fraudAmount: fraudAmount,
      tags: tags,
      relatedScammerCount: relatedScammerCount,
      topChronologies: nil,
      comments: nil,
      billing: nil,
      disclaimer: disclaimer,
      origin: .cache,
      fetchedAt: fetchedAt
    )
  }

  /// This result reduced to what may be kept against a transaction.
  ///
  /// A transaction record is read back under the transaction it was filed for and never under
  /// another request, so almost everything survives — including the fields `cacheableCopy()` drops
  /// for reasons that do not apply here. `checkId` and `billing` describe one call, which is exactly
  /// what this record is; keeping them is what lets a support agent reconcile the charge and a UI
  /// say whether that transfer spent a credit. `origin` and `fetchedAt` are kept as they are, not
  /// restamped, because the record is a statement about a past moment: a second transfer to an
  /// account already checked was served from the cache, spent nothing, and should say so.
  ///
  /// `topChronologies` and `comments` go, and that is the one deliberate loss. They are other
  /// people's accounts of being defrauded, written in prose; a record lives for months rather than
  /// hours, and nothing on a transaction-detail screen shows them.
  public func transactionRecordCopy() -> CheckResult {
    CheckResult(
      checkId: checkId,
      found: found,
      riskTier: riskTier,
      reportTotal: reportTotal,
      credibleReports: credibleReports,
      ambiguousReports: ambiguousReports,
      firstReportOn: firstReportOn,
      lastReportOn: lastReportOn,
      fraudAmount: fraudAmount,
      tags: tags,
      relatedScammerCount: relatedScammerCount,
      topChronologies: nil,
      comments: nil,
      billing: billing,
      disclaimer: disclaimer,
      origin: origin,
      fetchedAt: fetchedAt
    )
  }

  /// Returns a copy stamped with a different provenance. The transport layer uses this after
  /// decoding a response, and the cache layer uses it when replaying a stored entry.
  public func withOrigin(_ origin: Origin, fetchedAt: Date? = nil) -> CheckResult {
    CheckResult(
      checkId: checkId,
      found: found,
      riskTier: riskTier,
      reportTotal: reportTotal,
      credibleReports: credibleReports,
      ambiguousReports: ambiguousReports,
      firstReportOn: firstReportOn,
      lastReportOn: lastReportOn,
      fraudAmount: fraudAmount,
      tags: tags,
      relatedScammerCount: relatedScammerCount,
      topChronologies: topChronologies,
      comments: comments,
      billing: billing,
      disclaimer: disclaimer,
      origin: origin,
      fetchedAt: fetchedAt ?? self.fetchedAt
    )
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case checkId
    case found
    case riskTier
    case reportTotal
    case credibleReports
    case ambiguousReports
    case firstReportOn
    case lastReportOn
    case fraudAmount
    case tags
    case relatedScammerCount
    case topChronologies
    case comments
    case billing
    case disclaimer
    case origin
    case fetchedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    // `found` and `riskTier` are the two load-bearing fields: everything a caller decides rests on
    // them, so they are decoded strictly. A payload missing either is broken, not merely newer.
    self.found = try container.decode(Bool.self, forKey: .found)
    self.riskTier = try container.decode(RiskTier.self, forKey: .riskTier)

    self.checkId = container.traciveStringIfPresent(.checkId)
    self.reportTotal = container.traciveInt(.reportTotal, default: 0)
    self.credibleReports = container.traciveInt(.credibleReports, default: 0)
    self.ambiguousReports = container.traciveInt(.ambiguousReports, default: 0)
    self.firstReportOn = container.traciveYearMonthIfPresent(.firstReportOn)
    self.lastReportOn = container.traciveYearMonthIfPresent(.lastReportOn)
    self.fraudAmount = container.traciveDoubleMap(.fraudAmount, default: [:])
    self.tags = container.traciveStringArray(.tags, default: [])
    self.relatedScammerCount = container.traciveInt(.relatedScammerCount, default: 0)
    self.topChronologies = container.traciveDecodeIfPresent([Chronology].self, forKey: .topChronologies)
    self.comments = container.traciveDecodeIfPresent([Comment].self, forKey: .comments)
    self.billing = container.traciveDecodeIfPresent(Billing.self, forKey: .billing)
    self.disclaimer = container.traciveStringIfPresent(.disclaimer)

    // `origin` and `fetchedAt` are SDK-side provenance. A server response carries neither, so they
    // default to "just fetched from the server"; a cache record always carries both, because
    // `encode(to:)` always writes them.
    self.origin = container.traciveDecodeIfPresent(Origin.self, forKey: .origin) ?? .server
    self.fetchedAt = container.traciveDateIfPresent(.fetchedAt) ?? Date()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(checkId, forKey: .checkId)
    try container.encode(found, forKey: .found)
    try container.encode(riskTier, forKey: .riskTier)
    try container.encode(reportTotal, forKey: .reportTotal)
    try container.encode(credibleReports, forKey: .credibleReports)
    try container.encode(ambiguousReports, forKey: .ambiguousReports)
    try container.encodeIfPresent(firstReportOn, forKey: .firstReportOn)
    try container.encodeIfPresent(lastReportOn, forKey: .lastReportOn)
    try container.encode(fraudAmount, forKey: .fraudAmount)
    try container.encode(tags, forKey: .tags)
    try container.encode(relatedScammerCount, forKey: .relatedScammerCount)
    try container.encodeIfPresent(topChronologies, forKey: .topChronologies)
    try container.encodeIfPresent(comments, forKey: .comments)
    try container.encodeIfPresent(billing, forKey: .billing)
    try container.encodeIfPresent(disclaimer, forKey: .disclaimer)
    try container.encode(origin, forKey: .origin)
    try container.traciveEncodeISO8601(fetchedAt, forKey: .fetchedAt)
  }
}
