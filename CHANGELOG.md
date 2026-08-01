# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — `0.x`, so minor versions may break
source compatibility until the API freezes at 1.0.

## [Unreleased]

### Added

- **`TraciveScopes` — the OAuth scope names as public constants.** `scammerCheck`, `creditsRead`
  and `profileRead` hold the exact wire strings, so an integrator no longer retypes them at every
  call site. This is a new public type and therefore a (purely additive) change to the API surface.

  Worth having because of where a mistyped scope surfaces. The authorization server is the only
  thing that validates a scope name, and it rejects the **whole** consent request when it does not
  recognise one — so a typo does not degrade into a narrower grant, it is an integration that
  cannot authorize at all, discoverable only against a live server, and there is no live server
  yet. Tests pin each constant against its literal value rather than against another symbol, so
  renaming one fails the build instead of quietly redefining the contract.

  They are `String` constants in a caseless `enum`, matching how `TraciveAppPresence` already
  namespaces its wire strings, rather than a `RawRepresentable` enum. `grantedScopes` travels the
  other way — it is whatever the *server* granted, possibly including a scope registered after this
  version shipped — and a closed enum would have to fail or drop those; `[String]` is also the
  frozen shape the sibling SDKs share.

  There is no constant for the daily-usage aggregate, and the documentation scan now treats every
  spelling of that scope as an offence. This SDK models no call that needs it, and publishing a
  constant for a request it cannot make would only teach partners to ask a user for a permission
  that buys them nothing. (Deliberately not spelled out here: the same test scans this file.)

### Fixed

- **An unrecoverable stored grant was reported as `.grantRevoked`, which said the server had done
  something it had not done.** A stored record holding a blank access token with no refresh token
  beside it has nothing left to spend and nothing to renew from, so `accessToken()` fails — that
  much was right. What it failed *with* was wrong. `.grantRevoked` means the server revoked the
  grant, and on this path nothing is sent and nothing is rejected: one field of a local file is
  empty. No one revoked anything.

  It now throws `TraciveError.invalidToken` carrying the new code `unusable_grant`, which is both
  the honest answer and the one the Kotlin, Flutter and React Native SDKs already give. **An
  integrator alerting on `.grantRevoked` will stop seeing it from this cause** — and that is the
  point of the change rather than a side effect of it. Revocation is how the server's reuse
  detection surfaces, so alerting on it is a sensible thing to do; the old error fired that alert
  for a damaged file on a single device and sent whoever answered it looking for a server-side event
  that had never happened. What is left produces `.grantRevoked` only after something really did
  happen to the grant: the server answering `401 grant_revoked` on a request or
  `invalid_grant`/`grant_revoked` on a refresh, a refresh that a rejected token started finding
  nothing left to renew from, and a `signOut()` dropping the grant while a refresh is in flight.
  Merely reading a damaged record off the device is no longer one of them.

  The code is `unusable_grant` rather than the `no_grant` an absent record gets, because the two
  states point at different things. `no_grant` is a user who has not authorized; this is local
  storage that kept half a grant. Both are terminal for the caller and the remedy for both is
  `authorize()`, but only one of them is worth looking at a device's storage over. Callers matching
  on `TraciveError.invalidToken` without inspecting `info.code` need no change at all.

  **The record is no longer erased.** The old behaviour cleared it, as a side effect of routing this
  case through `refreshTokens(…)` — the branch that reports a rejected refresh, where clearing is
  right because the grant really is finished. Here nothing had been rejected, so a partner debugging
  the first report found a store that no longer held what the report was about, and a second call
  answered `no_grant` instead of repeating itself. Asking twice now gives the same answer twice. No
  sibling SDK erases on this path either. `clearStoredTokens()` and `signOut()` remain the ways a
  grant is dropped, both of them deliberate.

  The blank-token *repair* — a blank access token with a live refresh token beside it — is
  unchanged, still delegates to `refreshTokens(…)`, and still inherits its single-flight guarantee.
  An empty-string refresh token is now treated the same as an absent one on this path, matching the
  test `refreshTokens(…)` has always applied, so the correction has no gap in it.

- **A stored grant whose access token was blank put `Bearer ` on the wire, and could never
  recover.** `TraciveTokens.accessToken` is a plain `String`, so a stored record whose
  `access_token` is the empty string decodes exactly as cleanly as any other value — a partial
  write, a Keychain save interrupted by a termination, or a restored backup will each leave one
  behind, with the refresh token beside it completely intact. `accessToken()` returned whatever it
  found once a grant existed, so the SDK authenticated its next request with an empty bearer.

  It now attempts the refresh instead and returns the fresh token, so the grant is renewed before
  the first request leaves and the caller never learns anything was wrong. Both of the other
  options are worse: sending an empty bearer authenticates nothing, and treating the record as "no
  grant" would discard a refresh token that is still live — and the refresh token *is* the grant.
  One field of local storage being empty is not a reason to sign a user out of something that
  still works.

  **The reactive 401 path could not have covered this**, which is why the check belongs on the
  client. An empty bearer is not an expired token, it is a malformed one: the server answers
  `invalid_token`, which this SDK treats as terminal — no refresh is attempted and the grant is
  dropped. A damaged record left to the server therefore never healed. It failed permanently, one
  wasted round trip at a time, and the round trip bought nothing that was not already knowable
  before the send.

  With no refresh token beside it there is nothing to renew with, which is terminal in the same way
  the `no_grant` guard above it is: the host app sends the user through `authorize()`. That case was
  first delegated to `refreshTokens(…)` and reported as `.grantRevoked`; the entry above corrects it
  to `.invalidToken` with the code `unusable_grant`, in the same unreleased version, and is the
  description to read.

  The recovery is routed through the ordinary `refreshTokens(…)` rather than a private refresh, so
  it inherits the single-flight guarantee rather than opening a second door around it. A blank
  token discovered while a refresh is already running joins that refresh instead of racing it —
  two simultaneous refreshes present the same rotating token twice, which is what reuse detection
  revokes a grant for. An ordinary call with a usable token pays one `isEmpty` and nothing else.

  **`accessToken()` gains `async` and is now `public func accessToken() async throws -> String`.**
  Refreshing is asynchronous, so the guard cannot live here without it. **This is not
  source-breaking for callers outside the actor, which is every caller an integrator normally
  has:** `TraciveOAuth` is an `actor`, so a call from any other isolation domain was already
  awaited, and `try await oauth.accessToken()` compiles unchanged. `TraciveClient` needed no edit
  at all. The one shape that does break is a *synchronous* call made from inside the actor's own
  isolation — an `extension TraciveOAuth` written in your own module — which now needs `await` like
  every other call; nothing in this package had one.

  `Docs/oauth.md` and diagram 3 of `Docs/architecture.md` describe the branch, and the diagram also
  gains the "is there a refresh token at all" decision it had always omitted. The React Native SDK
  applies the identical rule, and the four SDKs are standardising on it.

- **An authorization did not survive the host app being terminated during consent, and the loss was
  reported as a state mismatch.** The pending attempt — the PKCE `code_verifier` and the `state` —
  was a field on the actor and nothing else. But consent happens in *another* app: the host app is
  backgrounded for the whole of the user's visit to Tracive, and the background is where iOS looks
  first when it needs memory. When the app was collected there, the verifier went with it; the
  Universal Link relaunched the app, the callback arrived, `state` matched nothing, and the user —
  who had consented perfectly successfully — landed in a dead flow. Nothing distinguished it from a
  CSRF attempt, because the SDK reported it as `.failed(.stateMismatch)`, which is what an attack
  looks like. On an older device this is not an edge case; it is the ordinary fate of a backgrounded
  app.

  The attempt is now written to the Keychain-backed token store **before** the authorize URL is
  opened, and read back in `handleCallback(url:)` when this process has no memory of one. The
  ordering is the mechanism: the app can only be killed once it is in the background, which is after
  the launch, so a record written afterwards would not exist during the one window that matters. It
  goes to the secure store and nowhere else — the verifier is the secret half of the code exchange,
  so `UserDefaults` and a plain file are as forbidden for it as they are for a refresh token. The
  exchange also replays the `redirect_uri` recorded with the attempt rather than re-reading it from
  the configuration, because RFC 6749 §4.1.3 asks for the URI the authorization was *started* with.

  The record expires after **ten minutes** (`PendingAuthorization.maxAge`), which is the lifetime of
  the authorization code itself. Holding the verifier longer buys no additional recovery — the code
  it would be exchanged with is already dead server-side — while a longer window does leave a live
  secret on the device with nothing to spend it on. A callback for an older attempt fails with
  `serverCode == "authorization_expired"` rather than `.stateMismatch`: "start again" and "somebody
  may be attacking you" are different messages and a partner should be able to tell them apart. The
  window is pinned by tests at absolute seconds either side of the boundary, not at
  `maxAge ± 1`, because a test written against the constant it is testing passes at any window size
  and is how such a value drifts unnoticed; and `isStale(at:)` takes no per-call override, so there
  is exactly one number.

  The record is erased on every outcome that spends or abandons an attempt — success, `.denied`, a
  server-reported error, a failed exchange, a refused launch, `cancelPendingAuthorization()`,
  `signOut()` and `clearStoredTokens()` — so a spent callback cannot be replayed, by this process or
  a later one, and a sign-out cannot leave a spendable verifier behind. A `state` **mismatch** is
  the one deliberate exception: any app on the device can hand the host app a URL, and erasing there
  would let a stray or hostile redirect cancel the consent the user is in the middle of for the cost
  of one `open`. Nothing is spent by a mismatch, so nothing needs consuming, and an attempt nobody
  returns to is collected by the expiry instead. The Flutter SDK makes the same exception for the
  same reason.

  **New public API, purely additive.** `PendingAuthorization` (a `Codable`, self-redacting record)
  and two `TraciveTokenStore` requirements, `loadPending()` and `savePending(_:)`. Both have default
  implementations that persist nothing, so a host app that already conforms its own vault to the
  protocol keeps compiling and keeps behaving exactly as before: the SDK still holds the attempt in
  memory too, and only consults the store when its own field is empty. Such a store forgoes the
  recovery and nothing else; implementing the two methods gets it back.

  **No new API was needed to deliver a recovered authorization, and none was added for it.**
  `handleCallback(url:)` already returns the `AuthResult`. That matters more than it sounds: the
  continuation `authorize()` suspends on cannot be persisted — it is a point in a process's stack,
  and a relaunched process has none — so after a termination there is nobody to resume and the
  return value is the *only* channel. It is now documented as the one to use. An app that discards
  it will store a perfectly good grant and never notice. `Docs/oauth.md` and diagram 2 of
  `Docs/architecture.md` describe the persisted record, its expiry and this consequence.

- **`TraciveQuery.email(value:)` accepted anything non-empty, and every typo was billed.**
  `email("budi")` built `EMAIL_budi` and sent it. The server applies no shape validation to an
  email, so that is a perfectly legal record key: it is looked up, it misses, and the miss is
  charged exactly like a hit. A client-side rejection was the only thing that could prevent the
  charge — the same job `phone()`'s E.164 check has always done — and there wasn't one. A value
  containing no `@` now throws `TraciveQueryError` with reason `not_an_email`.

  The check is `@`-presence and deliberately nothing more. A fuller address grammar would reject
  addresses the server would happily match (`budi@localhost`, an IP-literal domain, a quoted local
  part), and that is the worse failure: over-rejecting loses a real fraud answer, while
  under-rejecting costs at most one miss. An empty value keeps its own `empty_value` reason, so the
  two mistakes stay distinguishable to a caller.

- **The reserved-key guard was stricter than the server, across a line terminator.** The API
  reserves keys matching `^__.*__$`. That pattern carries no `s` flag, so `.` does not match a line
  terminator and `.*` cannot cover a middle containing one — `"__a\nb__"` is a key the server
  accepts. `DocumentIdGuard` implemented the rule as `hasPrefix("__") && hasSuffix("__")` and
  rejected it. The guard now matches the pattern's real semantics, including that `$` does not
  match before a trailing newline (no `m` flag either) and that U+0085 NEL is *not* a JavaScript
  line terminator even though ICU, and therefore `NSRegularExpression`, treats it as one.

  Previously recorded as a deliberate divergence, on the argument that over-rejection is the cheap
  direction and no builder can reach the branch anyway — the guard runs on the folded key, which
  every builder prefixes with its kind, so it never begins with `__`. That still holds, and no
  caller-visible behaviour changes because of it; the rule is corrected because three SDKs quietly
  disagreeing with the contract they all vendor is the more expensive kind of wrong.

- **`detail: .full` used the cache, and was wrong in both directions.** It now neither reads nor
  writes it. Two independent defects, one rule.

  *The read.* The cache stores only fields that do not vary with `detail`, so `comments` and
  `topChronologies` are stripped on the way in — but the read path never consulted `detail`, so a
  `.full` request on the default `.cacheFirst` source was served that stripped row with both fields
  `nil` and no network call. `nil` there is byte-identical to "the server answered in full and there
  are no incidents on file", so a partner screen would tell someone about to send money that an
  identifier with four incident reports is clean. That is a wrong fraud answer, not a caching
  subtlety: it is silent, it is on the default source, and the content it drops is exactly the
  narrative a person reads before deciding.

  *The write.* The stored projection keeps `tags` and `disclaimer`, and the row key carries no
  locale — while a `.full` request is the only kind that sends one. Storing its projection filed
  localized text under a locale-less key, and the next `.minimal` check, which sends no locale, read
  it straight back as the default. `disclaimer` is the one string this SDK requires every integrator
  to display, so the result was a legal notice rendered in a language the user never asked for.
  Skipping only the read would not have helped: the row is poisoned on the way in, by the `.full`
  call, and collected by a later `.minimal` call that reads the cache quite legitimately.

  So `.cacheFirst` skips the read, `.cache` raises `.cacheMiss`, `.serverFirst` surfaces the network
  error instead of degrading to a row, and none of them stores the response. `.minimal` routing is
  untouched and nothing in the public surface changed. Three behaviours to plan for: a `.full`
  request is never served free from cache; it no longer warms the cache, so `.full` then `.minimal`
  on one query costs two credits rather than one; and a `.full` request offline now fails rather
  than returning a partial answer that looks complete. `CheckResult.cacheableCopy()` documents the
  locale constraint it cannot enforce itself. The Kotlin and Flutter SDKs carry the identical rule.
- **The install link pointed at a host with no path.** `TraciveAppPresence.installURL(clientId:)`
  built `https://tracive.chottu.link` instead of `https://tracive.chottu.link/install`, so the one
  thing the SDK does for a user who does not have Tracive installed — open the download funnel and
  stop — sent them to a URL that is not the install page. The only test covering the link asserted
  `url.host` alone, which the wrong link satisfied, so it stayed green. The path is now part of the
  link and the test pins the whole URL, query parameters included. The link still carries no OAuth
  parameter of any kind: it transits a third-party link service, and `state`, `code_challenge`,
  `code_verifier`, `partner_user_id`, `redirect_uri` and `scope` may never be handed to one.

- **Query folding now mirrors JavaScript's whitespace semantics, not Foundation's.** Every fold used
  `trimmingCharacters(in: .whitespacesAndNewlines)` (and `Character.isWhitespace` for bank
  accounts), which disagrees with the backend's JS in *both* directions: it strips U+200B, which JS
  `trim()` keeps, and it does not strip U+FEFF, which JS `trim()` removes. A pasted identifier
  carrying a ZWSP or a BOM therefore folded to a different key than the server's — a guaranteed
  miss, and a miss is still billed. `QueryFolding` now uses a hand-written
  `WhiteSpace ∪ LineTerminator` class asserted against the fixture.

- **`signOut()` could be silently undone by an in-flight token refresh.** `signOut()` awaited
  `POST /oauth/revoke` before clearing the token store, so a refresh parked on its own round trip
  could resume afterwards and write its rotated grant back. The user was told they had signed out
  while a live, freshly rotated refresh token stayed in the Keychain. Cancelling the refresh task
  was not a fix: cancellation is cooperative, and a response already on the wire arrives regardless.
  Every token write is now gated on a generation counter that `signOut()` and `clearStoredTokens()`
  bump, and `signOut()` clears the store before the revoke rather than after.
- **`authorize()` could strand its caller forever.** The continuation was installed *after*
  `appLauncher.open(…)`, so a callback arriving during the launch completed the whole flow — grant
  stored, `.authorized` returned — while `authorize()`'s `await` never resumed. The continuation is
  now installed before the launch.
- **A corrupt cache data key was permanent.** A stored key that could no longer produce a usable AES
  key (an Enclave reset, a restore onto another device) made `dataKey()` throw for the lifetime of
  the install, and because the `.cacheFirst` path swallows cache errors, the only symptom was every
  check going to the server and being billed. The unusable item is now replaced and the cache
  restarts cold. Transient Keychain unavailability still propagates untouched.
- **The 401 replay could double-charge.** After refreshing an expired token the SDK re-sends the
  same non-idempotent check; with no caller-supplied `Idempotency-Key` the two attempts were
  indistinguishable to the server. The SDK now generates a per-call key when the caller supplies
  none. This does not grant a retry budget — that still requires the caller's own key.
- **`+` was not percent-encoded in the authorize URL.** `URLComponents.queryItems` leaves `+`
  unescaped, and a server parsing the query with a form decoder reads it as a space — breaking a
  `redirect_uri` exact match or a `partner_user_id` account link. It is now emitted as `%2B`.
- **`KeychainTokenStore` did not opt macOS into the data-protection keychain**, so the
  `ThisDeviceOnly` accessibility class the docs promise was ignored there. Both Keychain-backed
  stores now build their query through one shared definition so they cannot diverge again.
- **`SQLiteCheckCache.read` deleted a row while its `SELECT` was still open**, which can return
  `SQLITE_LOCKED` and, because the delete is best-effort, silently leave the row behind.
- **`SQLiteStatement` did not retain its `SQLiteConnection`**, leaving a use-after-free available to
  the first caller who outlived one.

### Changed

- **An empty crypto address and an empty username platform now have their own rejection reasons**,
  `empty_address` and `empty_platform`, instead of sharing the generic `empty_value`. Three
  different mistakes used to arrive as one token, so a caller catching the error could not tell
  which of the two arguments it had just been handed was the blank one, and could not put the
  message on the right field. `empty_value` remains, with an empty email as its only user.

  Source-breaking for anything that matches on `QueryRejectionReason.emptyValue` for a crypto or
  username rejection, or compares `rawReason` against `"empty_value"` for one; switch to
  `.emptyAddress` / `.emptyPlatform`. The tokens are the shared cross-SDK contract, so Kotlin and
  Flutter carry the identical spelling.

- `query-grammar-vectors.json` updated to **version 5**: 34 vectors, 14 rejection cases and 9
  document-id guard cases. The `nfcScope` note now states correctly that NFC applies to *every* code
  field, the bank code included, and a new `bank-code-nfc-composes-before-uppercasing` vector pins
  it — composition there is length-changing, so an implementation that skipped it would build keys
  that can never match. Version 5 adds the three query-validation rules listed above. The Swift
  suite now also pins the vector, rejection and guard-case counts, so a case dropped during a
  re-vendor fails the build instead of shrinking the contract silently.
- `TraciveError` and `AuthResult` are now **checked** `Sendable` rather than `@unchecked`. The
  `any Error` payload never blocked conformance, so the opt-out was unnecessary — and it was
  suppressing exactly the check that stops a future case carrying a thread-unsafe payload.
- `checkScammer` always sends an `Idempotency-Key`, generated per call (prefixed `sdk-`) when the
  caller supplies none. Previously the header was absent unless the caller passed one.
- The documented OAuth scope is `scammer.check` everywhere, and the README quick start now also
  lists `credits.read`. The prose docs previously named a different, read-flavoured scope that no
  code path ever used, so a partner copying the quick start would have been refused with
  `403 missing_scope`. (The old spelling is deliberately not repeated here: a test scans these
  documents for scope strings the SDK never requests, and it does not know prose from example.)
- **`TraciveClient.signOut()` now empties the result cache as well as the grant.** It previously
  cleared only the tokens and told the integrator, in four places, to call `cache.clear()` as a
  second step. That is documentation standing in for a safe default. The rows were fetched under the
  departing user's grant and are keyed by `SHA-256` of a phone number or an email address — a search
  space small enough to brute-force offline — so anyone who missed the second call left the previous
  user's search history readable on a shared device, with nothing to report it.

  The argument against was that `cache` is injectable and could be shared by two clients, so
  clearing here can empty rows another client put there. It loses on the shape of the two failures:
  over-clearing costs re-billed checks, which is bounded and visible in the billing, while
  under-clearing is a silent privacy leak on a device the SDK has no further contact with. Sharing
  is also weaker than it looks — `CheckCacheKey` carries no user and no client id, so a shared store
  is already serving one user's rows to another.

  **Behavioural, and it is the point.** A caller who deliberately wants a warm cache to survive a
  re-login on a single-user device should call `oauth?.signOut()`, which drops the grant and touches
  nothing else. A failing `clear()` cannot fail the sign-out: the tokens are already gone by then.
  Kotlin, Flutter and React Native clear on sign-out for the same reason.
- `TraciveClient.init` is documented as doing blocking disk and Keychain I/O.
- **A blank `installURL` override is now rejected at construction, and `TraciveOAuth.init` throws.**
  Three cases, shared by all four Tracive SDKs: `nil` (or the parameter omitted) selects the
  default install link exactly as before; a blank — whitespace-only — override throws `TraciveError`
  with `serverCode == "blank_install_url"`; anything else is used verbatim.

  **Source-breaking**, and knowingly so: every direct `TraciveOAuth(…)` call site needs `try`. Two
  things make that the right trade. The break is total and mechanical — the compiler names every
  site and the fix is one keyword — and the package is 0.1.0 and unreleased, so no partner has
  written the old call yet. It will never be cheaper to make than it is now.

  `TraciveClient` is untouched and still does **not** throw. It builds its own OAuth driver through
  an internal factory that supplies no override, so it has nothing that could be blank — an
  integrator who never heard of install links cannot be made to write `try` by a rule about them.

  This reverses the position recorded earlier in this same unreleased section, which was to keep a
  blank override and let the install funnel try to open it. That reasoning — that substituting our
  link for a partner's explicit value makes a misconfiguration *work* — still holds, and rejecting
  is not a retreat from it: the value is not replaced, it is refused. What changed is the evidence
  about *when* the partner finds out. A sibling SDK measured what a passed-through blank actually
  becomes downstream: `"?ref=…&utm_source=…"`, a schemeless string no operating system will open,
  neither our link nor theirs. The failure it produces surfaces late and only for a user without
  the Tracive app installed — the rarest path in the flow, and the one nobody instruments. Refusing
  at construction fails once, in the host app's own code, on every run, in development, before an
  end user is anywhere near it. Same principle, a failure several months earlier.

  It is **not** URL validation, and the tests say so with a deliberately silly list: a scheme no
  phone can open, a bare word, a link with a space on the end — all preserved byte for byte,
  including their whitespace, so nothing here trims or rebuilds what it was handed. The SDK cannot
  distinguish an enterprise distribution host or a regional store from a typo, and refusing a link
  that works is the worse error.

  The reason token is asserted as a string literal rather than through a constant, because it is a
  cross-SDK contract: renaming a Swift constant must fail this test rather than quietly redefine
  what four SDKs report.

  One trap comes with the `URL?` type and is documented rather than fixed: `URL(string: "")` is
  `nil`, so an empty configuration string cannot reach the initialiser as a URL at all — it arrives
  as a `nil` indistinguishable from passing nothing, and takes the default. Only the call site can
  tell those apart. Whitespace is what does survive the conversion, and it is what the rule catches;
  note that `URL` percent-encodes it, so the check decodes before it trims — trimming
  `absoluteString` directly would have seen `"%20%20%20"` and called it non-blank, accepting every
  blank the rule exists to catch.

- **`TraciveTokens.isExpired(at:leeway:)` has lost its `leeway` parameter and is now
  `isExpired(at:)`.** The method itself stays. Reading the stored expiry is a legitimate thing for a
  host app to want — pre-warming a session before a burst of checks, or showing the state of a
  connection in a settings screen — and what is being withdrawn is a knob, not the ability to look
  at the data.

  Nothing in the SDK ever called `isExpired`, with a leeway or without one. Expiry handling here has
  always been purely reactive: the stored access token is sent, and on the server's
  `401 expired_token` the SDK refreshes once, single-flight, and replays the request. A leeway is
  only meaningful to something that acts *before* the deadline, so the parameter configured
  behaviour this SDK has never performed — a public surface advertising a pre-emptive refresh that
  an integrator reading it would reasonably assume was happening, and that was not.

  Why it is not happening is a question of whose clock is being consulted. `expiresAt` is measured
  against the *device's* clock, which the SDK neither controls nor can correct; a device running
  fast reports tokens expired early, and one that is badly wrong reports them expired on arrival.
  Refreshing off that estimate would rotate the refresh token far more often than the grant needs,
  and since every rotation kills the token before it, each surplus rotation is one more chance for a
  dead token to be presented — which the server's reuse detection is entitled to read as a
  stolen-token replay and answer by revoking the entire grant. A wrong device clock would reach the
  user as random sign-outs. The server's clock is the one that decides, so the SDK waits to be told.

  **Source-breaking**, notwithstanding that the parameter carried a default: a call site that passed
  `leeway:` no longer compiles, and 0.x has no deprecation period to soften it. Behaviour is
  unchanged for everyone else — `isExpired(at:)` returns exactly what `isExpired(at:leeway: 0)`
  returned, boundary included.

  All four Tracive SDKs are standardising on this single reactive strategy. This one already
  implemented it and only its public surface disagreed, which makes the change here an honesty fix
  rather than a behavioural one.

### Internal

- **The vendored grammar fixture is now pinned by content hash**, in `swift test` and in CI, both
  reading one sidecar file. `query-grammar-vectors.json` is copied byte-identically into four SDK
  repositories, and identical bytes are the whole mechanism by which they are known to agree — but
  nothing here checked them. `QueryGrammarTests` decodes the file and drives its vectors, so it reads
  the fixture's meaning and is blind to its bytes: an audit reformatted the fixture from 21 662 bytes
  to 32 533 and watched all 259 tests stay green. That change is harmless to this SDK and fatal to
  the cross-repo contract, because once one copy is reformatted the comparison stops being answerable
  and the next real grammar change lands in a copy nobody can diff against the others.
- The reactive refresh is now pinned at its coldest point: a session whose **first** request carries
  a stored token that expired while the app was closed. Every other refresh test began from a token
  the session had already used successfully, so the case with nothing standing in front of it was
  the one case unasserted — and in a sibling SDK a pre-emptive expiry check meant that request never
  reached the server with a dead token at all. It passed on the first run, unchanged: the test
  records existing behaviour rather than accompanying a fix. `isExpired(at:)` also gains direct
  coverage of its boundary, which it previously had none of.
- CI can now fail where it previously could not: it builds for iOS (so `UIKitAppLauncher` is
  compiled at all), enforces the Swift 6 language mode and `-strict-concurrency=complete` with
  warnings as errors, and checks the dependency-free guarantee against the manifests themselves —
  the old guard inspected a `Package.resolved` that is never written for a dependency-free package,
  so it was unconditionally green, and it did not cover the Example at all.
- `OfflineGuaranteeTests` enforces the "no network, no Keychain" property of the test suite, which
  was previously only asserted in prose.
- Removed every citation to internal-only material, along with an unused `Darwin` import.

## [0.1.0] — 2026-07-31

First release. **The Tracive Open API is not deployed**: this package implements the frozen contract
and is fully unit-tested offline, but no request in it has ever reached a live server. Integrate and
ship the wiring now; expect real verdicts when the backend lands.

### Added

**Client (phase 1, OAuth mode)**

- `TraciveClient` with `checkScammer(query:source:detail:locale:idempotencyKey:)`, `credits()` and
  `profile()`.
- `TraciveEnvironment`: `.production`, `.sandbox`, `.custom(baseUrl:)`.
- An injectable HTTP transport, so a host app can unit-test its integration with no network at all.
- `TraciveMode.proxy` exists in the surface but throws
  `TraciveError.notImplemented("Proxy mode arrives in phase 2")` on every call. It is here so that
  enabling it later is not a source-breaking change. See `Docs/proxy-contract.md`.

**OAuth**

- Authorization Code + PKCE, **S256 only**. `plain` is neither sent nor accepted.
- A pre-flight check that the Tracive app is installed, before any redirect. Not installed opens the
  clean install link — carrying no OAuth parameters — and returns `AuthResult.appNotInstalled`.
- Consent opens through `UIApplication.open` on a Universal Link. Never a `WKWebView`: Universal
  Links do not fire from one, and RFC 8252 forbids it.
- Access and refresh tokens stored in the Keychain.
- Single-flight refresh on `401 expired_token`: concurrent 401s trigger exactly one refresh and the
  rest await its result. Doing this wrong trips the server's refresh-token reuse detection, which
  revokes the entire grant.
- `signOut()` calls `POST /oauth/revoke` best-effort, then clears local tokens regardless of the
  outcome.

**Queries**

- `phone`, `email`, `bankAccount`, `iban`, `crypto`, `username` builders, each producing the folded
  `searchQueryIndex` the server keys on.
- Validation runs before any network call, because a key that cannot hit is still billed as a miss.
- `query-grammar-vectors.json` vendored verbatim from the backend and driven as a test, so the Swift,
  Kotlin and Flutter folds cannot drift apart silently.
- Deliberately **no `domain()` builder** — the backend dropped the DOMAIN type, so such a key could
  only ever miss.

**Cache**

- `CheckCache` protocol, `SQLiteCheckCache` (system `libsqlite3`) and `NoOpCheckCache`.
- Rows keyed by `SHA-256(searchQueryIndex)`; the raw identifier is never written to disk.
- Per-row AES-256-GCM encryption via CryptoKit, fresh 96-bit nonce per record, with the cache key and
  schema version as additional authenticated data so a payload cannot be moved between rows.
- Data key in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), Secure
  Enclave-backed where the device has one.
- Per-tier TTLs — `HIGH` 30 d, `ELEVATED` 7 d, `CAUTION` 24 h, `NONE` 1 h — with the server's
  `cacheTtlSeconds` overriding them when present.
- Full-detail content (`topChronologies`, `comments`), `billing` and `checkId` are never cached.
- Lazy expiry on read, a prune pass on open, an optional `maxEntries` cap, and
  `SQLiteCheckCache.schemaVersion` as a one-line lever to invalidate every stored row on upgrade.
- An injectable clock, so TTL behaviour is tested exactly rather than by sleeping.

**Errors**

- `TraciveError` covering the documented status/code mapping. An unrecognised server code degrades to `.server` or
  `.unknown` carrying the raw code — it never crashes and is never dropped.
- `TraciveError.rateLimited` reads the `Retry-After` header, in both its seconds and HTTP-date forms.

**Repository**

- Apache-2.0 licence, `SECURITY.md`, `Docs/{integration,oauth,caching,proxy-contract}.md`, a SwiftUI
  example, and a GitHub Actions workflow running `swift build` and `swift test` on macOS.

### Security

- No API-key parameter exists in any public type, in either mode, by design.
- A check is never retried automatically. A blind retry after a 5xx or a timeout risks a double
  charge; callers who retry must pass an `Idempotency-Key`.
- `TraciveQuery`, `CheckCacheKey`, `ProxyConfiguration` and `TraciveQueryError` redact themselves in
  `description`, so no identifier or bearer token can reach a log through string interpolation.

### Notes

- **Zero third-party dependencies**, enforced in CI. No SQLCipher: the cache encrypts payloads per
  row with CryptoKit instead of encrypting the database file.
- iOS 15+ / macOS 12+.

[Unreleased]: https://github.com/pleistocent/tracive-sdk-swift/compare/0.1.0...HEAD
[0.1.0]: https://github.com/pleistocent/tracive-sdk-swift/releases/tag/0.1.0
