# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — `0.x`, so minor versions may break
source compatibility until the API freezes at 1.0.

## [Unreleased]

### Fixed

- **Query folding now mirrors JavaScript's whitespace semantics, not Foundation's.** Every fold used
  `trimmingCharacters(in: .whitespacesAndNewlines)` (and `Character.isWhitespace` for bank
  accounts), which disagrees with the backend's JS in *both* directions: it strips U+200B, which JS
  `trim()` keeps, and it does not strip U+FEFF, which JS `trim()` removes. A pasted identifier
  carrying a ZWSP or a BOM therefore folded to a different key than the server's — a guaranteed
  miss, and a miss is still billed. `QueryFolding` now uses a hand-written
  `WhiteSpace ∪ LineTerminator` class asserted against the fixture.

### Changed

- `query-grammar-vectors.json` updated to **version 2**: 33 vectors (8 new, covering NBSP/ZWSP
  trimming, length-changing case mapping, Arabic-Indic digit stripping and the unfolded `0X` EVM
  prefix) plus new `crossLanguageSemantics` and `documentIdGuard` sections. Both new sections are
  now driven as tests rather than read as prose.

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
