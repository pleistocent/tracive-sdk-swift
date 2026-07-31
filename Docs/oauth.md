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
     │ 3. UIApplication.open(authorize URL)  ─────────────▶
     │                                    user reviews scopes
     │                                    ◀───── POST consent ─────▶
     │ 4. ◀── Universal Link redirect: ?code=…&state=…
     │ 5. handleCallback(url:): verify state
     │ 6. POST /oauth/token  (code + code_verifier)  ─────────────────────▶
     │ 7. ◀── access_token (JWT, 1 h) + refresh_token (opaque, rotating)
     │    store both in the Keychain
     │    return .authorized(grantedScopes)
```

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
`AuthResult.appNotInstalled`. Clean means exactly that: no `client_id`, no `state`, no
`code_challenge`, no `redirect_uri`. An attribution tag naming the partner is allowed; OAuth
parameters are not, because they would be handed to the App Store, then to a fresh install, through
channels nobody controls.

**There is no deferred resume.** After installing, the user comes back to your app and taps again.
Give that a real UI path — a dead end here is the single most common way an integration silently
converts at zero.

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

Ask for what you need and check what you got — the user may grant a subset, and the server may cap it
by what your client is registered for:

```swift
case .authorized(let grantedScopes):
  guard grantedScopes.contains("scammer.read") else {
    showMessage("Tracive access is limited; scammer checks are unavailable.")
    return
  }
```

Calling something outside your granted scopes returns `403 missing_scope`, which surfaces as
`TraciveError.missingScope`.

## Testing the flow offline

The whole flow is unit-testable with no server and no browser:

- inject a fake `HttpTransport` so `POST /oauth/token` returns whatever you want, including the 401
  and 402 paths;
- call `handleCallback(url:)` directly with a hand-built redirect URL. Test the good path, a wrong
  `state` (must give `.failed(.stateMismatch)`), a `?error=access_denied` (must give `.denied`), and
  a URL with neither a code nor an error;
- for the single-flight property, fire several requests concurrently against a transport that returns
  `401 expired_token` and assert that `POST /oauth/token` was hit **exactly once**. That assertion is
  the one worth writing: it is the failure that would otherwise show up as random sign-outs in
  production and be nearly impossible to reproduce.
