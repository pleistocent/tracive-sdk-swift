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
    XCTAssertEqual(result.testDescription, "failed")
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
  }

  func testInstallLinkIsCleanOfEveryOAuthParameter() {
    let url = TraciveAppPresence.installURL(clientId: "test-client")
    let query = Self.queryItems(of: url)

    // Routing consent parameters through a third-party processor is forbidden. An attribution tag
    // naming the *client* is explicitly allowed; nothing about the user or the flow is.
    for forbidden in [
      "state", "code_challenge", "code_challenge_method", "redirect_uri", "client_id",
      "partner_user_id", "scope", "response_type", "code",
    ] {
      XCTAssertNil(query[forbidden], "Install link must not carry \(forbidden).")
    }
    XCTAssertEqual(query["ref"], "test-client")
    XCTAssertEqual(url.host, "tracive.chottu.link")
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

    XCTAssertEqual(result.testDescription, "denied")
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
    XCTAssertEqual(callbackResult.testDescription, "authorized")

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
      callbackOutcome.set(result)
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

func makeOAuth(
  transport: FakeHTTPTransport = FakeHTTPTransport { _, _ in HTTPResponse(status: 200) },
  tokenStore: (any TraciveTokenStore)? = nil,
  launcher: (any TraciveAppLauncher)? = nil,
  clock: RecordingClock = RecordingClock(),
  environment: TraciveEnvironment = .production,
  clientType: ClientType = .public
) -> TraciveOAuth {
  TraciveOAuth(
    configuration: OAuthConfiguration(
      clientId: "test-client",
      redirectUri: URL(string: "https://partner.example.com/tracive/callback")!,
      scopes: ["scammer.check", "credits.read"],
      partnerUserId: "partner-user-1",
      clientType: clientType
    ),
    environment: environment,
    transport: transport,
    tokenStore: tokenStore ?? InMemoryTokenStore(),
    appLauncher: launcher ?? FakeAppLauncher(canOpenAnything: true),
    clock: clock
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
