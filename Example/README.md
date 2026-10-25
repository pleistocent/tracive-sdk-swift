# TraciveExample

A one-screen SwiftUI demonstration of the Tracive SDK.

```bash
cd Example
swift build
```

CI builds this on every PR, which is the point: it is the only sample code in the repository that
cannot rot silently.

## What it shows

- Normalising a phone number to **E.164 before** building a `TraciveQuery` — the SDK rejects a
  local-format number, and this is where that has to be handled.
- The SDK's real encrypted cache in front of the check, so the same number twice returns
  `origin == .cache`.
- A verdict rendered as *advice*, not as a ruling, with `CheckResult.disclaimer` always visible.
- Provenance in the UI: a cached answer says so, and says how old it is.
- Every `TraciveError` mapped to something a user can act on — including the 402, handled by catching
  it rather than by calling `credits()` first.

## It runs entirely offline

The screen is wired to `SampleChecker` rather than to a client, so it needs neither credentials nor
a reachable host — which is what keeps it runnable on a fresh clone and in CI. It returns canned
verdicts keyed on the last digit of the number:

| Last digit | Result |
|---|---|
| `1` | `HIGH` — 23 reports, tags, linked accounts |
| `2` | `ELEVATED` |
| `3` | `CAUTION` |
| `9` | throws `insufficientCredits` (the 402 path) |
| anything else | `NONE`, `found == false` |

Check the same number twice and the second answer comes back from the cache.

## Wiring it to the real SDK

The screen depends on `ScammerChecking`, not on `TraciveClient`. Swapping in the real thing is one
type:

```swift
struct LiveChecker: ScammerChecking {
  let client: TraciveClient
  func check(_ query: TraciveQuery) async throws -> CheckResult {
    try await client.checkScammer(query)
  }
}

ScammerCheckView(checker: LiveChecker(client: tracive))
```

Use that same seam in your own app. It is what lets you unit-test what your UI does for `HIGH`, for a
402 and for a timeout — none of which you can reliably provoke against a real server, and all of which
are the cases that matter.

## Using it as your own experiment ground

Everything you have to supply, and every demo shortcut you have to take back
out, is marked `TODO(partner)`:

```bash
grep -rn "TODO(partner)" Example
```

## Running it as an app

This package stays a **library** so `swift build` can verify it on a Mac with no simulator and no
Xcode project involved. `App/` is an iOS app target that hosts the same views, so the example can
also be installed and run:

```bash
open App/TraciveSwiftExample.xcodeproj      # pick a scheme, then ⌘R
```

Or from a terminal:

```bash
xcodebuild -project App/TraciveSwiftExample.xcodeproj -scheme demo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### Three flavors, one scheme each

| Scheme | Talks to | Installs as |
|---|---|---|
| `demo` | nothing — `SampleChecker`, in-process | `id.tracive.sdk.sample.swift`, "Swift Demo" |
| `sandbox` | `https://api-sandbox.tracive.id/v1` | `….swift.sandbox`, "Swift Sandbox" |
| `production` | `https://api.tracive.id/v1` | `….swift.production`, "Tracive Swift" |

`demo` is the offline stub described above. `sandbox` and `production` are the real integration: a
`TraciveClient` for that environment behind the same screen (`LiveChecker`), with **Authorize**,
which runs the OAuth round trip through the Tracive app and back through `.onOpenURL`. Put the
client id Tracive issued you for each environment in `App/Sources/Flavor.swift`, and register that
flavor's redirect on it — they are separate registrations, and a sandbox client id is unknown to
production.

Each flavor installs as its own app. The SDK's token store and cache are not keyed by environment,
so one app rebuilt for another environment would send the old grant there and serve the old
verdicts as its answers. The demo keeps the original bundle id because that is where earlier
installs keep their cache of canned verdicts.

The per-flavor values — bundle id, display name, redirect scheme — live in `App/Flavors/*.xcconfig`,
and `Info.plist` hands the flavor and the redirect to `Flavor.swift`. The redirects are private-use
schemes (`tracive-swift-sandbox://oauth/callback`) only because this example controls no domain; a
real integration uses a Universal Link it owns — see [`../Docs/integration.md`](../Docs/integration.md).

Every flavor wears the Tracive icon with a red `SDK` ribbon so it is not mistaken for the real
Tracive app on a device that has both.

The project is generated from [`App/project.yml`](App/project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed so the repository can be opened
without installing anything. Change the spec, not the `.pbxproj`:

```bash
brew install xcodegen && cd App && xcodegen generate
```

### What the app exercises that `swift build` cannot

`ScammerCheckView()` builds its own in-memory cache with an ephemeral key, which is right for a
library CI compiles and never runs. `App/Sources/TraciveExampleApp.swift` instead passes a cache
backed by the on-disk `SQLiteCheckCache` and `KeychainCacheKeyStore`, because that pairing needs an
app sandbox and a Keychain to exist at all. Check a number, relaunch, check it again: a **Cached**
badge after a cold start is the data key surviving the process.

That same composition root is where the live flavors inject a real `TraciveClient` — the app passes
a `ScammerChecking`, so pointing this screen at a live environment is one type, not an edit to the
UI. The demo stays the stub: an example that needs credentials and a reachable host is one nobody can
run on a fresh clone.

For a real integration you also need `LSApplicationQueriesSchemes` containing `tracive` and
`tracivesandbox` (the app's `Info.plist` has both) and a Universal Link redirect URI — see
[`../Docs/integration.md`](../Docs/integration.md).
