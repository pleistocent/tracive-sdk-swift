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
- `signOut()` is documented as **not** clearing the check cache, with the shared-device consequence
  spelled out, and `TraciveClient.init` is documented as doing blocking disk and Keychain I/O.
- **A blank `installURL` override is now specified, and tested, as never being replaced by the
  default.** No behaviour changes: `TraciveOAuth` already kept whatever non-`nil` URL it was given,
  and only `nil` ever selected the default. What was missing was that this is a *decision* — the
  sibling SDKs split on it, one trimming a blank override and falling back — and nothing recorded
  or defended it here, so a well-meant "treat blank as absent" tidy-up could have landed as an
  obvious improvement.

  The position: substituting the default for a partner's explicit blank value makes a
  misconfiguration *work*. A plausible page opens, the unread environment variable or empty build
  setting survives review and ships, and it stays invisible until the partner needs their own
  install funnel and cannot explain why Tracive's link keeps appearing. Keeping the value fails
  immediately, visibly, and as the partner's own failure. The initialiser documents this, and three
  tests pin it — verified capable of failing by introducing the fallback and watching them go red.

  One trap comes with the `URL?` type and is documented rather than fixed: `URL(string:)` answers
  `nil` for an empty string, so a partner funnelling an unvalidated configuration value through it
  hands the SDK a `nil` indistinguishable from passing nothing, and does get the default. Only the
  call site can tell those apart.

### Internal

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
