# Caching

What the SDK stores locally, how it is protected, and how to tune it.

This is the part of the SDK with the most direct effect on both **the user's privacy** and **the
partner's bill**, so it is worth reading rather than skimming.

---

## Why there is a cache at all

A miss is billed the same as a hit. In a real app the same identifier gets checked repeatedly — the
user pastes a number, backs out, pastes it again; a list screen re-checks on scroll; the app relaunches
and re-renders the same transaction. Without a cache every one of those is a charge.

A cache hit costs **zero credits and does no network I/O**, and reports `origin == .cache` so you can
tell.

---

## What actually lands on disk

One SQLite table, at `Application Support/TraciveSDK/check-cache.sqlite3`:

| Column | Contents | Readable without the data key? |
|---|---|---|
| `key` | `SHA-256(searchQueryIndex)`, hex | yes — a digest, never the identifier |
| `payload` | AES-256-GCM sealed box of the cacheable `CheckResult` as JSON | no |
| `fetched_at` | when the server produced the data | yes |
| `expires_at` | prune hint: `fetched_at + TTL`, as of write time | yes |
| `written_at` | when this row was written | yes |

The raw phone number, email, IBAN or crypto address is **never** written to disk, in any column, in
any form. Neither is the verdict: risk tier, report counts, tags, fraud amounts and the disclaimer all
live inside the encrypted payload.

### Why the timestamps are in the clear

Pruning has to be a single indexed `DELETE`. If `expires_at` were encrypted, every prune would mean
decrypting the entire table.

What that leaks, precisely: `expires_at - fetched_at` is one of four values, so someone holding the
raw file can tell that *some* query resolved to a high-risk tier. They cannot tell **which** query —
the key is a digest — and they cannot read a single field of the verdict. That is a good trade for a
prune pass that stays O(log n) instead of O(n) decryptions.

### Application Support, not Caches

The OS may evict anything in `Caches` under disk pressure, at any moment, with no notice. Every
eviction is a re-fetch, and every re-fetch is a bill. The store prunes itself and honours
`maxEntries`, so it does not need the system to garbage-collect it. It is excluded from iCloud and
iTunes backups (the payloads would be undecryptable on another device anyway) and, on iOS, marked
`completeUntilFirstUserAuthentication` — set on the directory, so the WAL sidecars inherit it too.

---

## Encryption

### Payloads: AES-256-GCM, per row

```
sealed = AES.GCM.seal(
  json,
  using: dataKey,
  authenticating: "tracive.cache.v<schemaVersion>|<sha256-hex-of-query>"
)
```

Stored as CryptoKit's `combined` form: a fresh random **96-bit nonce** ‖ ciphertext ‖ 128-bit tag.
CryptoKit generates the nonce per call, so no counter is persisted and no nonce is ever reused under a
key — which for GCM is the single mistake that loses both confidentiality and integrity at once.

The **additional authenticated data** binds each ciphertext to the row it belongs to. That defeats a
concrete attack: someone with write access to the file copies the sealed payload from a known-clean
number onto a known scammer's row, so the app cheerfully reports the scammer as safe. The tag is
computed over the destination key, so a moved payload does not authenticate. It also makes a payload
written under an older schema version unopenable under a newer one.

### The data key: Keychain, Secure Enclave-backed where available

One Keychain item (`kSecClassGenericPassword`), tagged with a one-byte format marker:

| Marker | What is stored | When |
|---|---|---|
| `0x02` | a `SecureEnclave.P256.KeyAgreement.PrivateKey` data representation | `SecureEnclave.isAvailable` |
| `0x01` | 32 raw key bytes | Simulator, Intel Macs without a T2, anything else |

In the `0x02` case the stored blob is **not** the key. It is an opaque, device-bound wrapper only this
device's Secure Enclave can use, and the AES key is derived on demand:

```
shared  = ECDH(sk, sk.publicKey)         // computed inside the Secure Enclave
dataKey = HKDF-SHA256(shared, salt: "tracive.cache.datakey.v1", info: <service>)
```

Agreeing with our *own* public key looks strange, so to be explicit: this is not a key exchange. We
need a deterministic 256-bit secret that cannot be extracted from a stolen device image, and ECDH is
the only operation the Enclave exposes for a P-256 key-agreement key — it cannot store or derive
symmetric keys directly. `sk · (sk · G)` is stable across launches and computing it requires the
private key, which never leaves the Enclave. Someone with both the Keychain item and the database file
still cannot decrypt one row off-device.

Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:

- *AfterFirstUnlock*, not *WhenUnlocked*, so a background refresh or a share extension can still read
  the cache while the phone is locked. `WhenUnlocked` would make the cache randomly unavailable and
  every such moment is a billed re-fetch.
- *ThisDeviceOnly* so the item never travels in a backup. For the Enclave blob that would be
  pointless; for the raw-key fallback it would put the key in the same backup as the encrypted
  database, which defeats the encryption entirely.

### Why not SQLCipher

Whole-file encryption would mean a third-party C dependency, and zero dependencies is the property
this SDK is sold on.

More to the point, it would not buy much. SQLCipher protects the file from being read; it does not
protect a row from being *moved*, and it does nothing once the database is open. Per-row AEAD with the
key as additional data covers both, and it is built on a system framework Apple already ships and
maintains.

---

## Freshness

### Default TTL by tier

| Tier | TTL | Why |
|---|---|---|
| `HIGH` | 30 days | A high-risk verdict is stable. Reports accumulate; they do not evaporate. |
| `ELEVATED` | 7 days | |
| `CAUTION` | 24 hours | |
| `NONE` | 1 hour | The most volatile answer there is — today's clean number is tomorrow's scammer. |

### The tier ladder is the whole policy

`policy.ttl(for:)` is the lifetime, and nothing in a response can change it. The backend used to be
able to send a `cacheTtlSeconds` that replaced the tier default; that duplicated the table above on
the server, so it is gone. A `cacheTtlSeconds` still arriving from a proxy is a key the model does
not have, and `Codable` skips it rather than failing the decode.

Set your own numbers if you want different ones. A tier TTL of `0` means "do not keep answers of
this tier": nothing is stored, and any row already held for that query is removed.

### Read is authoritative, prune is best-effort

`read` decides staleness from the **current** policy applied to the decoded result. `expires_at` is
only an index for `prune`, computed from whatever policy was in force at write time.

That split has a direction that matters: prune may leave a stale row behind for a while, and `read`
will still refuse to serve it. It can never go the other way. It also means tightening
`CachePolicy` takes effect immediately on rows that are already stored.

### Expiry happens twice

- **Lazily, on read.** An entry that went stale while the app was backgrounded is never served, and
  the row is deleted on the spot.
- **On open.** A prune pass sweeps every expired row. Lazy expiry alone never reclaims space for a key
  that is never queried again — the number the user checked once, six months ago.

---

## What is never cached

```swift
result.cacheableCopy()   // what is actually persisted
```

Dropped: `topChronologies`, `comments`, `billing`, `checkId`.

The reason is the cache key. It is the query alone — not `(query, detail, locale)` — so a stored
`detail: .full, locale: "id"` response would later be served to a caller asking for `.minimal` in
`en`. Only the fields that are invariant across `detail` and `locale` can be stored safely.

Note what that rules out and what it does not. The projection is invariant across `detail`, but
`tags` and `disclaimer` survive it and are **localized**, so the projection is not invariant across
`locale`. That is why it is not enough to drop fields: a response that carried a `locale` must not
be stored at all, which is exactly the rule the next section describes.

`billing` is dropped for a second reason: a cache hit costs nothing, so replaying a stored `Billing`
would report a charge that did not happen. Same for `checkId`, which identifies one specific
server-side check — and a cache hit is not one, which is why `checkId` is `nil` on a hit.

**If a future version ever caches full detail, the key must become `(query, detail, locale)`.** That
note is in the code as well, at `CheckResult.cacheableCopy()` and on the `CheckCache` protocol.

### The consequence for `detail: .full`: the cache is bypassed in both directions

`detail` is the one thing outside `source` that changes cache routing, and it does so on the way in
*and* on the way out. A `.full` request never reads a row and never writes one:

| Source | `detail: .full` |
|---|---|
| `.cacheFirst` (default) | the cache read is skipped; the server is called; the response is not stored |
| `.server` | the server, as always — but the response is not stored |
| `.serverFirst` | the server; a transport failure is raised rather than falling back to a row |
| `.cache` | `TraciveError.cacheMiss`, always — and still no network call |

`.minimal` routing is untouched in every respect, and a `.minimal` response is stored exactly as
before, so the cache keeps serving everything it can legitimately serve.

**Why the read is skipped.** Serving a stored row would hand the caller `comments: nil` and
`topChronologies: nil` — byte-identical to the shape you get when the server really did return full
detail and there were no incidents and no comments. A UI that renders "no incident reports on file"
from that is telling a user an identifier with four reports is clean. That is a wrong fraud answer,
not a stale one, and it is silent: nothing throws, nothing logs, and no request leaves the device.

**Why the write is skipped, which is a different bug entirely.** `cacheableCopy()` drops the four
volatile fields but *keeps* `tags` and `disclaimer` — and the row key has no locale in it, while a
`.full` request is the only kind that sends a `locale`. Storing its projection therefore files
locale-specific text under a locale-less key, and the very next `.minimal` check — which sends no
locale at all — reads it straight back as though it were the default. `disclaimer` is the one string
this SDK requires every integrator to put on screen, so the visible result is a legal notice in a
language the user never asked for, with nothing in the payload to indicate it.

The two halves are independent. Skipping only the read would leave the write bug fully intact: the
row is poisoned on the way *in*, by the `.full` call, and collected later by a `.minimal` call that
is reading the cache entirely legitimately. Relaxing either half requires the key to become
`(query, detail, locale)` first.

An earlier version of this SDK read the cache for `.full` requests, on the grounds that the key is
frozen as the query alone and that a `detail`-dependent read would be a routing rule the sibling
SDKs did not have. The freeze argument was sound about *storage* and never reached the read path —
skipping a read stores nothing and invalidates nothing — and the symmetry argument resolved itself:
all three SDKs carry this rule. Nothing in the public surface changed to get it: no new `Source`
case, no new parameter, no signature change.

Three things to design around, since they replace the old caveat:

1. **A `.full` request is never free.** Every one is a round trip and a credit. Ask for `.minimal`
   when a risk tier is all the screen renders, and reserve `.full` for the detail view.
2. **A `.full` request does not warm the cache.** A `.full` check followed by a `.minimal` check on
   the same query costs two credits, not one. If your screen needs both, issue the `.minimal` one
   first — that one *is* stored, and it is the one a later cheap check can reuse.
3. **A `.full` request offline fails rather than degrading.** `.serverFirst` will not substitute a
   cached row. If a partial answer is better than none on your screen, catch the error and re-issue
   the check at `.minimal` — that decision belongs to the caller, because only the caller knows
   whether the UI can honestly say "detail unavailable".

`ClientTests.testFullDetailRequestBypassesTheCacheReadAndAsksTheServer`,
`testAFullDetailAnswerIsNeverWrittenToTheCache`,
`testCacheOnlySourceRefusesAFullDetailRequestWithACacheMiss` and
`testServerFirstDoesNotFallBackToACachedRowForFullDetail` pin all four branches and both
directions.

---

## Recording what a transaction was shown

`read(query)` answers "what does Tracive say about this account **now**". A transaction-detail screen
asks something else: "what was this user shown **before they sent the money**". Those two answers
diverge, and the cache cannot give you the second one — it holds the latest answer per identifier and
expires it as soon as it stops being trustworthy, so by the next morning a `.none` result is gone and
the card on yesterday's transfer would be blank.

So record it against your own transaction id:

```swift
// 1. On the confirmation screen, before the PIN.
let result = try await client.checkScammer(query)
show(result)                                   // tier, counts, and result.disclaimer

// 2. Once the transfer exists and has a reference number.
try client.cache.writeTransactionCheck(result, for: "TRF26090814320771")

// 3. Weeks later, on the transaction detail.
if let shown = try client.cache.readTransactionCheck(for: "TRF26090814320771") {
  renderSecurityCheckCard(shown)               // never "no reports found" when it is nil
}
```

It is a separate call rather than a parameter on `checkScammer` because of the order those two things
happen in: the check runs on the confirmation screen, and the reference number is minted after the
PIN. There is no transaction id to pass when the check is made.

**Each record is a snapshot, not a pointer into the cache.** That is the whole design decision, and
it is what makes the card truthful. A user transfers to the same account in September, when it is
clean, and again in October, after it has been reported. A pointer would rewrite September's card to
show October's verdict — an audit trail saying the user was warned before a transfer where they were
shown nothing of the kind. Two records, two answers, neither one editing the other.

**One check can serve several transactions.** The second transfer to an account you already checked
is a cache hit: no request, no credit, and `writeTransactionCheck` called a second time with that
transfer's id. Both details get a card, and the second one's `origin` is `.cache`, which is how your
UI knows that transfer spent nothing.

| | `write` / `read` | `writeTransactionCheck` / `readTransactionCheck` |
|---|---|---|
| Keyed on | the identifier | your transaction id, hashed, under a `txn:` prefix |
| Lifetime | tier TTL, 1 hour to 30 days | `transactionCheckRetention`, 90 days by default |
| Overwritten by a later check | yes | no |
| `origin` on read | restamped `.cache` | kept as recorded |
| `checkId`, `billing` | dropped | kept — this record *is* that one call |
| `topChronologies`, `comments` | dropped | dropped |

Both kinds of row live in the one `check_cache` table. `:` is not a hex digit, so a `txn:`-prefixed
key cannot collide with a 64-hex cache key, and the two authenticate under different AAD labels
(`tracive.cache.v1|…` and `tracive.record.v1|…`) so neither can be opened as the other. A plaintext
`kind` column would have been the obvious alternative and is exactly what this schema avoids: it
would sort a stolen file into "answers held" and "transfers made" before anyone decrypted a byte.

Four things to know before you build a screen on it:

- **`nil` means "no check is on file", never "nothing was found".** A transfer where the user chose
  to skip the check has no record, and rendering that as a clean result invents a reassurance nobody
  gave. Show nothing.
- **The id is hashed, and it is matched verbatim** apart from a trim. `TRF-1` and `trf-1` are two
  records; normalise your own reference before it gets here if its case can vary. A blank id throws
  `CheckCacheError.invalidTransactionId` rather than filing every unlabelled transfer under one row.
- **`clear()` takes the records with it**, so a Tracive sign-out empties the cards on transactions
  that are still in your history. That follows from whose data it is: the verdict was read under a
  grant that no longer exists.
- **Records are counted by `maxEntries`** and, with the defaults, evicted last: eviction drops
  whatever is closest to expiring, and 90 days outlives every tier TTL. That ordering is a consequence
  of the numbers, not a rule — raise a tier TTL above `transactionCheckRetention`, or lower the
  retention below one, and records start going first. If you record more transactions than
  `maxEntries`, raise it: an evicted cache entry costs a credit to replace and an evicted record
  cannot be replaced at all.

And the reason this lives in the SDK rather than in your backend: the partner terms forbid uploading
Tracive results, derived values included — a risk tier and a report count are as much our database as
the rows behind them. Local storage on the user's own device is the permitted place for them, which
is exactly what these rows are. What may go to your server is the user's *decision*: `riskAccepted`,
`riskAcceptedAt`. That is the audit trail you can defend, and it contains no result at all.

## Configuration

```swift
let client = TraciveClient(
  mode: .oauth(...),
  cachePolicy: CachePolicy(
    isEnabled: true,
    highTtl: 30 * 24 * 60 * 60,
    elevatedTtl: 7 * 24 * 60 * 60,
    cautionTtl: 24 * 60 * 60,
    noneTtl: 60 * 60,
    maxEntries: 5_000                // the default; nil = unbounded
  )
)
```

`maxEntries` evicts the rows **closest to expiring**, not the least recently used. LRU would mean a
write on every cache hit, which turns the cheap path into the expensive one; "dies soonest" needs no
extra bookkeeping and drops the entries whose re-fetch was imminent anyway.

**It defaults to 5 000 rather than to unbounded**, matching the Flutter SDK. Neither of the two
mechanisms that would otherwise hold the file down actually bounds it: lazy expiry only touches rows
that are read again, and the prune pass only deletes rows that have already expired. A `HIGH`
verdict lives for thirty days, so a screen that checks a fresh identifier on every render
accumulates a month of them, on a phone, with nothing to stop it and nothing to report it. Passing
`nil` restores the old behaviour if you genuinely want it.

`CachePolicy.disabled` turns the cache off entirely. Every check then goes to the server and is
billed — reach for it only when you have a specific reason.

---

## Operations

```swift
try client.cache.clear()                 // wipe everything (signOut() already does this)
try client.cache.remove(query)           // drop one entry
try client.cache.prune()                 // sweep expired rows now
let stored = try client.cache.count()    // diagnostics
```

### Invalidating everything on upgrade

```swift
public static let schemaVersion = 1      // SQLiteCheckCache
```

Bump it and the table is dropped and recreated on the next launch. Nothing migrates, deliberately: a
cold cache costs credits, but a mis-decoded one costs correctness in a fraud warning, and only one of
those is recoverable. Bump it whenever the payload shape or the encryption format changes.

**Transaction records go with the table, and that half is not disposable.** The drop is one
statement over `check_cache`, and by design there is no column that could tell the two kinds of row
apart, so a bump empties the check card on every transaction in the user's history as well — as does
a data key that is gone (a Keychain reset, a restore onto another device). A cache entry that goes
costs one credit; a record that goes cannot be recovered at all. So bump `schemaVersion` only when the
payload or the encryption genuinely changed, and do not build a flow that *depends* on a record still
being there: the card is something a transaction detail shows when it can, not the audit trail. The
audit trail is the `riskAccepted` / `riskAcceptedAt` pair on your own server.

---

## Failure behaviour

The cache is designed so that no local fault can break a check that could still be answered over the
network.

| Situation | What happens |
|---|---|
| Row will not decrypt (rotated key, restore onto another device, tampering) | the row is deleted and reported as a miss — a cold cache, not a throwing SDK |
| Keychain temporarily unavailable (locked device, entitlement problem) | the error **propagates**; rows are left alone, because a transient outage must not cost the user their whole cache |
| Disk full, file corrupt | `CheckCacheError`; treat a write failure as non-fatal and a read failure as a miss |
| `source: .cache` and nothing fresh stored | `TraciveError.cacheMiss` — never a silent empty result |
| `source: .cache` with `detail: .full` | `TraciveError.cacheMiss`, whatever is stored — no row can answer a full-detail request |

That last row is worth stating plainly: a cache miss is never dressed up as "no reports found". The
difference between "we checked and found nothing" and "we did not check" is the difference between a
safe transaction and a scam.

---

## Testing

```swift
final class Clock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}
let clock = Clock()

let cache = try SQLiteCheckCache.inMemory(
  policy: .default,
  keyStore: EphemeralCacheKeyStore(),
  now: { clock.now }
)

try cache.write(result, for: query)          // riskTier == .none, so a 1-hour TTL
clock.now.addTimeInterval(3600)
XCTAssertNil(try cache.read(query))          // asserted in a millisecond, not an hour
```

Two things that are not optional in tests:

- **`EphemeralCacheKeyStore`.** A test binary is unsigned; reaching the real Keychain from one either
  fails with `errSecMissingEntitlement` or prompts a human, and a test that can prompt is a test that
  hangs CI.
- **An injected clock.** It is the only way to assert the 30-day `HIGH` TTL at all, and it removes
  every sleep-shaped flake from the suite.

`Tests/TraciveSDKTests/CacheTests.swift` is the reference: TTL per tier, the server override, the
full-detail exclusion, schema invalidation, key rotation, the row-swap defence, and a byte-level scan
of the database file asserting that no identifier reached the disk.
