# Contributing

```sh
swift build
swift test
```

macOS only. The package targets iOS 15 / macOS 12 and leans on CryptoKit, Security and the system
libsqlite3; none of that exists on a Linux runner, so there is no Linux job to keep green.

## Read the exit code, not the output

`swift test` prints `Executed N tests, with 0 failures` **once per suite**. A 250-test run emits
eleven such lines, and every one of them says "0 failures" about its own suite while the run as a
whole can still be red. Grepping for that string is how a broken build gets reported as passing —
it has happened here.

The last line is the total, and `$?` is the answer:

```sh
swift test; echo "exit: $?"
```

Do not reach for `${PIPESTATUS[0]}` to read it through a pipe. In zsh — the default shell on macOS,
where this package is developed — that array is spelled `pipestatus` and is 1-indexed, so
`${PIPESTATUS[0]}` expands to nothing. The line prints `exit:` with an empty value after it, which
at a glance reads exactly like success. Redirect to a file and read `$?` with no pipe at all.

The swift-testing runner also announces `Test run with 0 tests in 0 suites passed`. That is not a
warning: this package's tests are XCTest, so that runner legitimately has nothing to do.

---

## What CI enforces, and why

Everything below runs on every push and pull request. None of it needs network access — the Tracive
API is not live, and a test that reached a real host could only be testing somebody else's DNS.

- **A Swift 6 toolchain is required, not preferred.** The language-mode gate passes
  `-swift-version 6`, which older toolchains reject. The job fails loudly on an old toolchain rather
  than skipping the gate, because a skipped gate reads exactly like a passing one.
- **Swift 6 language mode**, and **`-strict-concurrency=complete -warnings-as-errors`**. Data-race
  diagnostics are the point; a warning that nobody fails on is a warning nobody reads.
- **The package builds for iOS**, not only for the host. A macOS-only build will not tell you that
  an API is unavailable on the platform every integrator ships to.
- **The example app builds.** It consumes the SDK through a local path dependency, the way a
  partner consumes it, so a break in the public surface fails here before it fails for them.
- **No third-party dependencies**, in either manifest.

That last one is a design commitment, not tidiness: a partner integrating a fraud-check SDK takes on
its supply chain, and this package hands them none.

The guard asserts against `swift package dump-package` rather than `Package.resolved`, and that
detail is load-bearing. The earlier version resolved the package and then inspected the lockfile
`if [ -f ... ]` — but a dependency-free manifest produces no lockfile, so the body never ran and the
step was unconditionally green. It also assumed the v2 lockfile format and covered only the root
manifest, leaving `Example/Package.swift` — which has a real `dependencies:` array — entirely
unchecked. `dump-package` always produces output, so there is no "file missing, therefore fine"
path. A local path dependency is allowed; every other kind fails the build.

---

## The grammar fixture is not yours to edit

`Tests/TraciveSDKTests/Fixtures/query-grammar-vectors.json` is vendored **byte-identically** into
four SDK repositories, and its expected values were produced by executing the server's own key
normalizer. If your implementation disagrees with a vector, your implementation is wrong.

A grammar change starts at the Tracive API and lands in all four SDKs together, or it drifts.

---

## Foundation's defaults are not the specification

The server folds identifiers with JavaScript string semantics, so `QueryFolding.swift` reproduces
those semantics rather than Swift's. This is the part of the SDK most likely to look like it has
gratuitous hand-written character classes in it. It does not.

`trimmingCharacters(in: .whitespacesAndNewlines)`, `lowercased()`, `CharacterSet.decimalDigits` and
`String.isEmpty` all have reasonable Foundation definitions that differ from JavaScript's at the
edges — and the edges are where fraud identifiers live, because that is where a scammer puts them.
The fixture's `crossLanguageSemantics` section states the exact trim set, digit set, case mapping
and NFC scope the server uses. Follow it, and prefer a table you can diff against that section over
a platform call that is *nearly* right.

Never use `lowercased(with:)`, `uppercased(with:)` or any locale-sensitive comparison in folding
code. A Turkish locale silently changes what a key hashes to.

---

## Things that look like nits and are not

**Do not add an API key parameter anywhere, in either mode.** There is none, by design: a long-lived
secret shipped inside a mobile binary is a published secret. `OAuthTests` asserts that neither
`api_key` nor `apiKey` appears among the authorize parameter names, and `ClientTests` asserts the
same of the authorize URL's query string.

The `TraciveError.invalidApiKey` case is not a contradiction — it exists because the server can
answer `invalid_api_key`, and an error the SDK can receive still has to be representable. Mapping a
response is not sending one.

**Do not retry a check without an `Idempotency-Key`.** The SDK cannot tell whether the first attempt
was billed, so a blind retry risks charging a partner twice for one answer.

**Do not add a `domain()` query builder.** The Tracive API indexes five identifier types. A domain
key would match nothing — and a miss is still billed, so the cost of the mistake lands on the
integrator.

**Do not widen the `.serverFirst` fallback.** It degrades to the cache only when
`error.isTransient` — a network failure, 429 or 5xx. A 402 or 403 is a real answer about the
caller's account, and serving a cached verdict instead hides a billing or permission problem until
it becomes someone else's incident.

**Do not let `detail: .full` touch the cache, in either direction.** The stored projection keeps
`tags` and `disclaimer`, both localized, under a key that carries no locale — and full detail is the
only level that sends one. The gate is the safety property; the projection is not locale-proof.

**Never open a WebView**, and never add a method that would let a caller ask for one. App Links do
not fire from an embedded browser, and RFC 8252 §8.12 forbids it because the embedding app can read
the user's credentials. `AuthLauncher` has exactly one opening method for that reason.

---

## Tests

No unit test opens a socket, touches the Keychain of a real device, or launches a browser. Every
capability that reaches outside the process is a protocol; inject a fake.

When you add a test, check that it can fail. Set the value it asserts to something wrong and watch
it go red before you commit it. A test that passes against the bug it was written for is worse than
no test, because it also stops anyone else from writing a real one.

---

## The public-hygiene rule

**This repository is published.** Nothing in it — source, comments, documentation, test names, error
strings or commit messages — may name any of the following:

- an internal repository or an internal design document;
- a backend commit, source path or symbol;
- a server-side function name;
- the backend's database product, or any internal collection path;
- roadmap phase jargon in any language other than English.

Say **"the Tracive API"** or **"the server"**. Say **"record key"**. Say **"phase 1" / "phase 2"**.

The single allowed exception is the Android application id `com.pleistocent.tracive`, which the
app-presence check genuinely needs. No other application id belongs here — a non-production variant
appears nowhere in shipping code, so naming one only discloses that it exists.

There is no automated scan in this repository. That makes it your responsibility and the reviewer's,
and it makes the diff the place to catch it: read what you wrote as a stranger would, before it is
public and permanent.
