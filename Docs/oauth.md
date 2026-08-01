# OAuth

The consent flow, PKCE, token handling and sign-out.

> **Status.** OAuth mode is the whole of phase 1, and the consent endpoint it talks to is not
> deployed yet. The flow below is implemented against the frozen contract and unit-tested against a
> fake transport. It has never run against a live authorization server.

---

## The flow

```
Partner app                    Tracive app                 Tracive server
     │
     │ 1. authorize()
     │─── is Tracive installed? (canOpenURL "tracive")
     │
     │    no ──▶ open the clean install link ──▶ return .appNotInstalled  (flow ends)
     │
     │    yes
     │ 2. generate code_verifier, code_challenge (S256), state
     │    write the pending attempt to the Keychain  ← before anything is opened
     │ 3. UIApplication.open(authorize URL)  ─────────────▶
     │                                    user reviews scopes
     │        (your app is backgrounded here, and may be terminated)
     │                                    ◀───── POST consent ─────▶
     │ 4. ◀── Universal Link redirect: ?code=…&state=…
     │ 5. handleCallback(url:): read the pending attempt back, expire it if
     │    it is over 10 minutes old, then verify state
     │ 6. POST /oauth/token  (code + code_verifier)  ─────────────────────▶
     │ 7. ◀── access_token (JWT, 1 h) + refresh_token (opaque, rotating)
     │    store both in the Keychain, erase the pending attempt
     │    return .authorized(grantedScopes)
```

## Surviving a termination mid-consent

Consent happens **in another app**. For its whole duration your app is in the background, which is
where iOS looks first when it needs memory — so being killed there is ordinary, not exotic,
especially on older devices.

The SDK writes the pending attempt (`state`, `code_verifier`, `redirect_uri`, a creation timestamp)
to the same Keychain-backed store as the tokens, **before** it opens the authorize URL. When the
Universal Link relaunches your app, `handleCallback(url:)` reads it back and finishes the exchange
as if nothing had happened. Without this the verifier would die with the process, `state` would
match nothing, and a user who consented perfectly successfully would land in a dead flow reported as
`.failed(.stateMismatch)` — indistinguishable, from your side, from a CSRF attempt.

It goes to the Keychain and nowhere else, because the `code_verifier` is the secret half of the code
exchange. Never `UserDefaults`, never a file — the same rule as the tokens.

**This is the reason to use `handleCallback(url:)`'s return value:**

```swift
func scene(_ scene: UIScene, continue activity: NSUserActivity) {
  guard let url = activity.webpageURL else { return }
  Task {
    let result = await tracive.oauth?.handleCallback(url: url)
    // Handle `result` here, not only where you called authorize().
  }
}
```

`authorize()` suspends until the callback arrives, and in the ordinary case its `await` returns the
same value. But a continuation is a point in your *process's* stack: if the process was killed there
is nothing left to resume, and the relaunched one never called `authorize()` at all. The
authorization still completes and the grant is still stored — the outcome simply arrives as the
return value and nowhere else. An app that ignores it will authorize successfully and never notice.

### The attempt expires after 10 minutes

Ten minutes is the lifetime of the authorization code itself. Keeping the verifier for longer buys
no extra recovery, because by then the code it would be exchanged with is already dead server-side;
all a longer window adds is a live secret on the device with nothing to spend it on. A callback for
an older attempt fails with `TraciveError`, `serverCode == "authorization_expired"` — its own code,
not `.stateMismatch`, because "start again" and "somebody may be attacking you" are different
messages. Send the user back through `authorize()`.

The record is erased on every outcome that spends or abandons an attempt: success, `.denied`, a
server-reported error, a failed exchange, `cancelPendingAuthorization()`, `signOut()` and
`clearStoredTokens()`. So a spent callback cannot be replayed, even by a later process.

The one deliberate exception is a `state` **mismatch**, which leaves the record alone. Any app on
the device can hand yours a URL; if a mismatched redirect erased the pending attempt, an attacker
could cancel a consent your user is in the middle of for the cost of one `open`. Nothing is spent by
a mismatch, so nothing needs consuming — an attempt nobody comes back to is collected by the
ten-minute expiry instead.

### If you supply your own `TraciveTokenStore`

`loadPending()` and `savePending(_:)` have default implementations that persist nothing, so a store
written before this existed still compiles and still behaves exactly as it did. What it gives up is
only this recovery: the SDK also keeps the attempt in memory, so every in-process flow is unaffected.
Implement both — writing to wherever you keep the tokens — to get termination recovery back.

## PKCE

- `code_verifier`: 43–128 characters from the unreserved set, from a CSPRNG.
- `code_challenge = BASE64URL(SHA256(verifier))`, sent with `code_challenge_method=S256`.
- **S256 only.** `plain` is never sent and a server that offers it is not accommodated. Without PKCE,
  a malicious app that manages to receive the redirect can exchange the code for a token; `plain`
  provides no protection at all, since the "challenge" is the secret in cleartext.
- `state` is a separate random value, checked on the way back. A mismatch aborts the flow with
  `AuthResult.failed(.stateMismatch)` — it is never treated as a warning, because a mismatched state
  is what a CSRF attempt looks like.

## The install pre-check

The SDK checks that Tracive is installed **before** it redirects anywhere:

```swift
UIApplication.shared.canOpenURL(URL(string: "tracive://")!)
```

Your app must declare the scheme, or `canOpenURL` returns `false` for everyone:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>tracive</string>
</array>
```

When Tracive is not installed the SDK opens the **clean** install link and returns
`AuthResult.appNotInstalled`:

```
https://tracive.chottu.link/install?utm_source=tracive-sdk-ios&ref=<your client id>
```

Both query parameters are optional and neither is sensitive: `ref` is your OAuth client id — your
identifier, never the end user's — and is omitted if you have none; `utm_source` names the SDK.
Every Tracive SDK opens this same link, differing only in `utm_source`.

Clean means exactly that: no `client_id`, no `state`, no `code_challenge`, no `code_verifier`, no
`partner_user_id`, no `redirect_uri`, no `scope`. An attribution tag naming the partner is allowed;
OAuth parameters are not, because the link transits a third-party link service on its way to the
App Store and then to a fresh install, through channels nobody controls.

**There is no deferred resume.** After installing, the user comes back to your app and taps again.
Give that a real UI path — a dead end here is the single most common way an integration silently
converts at zero.

### Overriding the install link

`TraciveOAuth.init(…, installURL:)` takes your own link, and **it throws**:

```swift
let oauth = try TraciveOAuth(
  configuration: configuration,
  installURL: URL(string: "https://install.yourbank.example/tracive")
)
```

Three cases, and every Tracive SDK now applies the same three:

| You pass | What happens |
|---|---|
| nothing, or `nil` | the default link above. Absence is a real answer, and the common one. |
| a blank (whitespace-only) URL | **throws** `TraciveError`, `serverCode == "blank_install_url"` |
| anything else | used verbatim, untouched |

**A blank override is refused at construction.** It is never a considered choice — it is an unread
environment variable or an empty build setting — and passing it through produces a schemeless string
no operating system will open, which is neither our link nor yours. Whatever the SDK did with it,
the only signal would reach you much later and only for a user who does *not* have Tracive
installed: the rarest path in the flow, and the one nobody watches. Throwing here fails once, in
your own code, on every run, in development, before an end user is involved.

**This is not URL validation.** A wrong-but-non-blank link passes through untouched — a scheme no
phone can open, a bare word, a link with a space on the end. The SDK cannot tell an enterprise
distribution host or a regional store from a typo, and refusing a link that works would be the
worse mistake. Blankness is the one thing it will not accept.

If you would rather not write `try`, don't pass the parameter: `TraciveClient` builds its own OAuth
driver and never supplies an override, so `TraciveClient.init` does not throw.

One caveat belongs to the type rather than the SDK: `URL(string:)` returns `nil` for an empty
string, so an empty configuration value cannot reach the SDK as a URL at all — it arrives as a `nil`
indistinguishable from "no override", and takes the default. Only your call site can tell those
apart, so check the string before you convert it if the distinction matters. Whitespace is what
survives the conversion, and whitespace is what this rule catches.

## Never a `WKWebView`

The authorize URL opens with `UIApplication.open`, as a Universal Link. Not `WKWebView`, not
`SFSafariViewController` as a substitute for the app-to-app hop.

Two independent reasons, either sufficient:

1. **It does not work.** Universal Links do not fire from inside an in-app web view. The redirect
   will load as an ordinary page and the flow will simply never complete.
2. **It is forbidden.** RFC 8252 §8.12 prohibits embedded user agents for exactly this: the host app
   can read the credentials the user types, and the user has no way to verify what site they are
   actually on.

If you find yourself adding a web view to "make the redirect work", stop — the redirect URI or the
`apple-app-site-association` is wrong.

## The redirect URI

Must be an HTTPS Universal Link on a domain you control:

```
https://yourapp.example.com/oauth/tracive
```

A custom URL scheme (`myapp://oauth`) is not acceptable. Any app on the device can register the same
scheme, and iOS gives it to whichever app it feels like — which is an authorization-code interception
attack with no work required.

Register the URI with Tracive exactly as your app will send it. Matching is exact: no trailing-slash
tolerance, no prefix matching, no query-parameter tolerance.

## Public vs confidential clients

```swift
.oauth(clientId: "…", redirectUri: …, clientType: .public)        // default
.oauth(clientId: "…", redirectUri: …, clientType: .confidential)
```

**`.public`** — the SDK does the PKCE exchange itself and stores the tokens. This is the normal case
for a mobile app, because a mobile app has nowhere to keep a client secret.

**`.confidential`** — the SDK stops at the authorization code:

```swift
case .codeReceived(let code, let codeVerifier, let redirectUri):
  try await myBackend.exchangeTraciveCode(code, verifier: codeVerifier, redirectUri: redirectUri)
```

Your backend calls `POST /oauth/token` with its `client_secret` **and** the `code_verifier` the SDK
handed you. Tokens then live on your server and never touch the device; every check goes through your
backend. Note that this is the same shape as phase 2's Proxy mode, so a `.confidential` integration
is the easier one to migrate later.

## Tokens

| | |
|---|---|
| Access token | JWT, 1 hour, `Authorization: Bearer …` |
| Refresh token | opaque, **rotating** — every refresh returns a new one |
| Storage | Keychain, `ThisDeviceOnly`. Never `UserDefaults`, never a plist, never a file |

### Expiry is handled reactively, and only reactively

The SDK never refreshes ahead of the deadline. It sends the stored access token, and refreshes when
the server answers `401 expired_token`.

`TraciveTokens.isExpired(at:)` is available if you want to read the stored expiry yourself — to
pre-warm a session before a burst of checks, say — but **the SDK does not consult it**, and acting on
it is your decision rather than a switch that changes what the SDK does. It takes no leeway
parameter, because a leeway only means something to code that acts before the deadline and none here
does.

The reason is whose clock the expiry belongs to. It is measured against the *device's* clock, which
the SDK cannot control or correct, so a device running fast reports tokens expired early. Refreshing
on that estimate would rotate the refresh token more often than the grant needs — and every extra
rotation is another chance to present a token the server has already retired, which its reuse
detection may read as a stolen-token replay and answer by revoking the grant. The server's clock
decides.

### A blank stored access token is refreshed, not sent

There is one exception to "the stored access token is sent as it is", and it is not an expiry rule:
a stored access token that is **empty**. `TraciveTokens.accessToken` is a plain `String`, so a
record whose `access_token` is `""` decodes as cleanly as any other — a partial write, a Keychain
save interrupted by a termination, or a restored backup can each leave one behind, with the refresh
token beside it completely intact.

The SDK refreshes that grant instead of sending `Bearer `, and returns the fresh token. The refresh
token is the grant, and it is still good; throwing it away because a different field is empty would
sign the user out of something that still works. If there is no refresh token either, there is
nothing to renew with: the unusable record is cleared and the call fails with
`TraciveError.grantRevoked`, after which the next call reports `no_grant`. Send the user through
`authorize()`.

Do not expect the 401 path to cover this for you if you are reimplementing the token layer. An empty
bearer is malformed rather than expired, so the server answers `invalid_token` — which is terminal
here, as it should be — and the damaged record fails permanently instead of healing, one wasted
round trip at a time. The client-side check is the only thing that can recover it.

`TraciveOAuth.accessToken()` is `async` for this reason. Nothing changes at your call site: it is a
method on an `actor`, so every call from outside was already `await`ed.

### Refresh is single-flight

On a `401 expired_token` the SDK refreshes and replays the request. Concurrent 401s trigger
**exactly one** refresh; the others wait for its result.

This is not an optimisation. The refresh token rotates, so two simultaneous refreshes send the same
old token twice. The second one looks exactly like a stolen-token replay to the server's reuse
detection — and the correct server response to that is to **revoke the entire grant**. Your users
would be signed out at random, in bursts, under load, and the logs would show nothing but a
legitimate security response.

If you ever wrap or reimplement the token layer, this is the property to preserve.

### `grant_revoked`

```swift
case .grantRevoked:
  // Stored tokens have already been cleared by the SDK.
  showReconnect()
```

Do not retry. Do not refresh. The grant is gone — from the user revoking it in the Tracive app, from
an administrator, or from reuse detection firing. Send the user back through consent.

## Sign-out

```swift
await tracive.signOut()
```

Calls `POST /oauth/revoke` best-effort, then clears local tokens **regardless of the outcome**. A
user signing out on a plane still ends up signed out locally; the server-side token expires on its
own within the hour.

Clear the cache too:

```swift
try? tracive.cache.clear()
```

It is a separate call because it is a separate decision, but on a shared device you always want both:
the cache holds which identifiers this user looked up, which is exactly the kind of thing the next
person on the device should not inherit.

## Scopes

`TraciveScopes` carries the exact wire strings:

| Constant | Wire value | Grants |
|---|---|---|
| `TraciveScopes.scammerCheck` | `scammer.check` | running a scammer check |
| `TraciveScopes.creditsRead` | `credits.read` | reading the user's remaining credits |
| `TraciveScopes.profileRead` | `profile.read` | reading the minimal user profile |

Use them instead of string literals. A scope name is validated in exactly one place — the
authorization server — and an unknown one does not quietly produce a narrower grant: the entire
consent request is rejected. That makes a typo an integration that never authorizes, discoverable
only against a live server, and there is no live server yet.

The constants are `String`, not a closed enum, because `grantedScopes` travels the other way: it is
whatever the server says it granted, and that may include a scope registered after your copy of the
SDK shipped.

Ask for what you need and check what you got — the user may grant a subset, and the server may cap it
by what your client is registered for:

```swift
case .authorized(let grantedScopes):
  guard grantedScopes.contains(TraciveScopes.scammerCheck) else {
    showMessage("Tracive access is limited; scammer checks are unavailable.")
    return
  }
```

Calling something outside your granted scopes returns `403 missing_scope`, which surfaces as
`TraciveError.missingScope`.

## Testing the flow offline

The whole flow is unit-testable with no server and no browser:

- inject a fake `HTTPTransport` so `POST /oauth/token` returns whatever you want, including the 401
  and 402 paths;
- call `handleCallback(url:)` directly with a hand-built redirect URL. Test the good path, a wrong
  `state` (must give `.failed(.stateMismatch)`), a `?error=access_denied` (must give `.denied`), and
  a URL with neither a code nor an error;
- simulate a termination mid-consent by building **two** `TraciveOAuth` instances over **one**
  token store: start the attempt on the first, throw it away, and deliver the callback to the
  second. That is exactly what a relaunch is — the store survives, the process does not — and it
  must still reach `.authorized`. Advance an injected clock past ten minutes for the expiry case;
- for the single-flight property, fire several requests concurrently against a transport that returns
  `401 expired_token` and assert that `POST /oauth/token` was hit **exactly once**. That assertion is
  the one worth writing: it is the failure that would otherwise show up as random sign-outs in
  production and be nearly impossible to reproduce.
