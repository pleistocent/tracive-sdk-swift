# Extended SDK: in-app reporting on iOS

Lets a user report a scammer from inside your app, and check that report's status. Use Tracive's
form and status screens, or your own UI on the same calls.

```swift
.package(url: "https://github.com/pleistocent/tracive-sdk-swift.git", from: "X.Y.Z")
```

Replace `X.Y.Z` with the latest version from
[GitHub Releases](https://github.com/pleistocent/tracive-sdk-swift/releases). Add
`TraciveSDKExtendedUI` for Tracive's screens, or only `TraciveSDKExtended` for your own UI.

iOS 15 or newer. The core binary has no macOS slice, so unlike `TraciveSDK` these products do not
build for macOS. `LSApplicationQueriesSchemes` needs `tracive` for `openInTracive`, as the base SDK
already asks. A Kotlin Multiplatform app takes the core from Maven instead: adding these products
too would link a second copy.

The core, `TraciveReportCore`, is a 14 MB dynamic framework with avifkit and the Kotlin runtime
inside. It links only into an app that adds one of these products. SwiftPM still downloads its zip,
about 19 MB, when it resolves this package, whichever products you use.

## Connect it

Add the scopes to the client you already have. Tokens stay with `TraciveSDK`, which keeps doing the
refresh, because a reused refresh token revokes the grant.

```swift
let reports = TraciveReports(client: traciveClient)
```

If your backend keeps the tokens, answer for them yourself, and refresh only when `stale` asks:

```swift
let reports = TraciveReports(environment: .production) { stale in
  try await backend.traciveToken(stale: stale)
}
```

## Tracive's screens

```swift
TraciveReportForm.present(
  reports: reports,
  prefill: ReportPrefill(
    query: try .bankAccount(countryAlpha3: "IDN", bankCode: "BCA", account: account),
    incidentDate: ReportIncidentDate(transaction.date),
    title: "Fake seller",
    attachments: [.image(receiptPng, mimeType: "image/png")]
  ),
  theme: TraciveReportTheme(primaryColor: .systemTeal, cornerRadius: 16),
  from: viewController
) { outcome in
  switch outcome {
  case .submitted(let reportId, _): keepWithTransaction(reportId)
  case .needsConsent: authorize()
  case .cancelled: break
  }
}

TraciveReportStatus.present(reports: reports, reportId: reportId, theme: theme, from: viewController) { _ in }
```

In SwiftUI, use `.traciveReportForm(isPresented:reports:prefill:theme:completion:)` and
`.traciveReportStatus(isPresented:reports:reportId:theme:completion:)`.

The chronology has no prefill on purpose: it's the user's own account of what happened.

## Your own UI

```swift
let requirements = try await reports.requirements()
let evidence = try await reports.prepare(data, mimeType: "image/png")

let draft = ReportDraft(
  query: try .bankAccount(countryAlpha3: "IDN", bankCode: "BCA", account: account),
  title: title,
  chronology: chronology,
  incidentDate: date,
  evidence: [evidence],
  acceptedTerms: requirements.terms
)

switch try await reports.submit(draft, onProgress: { showProgress($0) }) {
case .submitted(let reportId, _): keepWithTransaction(reportId)
case .needsConsent: authorize()
case .failed(let error): show(error.code)
}

let status = try await reports.status(reportId)
reports.openInTracive(reportId)
```

Cancelling the Swift `Task` cancels the upload. Keep the same draft across retries: its idempotency
key is what stops a retry becoming a second report.

`prepare` compresses to AVIF, under 200 KB, 1024 px on the shortest side, with metadata dropped. JPEG
runs only when avifkit fails. A PDF under 1 MiB passes through.

## Errors

| `TraciveReportError.Code` | What to do |
|---|---|
| `.needsConsent` | Authorize with the scope added, then call again |
| `.emailNotVerified` | Ask the user to verify in Tracive |
| `.reportNotFound` | Unknown, not filed through your app, or older than 30 days |
| `.termsOutdated` | Read the requirements, show the new links, build a new draft |
| `.dailyLimitReached` | Wait `retryAfterSeconds` |
| `.reportingDisabled` | Try later |
| `.network` | Submit the same draft again |
| `.server` | Try later |
| `.invalidReport`, `.attachmentInvalid` | The message names the field or the file |
| `.unsupportedFile`, `.fileTooLarge`, `.imageUnreadable` | Ask for another file |

## App Privacy

Declare the evidence upload in your App Privacy answers. The package ships a privacy manifest for its
own API use.

## Sample

`ExtendedExample/` is an iOS app on these products. Its Xcode project is generated from `project.yml`.
The `sandbox` scheme needs your own client id in `Flavors/sandbox.xcconfig`. The `demo` scheme needs
no Tracive app and no grant: start `python3 ExtendedExample/demo-server.py` on the same Mac first.
