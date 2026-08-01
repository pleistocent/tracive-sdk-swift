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

### The server override wins

When a response carries `cacheTtlSeconds`, it **replaces** the tier default:

```json
{ "riskTier": "HIGH", "cacheTtlSeconds": 60 }
```

This is Tracive's fleet-wide invalidation lever. A verdict that turns out to be wrong — a
false-positive report, a number that changed hands — can be pulled back from every installed app
within a minute, without shipping a release to anyone. Honour it. `cacheTtlSeconds: 0` means "do not
reuse this at all", and is not the same as "no override".

You can turn it off (`CachePolicy(honorsServerTtlOverride: false)`), but you should not. Pinning
clients to local defaults makes a bad cached verdict un-revocable.

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

`billing` is dropped for a second reason: a cache hit costs nothing, so replaying a stored `Billing`
would report a charge that did not happen. Same for `checkId`, which identifies one specific
server-side check — and a cache hit is not one, which is why `checkId` is `nil` on a hit.

**If a future version ever caches full detail, the key must become `(query, detail, locale)`.** That
note is in the code as well, at `CheckResult.cacheableCopy()` and on the `CheckCache` protocol.

### The consequence for `detail: .full`, which you must design around

Because the key ignores `detail`, the read path ignores it too. `checkScammer(query, detail: .full)`
on `.cacheFirst` — the **default** source — hits whatever row exists for that query and returns it
as-is. If that row was stored by an earlier `.minimal` check, the caller gets `comments: nil` and
`topChronologies: nil` and no network call is made.

That `nil` is ambiguous by construction: it is identical to the shape you get when the server really
did return full detail and there were no incidents and no comments. The SDK cannot narrow it for you
without either caching full detail (which the key forbids) or adding a routing rule that the other
Tracive SDKs do not have (which would break the 1:1 surface this contract exists to protect).

So the caller must narrow it, and there are exactly two correct ways:

1. **Pass `source: .server` whenever you need full detail.** The response still refreshes the cache,
   so you lose nothing but the round trip you were always going to need.
2. **Branch on `origin` before trusting the full-detail fields.** `origin == .server` is the only
   condition under which `comments == nil` means "none on file". On `origin == .cache`, treat the
   full-detail fields as *absent*, not as *empty*, and render a summary rather than an assertion.

Getting this wrong produces a UI that tells a user "no incident reports on file" about an identifier
with four of them. That is a wrong fraud answer, and it is silent — nothing throws and nothing logs.
`ClientTests.testFullDetailRequestIsStillServedFromAMinimalCacheEntry` pins the behaviour, including
that `origin` is a reliable discriminator.

---

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
    honorsServerTtlOverride: true,   // leave this on
    maxEntries: 5_000                // nil = unbounded
  )
)
```

`maxEntries` evicts the rows **closest to expiring**, not the least recently used. LRU would mean a
write on every cache hit, which turns the cheap path into the expensive one; "dies soonest" needs no
extra bookkeeping and drops the entries whose re-fetch was imminent anyway.

`CachePolicy.disabled` turns the cache off entirely. Every check then goes to the server and is
billed — reach for it only when you have a specific reason.

---

## Operations

```swift
try client.cache.clear()                 // wipe everything (do this on sign-out)
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
