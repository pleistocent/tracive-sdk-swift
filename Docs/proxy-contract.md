# Proxy mode — the phase 2 contract

> **Proxy mode is not implemented.** Every call made in `TraciveMode.proxy` throws
> `TraciveError.notImplemented("Proxy mode arrives in phase 2")`. That is the specified behaviour for
> this release, not an unfinished stub.
>
> This document exists so you can design for it now: the type is already in the public surface, so
> enabling it later will not be a source-breaking change for you.

---

## What Proxy mode is

In OAuth mode the app talks to Tracive directly, carrying a user-scoped token obtained through the
Tracive app.

In Proxy mode the app talks to **your** backend, which talks to Tracive:

```
OAuth mode (phase 1)
  app ──── Bearer <user token> ────▶ api.tracive.id

Proxy mode (phase 2)
  app ──── your auth headers ────▶ your gateway ──── your Tracive credential ────▶ api.tracive.id
```

The difference is who holds the Tracive credential and who gets billed. In Proxy mode it is your
backend on both counts.

## When you would want it

- **You already authenticate your users.** Your app has a session; asking the user to also install
  Tracive and grant consent is friction you may not want to spend.
- **You want the checks billed to a partner balance**, not to individual users' credits.
- **You need server-side control**: your own rate limits, audit log, allow-list of who may check what,
  or an internal cache in front of Tracive.
- **You are in a regulated environment** where a third-party SDK talking to a third-party host from
  the handset is a compliance problem.

## When OAuth mode is the better answer

- You want the *user's* own Tracive credits spent, not yours.
- You have no backend, or no appetite for running one on the fraud-check path.
- You want the user's consent to be visible and revocable in the Tracive app, which is a real product
  property and not just a legal one.

---

## The intended surface

Already present, already compiling, already throwing:

```swift
let client = TraciveClient(
  mode: .proxy(
    baseUrl: URL(string: "https://api.yourcompany.com/tracive")!,
    authHeaders: ["Authorization": "Bearer \(yourOwnSessionToken)"]
  ),
  environment: .custom(baseUrl: URL(string: "https://api.yourcompany.com/tracive")!)
)

// Today, in phase 1:
try await client.checkScammer(query)
// throws TraciveError.notImplemented("Proxy mode arrives in phase 2")
```

`authHeaders` are forwarded verbatim and never logged — `ProxyConfiguration.description` prints
header **names** only, because the values routinely carry bearer tokens.

Note what is still absent: **there is no API-key parameter here either.** Proxy mode does not put a
Tracive credential in the app; it puts *your* credential in the app, which you can rotate and scope
yourself, and keeps the Tracive credential on your server where it belongs.

---

## What your gateway will need to implement

Enough detail to build against, subject to the same caveat as everything else here — no gateway
has been exercised against a real deployment, so treat this as the design and not as an observed
contract.

### `POST {baseUrl}/scammer-checks`

Request from the SDK:

```http
POST /tracive/scammer-checks
Authorization: <whatever you put in authHeaders>
Idempotency-Key: <always present; caller-supplied, or SDK-generated and prefixed `sdk-`>
Content-Type: application/json

{
  "creditSource": "PARTNER",
  "detail": "minimal",
  "locale": "id",
  "query": "PHONE_+6281234567891"
}
```

Your gateway:

1. authenticates the caller with **your** scheme,
2. authorises the check — is this user allowed to check this, and how often,
3. forwards to `https://api.tracive.id/v1/scammer-checks` with your Tracive credential,
4. returns the response body **unchanged**.

Point 4 matters. The SDK decodes the same `CheckResult` shape in both modes. You may add fields — the
decoder ignores unknown keys by design — but do not rename, retype or remove anything, or you will
break the SDK's model for no gain.

### `GET {baseUrl}/credits` and `GET {baseUrl}/profile`

Same pattern. `profile` in particular returns the *end user's* Tracive identity, which in Proxy mode
may be meaningless; returning a partner-level stub is reasonable, as long as the shape holds.

### Errors

Pass the upstream envelope through as-is:

```json
{ "error": { "code": "insufficient_partner_balance", "message": "…", "checkId": "chk_…" } }
```

with the upstream HTTP status. The SDK maps `error.code` to a typed `TraciveError`, and an
unrecognised code degrades to `.server` or `.unknown` still carrying the raw code — so a code you
invent for your own gateway reaches the app intact rather than crashing it. Preserve `Retry-After` on
a 429; it is what `TraciveError.rateLimited(retryAfter:)` reads. The SDK never retries a 429 itself.

### What your gateway must not do

- **Do not swallow a 402.** If the partner balance is empty the app needs to know, so it can say
  something better than "an error occurred".
- **Do not silently substitute a cached or stubbed verdict.** The SDK reports `origin` to the app, and
  a fabricated "no reports found" is indistinguishable from a real one to the user staring at a
  payment screen.
- **Do not fold or rewrite the `query` field.** The SDK has already folded it, and that same folded
  string is the local cache key. Re-folding it server-side can only introduce a mismatch.
- **Do not drop `Idempotency-Key`.** It is the only thing standing between a repeated check and a
  double charge. It is always present — the SDK generates one (prefixed `sdk-`) when the caller
  supplies none, because the SDK re-sends a check after refreshing an expired token and that replay
  must be collapsible even if you bill before authorising. Forward it verbatim.

---

## Planning for the migration now

If Proxy mode is where you are heading, three choices made today make the switch a configuration
change rather than a rewrite:

1. **Keep query construction in your own code**, not buried in a view. `TraciveQuery` is
   mode-independent; the folding never changes.
2. **Handle every `TraciveError` case already**, including `.insufficientCredits(.partnerBalance,
   _)`. The error family is identical in both modes.
3. **Do not build UI that assumes the user has a Tracive account.** In Proxy mode they will not have
   one, and `profile()` may return a partner-level stub.

The cache behaves identically in both modes: same keys, same encryption, same TTLs. A user migrating
from OAuth mode to Proxy mode keeps their cache, since the key is derived from the query and nothing
else.
