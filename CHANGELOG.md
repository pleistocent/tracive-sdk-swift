# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — `0.x`, so minor versions may break
source compatibility until the API freezes at 1.0.

## [Unreleased]

### Added
- **Three newer server error codes now have a type.** `user_credit_not_permitted` and
  `translation_not_permitted` (both 403 on a check) map to the new cases
  `.userCreditNotPermitted` and `.translationNotPermitted` instead of `.unknown`, with matching
  `TraciveErrorKind` values. `daily_quota_exceeded` stays `.rateLimited`, so an existing handler
  keeps working, and the new `error.isDailyQuotaExceeded` tells it apart from a short burst limit.
  A `switch` over `TraciveError` or `TraciveErrorKind` with no `default` gains two cases.
- **A check can now be recorded against your own transaction, so a transaction-detail screen can show
  it again later.** `client.cache` gains `writeTransactionCheck(_:for:)`,
  `readTransactionCheck(for:)` and `removeTransactionCheck(for:)`.

  ```swift
  try client.cache.writeTransactionCheck(result, for: "TRF26090814320771")  // once it has a reference
  try client.cache.readTransactionCheck(for: "TRF26090814320771")           // nil = no check on file
  ```

  There was no way to do this before, and the near-miss was worse than the gap: `checkScammer(query,
  source: .cache)` looks like it answers the question and does not. It returns the **latest** answer
  for that account rather than the one the user was shown, and it returns nothing at all once the
  tier TTL has run out — an hour, for a clean verdict. So the card on yesterday's transfer was either
  blank or, after the account was reported, quietly rewritten to claim the user had been warned.

  Each record is therefore a **snapshot**, not a pointer into the cache: a later check of the same
  account cannot edit an earlier transaction's card. One check can be recorded against several
  transactions — the second transfer to an account you already checked is a cache hit, so it costs no
  credit, and its record carries `origin == .cache` to say so. Retention is
  `CachePolicy.transactionCheckRetention`, 90 days by default, and deliberately not a tier TTL: a
  clean answer stops being trustworthy after an hour but never stops being what someone was
  shown.

  It is a separate call rather than a parameter on `checkScammer` because of when the two things
  happen: the check runs on the confirmation screen and the reference number is minted after the PIN,
  so there is no transaction id to pass at check time.

  Storage-wise this is the same `check_cache` table, the same Keychain data key and the same
  `clear()` on sign-out. Records are keyed `txn:` + `SHA-256(transactionId)` — the id is hashed like
  an identifier is, because in cleartext beside an encrypted verdict it would say which transfers a
  device holds a fraud answer for — and they authenticate under their own AAD label, so a record and
  a cached answer can never be opened as one another. `checkId` and `billing` are kept, unlike in a
  cache entry, because the record *is* that one call and those are what a dispute is reconciled
  against; report narratives are dropped, because nothing on a transaction detail shows them and a
  90-day archive of other people's accounts of being defrauded is not something to keep on a phone.

  This is also the supported way to build that screen at all. The partner terms forbid uploading
  Tracive results to your own servers, derived values included; local storage on the user's device is
  where they may live. What may go to your server is the user's decision — `riskAccepted`,
  `riskAcceptedAt` — which is the audit trail you can defend and contains no result.

### Changed
- **Report dates now carry month precision only.** The Tracive API sends `firstReportOn` and
  `lastReportOn` as the 15th of the month at 12:00 UTC, and `Chronology.incidentDate` and
  `Comment.date` as `"YYYY-MM"`. Show month and year only (e.g. "Jul 2026") — never the day, and
  nothing computed from it such as "3 days ago": an exact date could help identify the reporter. This
  is a server change, so it reaches installed apps whatever SDK version they run; the SDK's types and
  decoding are unchanged. The example now renders the month this way.

### Breaking
- **The server TTL override is gone: `CachePolicy.honorsServerTtlOverride`, both `effectiveTtl`
  overloads and `CheckResult.cacheTtlSeconds` are all removed.** The backend stopped sending
  `cacheTtlSeconds` because its per-tier ladder was a copy of the one every SDK already has
  locally; cache lifetime is the SDK's own business. So the flag gated a branch that could never be
  taken. `policy.ttl(for: tier)` is now the whole of the lifetime policy — use it where you used
  `effectiveTtl`. A `cacheTtlSeconds` still arriving from a proxy is a key the model does not have,
  and `Codable` skips it rather than failing the decode.

  Both types have memberwise initialisers, so a caller that passed either argument by name has to
  drop it.

  One behaviour goes with it: a zero `cacheTtlSeconds` used to evict a row already on the device.
  Setting that tier's TTL to `0` in your own `CachePolicy` is now the only way to reach that path.

- **`CheckCache` has three more requirements**, plus a new `CheckCacheError.invalidTransactionId`
  case. Anyone conforming their own type to `CheckCache` — a test double, or a host that swapped the
  storage — has to add `writeTransactionCheck(_:for:)`, `readTransactionCheck(for:)` and
  `removeTransactionCheck(for:)`, and any exhaustive `switch` over `CheckCacheError` gains an arm.
  There are no protocol-extension defaults on purpose: a default that silently kept nothing would
  leave a partner with a transaction-detail card that is always empty and nothing to say why.
  `SQLiteCheckCache` and `NoOpCheckCache` are unaffected, and so is every caller that only uses
  `client.cache`.

### Fixed
- **A 429 is no longer retried.** `credits()`, `profile()` and a check carrying your
  `Idempotency-Key` used to sleep for the `Retry-After` and send again, up to three times. A spent
  daily quota answers with a `Retry-After` that runs to the next UTC midnight, so one call could
  hold its caller for most of a day and still end in `.rateLimited`. A 429 now surfaces on the first
  response as `.rateLimited(retryAfter:)`, as it already did in the Kotlin and Flutter SDKs. 5xx and
  network retries are unchanged.
- **The quick start in `README.md` did not compile.** It omitted `partnerUserId`, which the OAuth
  configuration requires and gives no default, so the first thing anyone starting from the README
  met was a type error. The field is now in the snippet, and every value a partner has to supply
  carries a `TODO(partner)` marker so it travels into their code with the snippet they copied.

- **`Docs/oauth.md` showed an `LSApplicationQueriesSchemes` array without the sandbox scheme.**
  `Docs/integration.md` had it right and explained the failure; the OAuth guide did not, so a reader
  who followed that one got `false` from `canOpenURL` for a sandbox build that was installed, and
  every tester was routed to an install page for an app they were holding. No code changed — the
  probe already follows `environment` — but a wrong snippet in one of two guides is the same bug
  reaching the reader.


### Added
- **`access_denied` is not the only refusal, and now the OAuth guide says so.** The authorization
  server can end a consent with other codes, and the one it actually sends is
  `temporarily_unavailable` — for two situations that look identical to your app and are not the
  same to the user: the partner organisation has not accepted the current terms, or the device has
  reached its daily limit on new connections to your app. Neither is a refusal by *this* user, and
  both resolve on their own if the user retries later.

  This SDK has always passed the raw code through, but nothing told a partner to read it, so the
  natural handling was a generic failure or — worse — "you declined", which is the one thing it is
  not. The guide now shows how to branch, and says to branch on the **code** rather than the error
  type: the type differs between the Tracive SDKs, the code string does not. `error_description`
  carries the server's own wording, including any reset time, so show that.

  A test pins the code and the description, alongside the existing one that covers the mechanism
  with a stand-in code.

- **`normalizePhoneNumber`, so a locally-formatted number can reach `phone()`.** `phone()` takes
  E.164 and refuses `081234567891`, for a reason it states: the SDK cannot know your dial code, and a
  wrong guess still costs a credit. This supplies the missing dial code, so the strictness downstream
  stays intact rather than being loosened.

  ```
  phone(normalizePhoneNumber("IDN", "0857-1860-9079"))   // +6285718609079
  phone(normalizePhoneNumber("+62", "0857 1860 9079"))   // the same key
  ```

  The first argument is an ISO 3166-1 **alpha-3** code or a dial code with or without `+`, told apart
  by shape: letters mean alpha-3, digits mean a dial code. Alpha-2 (`ID`) is refused, because alpha-3
  is what `bankAccount()` already speaks and one code meaning two things is how a cache key stops
  matching. A country table of 245 entries comes with it.

  It is public and standalone rather than folded into `phone()`, because you need the E.164 form for
  your own records, logging and outbound messaging too.

  The rules copy the Tracive app's normalizer deliberately — Italy's leading zero is part of the
  number, Russia's trunk prefix is `8`, North America's is `1`, everywhere else it is `0` — because
  if the app folds a number one way and this SDK another, one person becomes two record keys and a
  report filed in the app is invisible to a check made here. `phone-normalization-vectors.json` pins
  that agreement, carries the country table so the enum cannot drift either, and is vendored
  byte-identically into all four SDK repositories with a hash pin in each CI.

  **Two rules deliberately do not match the app**, and they differ in kind. A leading `+` whose dial
  code contradicts the country named raises `country_conflict` rather than being concatenated —
  `("IDN", "+64857…")` would otherwise yield `+626485718609079`, a New Zealand number wearing an
  Indonesian dial code; every input this rejects produced an unusable key in the app too. And
  `+00<dial>` is refused, which the app accepts and folds correctly: `+` and `00` are alternative
  spellings of the same thing rather than stackable ones, what follows `+` must be a country code,
  and `00` is none.

### Breaking

- **`partnerUserId` is now required, and a blank one is refused.**
  `OAuthConfiguration.partnerUserId` is a non-optional `String`, and a blank one trips a
  precondition. The blank test was `!isEmpty`, which let a whitespace-only id through to a consent
  screen that rejects it. It was optional in all four SDKs, and the documentation here told you to
  omit it when your integration has no user accounts. Following that reached a consent screen that
  refuses **client-side, before any network call, and returns no redirect at all** — so your app is
  handed nothing to handle, the user sees a generic "invalid request", and no server-side log
  records that it happened. The field is what the grant is keyed on: stored as you sent it, echoed
  back in `grant.revoked` and `grant.superseded` so you can map the event to your own customer, and
  what enforces one of your accounts to one Tracive account. Send an opaque identifier — never a raw
  phone number or email.

### Fixed

- **The authorize URL pointed at a host no Tracive build claims.** Swift was already correct here;
  the fix landed in the Flutter and React Native SDKs. The Tracive app claims
  `https://tracive.id/oauth/authorize`, and `sandbox.tracive.id` for its sandbox build, as an App
  Link and a Universal Link — nothing else opens the app, so consent could not start at all. Both
  wrong spellings were pinned by their own repository's tests, so no single-repo check could have
  caught it.

- **The app-presence probe reported "not installed" on every Android device, including the ones
  holding the app.** It probed a custom-scheme URL carrying a host the app does not register, and
  Android resolves such a probe by intent-filter matching: a filter that declares a host requires
  the URI to carry a matching one. It now probes the bare scheme, which the Tracive app claims with
  a scheme-only intent-filter added for the purpose. Verified on a device — `tracivedev://` went
  from "unable to resolve Intent" to starting the app.

- **The presence probe now follows the environment.** It was hardcoded to production, so testing
  against sandbox on a device carrying only the sandbox build reported the app as absent. This SDK
  already followed it — it was the only one of the four that did.

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

- **A whitespace-only access token was not treated as damage, so `Authorization: Bearer    ` went
  on the wire.** The repair that renews a damaged grant before the first request leaves was written
  as an emptiness test, and `"   ".isEmpty` is `false`. Three spaces authenticate nobody and are
  exactly as unrepairable once sent as `Bearer ` is: the server answers `invalid_token`, which this
  SDK treats as terminal, so no refresh is attempted and the grant is discarded — while a perfectly
  live refresh token sat beside it in the store the whole time. The record never healed; it failed
  permanently, one wasted round trip at a time.

  Blankness is now the test, on the refresh token in that same guard as well as on the access token,
  which is what Kotlin has always done. The refresh token matters for a sharper reason than
  symmetry: sending `refresh_token=%20%20` earns a rejection, and a rejected refresh clears the
  stored grant and reports `.grantRevoked` — a revocation nobody performed, on a record that was
  only ever damaged locally, sending whoever answers that alert to look for a server-side event that
  never happened. It answers `.invalidToken` with `unusable_grant` and keeps the record instead.

  This is one step past the empty-token case fixed earlier, and it survived that fix because the
  rule was written as "empty" rather than as "blank".

- **The result cache was unbounded by default, and nothing else bounded it either.**
  `CachePolicy.maxEntries` defaulted to `nil`, and the two mechanisms that look like they hold the
  file down do not: lazy expiry only touches rows that are read again, and the prune pass only
  deletes rows that have already expired. A `HIGH` verdict is held for thirty days, so an app that
  checks a fresh identifier on every render accumulates a month of them — an encrypted SQLite file
  growing on a user's phone, with no error, no warning, and no further contact from this SDK.

  The default is now 5 000 rows, matching the Flutter SDK so both bound the same store at the same
  size. `SQLiteCheckCache` already honoured a non-`nil` cap on every write and in every prune, so
  nothing about the eviction itself changed: it takes the rows **closest to expiring** first,
  because those have the least value left, and it is deliberately not LRU — tracking last-read
  would mean a write on every cache hit and turn the cheap path into the expensive one.

  **This is a behaviour change for anyone relying on the old default.** A store that has grown past
  5 000 rows will evict down to it on the next write or prune, and each evicted row costs one credit
  the next time that identifier is checked. Pass `maxEntries: nil` to keep the previous behaviour.

- **Two overlapping checks of the same identifier were two requests and two charges.** The cache is
  a billing feature — a miss costs exactly what a hit costs — but the cache write is the only
  serialisation point in the check flow, and it happens after both requests have already left the
  device. So both callers read the cache, both missed, both POSTed and both were billed. A
  double-tapped button, or a list screen rendering the same identifier in two cells, doubled the
  bill silently: two correct answers came back and nothing anywhere reported that one of them had
  been paid for twice. `TraciveOAuth.refreshTokens` has had the right shape all along; this is the
  same latch in the one place where the unit is currency rather than latency.

  Concurrent checks for one identifier now share a single request, and both callers receive its
  answer. **The latch key is the record key plus the detail level plus the locale**, not the record
  key alone, and both extra components are load-bearing: a `.minimal` result handed to a caller who
  asked for `.full` carries no `topChronologies` and no `comments`, which reads as "the server
  answered in full and there is nothing on file", and `.full` results carry `tags` and `disclaimer`
  in the language that was requested. A different identifier, detail level or locale is a different
  question and goes out on its own.

  **A caller whose task is already cancelled neither joins a flight nor starts one**, matching the
  carve-out the React Native SDK makes for an explicit signal. It runs its own request exactly as
  before, so the transport still observes the cancellation; joining would park a caller that has
  been told to stop on somebody else's round trip, and starting a flight on its behalf would leave
  the next caller joining work already on its way out.

  **What changes for a caller who cancels mid-flight**: the request is no longer cancelled. An
  unstructured `Task` does not inherit the waiting task's cancellation and `Task.value` does not
  forward it, so a latched check runs to completion whoever walks away from it. That is the right
  trade rather than the convenient one — one caller's cancellation must never cancel another
  caller's check, and a POST already on the wire may already have been billed, so abandoning it
  discards an answer that was paid for while letting it finish warms the cache and makes the next
  check free. Cancelling a check was never part of this SDK's documented contract and no test
  depended on it.

- **The check latch ignored a caller's own `idempotencyKey`, so it collapsed checks the caller had
  deliberately told it apart.** The latch key was the record key, the detail level and the locale;
  the key you pass to `checkScammer` was not in it. Supplying one is an explicit statement about the
  check, and leaving it out of the latch overrode that statement in two directions.

  Two concurrent checks of one identifier carrying **different** keys are the caller saying "these
  are two billable transactions". They were collapsed into one request, sent under whichever key
  arrived first — so the second caller's transaction was one the server never saw, and only one of
  the two answers the caller asked for was billed. And a caller who **supplied** a key could join a
  flight started by one who did not, which silently costs them the retry budget: retrying a check is
  permitted only when the *caller's* key is on it, so a check that was keyed precisely in order to
  survive a 5xx or a timeout inherited the unkeyed flight's refusal to retry, with nothing to say
  why. `generatedIdempotencyKey` already stated the neighbouring rule — a key the SDK invents must
  never be derived from the query, since that would collapse two deliberate re-checks of one
  identifier into one — and the latch was doing exactly that through another door.

  **The caller's key now joins the latch key when there is one, and the key is unchanged when there
  is not.** That keeps the case the latch exists for: a double-tapped button and a list rendering
  one identifier in two cells both go through a single call site with a single set of options, so
  they still share one request and one charge, keyed or not. Only two callers who distinguished
  their transactions themselves now get two requests.

  **The key the SDK generates for an unkeyed check stays out of the latch key**, deliberately. It is
  unique per call, so including it would hand every check a latch of its own and switch the feature
  off; the generated key exists to make the SDK's own post-refresh replay collapsible server-side
  and nothing more. All four Tracive SDKs take this change together, so the latch collapses on the
  same four components everywhere.

- **A whitespace-only `idempotencyKey` counted as a key the caller had chosen.** The one helper the
  retry rule and the check latch both read tested the string for emptiness, and `"   ".isEmpty` is
  `false`. Three spaces are not a transaction id — they are an unread configuration value or an
  empty text field — but all three rules that turn on that answer acted as though a key had been
  supplied.

  It **earned a retry budget**, which is the half that costs money. The SDK repeats a failed check
  only when the caller's own key gives the server something to deduplicate the charge on, and
  `Idempotency-Key:    ` gives it nothing, so a 5xx or a timeout was retried with every attempt a
  candidate to be billed again. It also **took a latch of its own** that no ordinary unkeyed check
  could meet on, so a double-tapped button on a call site passing a blank value went out twice and
  was billed twice — the exact failure the latch was just added to prevent. And the blank went on
  the wire in place of the generated key that makes the SDK's own post-refresh replay collapsible.

  Blank now means absent, which is what Kotlin (`isNotBlank`) and Flutter have always done; this was
  the only one of the four SDKs still testing emptiness. **A key that is not blank is passed through
  byte for byte, surrounding whitespace included** — only this SDK's reading of "is there a key
  here at all" changes, because the string a caller chose is what the server deduplicates on and
  what the partner recorded against the transaction.

- **A refresh that timed out left its refresh token in the store, and the next refresh sent it
  again — which is what makes a server revoke a grant.** The refresh token rotates, and presenting
  a rotated one is the exact pattern reuse detection looks for; the server's correct response is to
  revoke the **whole grant**, not to fail the one call. The single-flight `refreshTask` did not
  cover this, and the reason is worth stating precisely: that latch answers "is a refresh running
  right now", which is the concurrent case. This one is sequential. The first attempt dies on the
  wire, the latch clears on its way out, the store still holds the old token, and whatever asks
  next picks it up and sends it. Two ordinary sequential calls were enough, and no test in this
  package pinned it.

  The SDK now records the refresh tokens it has put on the wire, and lifts the record on any answer
  that proves the token survived. **An error response issues no tokens** (RFC 6749 §5.2), so the
  token was not consumed and is spendable again — that half is what keeps the fix from being its own
  bug, since without it a single `500` would end a grant permanently. **A success that hands the
  same token back leaves it usable too**: RFC 6749 §6 does not require rotation, and permits both
  re-issuing the same refresh token and omitting `refresh_token` entirely, which means "keep the one
  you have" and is what this SDK stores. Reading any 2xx as a rotation would leave the marker on the
  exact string the store now holds, so the *next* refresh would be refused locally with
  `spent_refresh_token` and the user sent back through consent for the life of the process — a
  client-side revocation of a grant the server had just renewed. **No response at all settles
  nothing** — a socket timeout is indistinguishable from a success whose reply was lost, so the
  token is treated as spent and the caller is told to authorize again.

  That last case costs a consent, and it is the better trade rather than the more timid one: if the
  token really was consumed, the grant already needed re-authorization and this avoids a revocation
  event on top of it; if it was not, the price is one consent the user did not strictly need.
  Retrying loses outright in the first case and at best draws in the second. A connect-phase or DNS
  failure would prove the request never arrived and could safely be released — the SDK deliberately
  does not try to detect one, because `HTTPTransport` is a protocol an integrator may implement and
  matching on that error's shape would be guesswork about exactly the boundary the rule turns on.

  What settles a success is therefore the token the store ends up holding, compared with the one
  that went out — not the status. That comparison is load-bearing rather than a formality: releasing
  on any success would put a genuinely rotated-away token back into circulation, which is the hazard
  the record exists for. A 2xx whose body this SDK cannot decode keeps the record too, for the same
  reason a lost reply does: it says nothing about what became of the token.

  **Two new codes, both on `TraciveError.invalidToken`, both terminal, both answered by
  `authorize()`.** `refresh_outcome_unknown` is a refresh that got no answer; `spent_refresh_token`
  is a stored token this flow has already presented, refused locally with nothing sent. Neither
  clears the store — nothing was rejected on either path, and a record being debugged should still
  be there when someone looks. `refresh_outcome_unknown` is deliberately **not** `.network`:
  `.network` reports as `isTransient`, and a caller acting on that would retry, which is the one
  move these codes exist to prevent. **Integrators should expect the narrow case where a refresh
  round trip fails offline to surface as `.invalidToken` rather than `.network`** — it therefore no
  longer degrades to a cached verdict under `.serverFirst`, which is correct: a cached answer would
  hide a grant whose state nobody knows.

  The history holds the last eight tokens rather than only the most recent, matching the sibling
  SDKs. A single slot was tried in the Flutter SDK and could not answer for a token two rotations
  back — reachable here whenever a store's contents move backwards, from a restored device backup
  or a host app that keeps its own copy of the grant and writes it back. It is emptied wherever the
  grant is dropped, so a fresh consent starts clean.

  Kotlin, Flutter and React Native are landing the same guard; Flutter shipped it first and is the
  reference for the rule. Kotlin and React Native met the non-rotating case first, while carrying a
  token forward, and release the record on the same comparison.

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
- **The token refresh now fires on any non-terminal 401, not only on an exact `expired_token` body.**
  The old condition required the response to carry precisely `code: "expired_token"`. A bare
  `401 Unauthorized` — no body, or a `WWW-Authenticate` header and nothing else — is what CDNs, API
  gateways and misconfigured reverse proxies emit, and this SDK is explicitly designed to sit behind
  a partner gateway in phase 2. In that state it never refreshed at all: every call failed
  identically, for as long as the app ran, until something happened to call `authorize()` again. Not
  a degraded path, a permanently stuck client.

  `grant_revoked` and `invalid_token` stay terminal, for the same reason at one remove: the server is
  not saying the credential is stale, it is saying it is not a credential, so a fresh one earns
  nothing. Everything that made the old branch safe is unchanged — at most one refresh per request,
  and the replay does not consume the retry budget.

  Widening this is only safe because every check already carries an `Idempotency-Key`, generated per
  call when the caller supplies none. The refresh-then-replay path is now reached by many more
  responses than before, and each of them has to be collapsible server-side. **If the SDK did not
  attach that key unconditionally, this change would turn a rare double-charge risk into a routine
  one** — which is exactly what it did in a sibling SDK that widened the trigger first. A test now
  pins the key across the bare-401 replay specifically.

  All four Tracive SDKs are standardising on this trigger.
- **`handleCallback(url:)` now checks the URL is its own redirect, and returns `AuthResult?`.** It
  previously acted on whatever URL the host handed it. Hosts are told to route every incoming deep
  link through it, and any app on the device can open a URL at yours — so a foreign URL arriving
  mid-consent fell through to the `state` comparison, failed it, and **resumed the suspended
  `authorize()`** with `.stateMismatch`. One `open` from anywhere was enough to kill a consent in
  progress: the user would finish in the Tracive app, come back, and find the flow already given up,
  with nothing anywhere reporting that anything had gone wrong. The pending record surviving the
  mismatch — correct, and already the case — did not help, because the continuation was gone.

  `nil` now means "not this client's redirect, or no OAuth parameter on it", and in that case
  nothing is touched at all. The comparison is scheme, authority and path, case-insensitively and
  ignoring trailing slashes, and it errs towards accepting: `state` is still compared afterwards and
  is what decides whether a code may be redeemed, while a comparison that is too strict would drop a
  genuine redirect and strand a user who consented successfully.

  **Source-breaking** for every call site, mechanically so: `handle(await tracive.handleCallback(url:
  url))` becomes `if let result = await tracive.handleCallback(url: url) { handle(result) }`. Proxy
  mode is the one non-`nil` refusal — `.failed(.proxyModeNotImplemented)` — because that is a fact
  about the client's configuration rather than about the URL. This is the shape the Kotlin SDK
  already has.
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

- **The five default retry parameters are now written down and pinned.** No value changed: this SDK
  already had the set the four are standardising on — `maxAttempts` 3, `multiplier` 2.0,
  `initialBackoff` 500 ms, `jitter` 0.2, `maxBackoff` 8 s. What was missing was any recorded reason
  for any of them, in any of the four repositories, which is how they came to ship three different
  initial backoffs and two jitter ratios without a single review catching it. `RetryPolicy` now
  carries the reasoning per number, and `RetryPolicyTests` asserts each one against a literal, so a
  future divergence has to be written deliberately into a diff. The numbers are defensible starting
  points rather than tuned constants — the Tracive API is not deployed, so nothing here has been
  measured — and that is stated where they are defined.
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
