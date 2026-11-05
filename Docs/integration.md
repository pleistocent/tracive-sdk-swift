# Integration guide

How to wire the Tracive SDK into an iOS app, end to end.

> **Before you start.** phase 1 supports OAuth mode only. Build against sandbox first: sandbox and
> production are separate registrations, each needing a client id issued for it with your redirect
> registered on that client, and a sandbox client id is unknown to production.

---

## 1. Add the package

```swift
// Package.swift
.package(url: "https://github.com/pleistocent/tracive-sdk-swift.git", from: "0.2.1")
```

In Xcode: **File → Add Package Dependencies…**, then add `TraciveSDK` to your app target.

Requires iOS 15+. The package has no dependencies of its own, so nothing else appears in your
dependency graph.

## 2. Declare the Tracive app in `Info.plist`

The SDK checks whether the Tracive app is installed *before* it redirects anywhere. On iOS that means
`canOpenURL`, and `canOpenURL` returns `false` for any scheme not declared here — silently. Miss this
step and every user looks like they do not have the app installed.

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>tracive</string>
  <string>tracivesandbox</string>
  <string>tracive-report</string>
  <string>tracivesandbox-report</string>
</array>
```

The last two are for `openReportForm` ([section 10](#10-report-a-scammer)); list them even if you
do not use it yet, so adding it later is not also an `Info.plist` change.

Both environments, not just production. `TraciveAppPresence.scheme(for:)` follows the environment: against
`.sandbox` it probes `tracivesandbox://`, and an app that lists only `tracive` gets `false` from
`canOpenURL` for a sandbox build that is installed — which routes a tester to an install page for an
app they are holding.

## 3. Register your redirect URI as a Universal Link

Your redirect URI must be an HTTPS URL on a domain you own, with a matching
`apple-app-site-association` file. A custom URL scheme is not acceptable: any app on the device can
claim a custom scheme and intercept the authorization code.

```
https://yourapp.example.com/oauth/tracive
```

Register the exact same URL with Tracive when you get your `clientId`. The server matches it
exactly — no trailing-slash tolerance, no prefix matching.

Full details, including the confidential-client variant: [`oauth.md`](oauth.md).

## 4. Create the client

Once, at app start. Hold it for the app's lifetime — it owns the token store, the single-flight
refresh and the cache connection, and creating a second one gives you two of each.

**`TraciveClient.init` does blocking I/O.** With the default cache it opens (and on first run
creates) the SQLite database in Application Support, migrates it and prunes it, all synchronously on
the calling thread; the first check after that reaches the Keychain and the Secure Enclave. "At app
start" in SwiftUI usually means the main thread, so on a cold launch this is real work in front of
your first frame. If your launch budget is tight, build the client off the main thread and hand it
to your UI when it is ready, or construct a `SQLiteCheckCache` yourself and inject it at a moment
you control.

```swift
import TraciveSDK

let tracive = TraciveClient(
  mode: .oauth(
    clientId: "your-client-id",
    redirectUri: URL(string: "https://yourapp.example.com/oauth/tracive")!,
    scopes: [TraciveScopes.scammerCheck, TraciveScopes.creditsRead],
    partnerUserId: currentUser.id,   // required, never blank: your own stable, opaque id
    clientType: .public              // .confidential if your backend holds a client secret
  ),
  environment: .production
)
```

There is no API key parameter. See the README for why that is deliberate and permanent.

### `scopes`

Ask for the narrowest set that works; every extra scope is one more permission the user has to
accept on the consent screen. Name them with the `TraciveScopes` constants rather than typing the
strings — the authorization server is the only thing that validates a scope name, and it rejects
the *whole* consent request when it does not recognise one, so a typo is not a narrower grant, it is
an integration that cannot authorize at all:

| Constant | Wire value | Grants |
|---|---|---|
| `TraciveScopes.scammerCheck` | `scammer.check` | running a scammer check |
| `TraciveScopes.creditsRead` | `credits.read` | reading the user's remaining credits |
| `TraciveScopes.profileRead` | `profile.read` | reading the minimal user profile |

`creditsRead` is for a settings or billing screen. You do **not** need it to handle a 402: the
insufficient-credit signal rides on the check itself, which is why the SDK tells you not to poll
`credits()` before every check.

`detail: .full` needs a contractual rider server-side rather than an extra scope; requesting one you
have no rider for buys nothing.

### `.public` vs `.confidential`

| | `.public` | `.confidential` |
|---|---|---|
| Who exchanges the code | the SDK, using PKCE | your backend, using its client secret |
| What `authorize` returns | `.authorized(grantedScopes)` | `.codeReceived(code, codeVerifier, redirectUri)` |
| Where tokens live | the device Keychain | your server |

Use `.public` unless you already run a backend that holds credentials. If you pick `.confidential`,
the SDK stops at the authorization code and hands it to you; forwarding it and everything after is
yours.

## 5. Get consent

```swift
func connectTracive() async throws {
  switch await tracive.authorize() {
  case .authorized(let grantedScopes):
    // Check what you actually got — the user may have granted a subset.
    guard grantedScopes.contains(TraciveScopes.scammerCheck) else {
      showMessage("Tracive access is limited; scammer checks are unavailable.")
      return
    }
    enableChecks()

  case .appNotInstalled:
    // The SDK has already opened the install link. There is no deferred resume:
    // the user installs Tracive, comes back here, and taps again.
    showMessage("Install Tracive to continue, then tap Connect again.")

  case .denied:
    showMessage("You can connect Tracive later from Settings.")

  case .codeReceived(let code, let codeVerifier, let redirectUri):
    // Confidential clients only.
    try await myBackend.exchangeTraciveCode(code, verifier: codeVerifier, redirectUri: redirectUri)

  case .failed(let error):
    throw error
  }
}
```

Then route the callback — and **handle its result here too**, with the same `handle(_:)` above:

```swift
// SwiftUI
.onOpenURL { url in
  Task { if let result = await tracive.handleCallback(url: url) { handle(result) } }
}

// UIKit
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
  guard let url = userActivity.webpageURL else { return }
  Task { if let result = await tracive.handleCallback(url: url) { handle(result) } }
}
```

Route **every** incoming deep link through it. `nil` means "not mine" — the URL is not this client's
redirect, or carries no OAuth parameter — and in that case the SDK has touched nothing, including an
authorization the user is in the middle of. Anything non-`nil` is an outcome to handle.

Handling it in both places is not belt and braces. Consent happens inside the Tracive app, so your
app is backgrounded throughout and iOS may terminate it there. The SDK survives that — it persists
the pending authorization and the relaunched app completes the exchange — but the `await` on
`authorize()` died with the old process, so in that case this return value is the only place the
outcome appears. Ignore it and you will store a valid grant while your UI still shows a
"Connect Tracive" button. See [oauth.md](oauth.md).

## 6. Run a check

```swift
func check(_ phoneNumber: String) async {
  let query: TraciveQuery
  do {
    query = try TraciveQuery.phone(e164: phoneNumber)
  } catch let error as TraciveQueryError {
    // Rejected locally, before any request. Nothing was billed.
    showFieldError(error.errorDescription)
    return
  } catch {
    return
  }

  do {
    let result = try await tracive.checkScammer(query)
    render(result)
  } catch let error as TraciveError {
    handle(error)
  } catch {
    // ignore
  }
}
```

### Normalise to E.164 first

`TraciveQuery.phone` requires E.164 and **rejects** a local-format number. It has to: the server does
not up-convert `081234567891` to `+6281234567891` — it cannot know the dial code at that layer — so a
local number would index as a different entity, miss, and still be billed.

Use the user's region to build E.164 before you get here. A rejected query costs nothing; a
wrongly-formed one costs a credit.

## 7. Render the result

```swift
func render(_ result: CheckResult) {
  guard result.found else {
    show("No reports found.")
    return
  }

  switch result.riskTier {
  case .high:     showBanner(.red,    "High risk")
  case .elevated: showBanner(.orange, "Elevated risk")
  case .caution:  showBanner(.yellow, "Be careful")
  case .none:     showBanner(.grey,   "No risk signals")
  }

  show(reports: result.reportTotal, credible: result.credibleReports, tags: result.tags)

  // Not optional. Tracive's data is community-submitted; presenting it as established fact
  // misrepresents it. Show this wherever you show the verdict.
  if let disclaimer = result.disclaimer { showFootnote(disclaimer) }

  if result.origin == .cache {
    show(footnote: "Last updated \(result.fetchedAt.formatted())")
  }
}
```

`relatedScammerCount` is a count and never a list, on purpose: the SDK cannot walk the scammer graph,
so do not build a UI that expects to.

### Keep the check on the transaction it belongs to

A verdict is worth showing twice: once while the user can still stop, and once afterwards, on the
record of what they did. The second one is not a second check — record the first and read it back.

```swift
// After the transfer is created and has its own reference.
try client.cache.writeTransactionCheck(result, for: transaction.reference)

// On the transaction detail, however much later.
if let shown = try client.cache.readTransactionCheck(for: transaction.reference) {
  renderSecurityCheckCard(shown)     // tier, counts, shown.fetchedAt, shown.disclaimer
}
```

**When to run the check**

- **On the confirmation screen, before the PIN.** The user has seen the payee's name and the amount,
  so they have a reason to care, and they have not authorised anything yet, so a warning can still
  save the money for free.
- **Not while they are typing the account number.** There is no payee name on screen yet, so the
  answer means nothing to them — and every typo costs a credit.
- **Not on the receipt.** A warning after the money has gone is not protection, it is bad news. The
  receipt is the right place to *record* that a check happened, never to run one.
- **On the first transfer to a given account, plus a manual "check this payee" action.** Re-checking
  a payee the user pays every month spends their credits and teaches them to swipe past the result.

**When to record it**

- **Whenever a transaction exists and a check was run for it** — including, and especially, one where
  the user was warned and chose to continue. That is the transfer whose history someone will ask
  about.
- **Once per transaction, not once per check.** Two transfers to one account share one billed check;
  call `writeTransactionCheck` twice, with each transfer's own id.
- **Never when the user declined the check.** No record means no card, which is the truth. Rendering
  an empty result as "no reports found" invents a reassurance nobody gave.
- **Do not send any of it to your own servers.** The partner terms forbid uploading Tracive results,
  including derived values like a tier or a report count. What may leave the device is the user's
  decision — `riskAccepted`, `riskAcceptedAt` — and that is enough to defend the transfer in a
  dispute.

## 8. Handle errors properly

```swift
func handle(_ error: TraciveError) {
  switch error {
  case .insufficientCredits(let which, _):
    showTopUp(for: which)

  case .rateLimited(let retryAfter, _) where error.isDailyQuotaExceeded:
    // A daily allowance is spent; `retryAfter` points at 00:00 UTC.
    showTryAgainTomorrow(after: retryAfter)

  case .rateLimited(let retryAfter, _):
    scheduleRetry(after: retryAfter ?? 30)

  case .grantRevoked, .expiredToken:
    // Tokens are already cleared. Send the user back through consent.
    showReconnect()

  case .invalidToken(let info):
    // No usable grant is stored, and nothing was sent to the server. `info.code` is `no_grant`
    // when nobody has authorised yet, and `unusable_grant` when the stored record kept neither an
    // access token nor a refresh token. Log the second one separately — it points at local
    // storage rather than at the user, and it is not something they did.
    //
    // A record that has lost only its access token never reaches here: while the refresh token
    // beside it is good, the SDK renews it with a single token request and carries on, which shows
    // up as one unexplained refresh before the call you actually made.
    showReconnect()

  case .missingScope, .detailNotPermitted, .userCreditNotPermitted:
    log("This client is not entitled to that call: \(error.serverCode ?? "-")")

  case .translationNotPermitted:
    // Your contract withholds translation, or the user has no premium subscription. Checking again
    // without a `locale` returns the English result.
    retryInEnglish()

  case .cacheMiss:
    // Only possible with source: .cache.
    showOfflineNotice()

  case .network:
    showOfflineNotice()

  case .notImplemented:
    assertionFailure("Proxy mode is phase 2")

  default:
    showGenericError(error.errorDescription)
  }
}
```

Two rules worth putting in your own code review checklist:

1. **Do not call `credits()` before every check.** It doubles your request volume and is still racy —
   the balance can change between the two calls. Catch the 402 instead. `credits()` belongs on a
   settings screen.
2. **Do not retry a check without an `Idempotency-Key`.** A check that timed out may already have
   been charged. The SDK never auto-retries for this reason. If you retry, pass the *same* key both
   times so the server can collapse the duplicate.

## 9. Sign out

```swift
await tracive.signOut()     // best-effort revoke, then tokens and cached verdicts, regardless
```

`signOut()` clears local tokens even if the revoke call fails, so a user on a plane still ends up
signed out. It empties the result cache in the same breath: those rows are the departing user's
search history, and a failure to clear them is silent and lands on whoever picks the device up next.

If you specifically want a warm cache to survive a re-login on a single-user device, call
`await tracive.oauth?.signOut()` instead — that drops the grant and nothing else.

## 10. Report a scammer

On a transaction detail screen, a "Report" button can open the Tracive app's report form with the
recipient's account, the transaction date and the receipt already filled in. No consent, no token,
no network and no credit are involved, so this works before `authorize()` and for `.confidential`
clients.

```swift
@IBAction func reportTapped(_ sender: UIButton) {
  Task {
    sender.isEnabled = false
    defer { sender.isEnabled = true }

    let query: TraciveQuery
    do {
      query = try .bankAccount(countryAlpha3: "IDN", bankCode: transfer.bankCode, account: transfer.account)
    } catch {
      return showMessage("This account cannot be reported.")
    }

    let result = await tracive.openReportForm(
      query,
      incidentDate: ReportIncidentDate(transfer.completedAt),
      attachments: [.image(transfer.receiptImage, mimeType: "image/png")],
      from: .view(sender)
    )
    handle(result)
  }
}

func handle(_ result: ReportFormResult) {
  switch result {
  case .opened(attachmentsDelivered: true):
    break
  case .opened(attachmentsDelivered: false):
    // An older Tracive app, or `tracive-report` missing from LSApplicationQueriesSchemes:
    // the form opened with the account only.
    showMessage("Tracive opened. Please attach the receipt there.")
  case .cancelled:
    break
  case .installPageOpened:
    showMessage("Install Tracive, then tap Report again.")
  case .failed(let error):
    showMessage(error.localizedDescription)
  }
}
```

In SwiftUI there is no `UIView` to anchor to; pass `.keyWindow` and the sheet is presented from the
key window's top view controller (on iPad, as a popover pointing at its centre).

What happens, in order:

1. **Validation.** Types (JPEG, PNG, WebP, HEIC, HEIF, BMP, PDF; never GIF), bytes matching the
   declared type, at most 5 attachments (10 for a phone number), each PDF under 1 MiB, the encoded
   package at most 20 MiB, and a date no later than the device's local today. A failure answers
   `.failed(ReportFormError)` and opens nothing. `error.code` is the spelling all four Tracive SDKs
   share (`PDF_TOO_LARGE`, …, and `PLATFORM_FAILURE` when iOS refused a step); the index, the
   limit or the reason rides on the case.
2. **A Tracive app that accepts packages** (it answers `canOpenURL("tracive-report://")`): the SDK
   writes the package to its temporary directory and shows iOS's "Open in" sheet. The call waits for
   the user. Picking the Tracive app answers `.opened(attachmentsDelivered: true)`. Closing the
   sheet, "Save to Files" or any other app answers `.cancelled`; another app can claim the same file
   type, so the SDK checks which app the user actually picked. On iPad, rotating the device closes
   the sheet too, and the call answers `.cancelled` about a second later.
3. **An older Tracive app** (only `tracive://` answers): the SDK opens
   `tracive://report/create?media=…` and iOS asks the user to confirm.
   `.opened(attachmentsDelivered: false)`, or `.cancelled` if they decline.
4. **No Tracive app**: the install page, exactly as `authorize()` opens it, carrying nothing from the
   report. `.installPageOpened`.

Only one report can be on screen at a time: a call made while another is still waiting on the sheet
answers `.failed(.platform(reason: "already_in_progress"))`. Disable the button while the call is
running, as above.

The build follows the client's `environment`: production (and `.custom`) hand over to the production
app, sandbox to the sandbox app. Each claims its own file type, so a sandbox report never opens the
production form on a device that has both. `target:` overrides that, and is only for testing against
a build the SDK does not know about.

---

## Testing your integration

Everything below runs with no network and no server, so none of it depends on either environment
being up.

### Inject a fake transport

```swift
final class FakeTransport: HTTPTransport, @unchecked Sendable {
  var nextResponse = HTTPResponse(status: 200, body: Data("{}".utf8))
  private(set) var sentRequests: [HTTPRequest] = []

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    sentRequests.append(request)
    return nextResponse
  }
}

let transport = FakeTransport()
let client = TraciveClient(
  mode: .oauth(clientId: "test", redirectUri: URL(string: "https://example.com/cb")!),
  environment: .custom(baseUrl: URL(string: "https://example.invalid/v1")!),
  transport: transport
)
```

`HTTPTransport` returns the response for **every** status, including 4xx and 5xx — it throws only for
a transport-level failure. That is what lets you drive the 402, 403 and 429 paths from a test without
inventing a fake `URLError`.

### Use an in-memory cache and a fake clock

```swift
let clock = { Date(timeIntervalSince1970: 1_800_000_000) }
let cache = try SQLiteCheckCache.inMemory(keyStore: EphemeralCacheKeyStore(), now: clock)

let client = TraciveClient(
  mode: .oauth(clientId: "test", redirectUri: URL(string: "https://example.com/cb")!),
  transport: transport,
  cache: cache
)
```

`EphemeralCacheKeyStore` matters more than it looks: a test binary is unsigned, and reaching the real
Keychain from one either fails with `errSecMissingEntitlement` or prompts a human. A test that can
prompt is a test that hangs CI.

Move `clock` forward instead of sleeping, and you can assert a 30-day TTL in a millisecond. See
`Tests/TraciveSDKTests/CacheTests.swift` for the pattern.

### Assert the folded keys, not just the happy path

If you build queries from user input, test the folding: `+62 812-3456-7891`, `+6281234567891` and
`+62 (812) 3456 7891` must all produce one key. The canonical vectors are in
`Tests/TraciveSDKTests/Fixtures/query-grammar-vectors.json`.

---

## Checklist before you ship

- [ ] `LSApplicationQueriesSchemes` contains `tracive` **and** `tracivesandbox`, plus
      `tracive-report` and `tracivesandbox-report` if you call `openReportForm`
- [ ] Redirect URI is a Universal Link with a live `apple-app-site-association`, and matches what is
      registered with Tracive **exactly**
- [ ] The consent flow does not go through a `WKWebView` anywhere
- [ ] `.appNotInstalled` has a real UI path, not a silent no-op
- [ ] Phone numbers are normalised to E.164 before `TraciveQuery.phone`
- [ ] `result.disclaimer` is displayed wherever the verdict is
- [ ] 402 is handled; `credits()` is not called before each check
- [ ] Retries — if you have any — pass an `Idempotency-Key`
- [ ] Sign-out goes through `client.signOut()`, which clears the cache as well as the grant
- [ ] No `apiKey` anywhere in your integration. There is no parameter for one; if you found a way,
      you found a bug
