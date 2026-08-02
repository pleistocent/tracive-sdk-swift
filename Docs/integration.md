# Integration guide

How to wire the Tracive SDK into an iOS app, end to end.

> **Before you start.** The Tracive Open API is not deployed yet, and phase 1 supports OAuth mode
> only. You can build, unit-test and ship everything on this page today; you will not get a real
> verdict back until the backend lands. Nothing in this guide requires a live server.

---

## 1. Add the package

```swift
// Package.swift
.package(url: "https://github.com/pleistocent/tracive-sdk-swift.git", from: "0.1.0")
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
  <string>tracivedev</string>
</array>
```

Both schemes, not just the first. `TraciveAppPresence.scheme(for:)` follows the environment: against
`.sandbox` it probes `tracivedev://`, and an app that lists only `tracive` gets `false` from
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
    partnerUserId: currentUser.id,   // optional; echoed back for your own reconciliation
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

## 8. Handle errors properly

```swift
func handle(_ error: TraciveError) {
  switch error {
  case .insufficientCredits(let which, _):
    showTopUp(for: which)

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

  case .missingScope, .detailNotPermitted:
    log("This client is not entitled to that call: \(error.serverCode ?? "-")")

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

---

## Testing your integration

Everything below runs with no network and no server, which is just as well, because there is no
server.

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

- [ ] `LSApplicationQueriesSchemes` contains `tracive` **and** `tracivedev`
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
