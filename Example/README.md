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

There is nothing to connect to. The Tracive Open API is not deployed, so the example is wired to
`SampleChecker`, which returns canned verdicts keyed on the last digit of the number:

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

## Running it as an app

This package is a **library** so that `swift build` can verify it on a Mac without an Xcode project
in the repository. To run it on a device or simulator:

1. Create an iOS App target in Xcode (iOS 15+).
2. **File → Add Package Dependencies… → Add Local…** and pick the repository root.
3. Add these two source files to the app target, or add this package as a second local dependency.
4. In your `App` body:

```swift
import SwiftUI
import TraciveExample

@main
struct DemoApp: App {
  var body: some Scene {
    WindowGroup { ScammerCheckView() }
  }
}
```

For a real integration you also need `LSApplicationQueriesSchemes` containing `tracive` and a
Universal Link redirect URI — see [`../Docs/integration.md`](../Docs/integration.md).
