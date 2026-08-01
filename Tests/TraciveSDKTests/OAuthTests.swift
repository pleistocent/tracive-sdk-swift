import Security
import XCTest

@testable import TraciveSDK

/// The OAuth + PKCE flow: the RFC 7636 vector, the authorize URL, the app-presence pre-check
/// and its clean install-link fallback, `state` verification, both client types, token rotation,
/// and single-flight refresh.
///
/// No network, no `UIApplication`, no browser. The launcher and the transport are both injected, so
/// the whole app-to-app flow — which normally crosses a process boundary — runs in-process.
final class OAuthTests: XCTestCase {

  // MARK: - PKCE

  func testRFC7636AppendixBVector() {
    // The canonical vector from RFC 7636 Appendix B. If this ever fails, the SDK is computing a
    // different challenge from the one the authorization server derives, and every exchange fails
    // with `invalid_grant`.
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    XCTAssertEqual(PKCE.challenge(for: verifier), expected)
  }

  func testChallengeMethodIsS256Only() {
    // `plain` makes the challenge *be* the verifier, so anyone who can read the authorize URL can
    // finish the exchange. Tracive's server rejects it and so does this SDK (step 1).
    XCTAssertEqual(PKCE.codeChallengeMethod, "S256")
  }

  func testGeneratedVerifierSatisfiesRFC7636() {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
      .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"))
      .union(CharacterSet(charactersIn: "0123456789-._~"))

    for _ in 0..<50 {
      let pkce = SystemPKCEGenerator().generate()
      XCTAssertGreaterThanOrEqual(pkce.codeVerifier.count, 43)
      XCTAssertLessThanOrEqual(pkce.codeVerifier.count, 128)
      XCTAssertTrue(
        pkce.codeVerifier.unicodeScalars.allSatisfy(unreserved.contains),
        "Verifier must use only the unreserved set."
      )
      XCTAssertEqual(pkce.codeChallenge, PKCE.challenge(for: pkce.codeVerifier))
    }
  }

  func testGeneratedMaterialIsUnique() {
    let generator = SystemPKCEGenerator()
    let samples = (0..<200).map { _ in generator.generate() }
    XCTAssertEqual(Set(samples.map(\.codeVerifier)).count, 200)
    XCTAssertEqual(Set(samples.map(\.state)).count, 200)
  }

  func testPKCEDescriptionRedactsEverything() {
    let description = String(describing: PKCE(codeVerifier: "v", codeChallenge: "c", state: "s"))
    XCTAssertFalse(description.contains("\"v\""))
    XCTAssertEqual(
      description,
      "PKCE(codeVerifier: <redacted>, codeChallenge: <redacted>, state: <redacted>)"
    )
  }

  // MARK: - Authorize URL

  func testAuthorizeURLCarriesEveryRequiredParameter() async throws {
    let oauth = makeOAuth()

    let request = try await oauth.makeAuthorizationRequest()
    let query = Self.queryItems(of: request.url)

    XCTAssertEqual(request.url.host, "tracive.id")
    XCTAssertEqual(request.url.path, "/oauth/authorize")
    XCTAssertEqual(query["response_type"], "code")
    XCTAssertEqual(query["client_id"], "test-client")
    XCTAssertEqual(query["redirect_uri"], "https://partner.example.com/tracive/callback")
    XCTAssertEqual(query["scope"], "scammer.check credits.read")
    XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertEqual(query["code_challenge"], request.codeChallenge)
    XCTAssertEqual(query["state"], request.state)
    // Required by the authorization server for the 1:1 account link, even though the frozen SDK
    // surface makes it optional.
    XCTAssertEqual(query["partner_user_id"], "partner-user-1")
  }

  func testAuthorizeURLNeverCarriesASecret() async throws {
    let oauth = makeOAuth()

    let request = try await oauth.makeAuthorizationRequest()
    let names = Set(Self.queryItems(of: request.url).keys)

    // The hard design invariant: a mobile binary holds no Tracive credential, in any mode.
    XCTAssertFalse(names.contains("client_secret"))
    XCTAssertFalse(names.contains("api_key"))
    XCTAssertFalse(names.contains("apiKey"))
    XCTAssertFalse(names.contains("x-api-key"))
    XCTAssertFalse(request.url.absoluteString.lowercased().contains("secret"))
  }

  /// `+` must be percent-encoded in the authorize URL.
  ///
  /// `URLComponents.queryItems` does not escape it — `+` is a legal query sub-delim under RFC 3986,
  /// where it means a literal plus. But a great many servers parse a query string with a
  /// form-urlencoded decoder, under which `+` means a **space**. The two readings disagree, and the
  /// SDK cannot know which one the authorization server uses. `%2B` means a literal plus under both.
  ///
  /// This is the same hazard `FormURLEncoding` exists for, ten lines further down the same file:
  /// its doc comment spells out that "`+` in a form body decodes as a space on the server". The URL
  /// builder simply did not apply the same care.
  ///
  /// `state` and `code_challenge` are base64**url** and can never contain `+`. The exposure is the
  /// partner-supplied values: a `+` in `redirect_uri` produces a consent rejection the partner
  /// cannot diagnose from the client side, because redirect-URI matching is exact; a `+` in
  /// `partner_user_id` silently breaks the 1:1 account link the parameter exists for.
  func testPlusIsPercentEncodedInTheAuthorizeURL() throws {
    let configuration = OAuthConfiguration(
      clientId: "client+one",
      redirectUri: URL(string: "https://partner.example.com/cb+path")!,
      scopes: ["scammer.check", "credits.read"],
      partnerUserId: "user+42",
      clientType: .public
    )
    let pkce = PKCE(codeVerifier: "v", codeChallenge: "chal", state: "ab+cd")

    let url = try AuthorizeURLBuilder.build(
      endpoint: URL(string: "https://tracive.id/oauth/authorize")!,
      configuration: configuration,
      pkce: pkce
    )

    // The raw wire form carries no bare `+` anywhere.
    let raw = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .percentEncodedQuery)
    XCTAssertFalse(raw.contains("+"), "a bare '+' survived into the authorize URL: \(raw)")
    XCTAssertTrue(raw.contains("%2B"))

    // …and every value still decodes back to exactly what was put in.
    let query = Self.queryItems(of: url)
    XCTAssertEqual(query["partner_user_id"], "user+42")
    XCTAssertEqual(query["client_id"], "client+one")
    XCTAssertEqual(query["redirect_uri"], "https://partner.example.com/cb+path")
    XCTAssertEqual(query["state"], "ab+cd")
    // Unaffected values must not be mangled by the escaping pass.
    XCTAssertEqual(query["scope"], "scammer.check credits.read")
    XCTAssertEqual(query["code_challenge"], "chal")
    XCTAssertEqual(query["response_type"], "code")
  }

  /// The escaping pass must not disturb a URL that contains no `+`, and in particular must leave
  /// `redirect_uri` byte-identical — the server matches it exactly, with no tolerance, so
  /// over-encoding `:` or `/` here could itself cause a consent rejection.
  func testTheAuthorizeURLIsOtherwiseUnchangedByTheEscapingPass() async throws {
    let oauth = makeOAuth()
    let request = try await oauth.makeAuthorizationRequest()

    let raw = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
      .percentEncodedQuery)
    XCTAssertTrue(
      raw.contains("redirect_uri=https%3A//partner.example.com/tracive/callback")
        || raw.contains("redirect_uri=https://partner.example.com/tracive/callback"),
      "redirect_uri was re-encoded beyond what URLComponents already does: \(raw)"
    )
    XCTAssertEqual(
      Self.queryItems(of: request.url)["redirect_uri"],
      "https://partner.example.com/tracive/callback"
    )
  }

  func testAuthorizeHostIsEnvironmentSpecific() {
    // Sandbox and production are parallel worlds: the dev app claims `sandbox.tracive.id` and the
    // store app claims `tracive.id`, so a sandbox consent can never land in a production app.
    XCTAssertEqual(
      AuthorizeURLBuilder.defaultEndpoint(for: .production).absoluteString,
      "https://tracive.id/oauth/authorize"
    )
    XCTAssertEqual(
      AuthorizeURLBuilder.defaultEndpoint(for: .sandbox).absoluteString,
      "https://sandbox.tracive.id/oauth/authorize"
    )
  }

  func testPreparingASecondRequestInvalidatesTheFirstState() async throws {
    let oauth = makeOAuth()
    let first = try await oauth.makeAuthorizationRequest()
    _ = try await oauth.makeAuthorizationRequest()

    // A callback for the abandoned attempt must no longer satisfy the state check.
    let result = await oauth.handleCallback(url: Self.callback(code: "abc", state: first.state))
    XCTAssertEqual(result?.testDescription, "failed")
    if case .failed(let error) = result {
      XCTAssertEqual(error.kind, .stateMismatch)
    }
  }

  // MARK: - App presence and the install funnel (steps 2–3)

  func testMissingAppOpensTheInstallLinkAndStopsTheFlow() async throws {
    let launcher = FakeAppLauncher(canOpenAnything: false)
    let transport = FakeHTTPTransport { _, _ in .ok(json: "{}") }
    let oauth = makeOAuth(transport: transport, launcher: launcher)

    let result = await oauth.authorize()

    XCTAssertEqual(result.testDescription, "appNotInstalled")
    XCTAssertEqual(launcher.opened.count, 1)
    // The OAuth flow never starts: no authorize URL is opened and no request is sent.
    XCTAssertFalse(launcher.opened[0].absoluteString.contains("code_challenge"))
    XCTAssertEqual(transport.callCount, 0)
    // And what it opened is the agreed install link itself, not merely something clean.
    XCTAssertEqual(
      launcher.opened[0].absoluteString,
      "https://tracive.chottu.link/install?utm_source=tracive-sdk-ios&ref=test-client"
    )
  }

  func testInstallLinkIsCleanOfEveryOAuthParameter() {
    let url = TraciveAppPresence.installURL(clientId: "test-client")
    let query = Self.queryItems(of: url)

    // Routing consent parameters through a third-party link service is forbidden. An attribution
    // tag naming the *client* is explicitly allowed; nothing about the user or the flow is.
    for forbidden in [
      "state", "code_challenge", "code_challenge_method", "code_verifier", "redirect_uri",
      "client_id", "partner_user_id", "scope", "response_type", "code",
    ] {
      XCTAssertNil(query[forbidden], "Install link must not carry \(forbidden).")
    }
    XCTAssertEqual(query["ref"], "test-client")
    XCTAssertEqual(query["utm_source"], "tracive-sdk-ios")
  }

  /// The whole link, not just its host.
  ///
  /// This previously asserted `url.host` alone, and stayed green while the builder emitted the bare
  /// host with **no path at all** — `https://tracive.chottu.link`, which is not the install page.
  /// Every user who did not have Tracive installed would have been sent somewhere that could not
  /// install it, and the one test covering the link reported success. The path is load-bearing, so
  /// it is pinned here character for character, as is the parameter set every Tracive SDK shares.
  func testInstallLinkIsTheAgreedURLIncludingItsPath() {
    XCTAssertEqual(
      TraciveAppPresence.installURL(clientId: "test-client").absoluteString,
      "https://tracive.chottu.link/install?utm_source=tracive-sdk-ios&ref=test-client"
    )

    // Both query parameters are optional; an absent client id drops `ref` and nothing else.
    for missing in [nil, ""] as [String?] {
      XCTAssertEqual(
        TraciveAppPresence.installURL(clientId: missing).absoluteString,
        "https://tracive.chottu.link/install?utm_source=tracive-sdk-ios"
      )
    }
  }

  // MARK: - A blank install-URL override

  /// The default install link, for the assertions below to be measured against.
  private static let defaultInstallLink =
    "https://tracive.chottu.link/install?utm_source=tracive-sdk-ios&ref=test-client"

  /// A blank override is refused at construction, with the shared reason token.
  ///
  /// The four Tracive SDKs converged on this rule, and this is the Swift half of it: `nil` means
  /// "no override" and takes the default, a blank override is rejected, and any non-blank value is
  /// used verbatim.
  ///
  /// Why rejecting beats passing it through. A sibling SDK measured what a blank override actually
  /// produces once it reaches the install funnel: `"?ref=…&utm_source=…"` — a schemeless string no
  /// operating system will open. It is neither the default nor the partner's link, and the only
  /// signal it ever generates arrives much later and only for a user who does *not* have the
  /// Tracive app installed, which is the rarest path in the flow and the one nobody watches.
  /// Refusing at construction fails once, in the host app's own code, on every run, in
  /// development, before an end user is anywhere near it.
  ///
  /// The reason token is asserted as a literal rather than through a constant on purpose: it is a
  /// cross-SDK contract now, so renaming the constant must fail this test instead of quietly
  /// redefining what all four SDKs report.
  ///
  /// Whitespace is the only blankness a `URL` can carry — see
  /// `testAnEmptyStringCannotEvenReachTheInitialiserAsAURL` for why.
  func testABlankInstallURLOverrideIsRejectedAtConstruction() throws {
    for blank in ["   ", "\t", "\n", " \t\n "] {
      let url = try XCTUnwrap(URL(string: blank), "\(String(reflecting: blank)) should be a URL")

      XCTAssertThrowsError(
        try TraciveOAuth(configuration: makeOAuthConfiguration(), installURL: url),
        "a whitespace-only override must not be accepted: \(String(reflecting: blank))"
      ) { error in
        XCTAssertEqual((error as? TraciveError)?.serverCode, "blank_install_url")
      }
    }
  }

  /// `nil` — and only `nil` — means "no override", and still selects the default.
  ///
  /// Absence is a real answer, and it is the answer almost every integrator gives: the parameter
  /// has a default, so a host app that never heard of it must keep working unchanged.
  func testOnlyNilInstallURLMeansNoOverride() throws {
    let oauth = try TraciveOAuth(configuration: makeOAuthConfiguration(), installURL: nil)
    XCTAssertEqual(oauth.installURL.absoluteString, Self.defaultInstallLink)
  }

  /// The trap in the parameter's type, which is why the rule can only ever catch whitespace.
  ///
  /// `URL(string: "")` is `nil`, so an empty configuration string cannot reach the initialiser as a
  /// URL at all — it arrives as a `nil` indistinguishable from passing nothing, and takes the
  /// default. Only the call site can tell those two apart. What *can* reach us is whitespace:
  /// `URL(string: "   ")` is a non-nil URL whose `absoluteString` is the percent-encoded
  /// `"%20%20%20"`, which is also why the check has to decode before it trims.
  func testAnEmptyStringCannotEvenReachTheInitialiserAsAURL() throws {
    XCTAssertNil(URL(string: ""), "An empty string cannot become a URL, so it arrives here as nil.")

    let whitespace = try XCTUnwrap(URL(string: "   "))
    XCTAssertEqual(whitespace.absoluteString, "%20%20%20")
    XCTAssertFalse(
      whitespace.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "trimming the raw absoluteString cannot see this blank — the check must decode first"
    )
  }

  /// **This is not URL validation.** Any non-blank value is kept exactly as given.
  ///
  /// Every value below is wrong in some way a partner might plausibly ship — no scheme, a scheme
  /// no phone can open, a bare word, whitespace around a real value — and every one of them must
  /// survive untouched. The rule rejects blankness and nothing else; widening it into "is this a
  /// sensible install link?" would start refusing links that work (an enterprise distribution
  /// host, a regional store, a partner's own shortener) for the sake of catching mistakes the SDK
  /// is in no position to recognise.
  ///
  /// Two of these carry more weight than the rest. The whitespace-padded pair proves the SDK
  /// neither trims nor rebuilds the value it was handed — the padding is still there afterwards.
  /// Verified capable of failing: an implementation that percent-decodes, trims and rebuilds the
  /// override turns both of them into something else and this test goes red. And
  /// `"?ref=…&utm_source=…"` is the exact string a sibling SDK measured a passed-through blank
  /// turning into; here it is a value a partner supplied deliberately, so it is non-blank, so it
  /// is kept. Rejecting *that* would be URL validation, which this is not.
  func testANonBlankOverrideIsUsedVerbatimHoweverOddItLooks() throws {
    let odd = [
      "https://install.partner.example/regional",
      "gopher://example.invalid/nope",
      "howdy",
      "https://install.partner.example/padded ",
      " howdy ",
      "?ref=partner&utm_source=partner-app",
    ]

    for candidate in odd {
      let url = try XCTUnwrap(URL(string: candidate), "\(candidate) should be a URL")
      let oauth = try TraciveOAuth(configuration: makeOAuthConfiguration(), installURL: url)

      XCTAssertEqual(oauth.installURL, url, "\(candidate) must survive verbatim")
      XCTAssertNotEqual(oauth.installURL.absoluteString, Self.defaultInstallLink)
    }
  }

  /// And a non-blank override is what the install funnel actually opens.
  ///
  /// Asserted separately from the property above because a fallback could live in either place,
  /// and one in `authorize()` would leave the property honest while the behaviour was not.
  func testTheNonBlankOverrideIsWhatTheInstallFunnelOpens() async throws {
    let override = try XCTUnwrap(URL(string: "https://install.partner.example/regional"))
    let launcher = FakeAppLauncher(canOpenAnything: false)
    let oauth = makeOAuth(launcher: launcher, installURL: override)

    let result = await oauth.authorize()

    XCTAssertEqual(result.testDescription, "appNotInstalled")
    XCTAssertEqual(launcher.opened, [override])
  }

  /// A host app that never touched this parameter cannot start failing.
  ///
  /// `TraciveClient.init` builds the OAuth driver itself and supplies no override, so it has
  /// nothing that could be blank. It stays non-throwing, and the driver it builds still carries the
  /// default install link.
  func testTraciveClientStillBuildsItsOAuthDriverWithoutThrowing() throws {
    let client = makeClient(transport: FakeHTTPTransport { _, _ in .ok(json: "{}") })

    let oauth = try XCTUnwrap(client.oauth)
    XCTAssertEqual(oauth.installURL.absoluteString, Self.defaultInstallLink)
  }

  func testPresenceProbeUsesTheEnvironmentScheme() {
    XCTAssertEqual(TraciveAppPresence.probeURL(for: .production).scheme, "tracive")
    XCTAssertEqual(TraciveAppPresence.probeURL(for: .sandbox).scheme, "tracivedev")
  }

  func testInstalledAppReceivesTheAuthorizeURL() async throws {
    let launcher = FakeAppLauncher(canOpenAnything: true)
    let oauth = makeOAuth(launcher: launcher)

    let flow = Task { await oauth.authorize() }
    let launched = await waitUntil { launcher.opened.count == 1 }
    XCTAssertTrue(launched)

    let authorizeURL = launcher.opened[0]
    XCTAssertEqual(authorizeURL.host, "tracive.id")
    XCTAssertNotNil(Self.queryItems(of: authorizeURL)["code_challenge"])

    await oauth.cancelPendingAuthorization()
    _ = await flow.value
  }

  func testASecondAuthorizeReleasesTheFirstInsteadOfLeavingItSuspended() async throws {
    // `authorize()` suspends until a callback arrives, and only one `state` can be outstanding —
    // preparing a second attempt invalidates the first, so the first attempt's callback can never
    // satisfy the state check again. If the superseded caller were not resumed, its `await` would
    // never return: a permanent, silent hang on a partner's "Connect Tracive" button, with no error
    // to log. This asserts the release, and fails (rather than hanging) if it regresses.
    let launcher = FakeAppLauncher(canOpenAnything: true)
    let oauth = makeOAuth(launcher: launcher)

    // Neither attempt is ever awaited directly: a regression here means a task that never finishes,
    // and awaiting one of those would hang the suite instead of failing it.
    let firstOutcome = TestResultBox<AuthResult>()
    Task { firstOutcome.set(await oauth.authorize()) }
    let firstLaunched = await waitUntil { launcher.opened.count == 1 }
    XCTAssertTrue(firstLaunched, "The first attempt never opened an authorize URL.")

    let secondOutcome = TestResultBox<AuthResult>()
    Task { secondOutcome.set(await oauth.authorize()) }
    let secondLaunched = await waitUntil { launcher.opened.count == 2 }
    XCTAssertTrue(secondLaunched, "The second attempt never opened an authorize URL.")

    guard let firstResult = await firstOutcome.settled() else {
      return XCTFail("A superseded authorize() must be resumed, not left suspended forever.")
    }
    guard case .failed(let error) = firstResult else {
      return XCTFail("Expected the superseded attempt to fail, got \(firstResult).")
    }
    // Not `.denied`: the user refused nothing, the partner app restarted the flow.
    XCTAssertEqual(error.serverCode, "authorization_superseded")

    await oauth.cancelPendingAuthorization()
    guard let secondResult = await secondOutcome.settled() else {
      return XCTFail("cancelPendingAuthorization() must release the waiting attempt.")
    }
    guard case .failed(let cancelled) = secondResult else {
      return XCTFail("Expected the cancelled attempt to fail, got \(secondResult).")
    }
    XCTAssertEqual(cancelled.serverCode, "authorization_cancelled")
  }

  // MARK: - Callback handling (step 5)

  func testStateMismatchFailsTheFlow() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport)
    _ = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(
      url: Self.callback(code: "stolen", state: "not-our-state"))

    guard case .failed(let error) = result else {
      return XCTFail("Expected failure, got \(result).")
    }
    XCTAssertEqual(error.kind, .stateMismatch)
    // The code is never exchanged: a callback whose state is not ours is not ours to act on.
    XCTAssertEqual(transport.callCount, 0)
  }

  func testCallbackWithNoPendingAttemptIsRejected() async throws {
    let oauth = makeOAuth()

    let result = await oauth.handleCallback(url: Self.callback(code: "abc", state: "whatever"))

    guard case .failed(let error) = result else {
      return XCTFail("Expected failure, got \(result).")
    }
    XCTAssertEqual(error.kind, .stateMismatch)
  }

  func testAccessDeniedMapsToDenied() async throws {
    let oauth = makeOAuth()
    let request = try await oauth.makeAuthorizationRequest()

    let url = Self.callbackURL(["error": "access_denied", "state": request.state])
    let result = await oauth.handleCallback(url: url)

    XCTAssertEqual(result?.testDescription, "denied")
  }

  func testOtherCallbackErrorsSurfaceTheRawCode() async throws {
    let oauth = makeOAuth()
    let request = try await oauth.makeAuthorizationRequest()

    let url = Self.callbackURL([
      "error": "invalid_scope", "error_description": "unknown scope", "state": request.state,
    ])
    let result = await oauth.handleCallback(url: url)

    guard case .failed(let error) = result else {
      return XCTFail("Expected failure, got \(result).")
    }
    // An unrecognised code must reach the caller intact rather than crash or be swallowed.
    XCTAssertEqual(error.serverCode, "invalid_scope")
    XCTAssertEqual(error.info?.message, "unknown scope")
  }

  func testCallbackWithNeitherCodeNorErrorFails() async throws {
    let oauth = makeOAuth()
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callbackURL(["state": request.state]))

    guard case .failed(let error) = result else {
      return XCTFail("Expected failure, got \(result).")
    }
    XCTAssertEqual(error.serverCode, "invalid_callback")
  }

  func testCallbackIsSingleUse() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport)
    let request = try await oauth.makeAuthorizationRequest()
    let url = Self.callback(code: "abc", state: request.state)

    _ = await oauth.handleCallback(url: url)
    let replay = await oauth.handleCallback(url: url)

    guard case .failed(let error) = replay else {
      return XCTFail("A replayed callback must not authorize again.")
    }
    XCTAssertEqual(error.kind, .stateMismatch)
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 1)
  }

  // MARK: - Surviving process death

  /// The attempt must outlive the process that started it.
  ///
  /// Consent happens in *another* app. The host app is backgrounded for its whole duration and iOS
  /// is entitled to terminate it there under memory pressure — which is not an exotic condition, it
  /// is the ordinary fate of a backgrounded app on an older device. When that happens the PKCE
  /// `code_verifier` dies with the process, the Universal Link relaunches the app, the callback
  /// arrives, and there is nothing left to match `state` against or to exchange the code with. The
  /// user, who consented perfectly successfully, lands in a dead flow, and the SDK reports nothing
  /// that distinguishes it from a CSRF attempt.
  ///
  /// Two objects here, and the split is the whole point: the actor is rebuilt (a new process has a
  /// new one) while the store is the same instance throughout (the Keychain is not emptied by a
  /// termination). Anything the first actor kept only in a field is gone; anything it wrote to the
  /// store is still there.
  func testAPendingAuthorizationSurvivesTheHostAppBeingTerminated() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }

    // Launch 1: the attempt is prepared and the authorize URL is opened. Then the OS collects the
    // app while the user is still inside Tracive.
    let launcher = FakeAppLauncher(canOpenAnything: true)
    let state: String
    do {
      let beforeTermination = makeOAuth(transport: transport, tokenStore: store, launcher: launcher)
      state = try await beforeTermination.makeAuthorizationRequest().state
    }

    // Launch 2: a brand-new actor with no memory of anything, holding the same store. The redirect
    // arrives and the flow must complete exactly as if nothing had happened.
    let afterRelaunch = makeOAuth(transport: transport, tokenStore: store, launcher: launcher)
    let result = await afterRelaunch.handleCallback(
      url: Self.callback(code: "auth-code", state: state))

    guard case .authorized(let scopes) = result else {
      return XCTFail("a consent the user completed was lost to a process restart: \(result)")
    }
    XCTAssertEqual(scopes, ["scammer.check", "credits.read"])
    XCTAssertEqual(try store.load()?.accessToken, "access-2")

    // And the exchange used the verifier from launch 1, which only the store could have supplied.
    let fields = Self.formFields(transport.requests.first?.body)
    XCTAssertEqual(fields["code"], "auth-code")
    XCTAssertEqual(fields["redirect_uri"], "https://partner.example.com/tracive/callback")
    XCTAssertFalse((fields["code_verifier"] ?? "").isEmpty)
  }

  /// The recovered attempt carries the real verifier, not merely *a* verifier.
  ///
  /// Asserted against the value launch 1 was handed, because "the exchange sent something
  /// non-empty" would also pass if a relaunched process quietly generated fresh PKCE material —
  /// which the server would answer with `invalid_grant`, and which would look, from the client, like
  /// exactly the same dead flow this change exists to prevent.
  func testTheRecoveredAttemptExchangesTheOriginalVerifier() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }

    let request = try await makeOAuth(transport: transport, tokenStore: store)
      .makeAuthorizationRequest()

    let afterRelaunch = makeOAuth(transport: transport, tokenStore: store)
    _ = await afterRelaunch.handleCallback(url: Self.callback(code: "c", state: request.state))

    XCTAssertEqual(Self.formFields(transport.requests.first?.body)["code_verifier"],
      request.codeVerifier)
  }

  /// The record must be in the store *before* the OS is asked to open anything.
  ///
  /// Ordering is the entire mechanism. A record written after the launch returns is a record that
  /// does not exist during the only window in which the app can be killed — the user is in Tracive
  /// by then — so persisting late would satisfy every "is it stored?" assertion and still lose the
  /// verifier in the one case that matters. The launcher parks inside `open`, which is that window.
  func testTheAttemptIsPersistedBeforeTheAuthorizeURLIsOpened() async throws {
    let launchGate = TestGate()
    let launcher = GatedAppLauncher(openGate: launchGate)
    let store = InMemoryTokenStore()
    let oauth = makeOAuth(tokenStore: store, launcher: launcher)

    Task { _ = await oauth.authorize() }
    let parkedInOpen = await waitUntil { launcher.openCallCount == 1 }
    XCTAssertTrue(parkedInOpen, "the launcher was never asked to open the authorize URL")

    let persisted = try XCTUnwrap(
      try store.loadPending(),
      "the attempt was not in the store while the authorize URL was being opened"
    )
    let launched = try XCTUnwrap(launcher.lastOpenedURL)
    XCTAssertEqual(persisted.state, Self.queryItems(of: launched)["state"])
    XCTAssertEqual(persisted.redirectUri, "https://partner.example.com/tracive/callback")

    await launchGate.open()
    await oauth.cancelPendingAuthorization()
  }

  // MARK: - Expiry

  /// Ten minutes, and the number is not arbitrary.
  ///
  /// It is the lifetime of the authorization code itself. A verifier held past the point where the
  /// code it pairs with is dead server-side cannot complete anything — it is a live secret with
  /// nothing left to spend it on, and a wider window in which an abandoned attempt could be
  /// replayed.
  ///
  /// Every number below is an **absolute** literal, never `maxAge ± 1`. A test written against the
  /// constant it is meant to be testing passes at ten minutes, at thirty, and at a year: it looks
  /// like coverage and asserts nothing about the window. A sibling SDK's expiry test did exactly
  /// that — it advanced its clock by two hours — which is how that SDK's window was free to drift
  /// without anything going red. Verified capable of failing: setting `maxAge` to 1800 fails this
  /// test on the constant and on the 601-second case.
  func testThePendingAttemptExpiresAfterTenMinutes() {
    XCTAssertEqual(PendingAuthorization.maxAge, 600, "ten minutes — the authorization code's own life")

    let started = Date(timeIntervalSince1970: 1_760_000_000)
    let attempt = PendingAuthorization(
      state: "s", codeVerifier: "v", redirectUri: "https://x.test/cb", createdAt: started)

    XCTAssertFalse(attempt.isStale(at: started))
    XCTAssertFalse(attempt.isStale(at: started.addingTimeInterval(599)))
    XCTAssertFalse(attempt.isStale(at: started.addingTimeInterval(600)), "the boundary is inclusive")
    XCTAssertTrue(attempt.isStale(at: started.addingTimeInterval(601)))
  }

  /// `TraciveTokens.isExpired(at:)` reports the stored deadline and nothing more.
  ///
  /// The method survives as a read of the data; what it no longer offers is a leeway parameter. A
  /// leeway is only meaningful to something that acts *before* the deadline, and this SDK never
  /// does — it sends the token and refreshes on the server's `401 expired_token`. The knob
  /// advertised a pre-emptive refresh that no code path here has ever performed.
  ///
  /// Verified capable of failing: flipping the comparison to `>` reddens the boundary case.
  func testIsExpiredReadsTheStoredDeadlineWithNoLeeway() {
    let issued = Date(timeIntervalSince1970: 1_760_000_000)
    let tokens = TraciveTokens(accessToken: "a", expiresAt: issued.addingTimeInterval(3600))

    XCTAssertFalse(tokens.isExpired(at: issued))
    XCTAssertFalse(tokens.isExpired(at: issued.addingTimeInterval(3599)))
    XCTAssertTrue(
      tokens.isExpired(at: issued.addingTimeInterval(3600)),
      "the deadline itself counts as expired"
    )
    XCTAssertTrue(tokens.isExpired(at: issued.addingTimeInterval(3601)))

    // A grant issued without an `expires_in` is not *known* to be expired, so it reads as live and
    // the 401 remains the thing that settles it.
    XCTAssertFalse(TraciveTokens(accessToken: "a").isExpired(at: issued))
  }

  /// A forged redirect arriving after the window reports the mismatch, and leaves the record alone.
  ///
  /// This is the ordering test. `state` is compared before expiry, so waiting out the window buys
  /// an attacker nothing: the answer is the same one a forgery gets at any age, and the attempt the
  /// user may still be in the middle of survives. Under the old order this returned
  /// `authorization_expired` *and* cleared the record — the same denial of service the mismatch
  /// branch refuses, reached by being patient about it.
  func testAForgedRedirectAfterTheWindowIsStillOnlyAMismatch() async throws {
    let clock = RecordingClock()
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, clock: clock)

    _ = try await oauth.makeAuthorizationRequest()
    clock.advance(by: 601)

    let result = await oauth.handleCallback(url: Self.callback(code: "abc", state: "not-the-state"))

    guard case .failed(let error) = result else {
      return XCTFail("Expected a forged redirect to fail, got \(String(describing: result)).")
    }
    XCTAssertEqual(
      error.kind, .stateMismatch,
      "a forgery must learn nothing about the age of the record it did not match")
    XCTAssertEqual(transport.callCount, 0)
    XCTAssertNotNil(
      try store.loadPending(),
      "and must not be able to cancel the attempt by waiting the window out first")
  }

  /// A callback for an attempt older than the maximum age is refused, and the record is dropped.
  ///
  /// The clock advances by an absolute 601 seconds rather than by `maxAge + 1`, so this pins the
  /// window where it is actually enforced. Written the relative way it would pass at any window
  /// size, which is the failure mode described on `testThePendingAttemptExpiresAfterTenMinutes`.
  func testACallbackForAnExpiredAttemptIsRejectedAndTheRecordIsCleared() async throws {
    let clock = RecordingClock()
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, clock: clock)

    let request = try await oauth.makeAuthorizationRequest()
    clock.advance(by: 601)

    let result = await oauth.handleCallback(url: Self.callback(code: "abc", state: request.state))

    guard case .failed(let error) = result else {
      return XCTFail("Expected an expired attempt to fail, got \(result).")
    }
    // Its own code, not `.stateMismatch`: "start again" and "somebody may be attacking you" are
    // different messages and a partner should be able to tell them apart.
    XCTAssertEqual(error.serverCode, "authorization_expired")
    // The code was never exchanged — it is already dead server-side anyway.
    XCTAssertEqual(transport.callCount, 0)
    XCTAssertNil(try store.loadPending(), "an expired attempt must not stay in the store")
    XCTAssertNil(try store.load())
  }

  /// The same rule after a restart: a stale record recovered from the store is not a licence to
  /// exchange, or the expiry would only apply to processes that happened to survive.
  func testAnExpiredAttemptRecoveredFromTheStoreIsAlsoRejected() async throws {
    let clock = RecordingClock()
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }

    let request = try await makeOAuth(transport: transport, tokenStore: store, clock: clock)
      .makeAuthorizationRequest()
    clock.advance(by: 601)

    let afterRelaunch = makeOAuth(transport: transport, tokenStore: store, clock: clock)
    let result = await afterRelaunch.handleCallback(
      url: Self.callback(code: "abc", state: request.state))

    guard case .failed(let error) = result else {
      return XCTFail("Expected an expired attempt to fail, got \(result).")
    }
    XCTAssertEqual(error.serverCode, "authorization_expired")
    XCTAssertEqual(transport.callCount, 0)
    XCTAssertNil(try store.loadPending())
  }

  /// An attempt just inside the window still completes, so the expiry cannot be an off-by-one that
  /// silently kills slow-but-legitimate consents.
  ///
  /// This is the other half of the boundary, and the pair is what makes the window a window: 599
  /// must pass and 601 must fail, both as absolute numbers. A single one-sided test is satisfied by
  /// "never expires" or by "always expires" respectively.
  func testAnAttemptJustInsideTheWindowStillCompletes() async throws {
    let clock = RecordingClock()
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, clock: clock)

    let request = try await oauth.makeAuthorizationRequest()
    clock.advance(by: 599)

    let result = await oauth.handleCallback(url: Self.callback(code: "abc", state: request.state))

    XCTAssertEqual(result?.testDescription, "authorized")
  }

  // MARK: - Clearing the persisted attempt

  /// Every outcome that spends or abandons an attempt must leave the store empty.
  ///
  /// A record that outlives its own flow is a `code_verifier` sitting in the Keychain with a `state`
  /// that a later callback — replayed, or simply late — can still satisfy. Each case is driven end
  /// to end rather than by calling a clearing helper, because the defect this guards against is a
  /// branch that forgets to call one.
  func testEveryTerminalOutcomeClearsThePersistedAttempt() async throws {
    // Success.
    try await withAttempt { oauth, store, request in
      let result = await oauth.handleCallback(url: Self.callback(code: "c", state: request.state))
      XCTAssertEqual(result?.testDescription, "authorized")
      XCTAssertNil(try store.loadPending(), "an authorized attempt stayed in the store")
    }

    // The user refused consent inside Tracive.
    try await withAttempt { oauth, store, request in
      let url = Self.callbackURL(["error": "access_denied", "state": request.state])
      let result = await oauth.handleCallback(url: url)
      XCTAssertEqual(result?.testDescription, "denied")
      XCTAssertNil(try store.loadPending(), "a denied attempt stayed in the store")
    }

    // Any other server-reported error.
    try await withAttempt { oauth, store, request in
      let url = Self.callbackURL(["error": "invalid_scope", "state": request.state])
      let result = await oauth.handleCallback(url: url)
      XCTAssertEqual(result?.testDescription, "failed")
      XCTAssertNil(try store.loadPending(), "a rejected attempt stayed in the store")
    }

    // A callback carrying neither a code nor an error.
    try await withAttempt { oauth, store, request in
      let url = Self.callbackURL(["state": request.state])
      let result = await oauth.handleCallback(url: url)
      XCTAssertEqual(result?.testDescription, "failed")
      XCTAssertNil(try store.loadPending(), "a malformed callback left the attempt in the store")
    }

    // The user backed out of the partner's screen.
    try await withAttempt { oauth, store, _ in
      await oauth.cancelPendingAuthorization()
      XCTAssertNil(try store.loadPending(), "a cancelled attempt stayed in the store")
    }

    // Sign-out, which must not leave a spendable verifier on the device.
    try await withAttempt { oauth, store, _ in
      await oauth.signOut()
      XCTAssertNil(try store.loadPending(), "a verifier survived signOut()")
    }

    // The `grant_revoked` path.
    try await withAttempt { oauth, store, _ in
      await oauth.clearStoredTokens()
      XCTAssertNil(try store.loadPending(), "a verifier survived clearStoredTokens()")
    }
  }

  /// A failed exchange counts as terminal too: the code is spent as far as the server is concerned,
  /// and retrying the same callback would only produce a second `invalid_grant`.
  func testAFailedExchangeClearsThePersistedAttempt() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in
      .oauthError(status: 400, error: "invalid_grant", description: "code expired")
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callback(code: "c", state: request.state))

    XCTAssertEqual(result?.testDescription, "failed")
    XCTAssertNil(try store.loadPending())
  }

  /// A refused launch clears it as well, or the abandoned attempt's `state` would still satisfy a
  /// callback that arrived later by some other route.
  func testARefusedLaunchClearsThePersistedAttempt() async throws {
    let store = InMemoryTokenStore()
    let oauth = makeOAuth(tokenStore: store, launcher: RefusingOpenAppLauncher())

    _ = await oauth.authorize()

    XCTAssertNil(try store.loadPending())
  }

  /// And the cross-restart consequence of all of the above: a spent callback cannot be replayed by
  /// a *new* process either. Single-use has to be a property of the record, not of a field that a
  /// termination would have reset anyway.
  func testASpentCallbackCannotBeReplayedAfterARestart() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)
    let request = try await oauth.makeAuthorizationRequest()
    let url = Self.callback(code: "abc", state: request.state)

    let first = await oauth.handleCallback(url: url)
    XCTAssertEqual(first?.testDescription, "authorized")

    let afterRelaunch = makeOAuth(transport: transport, tokenStore: store)
    let replay = await afterRelaunch.handleCallback(url: url)

    guard case .failed(let error) = replay else {
      return XCTFail("A replayed callback must not authorize again, got \(replay).")
    }
    XCTAssertEqual(error.kind, .stateMismatch)
    XCTAssertEqual(transport.count(pathSuffix: "oauth/token"), 1)
  }

  /// The one outcome that must **not** clear it: a `state` mismatch.
  ///
  /// Any app on the device can hand the host app a URL. If a mismatched redirect erased the pending
  /// record, an attacker could cancel a consent the user is in the middle of for the cost of one
  /// `open` — and the user would see the flow die for no visible reason. Nothing is spent by a
  /// mismatch, so nothing needs consuming; an attempt nobody comes back to is collected by the
  /// ten-minute expiry instead. The sibling SDKs make the same exception for the same reason.
  func testAMismatchedRedirectCannotCancelTheAttemptInProgress() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)
    let request = try await oauth.makeAuthorizationRequest()

    let hostile = await oauth.handleCallback(url: Self.callback(code: "x", state: "not-our-state"))
    XCTAssertEqual(hostile?.testDescription, "failed")
    XCTAssertNotNil(try store.loadPending(), "a stray redirect cancelled the user's own flow")

    // The genuine redirect, arriving afterwards, still completes.
    let real = await oauth.handleCallback(url: Self.callback(code: "abc", state: request.state))
    XCTAssertEqual(real?.testDescription, "authorized")
    XCTAssertNil(try store.loadPending())
  }

  // MARK: - Callback URL ownership

  /// A URL that is not this client's redirect is not this client's business.
  ///
  /// Hosts are told to route *every* incoming deep link through `handleCallback(url:)`, and any app
  /// on the device can open a URL at yours. Before the ownership check, a foreign URL fell through
  /// to the `state` comparison, failed it, and **resumed the suspended `authorize()`** with
  /// `.stateMismatch` — so one `open` from anywhere killed the consent the user was in the middle
  /// of. The record survived, which is what made this so quiet: the flow was already dead and the
  /// SDK reported nothing wrong.
  ///
  /// This test is written against `authorize()` rather than against `handleCallback` alone, because
  /// the continuation is where the damage was. Asserting only the return value would have missed it.
  func testAForeignURLCannotCancelTheConsentInProgress() async throws {
    let launchGate = TestGate()
    let launcher = GatedAppLauncher(openGate: launchGate)
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, launcher: launcher)

    let authorizeOutcome = TestResultBox<AuthResult>()
    Task { authorizeOutcome.set(await oauth.authorize()) }
    let launched = await waitUntil { launcher.openCallCount == 1 }
    XCTAssertTrue(launched, "the launcher was never asked to open the authorize URL")

    // Every one of these is refused outright: a different host, a different path, and a
    // private-use scheme any app on the device could have declared.
    for foreign in [
      URL(string: "https://evil.example.com/tracive/callback?code=x&state=y")!,
      URL(string: "https://partner.example.com/some/other/path?code=x&state=y")!,
      URL(string: "partner-app://tracive/callback?code=x&state=y")!,
    ] {
      let outcome = await oauth.handleCallback(url: foreign)
      XCTAssertNil(outcome, "\(foreign) was treated as this client's redirect")
    }

    // Nothing was touched: the record is intact and `authorize()` is still waiting.
    XCTAssertNotNil(try store.loadPending(), "a foreign URL consumed the pending attempt")
    XCTAssertFalse(authorizeOutcome.isSet, "a foreign URL resumed authorize() and killed the flow")

    // And the genuine redirect still completes, through the same method.
    await launchGate.open()
    let state = try XCTUnwrap(Self.queryItems(of: try XCTUnwrap(launcher.lastOpenedURL))["state"])
    let real = await oauth.handleCallback(url: Self.callback(code: "abc", state: state))
    XCTAssertEqual(real?.testDescription, "authorized")

    guard let settled = await authorizeOutcome.settled(within: 2) else {
      return XCTFail("authorize() never returned")
    }
    XCTAssertEqual(settled.testDescription, "authorized")
    XCTAssertNotNil(try store.load(), "the grant was not stored")
  }

  /// A URL on our own redirect that carries no OAuth parameter did not come from the authorization
  /// server either — and it is the cheaper attack, because it needs no guessing beyond the redirect
  /// itself. It is left alone for the same reason.
  func testARedirectCarryingNoOAuthParameterIsLeftAlone() async throws {
    let store = InMemoryTokenStore()
    let oauth = makeOAuth(tokenStore: store)
    _ = try await oauth.makeAuthorizationRequest()

    for bare in [
      URL(string: "https://partner.example.com/tracive/callback")!,
      URL(string: "https://partner.example.com/tracive/callback?utm_source=push")!,
    ] {
      let outcome = await oauth.handleCallback(url: bare)
      XCTAssertNil(outcome, "\(bare) was treated as an authorization redirect")
    }
    XCTAssertNotNil(try store.loadPending(), "a bare deep link consumed the pending attempt")
  }

  /// The comparison must not be so strict that it drops a real redirect, which would be the worse
  /// failure: a user who consented successfully landing in a dead flow. Scheme and host are
  /// case-insensitive under RFC 3986, and a trailing slash is something a browser adds and a
  /// registration usually omits.
  func testAGenuineRedirectSurvivesCaseAndTrailingSlashDifferences() async throws {
    let variants = [
      "https://PARTNER.example.com/tracive/callback",
      "https://partner.example.com/tracive/callback/",
    ]
    for variant in variants {
      let store = InMemoryTokenStore()
      let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
      let oauth = makeOAuth(transport: transport, tokenStore: store)
      let request = try await oauth.makeAuthorizationRequest()

      var components = URLComponents(string: variant)!
      components.queryItems = [
        URLQueryItem(name: "code", value: "abc"),
        URLQueryItem(name: "state", value: request.state),
      ]
      let outcome = await oauth.handleCallback(url: components.url!)

      XCTAssertEqual(outcome?.testDescription, "authorized", "\(variant) was refused")
    }
  }

  // MARK: - The record itself

  /// It is a credential, so it redacts itself for the same reason `TraciveTokens` does: the
  /// verifier is the secret half of the exchange, and `state` is the CSRF nonce.
  func testPendingAuthorizationDescriptionRedactsTheSecrets() {
    let description = String(
      describing: PendingAuthorization(
        state: "SECRETSTATE",
        codeVerifier: "SECRETVERIFIER",
        redirectUri: "https://partner.example.com/cb",
        createdAt: Date(timeIntervalSince1970: 1_760_000_000)
      ))

    XCTAssertFalse(description.contains("SECRETSTATE"))
    XCTAssertFalse(description.contains("SECRETVERIFIER"))
    XCTAssertTrue(description.contains("<redacted>"))
    // The redirect URI is not a secret, and it is the field worth seeing in a log.
    XCTAssertTrue(description.contains("https://partner.example.com/cb"))
  }

  /// It has to survive the encoding the Keychain store puts it through, or the recovery would fail
  /// on a real device while passing against every in-memory double in this file.
  func testPendingAuthorizationSurvivesJSONRoundTripAsTheKeychainStoresIt() throws {
    let attempt = PendingAuthorization(
      state: "the-state",
      codeVerifier: "the-verifier",
      redirectUri: "https://partner.example.com/tracive/callback",
      createdAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    let decoded = try JSONDecoder().decode(
      PendingAuthorization.self, from: JSONEncoder().encode(attempt))

    XCTAssertEqual(decoded, attempt)
  }

  /// The pending record and the grant are separate Keychain items, separated by **service** rather
  /// than by a suffix on the account — the account is the caller's client id, so decorating it
  /// would let a client id ending in the suffix address another client's pending slot.
  func testThePendingRecordIsItsOwnKeychainItem() {
    let store = KeychainTokenStore(clientId: "test-client")

    let grant = store.baseQuery()
    let attempt = store.pendingQuery()

    XCTAssertNotEqual(
      grant[kSecAttrService as String] as? String,
      attempt[kSecAttrService as String] as? String,
      "the verifier would overwrite the grant"
    )
    // Same account, so two OAuth clients still keep separate attempts.
    XCTAssertEqual(attempt[kSecAttrAccount as String] as? String, "test-client")
    // …and everything else, including the macOS data-protection opt-in, is identical.
    XCTAssertEqual(Set(grant.keys), Set(attempt.keys))
  }

  /// `clear()` means everything, tokens and attempt alike. `signOut()` relies on it.
  func testClearingTheStoreErasesThePendingRecordToo() throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    try store.savePending(
      PendingAuthorization(
        state: "s", codeVerifier: "v", redirectUri: "https://x.test/cb", createdAt: Date()))

    try store.clear()

    XCTAssertNil(try store.load())
    XCTAssertNil(try store.loadPending())
  }

  /// A store written before this record existed still compiles and still works.
  ///
  /// `loadPending()` and `savePending(_:)` have default implementations that persist nothing, so a
  /// host app's own vault is not broken by a protocol requirement it has never heard of. What it
  /// gives up is precisely the recovery — the in-memory attempt still drives the ordinary flow, so
  /// nothing that used to work stops working.
  func testAStoreWithoutPendingSupportKeepsTheOrdinaryFlowWorking() async throws {
    let store = LegacyTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let request = try await oauth.makeAuthorizationRequest()
    let result = await oauth.handleCallback(url: Self.callback(code: "c", state: request.state))

    XCTAssertEqual(result?.testDescription, "authorized")
    XCTAssertNil(try store.loadPending(), "the default implementation must persist nothing")
  }

  /// Builds an attempt against a fresh in-memory store and hands both to `body`, so each terminal
  /// outcome above is exercised from the same starting point.
  private func withAttempt(
    _ body: (TraciveOAuth, InMemoryTokenStore, AuthorizationRequest) async throws -> Void
  ) async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { request, _ in
      request.url.path.hasSuffix("/oauth/token")
        ? .ok(json: Fixtures.refreshedTokenJSON) : HTTPResponse(status: 200)
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)
    let request = try await oauth.makeAuthorizationRequest()
    XCTAssertNotNil(try store.loadPending(), "nothing was persisted, so this case proves nothing")

    try await body(oauth, store, request)
  }

  // MARK: - Public client exchange (step 6)

  func testPublicClientExchangesTheCodeAndStoresTheGrant() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, clientType: .public)
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callback(code: "auth-code", state: request.state))

    guard case .authorized(let scopes) = result else {
      return XCTFail("Expected .authorized, got \(result).")
    }
    XCTAssertEqual(scopes, ["scammer.check", "credits.read"])
    XCTAssertEqual(try store.load()?.accessToken, "access-2")
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")

    let tokenRequest = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(tokenRequest.method, .post)
    XCTAssertEqual(tokenRequest.url.absoluteString, "https://api.tracive.id/v1/oauth/token")
    XCTAssertEqual(tokenRequest.header("Content-Type"), "application/x-www-form-urlencoded")

    let fields = Self.formFields(tokenRequest.body)
    XCTAssertEqual(fields["grant_type"], "authorization_code")
    XCTAssertEqual(fields["code"], "auth-code")
    XCTAssertEqual(fields["code_verifier"], request.codeVerifier)
    XCTAssertEqual(fields["client_id"], "test-client")
    XCTAssertEqual(fields["redirect_uri"], "https://partner.example.com/tracive/callback")
    // A public client has no secret to send, and nowhere safe to keep one if it did.
    XCTAssertNil(fields["client_secret"])
  }

  func testGrantedScopesMayBeNarrowerThanRequested() async throws {
    let json = #"{"access_token":"a","token_type":"Bearer","expires_in":3600,"scope":"scammer.check"}"#
    let transport = FakeHTTPTransport { _, _ in .ok(json: json) }
    let oauth = makeOAuth(transport: transport)
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callback(code: "c", state: request.state))

    guard case .authorized(let scopes) = result else {
      return XCTFail("Expected .authorized, got \(result).")
    }
    // The user consented to less than was asked for. Check before relying on a scope.
    XCTAssertEqual(scopes, ["scammer.check"])
  }

  func testTokenExpiryIsResolvedAgainstTheInjectedClock() async throws {
    let clock = RecordingClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, clock: clock)
    let request = try await oauth.makeAuthorizationRequest()

    _ = await oauth.handleCallback(url: Self.callback(code: "c", state: request.state))

    XCTAssertEqual(try store.load()?.expiresAt, clock.now.addingTimeInterval(3600))
  }

  func testExchangeFailureIsReportedAndNothingIsStored() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in
      .oauthError(status: 400, error: "invalid_grant", description: "code expired")
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callback(code: "stale", state: request.state))

    guard case .failed(let error) = result else {
      return XCTFail("Expected failure, got \(result).")
    }
    // The token endpoint speaks RFC 6749's flat error shape, not Tracive's envelope.
    XCTAssertEqual(error.serverCode, "invalid_grant")
    XCTAssertNil(try store.load())
  }

  func testStorageFailureIsNotReportedAsAuthorized() async throws {
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: FailingTokenStore())
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callback(code: "c", state: request.state))

    guard case .failed(let error) = result else {
      return XCTFail("A grant that could not be persisted must not read as .authorized.")
    }
    XCTAssertEqual(error.serverCode, "token_storage_failed")
  }

  // MARK: - Confidential client (step 6)

  func testConfidentialClientStopsAtTheCode() async throws {
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, clientType: .confidential)
    let request = try await oauth.makeAuthorizationRequest()

    let result = await oauth.handleCallback(url: Self.callback(code: "auth-code", state: request.state))

    guard case .codeReceived(let code, let verifier, let redirectUri) = result else {
      return XCTFail("Expected .codeReceived, got \(result).")
    }
    XCTAssertEqual(code, "auth-code")
    XCTAssertEqual(verifier, request.codeVerifier)
    XCTAssertEqual(redirectUri, "https://partner.example.com/tracive/callback")
    // The exchange belongs to the partner's backend, which holds the client secret.
    XCTAssertEqual(transport.callCount, 0)
    XCTAssertNil(try store.load())
  }

  func testAuthResultDescriptionRedactsTheCodeAndVerifier() {
    let description = String(
      describing: AuthResult.codeReceived(
        code: "SECRETCODE", codeVerifier: "SECRETVERIFIER", redirectUri: "https://x.test/cb"))
    XCTAssertFalse(description.contains("SECRETCODE"))
    XCTAssertFalse(description.contains("SECRETVERIFIER"))
  }

  // MARK: - Refresh and rotation

  func testRefreshRotatesTheStoredRefreshToken() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let token = try await oauth.refreshTokens(staleAccessToken: "access-1")

    XCTAssertEqual(token, "access-2")
    let fields = Self.formFields(transport.requests.first?.body)
    XCTAssertEqual(fields["grant_type"], "refresh_token")
    XCTAssertEqual(fields["refresh_token"], "refresh-1")
    XCTAssertEqual(fields["client_id"], "test-client")
    // Rotation is atomic: the dead token is gone, not sitting around to be replayed.
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
  }

  func testRefreshKeepsTheOldRefreshTokenWhenTheServerOmitsANewOne() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let json = #"{"access_token":"access-9","token_type":"Bearer","expires_in":3600}"#
    let transport = FakeHTTPTransport { _, _ in .ok(json: json) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    _ = try await oauth.refreshTokens(staleAccessToken: "access-1")

    XCTAssertEqual(try store.load()?.accessToken, "access-9")
    // RFC 6749 permits omitting it; keeping ours means the grant stays usable.
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-1")
  }

  func testRefreshShortCircuitsWhenSomebodyElseAlreadyRefreshed() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    // The caller's 401 was raised against a token that is already two rotations old.
    let token = try await oauth.refreshTokens(staleAccessToken: "access-0")

    XCTAssertEqual(token, "access-1")
    XCTAssertEqual(transport.callCount, 0)
  }

  func testConcurrentRefreshesShareOneRoundTrip() async throws {
    let gate = TestGate()
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in
      await gate.wait()
      return .ok(json: Fixtures.refreshedTokenJSON)
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let tokens = await withTaskGroup(of: String?.self) { group -> [String?] in
      for _ in 0..<8 {
        group.addTask { try? await oauth.refreshTokens(staleAccessToken: "access-1") }
      }
      _ = await waitUntil { transport.callCount >= 1 }
      await gate.open()

      var collected: [String?] = []
      for await token in group { collected.append(token) }
      return collected
    }

    XCTAssertEqual(tokens.compactMap { $0 }.count, 8)
    XCTAssertTrue(tokens.allSatisfy { $0 == "access-2" })
    // One rotation, not eight. Eight would trip reuse detection and revoke the grant.
    XCTAssertEqual(transport.callCount, 1)
  }

  func testRejectedRefreshClearsTheGrant() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in
      .oauthError(status: 400, error: "invalid_grant", description: "refresh token reused")
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await oauth.refreshTokens(staleAccessToken: "access-1") }

    XCTAssertEqual(error?.kind, .grantRevoked)
    XCTAssertNil(try store.load())
  }

  func testServerErrorDuringRefreshKeepsTheGrant() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in .error(status: 503, code: nil) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await oauth.refreshTokens(staleAccessToken: "access-1") }

    XCTAssertEqual(error?.kind, .server)
    // A transient outage must not log the user out.
    XCTAssertNotNil(try store.load())
  }

  func testRefreshWithoutARefreshTokenClearsTheGrant() async throws {
    let store = InMemoryTokenStore(tokens: TraciveTokens(accessToken: "access-1"))
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await oauth.refreshTokens(staleAccessToken: "access-1") }

    XCTAssertEqual(error?.kind, .grantRevoked)
    XCTAssertEqual(transport.callCount, 0)
    XCTAssertNil(try store.load())
  }

  // MARK: - Sign out

  func testSignOutRevokesThenClears() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in HTTPResponse(status: 200) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    await oauth.signOut()

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url.absoluteString, "https://api.tracive.id/v1/oauth/revoke")
    let fields = Self.formFields(request.body)
    XCTAssertEqual(fields["token"], "refresh-1")
    XCTAssertEqual(fields["token_type_hint"], "refresh_token")
    XCTAssertNil(try store.load())
  }

  func testSignOutClearsEvenWhenRevokeFails() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in throw URLError(.notConnectedToInternet) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    await oauth.signOut()

    // Revocation is best-effort. A sign-out that leaves a live token on the device because the network
    // was down is the worse of the two failures.
    XCTAssertNil(try store.load())
  }

  /// A callback that arrives while the launcher is still opening must not strand the caller.
  ///
  /// `authorize()` used to set `pending`, then **await** `appLauncher.open(...)`, and only install
  /// its continuation after that resumed. The actor is free during that suspension, so a
  /// `handleCallback(url:)` landing in the window found `pending` set, validated `state`, exchanged
  /// the code, stored the grant and called `resumePending(...)` — which returned early, because
  /// there was no continuation yet. `authorize()` then installed a continuation nobody would ever
  /// resume.
  ///
  /// The symptom is not a plain hang: the app really *is* authorized and the tokens really *are*
  /// stored, while the partner's `await` never returns and its UI sits on a spinner forever.
  ///
  /// Reachable through a custom `TraciveAppLauncher` whose `open` does async work of its own, and
  /// through a host app that drives the launch itself via the public `makeAuthorizationRequest()`
  /// and forwards the callback promptly.
  func testACallbackArrivingDuringTheLaunchStillResumesAuthorize() async throws {
    let launchGate = TestGate()
    let launcher = GatedAppLauncher(openGate: launchGate)
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store, launcher: launcher)

    let authorizeOutcome = TestResultBox<AuthResult>()
    Task { authorizeOutcome.set(await oauth.authorize()) }

    // Wait until `open` is parked mid-launch — this is precisely the window the bug lives in.
    let parkedInOpen = await waitUntil { launcher.openCallCount == 1 }
    XCTAssertTrue(parkedInOpen, "the launcher was never asked to open the authorize URL")

    // The callback beats the launcher's completion.
    let state = try XCTUnwrap(Self.queryItems(of: try XCTUnwrap(launcher.lastOpenedURL))["state"])
    let callbackResult = await oauth.handleCallback(url: Self.callback(code: "abc", state: state))
    XCTAssertEqual(callbackResult?.testDescription, "authorized")

    await launchGate.open()

    guard let result = await authorizeOutcome.settled(within: 2) else {
      return XCTFail("authorize() never returned — its continuation was lost")
    }
    XCTAssertEqual(result.testDescription, "authorized")
    XCTAssertNotNil(try store.load(), "the grant should have been stored by the callback")
  }

  /// The launch-failure path has to keep working once the continuation is installed first: a
  /// refused `open` must resume the waiting caller rather than leave it suspended.
  func testARefusedLaunchResumesAuthorizeWithALaunchFailure() async throws {
    let launcher = RefusingOpenAppLauncher()
    let oauth = makeOAuth(launcher: launcher)

    let result = await oauth.authorize()

    guard case .failed(let error) = result else {
      return XCTFail("Expected a launch failure, got \(result).")
    }
    XCTAssertEqual(error.serverCode, "app_launch_failed")

    // The attempt must also be forgotten, or its `state` would still satisfy a later callback.
    let stale = await oauth.handleCallback(url: Self.callback(code: "abc", state: "whatever"))
    if case .failed(let staleError) = stale {
      XCTAssertEqual(staleError.kind, .stateMismatch)
    } else {
      XCTFail("Expected the abandoned attempt's state to be cleared, got \(stale).")
    }
  }

  // MARK: - Keychain query shape
  //
  // These build a query dictionary and assert on it. They never call `SecItemAdd`, so the suite's
  // "no network, no Keychain" claim still holds — which is the point: the attribute under test is
  // one whose absence a real Keychain call would *not* report, because `SecItemAdd` succeeds either
  // way and only the resulting protection differs.

  func testKeychainQueryOptsMacOSIntoTheDataProtectionKeychain() {
    let query = KeychainItemQuery.base(service: "svc", account: "acct", accessGroup: nil)

    #if os(macOS)
      // Without this key the item goes to the legacy file keychain, where the
      // `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` that both stores set is ignored — so the
      // ThisDeviceOnly guarantee SECURITY.md makes would not hold on a platform the package
      // declares support for.
      XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    #else
      // iOS is always the data-protection keychain; setting the key there is meaningless.
      XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
    #endif

    XCTAssertEqual(query[kSecAttrService as String] as? String, "svc")
    XCTAssertEqual(query[kSecAttrAccount as String] as? String, "acct")
    XCTAssertNil(query[kSecAttrAccessGroup as String], "no access group was asked for")
  }

  /// The token store and the cache key store must produce identical queries for identical inputs.
  /// They did not: only the cache key store set the data-protection flag, which left the *more*
  /// sensitive item — the OAuth refresh token — as the unprotected one on macOS. Both now go
  /// through one definition, and this asserts they still do.
  func testBothKeychainStoresShareOneQueryDefinition() {
    let fromShared = KeychainItemQuery.base(service: "s", account: "a", accessGroup: "group.test")

    XCTAssertEqual(fromShared[kSecAttrAccessGroup as String] as? String, "group.test")
    XCTAssertEqual(fromShared[kSecClass as String] as? String, kSecClassGenericPassword as String)

    // Asserted against the queries the two stores *actually build* — constructing the stores does
    // no Keychain I/O, and `baseQuery()` is a pure function. If either one reintroduces its own
    // dictionary and drops an attribute, the key sets diverge and this goes red.
    let tokenStoreKeys = Set(
      KeychainTokenStore(clientId: "c", accessGroup: "group.test").baseQuery().keys)
    let cacheKeyStoreKeys = Set(
      KeychainCacheKeyStore(accessGroup: "group.test").baseQuery().keys)

    XCTAssertEqual(tokenStoreKeys, cacheKeyStoreKeys, "the two Keychain stores build different queries")
    XCTAssertEqual(tokenStoreKeys, Set(fromShared.keys))
  }

  func testSignOutWithoutAGrantSendsNothing() async throws {
    let transport = FakeHTTPTransport { _, _ in HTTPResponse(status: 200) }
    let oauth = makeOAuth(transport: transport, tokenStore: InMemoryTokenStore())

    await oauth.signOut()

    XCTAssertEqual(transport.callCount, 0)
  }

  /// A refresh that is already in flight must not write its rotated grant back after `signOut()`.
  ///
  /// The ordering that matters: `signOut()` awaits the revoke round trip, and the refresh is parked
  /// on its own token round trip. If the revoke returns first, the store is cleared and *then* the
  /// refresh resumes and saves. `refreshTask.cancel()` does not prevent this — cancellation is
  /// cooperative, a custom transport need not honour it, and a response already on the wire arrives
  /// regardless. The outcome is a live, freshly rotated refresh token sitting in the Keychain after
  /// the user was told they had signed out.
  ///
  /// Both round trips are gated so the interleaving is deterministic rather than scheduler luck.
  func testAnInFlightRefreshCannotResurrectTokensAfterSignOut() async throws {
    let refreshGate = TestGate()
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("/oauth/token") {
        // Park the refresh until sign-out has finished clearing the store.
        await refreshGate.wait()
        return .ok(json: Fixtures.refreshedTokenJSON)
      }
      return HTTPResponse(status: 200)  // the revoke, which returns immediately
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    // The box records the outcome either way, so the wait below ends as soon as the refresh
    // finishes rather than idling out a timeout on the (expected) failure path.
    let refreshOutcome = TestResultBox<String>()
    Task {
      do { refreshOutcome.set(try await oauth.refreshTokens(staleAccessToken: "access-1")) }
      catch { refreshOutcome.set("threw: \(error)") }
    }
    // Wait until the refresh is genuinely parked mid-round-trip, not merely scheduled.
    let refreshIsParked = await waitUntil { transport.count(pathSuffix: "/oauth/token") == 1 }
    XCTAssertTrue(refreshIsParked, "the refresh never reached the transport")

    await oauth.signOut()
    XCTAssertNil(try store.load(), "sign-out did not clear the store even before the race")

    // Now let the refresh finish. Its `save` lands after the clear.
    await refreshGate.open()
    _ = await refreshOutcome.settled(within: 2)

    XCTAssertNil(
      try store.load(),
      "tokens were resurrected after signOut() — a live rotated refresh token survived sign-out"
    )
    let authorized = await oauth.isAuthorized
    XCTAssertFalse(authorized, "the SDK still reports an authorized grant after signOut()")
  }

  /// The same race against `clearStoredTokens()`, which `TraciveClient` calls when the server
  /// answers a check with 401 `grant_revoked`. The grant is dead server-side at that point; a
  /// refresh completing afterwards must not put it back.
  func testAnInFlightRefreshCannotResurrectTokensAfterClearStoredTokens() async throws {
    let refreshGate = TestGate()
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in
      await refreshGate.wait()
      return .ok(json: Fixtures.refreshedTokenJSON)
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    // The box records the outcome either way, so the wait below ends as soon as the refresh
    // finishes rather than idling out a timeout on the (expected) failure path.
    let refreshOutcome = TestResultBox<String>()
    Task {
      do { refreshOutcome.set(try await oauth.refreshTokens(staleAccessToken: "access-1")) }
      catch { refreshOutcome.set("threw: \(error)") }
    }
    let refreshIsParked = await waitUntil { transport.callCount == 1 }
    XCTAssertTrue(refreshIsParked, "the refresh never reached the transport")

    await oauth.clearStoredTokens()
    XCTAssertNil(try store.load())

    await refreshGate.open()
    _ = await refreshOutcome.settled(within: 2)

    XCTAssertNil(
      try store.load(),
      "a refresh wrote the grant back after the SDK decided it was revoked"
    )
  }

  /// The code exchange is a round trip too, so it carries the same race: a `signOut()` landing
  /// while the exchange is in flight must win, rather than the exchange storing a grant afterwards.
  func testAnInFlightCodeExchangeCannotStoreAGrantAfterSignOut() async throws {
    let exchangeGate = TestGate()
    let store = InMemoryTokenStore()
    let transport = FakeHTTPTransport { request, _ in
      if request.url.path.hasSuffix("/oauth/token") {
        await exchangeGate.wait()
        return .ok(json: Fixtures.refreshedTokenJSON)
      }
      return HTTPResponse(status: 200)
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let request = try await oauth.makeAuthorizationRequest()
    let callbackOutcome = TestResultBox<AuthResult>()
    Task {
      let result = await oauth.handleCallback(
        url: Self.callback(code: "the-code", state: request.state))
      // `nil` means the SDK did not recognise its own redirect, which would be a different bug.
      // Mapped to a value the assertion below cannot mistake for the outcome it expects.
      callbackOutcome.set(result ?? .appNotInstalled)
    }
    let exchangeIsParked = await waitUntil { transport.count(pathSuffix: "/oauth/token") == 1 }
    XCTAssertTrue(exchangeIsParked, "the exchange never reached the transport")

    await oauth.signOut()

    await exchangeGate.open()
    let result = await callbackOutcome.settled(within: 2)

    XCTAssertNil(try store.load(), "the exchange stored a grant after signOut()")
    XCTAssertEqual(result?.testDescription, "failed")
    let authorized = await oauth.isAuthorized
    XCTAssertFalse(authorized)
  }

  /// The guard must not be so blunt that it breaks the ordinary case: a refresh that starts and
  /// finishes with no sign-out in between still stores its rotated pair.
  func testARefreshWithNoSignOutStillStoresItsRotatedPair() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.storedTokens)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let token = try await oauth.refreshTokens(staleAccessToken: "access-1")

    XCTAssertEqual(token, "access-2")
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
  }

  // MARK: - Access token

  func testAccessTokenRequiresAGrant() async throws {
    let oauth = makeOAuth(tokenStore: InMemoryTokenStore())

    let error = await expectTraciveError { try await oauth.accessToken() }

    XCTAssertEqual(error?.kind, .invalidToken)
    XCTAssertEqual(error?.serverCode, "no_grant")
    let authorized = await oauth.isAuthorized
    XCTAssertFalse(authorized)
  }

  /// A blank access token is a damaged record, not an absent grant — and the refresh token beside
  /// it is the part that matters, so the grant is renewed rather than thrown away.
  ///
  /// `TraciveTokens` is `Codable` over a plain `String`, so a stored `access_token` of `""` decodes
  /// as cleanly as any other value; a partial write, a Keychain save interrupted by a termination,
  /// or a restored backup can all produce one.
  func testABlankAccessTokenIsRefreshedRatherThanReturned() async throws {
    let store = InMemoryTokenStore(tokens: Fixtures.damagedTokens)
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let token = try await oauth.accessToken()

    XCTAssertEqual(token, "access-2")
    XCTAssertEqual(transport.count(pathSuffix: "/oauth/token"), 1)
    // The refresh sent the stored refresh token, which is the only credential the record had left.
    XCTAssertEqual(Self.formFields(transport.requests.first?.body)["refresh_token"], "refresh-1")
    XCTAssertEqual(try store.load()?.accessToken, "access-2")
    XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
  }

  /// With no refresh token there is nothing to renew with, so the record is terminal — and it is
  /// terminal in the way an *absent* grant is, which is what it gets to say.
  ///
  /// This answered `.grantRevoked` until now, and that was not merely inconsistent with the other
  /// SDKs: it was a false statement about the server. Nothing is sent on this path and nothing is
  /// rejected on it. One field of a local record is empty and there is no refresh token beside it
  /// to renew it from; no one revoked anything. A partner alerting on revocation — a reasonable
  /// thing to watch, because revocation is how the server's reuse detection surfaces — was paged by
  /// a damaged file on one device and sent looking for a server-side event that never happened.
  func testABlankAccessTokenWithNoRefreshTokenReportsAnInvalidToken() async throws {
    let store = InMemoryTokenStore(
      tokens: TraciveTokens(accessToken: "", refreshToken: nil, scopes: ["scammer.check"])
    )
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await oauth.accessToken() }

    XCTAssertEqual(error?.kind, .invalidToken)
    // Its own code, so a reader can tell "no record at all" from "a record with nothing usable in
    // it". The two want different things looked at: one is a user who has not authorized, the
    // other is local storage that lost half a grant.
    XCTAssertEqual(error?.serverCode, "unusable_grant")
    XCTAssertEqual(transport.callCount, 0, "there was nothing to send and nothing was sent")
  }

  /// An empty-string refresh token is as unrenewable as an absent one, and answers identically.
  ///
  /// The guard has to agree with `refreshTokens(…)`'s own, which treats `""` and `nil` alike. If it
  /// only checked for `nil`, this record would still be handed to `refreshTokens(…)` and would
  /// still come back as a revocation that never happened — the bug, surviving in the one shape
  /// nobody writes a test for.
  func testABlankAccessTokenWithAnEmptyRefreshTokenReportsAnInvalidToken() async throws {
    let store = InMemoryTokenStore(
      tokens: TraciveTokens(accessToken: "", refreshToken: "", scopes: ["scammer.check"])
    )
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let error = await expectTraciveError { try await oauth.accessToken() }

    XCTAssertEqual(error?.kind, .invalidToken)
    XCTAssertEqual(error?.serverCode, "unusable_grant")
    XCTAssertEqual(transport.callCount, 0)
  }

  /// Asking twice gives the same answer, because the first attempt does not destroy the evidence.
  ///
  /// The old path erased the record on its way out — a side effect of routing this case through
  /// `refreshTokens(…)` — so a second call reported `no_grant` and a partner debugging the first
  /// report found a store that no longer held what the report was about. Reading a damaged record
  /// is not a reason to delete it: no sibling SDK deletes it, nothing was spent that needs
  /// consuming, and the deletion threw away whatever the store still held.
  func testTheUnusableRecordSurvivesTheCallAndTheAnswerDoesNotChange() async throws {
    let store = InMemoryTokenStore(
      tokens: TraciveTokens(accessToken: "", refreshToken: nil, scopes: ["scammer.check"])
    )
    let transport = FakeHTTPTransport { _, _ in .ok(json: Fixtures.refreshedTokenJSON) }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let first = await expectTraciveError { try await oauth.accessToken() }
    let again = await expectTraciveError { try await oauth.accessToken() }

    XCTAssertEqual(first?.kind, again?.kind)
    XCTAssertEqual(first?.serverCode, again?.serverCode)
    XCTAssertEqual(again?.serverCode, "unusable_grant", "not no_grant — nothing erased the record")
    XCTAssertEqual(try store.load()?.scopes, ["scammer.check"])
    XCTAssertEqual(transport.callCount, 0)
    // `isAuthorized` consequently keeps answering `true`, where the erasing version flipped it to
    // `false` on the first read. That is the documented contract rather than a wrinkle: it reports
    // whether a grant is stored and says outright that it is not a liveness check. A record is
    // stored. Deciding whether it is any good is what `accessToken()` is for, and it now says so
    // the same way every time it is asked.
    let authorized = await oauth.isAuthorized
    XCTAssertTrue(authorized)
  }

  /// The recovery goes through the ordinary `refreshTokens(…)`, so it inherits the single-flight
  /// guarantee rather than opening a second door around it.
  ///
  /// This is the property worth pinning: two simultaneous refreshes present the same rotating
  /// token twice, which the server's reuse detection is entitled to read as a stolen-token replay
  /// and answer by revoking the whole grant. A private refresh path here would have been invisible
  /// to `refreshTask` and would have raced with every 401-driven refresh in flight.
  func testConcurrentBlankAccessTokenReadsProduceExactlyOneRefresh() async throws {
    let gate = TestGate()
    let store = InMemoryTokenStore(tokens: Fixtures.damagedTokens)
    let transport = FakeHTTPTransport { _, _ in
      await gate.wait()
      return .ok(json: Fixtures.refreshedTokenJSON)
    }
    let oauth = makeOAuth(transport: transport, tokenStore: store)

    let tokens = await withTaskGroup(of: String?.self) { group -> [String?] in
      for _ in 0..<6 {
        group.addTask { try? await oauth.accessToken() }
      }
      // Let the first caller reach the transport before releasing it, so the others really do race
      // rather than arriving after the refresh has already finished.
      _ = await waitUntil { transport.callCount >= 1 }
      await gate.open()

      var collected: [String?] = []
      for await token in group { collected.append(token) }
      return collected
    }

    XCTAssertEqual(tokens.count, 6)
    XCTAssertTrue(tokens.allSatisfy { $0 == "access-2" })
    XCTAssertEqual(transport.count(pathSuffix: "/oauth/token"), 1)
  }

  func testTokensDescriptionRedactsBothSecrets() {
    let description = String(describing: Fixtures.storedTokens)
    XCTAssertFalse(description.contains("access-1"))
    XCTAssertFalse(description.contains("refresh-1"))
    XCTAssertTrue(description.contains("<redacted>"))
  }

  func testInMemoryTokenStoreRoundTrips() throws {
    let store = InMemoryTokenStore()
    XCTAssertNil(try store.load())

    try store.save(Fixtures.storedTokens)
    XCTAssertEqual(try store.load(), Fixtures.storedTokens)

    try store.clear()
    XCTAssertNil(try store.load())
  }

  func testTokensSurviveJSONRoundTripAsTheKeychainStoresThem() throws {
    let encoded = try JSONEncoder().encode(Fixtures.storedTokens)
    let decoded = try JSONDecoder().decode(TraciveTokens.self, from: encoded)
    XCTAssertEqual(decoded, Fixtures.storedTokens)
  }

  // MARK: - Form encoding

  func testFormEncodingEscapesCharactersThatWouldCorruptAToken() {
    // `+` decodes as a space in a form body, so a base64 token containing one would arrive
    // mangled — `URLComponents.percentEncodedQuery` does not escape it and cannot be used here.
    let body = FormURLEncoding.encode([(name: "token", value: "a+b/c=d&e")])
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "token=a%2Bb%2Fc%3Dd%26e")
  }

  // MARK: - Helpers

  private static func callback(code: String, state: String) -> URL {
    callbackURL(["code": code, "state": state])
  }

  private static func callbackURL(_ parameters: [String: String]) -> URL {
    var components = URLComponents(string: "https://partner.example.com/tracive/callback")!
    components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.url!
  }

  private static func queryItems(of url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return items.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
  }

  private static func formFields(_ body: Data?) -> [String: String] {
    guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
    return text.split(separator: "&").reduce(into: [:]) { fields, pair in
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return }
      let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
      let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
      fields[name] = value
    }
  }
}

// MARK: - OAuth test doubles

/// The configuration every OAuth fixture in this file is built from.
///
/// Factored out of `makeOAuth` so the tests that drive the *initialiser's* failure can construct
/// `TraciveOAuth` directly, with the same client id the rest of the suite uses.
func makeOAuthConfiguration(
  clientType: ClientType = .public,
  scopes: [String] = ["scammer.check", "credits.read"]
) -> OAuthConfiguration {
  OAuthConfiguration(
    clientId: "test-client",
    redirectUri: URL(string: "https://partner.example.com/tracive/callback")!,
    scopes: scopes,
    partnerUserId: "partner-user-1",
    clientType: clientType
  )
}

func makeOAuth(
  transport: FakeHTTPTransport = FakeHTTPTransport { _, _ in HTTPResponse(status: 200) },
  tokenStore: (any TraciveTokenStore)? = nil,
  launcher: (any TraciveAppLauncher)? = nil,
  clock: RecordingClock = RecordingClock(),
  environment: TraciveEnvironment = .production,
  clientType: ClientType = .public,
  scopes: [String] = ["scammer.check", "credits.read"],
  installURL: URL? = nil
) -> TraciveOAuth {
  // `try!` rather than propagating: the initialiser's only failure is a blank `installURL`
  // override, and no caller of this helper passes one. Making the helper throw would put `try` on
  // forty call sites that have nothing to do with install links, and the tests that *do* exercise
  // the rejection construct the actor directly — so the throw is the subject of a test rather than
  // a crash hidden inside a fixture.
  try! TraciveOAuth(
    configuration: makeOAuthConfiguration(clientType: clientType, scopes: scopes),
    environment: environment,
    transport: transport,
    tokenStore: tokenStore ?? InMemoryTokenStore(),
    appLauncher: launcher ?? FakeAppLauncher(canOpenAnything: true),
    clock: clock,
    installURL: installURL
  )
}

/// Stands in for `UIApplication`. Records everything it was asked to open, which is how the
/// "install link instead of authorize URL" branch is verified without a device.
final class FakeAppLauncher: TraciveAppLauncher, @unchecked Sendable {

  private let canOpenAnything: Bool
  private let lock = NSLock()
  private var openedURLs: [URL] = []

  init(canOpenAnything: Bool) {
    self.canOpenAnything = canOpenAnything
  }

  func canOpen(_ url: URL) async -> Bool { canOpenAnything }

  @discardableResult
  func open(_ url: URL) async -> Bool {
    record(url)
    return true
  }

  /// Synchronous on purpose. `NSLock.lock()` is unavailable from an async context — a suspension
  /// while holding it can resume on a different thread and deadlock — which is a warning under
  /// Swift 5 and an error under the Swift 6 language mode. Keeping the critical section in a
  /// non-async helper is the fix, not silencing it.
  private func record(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    openedURLs.append(url)
  }

  var opened: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return openedURLs
  }
}

/// A launcher whose `open` parks on a gate, standing in for any `TraciveAppLauncher` that does
/// async work of its own before reporting the launch as done. `canOpen` answers immediately, so the
/// app-presence pre-check is not what is being held.
final class GatedAppLauncher: TraciveAppLauncher, @unchecked Sendable {

  private let openGate: TestGate
  private let lock = NSLock()
  private var opened: [URL] = []

  init(openGate: TestGate) {
    self.openGate = openGate
  }

  func canOpen(_ url: URL) async -> Bool { true }

  @discardableResult
  func open(_ url: URL) async -> Bool {
    record(url)
    await openGate.wait()
    return true
  }

  var openCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return opened.count
  }

  var lastOpenedURL: URL? {
    lock.lock()
    defer { lock.unlock() }
    return opened.last
  }

  private func record(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    opened.append(url)
  }
}

/// Reports the app as installed but refuses to open the authorize URL — the system declining the
/// hand-off. `FakeAppLauncher` cannot express this: its `open` always succeeds.
final class RefusingOpenAppLauncher: TraciveAppLauncher, @unchecked Sendable {
  func canOpen(_ url: URL) async -> Bool { true }
  @discardableResult
  func open(_ url: URL) async -> Bool { false }
}

/// A token store whose writes always fail — a full disk, a locked Keychain, a missing entitlement.
final class FailingTokenStore: TraciveTokenStore {

  struct Failure: Error {}

  func load() throws -> TraciveTokens? { nil }
  func save(_ tokens: TraciveTokens) throws { throw Failure() }
  func clear() throws {}
}

/// A store written against the protocol as it stood before it could hold a pending authorization:
/// three methods and nothing else.
///
/// It exists to be compiled. A host app that conformed its own vault to `TraciveTokenStore` must
/// not be broken by a requirement added after it shipped, so `loadPending()` and `savePending(_:)`
/// have default implementations and this type deliberately overrides neither.
final class LegacyTokenStore: TraciveTokenStore, @unchecked Sendable {

  private let lock = NSLock()
  private var tokens: TraciveTokens?

  func load() throws -> TraciveTokens? {
    lock.lock()
    defer { lock.unlock() }
    return tokens
  }

  func save(_ tokens: TraciveTokens) throws {
    lock.lock()
    defer { lock.unlock() }
    self.tokens = tokens
  }

  func clear() throws {
    lock.lock()
    defer { lock.unlock() }
    tokens = nil
  }
}

extension AuthResult {
  /// Case name only, for assertions that do not care about payloads.
  var testDescription: String {
    switch self {
    case .authorized: return "authorized"
    case .codeReceived: return "codeReceived"
    case .denied: return "denied"
    case .appNotInstalled: return "appNotInstalled"
    case .failed: return "failed"
    }
  }
}

// MARK: - Documented scope names

/// The scope strings in the prose docs must be the ones the SDK actually asks for.
///
/// They were not. `README.md`, `Docs/integration.md` (twice) and `Docs/oauth.md` all said
/// `"scammer.read"`, while every code path, sample and test in the package used `"scammer.check"`.
/// Both cannot be right, and with the authorization server not deployed nobody could find out
/// empirically. A partner copy-pasting the README's quick start would have requested a scope that
/// does not exist and been answered `403 missing_scope` by `checkScammer` — an error whose
/// documented remedy points them at their client registration rather than at the typo.
///
/// This drives the doc files themselves rather than restating their contents, because a test that
/// merely asserted the canonical spelling would have passed happily while the README stayed wrong.
final class DocumentedScopeTests: XCTestCase {

  /// Every scope the authorization server is expected to register, and the only ones the prose is
  /// allowed to name. Spelled out as literals rather than through `TraciveScopes`, for the reason
  /// `TraciveScopeConstantTests` gives.
  private static let canonicalScopes: Set<String> = [
    "scammer.check", "credits.read", "profile.read",
  ]

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)  // Tests/TraciveSDKTests/OAuthTests.swift
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static var documentationFiles: [URL] {
    let root = repositoryRoot
    let candidates =
      ["README.md", "SECURITY.md", "CHANGELOG.md"].map { root.appendingPathComponent($0) }
      + (
        (try? FileManager.default.contentsOfDirectory(
          at: root.appendingPathComponent("Docs"),
          includingPropertiesForKeys: nil
        )) ?? []
      ).filter { $0.pathExtension == "md" }
    return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  func testTheDocsOnlyMentionScopesTheSDKActuallyRequests() throws {
    let files = Self.documentationFiles
    XCTAssertFalse(files.isEmpty, "found no documentation to scan — this check would never fail")

    // Anything shaped like one of our scope namespaces. Deliberately broad: the point is to catch a
    // *plausible-looking but wrong* scope, which is exactly what "scammer.read" was.
    //
    // `usage` is in the alternation without being in `canonicalScopes`, on purpose. The
    // authorization server does register a daily-usage scope, and this SDK models no call that
    // needs it — so every spelling of it is an offence here. Documenting one would teach partners
    // to ask a user for a permission that buys them nothing, and `TraciveScopes` deliberately
    // ships no constant for it.
    let pattern = try NSRegularExpression(
      pattern: "\\b(?:scammer|credits|profile|usage)\\.[a-z]+\\b")

    var offences: [String] = []
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      let range = NSRange(text.startIndex..., in: text)
      for match in pattern.matches(in: text, range: range) {
        guard let matched = Range(match.range, in: text) else { continue }
        let scope = String(text[matched])
        if !Self.canonicalScopes.contains(scope) {
          offences.append("\(file.lastPathComponent): \(scope)")
        }
      }
    }

    XCTAssertEqual(
      offences.sorted(), [],
      "documentation names a scope the SDK never requests; both cannot be right"
    )
  }

  /// The other direction: the canonical strings the docs are checked against must be the ones the
  /// SDK really sends, or the check above would be pinning the wrong pair.
  ///
  /// Configured through `TraciveScopes`, so this also closes the loop the constants exist for — a
  /// constant carrying a wrong value would land that wrong value in the `scope` parameter, and the
  /// comparison against the literal set above is what catches it.
  func testTheCanonicalScopesAreTheOnesPutOnTheWire() async throws {
    let oauth = makeOAuth(scopes: [
      TraciveScopes.scammerCheck, TraciveScopes.creditsRead, TraciveScopes.profileRead,
    ])
    let request = try await oauth.makeAuthorizationRequest()

    let sent = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "scope" }?.value
    XCTAssertEqual(
      Set((sent ?? "").split(separator: " ").map(String.init)),
      Self.canonicalScopes
    )
  }
}

// MARK: - The scope constants

/// `TraciveScopes` holds the wire strings so integrators stop retyping them.
///
/// Every assertion below writes the expected value as a **literal**, never as another constant.
/// That is the whole point of the class: comparing `TraciveScopes.scammerCheck` against itself, or
/// against a shared symbol, would pass no matter what the value became. Renaming a constant breaks
/// compilation here, and changing one's value fails the assertion — either way the contract cannot
/// be redefined quietly, which matters because nothing else can check it: the authorization server
/// is the only validator of a scope name and it is not deployed.
final class TraciveScopeConstantTests: XCTestCase {

  func testScammerCheckIsTheExactWireString() {
    XCTAssertEqual(TraciveScopes.scammerCheck, "scammer.check")
  }

  func testCreditsReadIsTheExactWireString() {
    XCTAssertEqual(TraciveScopes.creditsRead, "credits.read")
  }

  func testProfileReadIsTheExactWireString() {
    XCTAssertEqual(TraciveScopes.profileRead, "profile.read")
  }

  /// Three distinct scopes, not two and a copy.
  ///
  /// A constant that duplicates its neighbour's value still passes a per-constant equality check if
  /// the duplicate is the one the literal was copied from, and it silently asks for the wrong
  /// permission. Pinning the set size is what makes that impossible.
  func testTheConstantsAreThreeDistinctScopes() {
    let scopes = [
      TraciveScopes.scammerCheck, TraciveScopes.creditsRead, TraciveScopes.profileRead,
    ]
    XCTAssertEqual(Set(scopes).count, 3)
  }
}
