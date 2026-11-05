import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI
import TraciveSDK

/// What the report screen needs: something that calls `TraciveClient.openReportForm`.
///
/// A seam for the same reason as `ScammerChecking`. The call itself is iOS-only (it presents a
/// UIKit sheet), so this library, which also builds on macOS, cannot make it; the app target does,
/// in one line:
///
/// ```swift
/// struct LiveReportFormOpener: ReportFormOpening {
///   let client: TraciveClient
///   @MainActor func open(
///     _ query: TraciveQuery, incidentDate: ReportIncidentDate?,
///     attachments: [ReportAttachment], target: ReportFormTarget?
///   ) async -> ReportFormResult {
///     await client.openReportForm(
///       query, incidentDate: incidentDate, attachments: attachments, target: target,
///       from: .keyWindow)
///   }
/// }
/// ```
public protocol ReportFormOpening {
  @MainActor
  func open(
    _ query: TraciveQuery,
    incidentDate: ReportIncidentDate?,
    attachments: [ReportAttachment],
    target: ReportFormTarget?
  ) async -> ReportFormResult
}

/// Which Tracive build the Report button hands over to. Only for trying the sample against each
/// build; a real integration passes no target and lets the client's environment decide.
public enum ReportTargetChoice: String, CaseIterable, Identifiable {
  case sandbox = "Sandbox"
  case production = "Production"
  case devBuild = "Dev build (QA)"

  public var id: String { rawValue }

  public var target: ReportFormTarget {
    switch self {
    case .sandbox: return .sandbox
    case .production: return .production
    case .devBuild:
      return ReportFormTarget(
        bundleIdentifier: "com.pleistocent.tracive.dev",
        scheme: "tracivedev",
        capabilityScheme: "tracivedev-report",
        fileExtension: "tracivedevreport"
      )
    }
  }
}

/// A mock transaction detail with a Report button: the screen a bank or wallet would put this on.
public struct ReportScammerView: View {

  private let opener: any ReportFormOpening

  @State private var choice: ReportTargetChoice = .sandbox
  @State private var isOpening = false
  @State private var outcome: String?

  private let transfer = MockTransfer.yesterday

  public init(opener: any ReportFormOpening) {
    self.opener = opener
  }

  public var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Transfer")) {
          row("Amount", transfer.amount)
          row("Date", transfer.date.iso8601)
          row("To", "\(transfer.recipientName)\n\(transfer.bankName) · \(transfer.account)")
          row("Reference", transfer.reference)
        }

        Section(
          header: Text("Hand over to"),
          footer: Text(
            "For trying the sample against each Tracive build. A real app passes no target: the "
              + "client's environment picks the build.")
        ) {
          Picker("Tracive build", selection: $choice) {
            ForEach(ReportTargetChoice.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
        }

        Section(
          footer: Text(
            "Opens the Tracive report form with this account, yesterday's date and a generated "
              + "receipt (one PNG, one PDF). No sign-in, network or credit involved.")
        ) {
          Button(isOpening ? "Opening…" : "Report this account") { report() }
            .disabled(isOpening)
          if let outcome {
            Text(outcome).font(.footnote)
          }
        }
      }
      .navigationTitle("Transaction")
    }
    #if os(iOS)
      .navigationViewStyle(.stack)
    #endif
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).foregroundColor(.secondary)
      Spacer()
      Text(value).multilineTextAlignment(.trailing)
    }
  }

  private func report() {
    isOpening = true
    outcome = nil
    Task { @MainActor in
      defer { isOpening = false }
      let query: TraciveQuery
      do {
        query = try .bankAccount(
          countryAlpha3: "IDN", bankCode: transfer.bankCode, account: transfer.account)
      } catch {
        outcome = "This account cannot be reported: \(error.localizedDescription)"
        return
      }
      let result = await opener.open(
        query,
        incidentDate: transfer.date,
        attachments: ExampleReceipt.attachments(for: transfer),
        // TODO(partner): leave the target out; `environment` picks the Tracive build.
        target: choice.target
      )
      outcome = Self.describe(result)
    }
  }

  static func describe(_ result: ReportFormResult) -> String {
    switch result {
    case .opened(attachmentsDelivered: true):
      return "Opened in Tracive with the account, the date and both receipts."
    case .opened(attachmentsDelivered: false):
      return "Opened in Tracive with the account only. This Tracive version takes no attachments, "
        + "or LSApplicationQueriesSchemes lacks its report scheme."
    case .cancelled:
      return "Cancelled. Nothing was delivered."
    case .installPageOpened:
      return "Tracive is not installed. The install page has been opened."
    case .failed(let error):
      return "\(error.code): \(error.localizedDescription)"
    }
  }
}

/// The transaction on screen. Demo data.
struct MockTransfer {
  let amount: String
  let date: ReportIncidentDate
  let recipientName: String
  let bankName: String
  let bankCode: String
  let account: String
  let reference: String

  static var yesterday: MockTransfer {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let instant = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    return MockTransfer(
      amount: "Rp2.500.000",
      date: ReportIncidentDate(instant),
      recipientName: "Cheap Gadget Store",
      bankName: "BCA",
      bankCode: "BCA",
      account: "1234567890",
      reference: "TRF26110412000001"
    )
  }
}

/// A receipt made in code, as a PNG and as a one-page PDF, so the sample needs no bundled files.
/// CoreGraphics, CoreText and ImageIO only, so it builds on macOS as well.
enum ExampleReceipt {

  static func attachments(for transfer: MockTransfer) -> [ReportAttachment] {
    var attachments: [ReportAttachment] = []
    if let png = png(for: transfer) { attachments.append(.image(png, mimeType: "image/png")) }
    if let pdf = pdf(for: transfer) { attachments.append(.pdf(pdf)) }
    return attachments
  }

  private static let size = CGSize(width: 360, height: 480)

  private static func lines(for transfer: MockTransfer) -> [String] {
    [
      "TRANSFER RECEIPT",
      transfer.amount,
      transfer.date.iso8601,
      "To \(transfer.recipientName)",
      "\(transfer.bankName) \(transfer.account)",
      "Ref \(transfer.reference)",
    ]
  }

  private static func draw(_ transfer: MockTransfer, in context: CGContext) {
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(red: 0.84, green: 0.12, blue: 0.16, alpha: 1))
    context.fill(CGRect(x: 0, y: size.height - 64, width: size.width, height: 64))

    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    var y = size.height - 104
    for line in lines(for: transfer) {
      let attributed = NSAttributedString(
        string: line,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
      context.textPosition = CGPoint(x: 24, y: y)
      CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
      y -= 40
    }
  }

  static func png(for transfer: MockTransfer) -> Data? {
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    draw(transfer, in: context)
    guard let image = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  static func pdf(for transfer: MockTransfer) -> Data? {
    let output = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return nil }
    context.beginPDFPage(nil)
    draw(transfer, in: context)
    context.endPDFPage()
    context.closePDF()
    return output as Data
  }
}
