import XCTest
import WebKit
#if os(macOS)
@testable import TurfReviewMac
#else
@testable import TurfReviewNative
#endif

final class TurfReviewClientTests: XCTestCase {
  private var defaultsSuiteName: String?
  private var credentialStore: InMemoryCredentialStore!
  private var sessionStore: InMemorySessionStore!

  override func setUp() {
    super.setUp()
    let suiteName = "TurfReviewClientTests.\(UUID().uuidString)"
    defaultsSuiteName = suiteName
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    credentialStore = InMemoryCredentialStore()
    sessionStore = InMemorySessionStore()
    APIConfiguration.defaultsStore = defaults
    APIConfiguration.credentialStore = credentialStore
    APIConfiguration.sessionStore = sessionStore
  }

  override func tearDown() {
    MockURLProtocol.requestHandler = nil
    if let defaultsSuiteName {
      UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }
    APIConfiguration.defaultsStore = .standard
    APIConfiguration.credentialStore = KeychainCredentialStore()
    APIConfiguration.sessionStore = KeychainSessionStore()
    credentialStore = nil
    sessionStore = nil
    defaultsSuiteName = nil
    super.tearDown()
  }

  func testServerURLNormalizationAcceptsFullAndShorthandHTTPURLs() {
    XCTAssertEqual(
      APIConfiguration.normalizedServerURL(from: " http://localhost:3457/ ")?.absoluteString,
      "http://localhost:3457/"
    )
    XCTAssertEqual(
      APIConfiguration.normalizedServerURL(from: "localhost:3457")?.absoluteString,
      "http://localhost:3457"
    )
    XCTAssertEqual(
      APIConfiguration.normalizedServerURL(from: "127.0.0.1:3457")?.absoluteString,
      "http://127.0.0.1:3457"
    )
    XCTAssertEqual(
      APIConfiguration.normalizedServerURL(from: "https://turf.example.com")?.absoluteString,
      "https://turf.example.com"
    )
    XCTAssertEqual(
      APIConfiguration.normalizedServerURL(from: "https://turf.example.com/native")?.absoluteString,
      "https://turf.example.com/native/"
    )
    XCTAssertEqual(
      APIConfiguration.normalizedServerURL(from: "https://turf.example.com/native/?debug=1#queue")?.absoluteString,
      "https://turf.example.com/native/"
    )
  }

  func testServerURLNormalizationRejectsBlankAndUnsupportedSchemes() {
    XCTAssertNil(APIConfiguration.normalizedServerURL(from: "  "))
    XCTAssertNil(APIConfiguration.normalizedServerURL(from: "ftp://localhost:3457"))
    XCTAssertNil(APIConfiguration.normalizedServerURL(from: "mailto:jimmy@example.com"))
  }

  func testDefaultServerURLUsesBuildConfiguredValueWhenPresent() {
    XCTAssertEqual(
      APIConfiguration.defaultServerURL(rawValue: "http://192.168.1.151:3457").absoluteString,
      "http://192.168.1.151:3457"
    )
  }

  func testDefaultServerURLFallsBackWhenBuildValueIsUnsetOrInvalid() {
    XCTAssertEqual(APIConfiguration.defaultServerURL(rawValue: nil).absoluteString, "http://localhost:3457")
    XCTAssertEqual(APIConfiguration.defaultServerURL(rawValue: "$(TURF_DEFAULT_SERVER_URL)").absoluteString, "http://localhost:3457")
    XCTAssertEqual(APIConfiguration.defaultServerURL(rawValue: "ftp://192.168.1.151:3457").absoluteString, "http://localhost:3457")
  }

  func testColdLoadMigratesPersistedLocalhostServerToProductionDefault() {
    let productionURL = URL(string: "https://review.turfterrace.com")!
    APIConfiguration.defaultsStore.set("http://localhost:3457", forKey: "turf.serverURL")

    let configuration = APIConfiguration.load(compiledDefaultServerURL: productionURL)

    XCTAssertEqual(configuration.serverURL, productionURL)
    XCTAssertEqual(
      APIConfiguration.defaultsStore.string(forKey: "turf.serverURL"),
      productionURL.absoluteString
    )
  }

  func testColdLoadMigratesPersistedIPv4LoopbackServerToProductionDefault() {
    let productionURL = URL(string: "https://review.turfterrace.com")!
    APIConfiguration.defaultsStore.set("http://127.0.0.1:3457", forKey: "turf.serverURL")

    let configuration = APIConfiguration.load(compiledDefaultServerURL: productionURL)

    XCTAssertEqual(configuration.serverURL, productionURL)
    XCTAssertEqual(
      APIConfiguration.defaultsStore.string(forKey: "turf.serverURL"),
      productionURL.absoluteString
    )
  }

  func testColdLoadPreservesIntentionallyConfiguredNonLoopbackServer() {
    let productionURL = URL(string: "https://review.turfterrace.com")!
    let configuredURL = URL(string: "https://review-staging.example.com")!
    APIConfiguration.defaultsStore.set(configuredURL.absoluteString, forKey: "turf.serverURL")

    let configuration = APIConfiguration.load(compiledDefaultServerURL: productionURL)

    XCTAssertEqual(configuration.serverURL, configuredURL)
    XCTAssertEqual(
      APIConfiguration.defaultsStore.string(forKey: "turf.serverURL"),
      configuredURL.absoluteString
    )
  }

  func testColdLoadMigratesLegacyCredentialsToProductionOriginAfterLoopbackUpgrade() throws {
    let productionURL = URL(string: "https://review.turfterrace.com")!
    APIConfiguration.defaultsStore.set("http://localhost:3457", forKey: "turf.serverURL")
    APIConfiguration.defaultsStore.set("legacy-reader", forKey: "turf.username")
    APIConfiguration.defaultsStore.set("legacy-password", forKey: "turf.password")

    let configuration = APIConfiguration.load(compiledDefaultServerURL: productionURL)

    XCTAssertEqual(configuration.serverURL, productionURL)
    XCTAssertEqual(configuration.username, "legacy-reader")
    XCTAssertEqual(configuration.password, "legacy-password")
    XCTAssertEqual(
      try credentialStore.load(),
      StoredBasicAuthCredentials(
        serverURL: productionURL,
        username: "legacy-reader",
        password: "legacy-password"
      )
    )
    XCTAssertNil(APIConfiguration.defaultsStore.string(forKey: "turf.username"))
    XCTAssertNil(APIConfiguration.defaultsStore.string(forKey: "turf.password"))
  }

  func testConfigurationPersistsCredentialsOutsideUserDefaultsAndRestoresOnColdLoad() throws {
    let configuration = APIConfiguration(
      serverURL: URL(string: "https://review.turfterrace.com")!,
      username: "reader",
      password: "private-password",
      useDemoOnFailure: false
    )

    XCTAssertTrue(configuration.save())

    let restored = APIConfiguration.load()
    XCTAssertEqual(restored, configuration)
    XCTAssertNil(APIConfiguration.defaultsStore.string(forKey: "turf.username"))
    XCTAssertNil(APIConfiguration.defaultsStore.string(forKey: "turf.password"))
    XCTAssertEqual(try credentialStore.load()?.username, "reader")
  }

  func testConfigurationMigrationRemovesLegacyCredentialsOnlyAfterSecureWrite() throws {
    APIConfiguration.defaultsStore.set("legacy-reader", forKey: "turf.username")
    APIConfiguration.defaultsStore.set("legacy-password", forKey: "turf.password")
    APIConfiguration.defaultsStore.set("https://review.turfterrace.com", forKey: "turf.serverURL")

    let migrated = APIConfiguration.load()

    XCTAssertEqual(migrated.username, "legacy-reader")
    XCTAssertEqual(migrated.password, "legacy-password")
    XCTAssertEqual(try credentialStore.load()?.username, "legacy-reader")
    XCTAssertNil(APIConfiguration.defaultsStore.string(forKey: "turf.username"))
    XCTAssertNil(APIConfiguration.defaultsStore.string(forKey: "turf.password"))
  }

  func testConfigurationMigrationRetainsLegacyCredentialsWhenSecureWriteFails() {
    APIConfiguration.defaultsStore.set("legacy-reader", forKey: "turf.username")
    APIConfiguration.defaultsStore.set("legacy-password", forKey: "turf.password")
    APIConfiguration.defaultsStore.set("https://review.turfterrace.com", forKey: "turf.serverURL")
    credentialStore.shouldFailWrites = true

    let loaded = APIConfiguration.load()

    XCTAssertEqual(loaded.username, "legacy-reader")
    XCTAssertEqual(loaded.password, "legacy-password")
    XCTAssertEqual(APIConfiguration.defaultsStore.string(forKey: "turf.username"), "legacy-reader")
    XCTAssertEqual(APIConfiguration.defaultsStore.string(forKey: "turf.password"), "legacy-password")
  }

  func testLoopbackUpgradeKeepsStoredServerWhenLegacyCredentialWriteFails() {
    let loopbackURL = "http://localhost:3457"
    let productionURL = URL(string: "https://review.turfterrace.com")!
    APIConfiguration.defaultsStore.set(loopbackURL, forKey: "turf.serverURL")
    APIConfiguration.defaultsStore.set("legacy-reader", forKey: "turf.username")
    APIConfiguration.defaultsStore.set("legacy-password", forKey: "turf.password")
    credentialStore.shouldFailWrites = true

    let loaded = APIConfiguration.load(compiledDefaultServerURL: productionURL)

    XCTAssertEqual(loaded.serverURL, productionURL)
    XCTAssertEqual(loaded.username, "legacy-reader")
    XCTAssertEqual(loaded.password, "legacy-password")
    XCTAssertEqual(APIConfiguration.defaultsStore.string(forKey: "turf.serverURL"), loopbackURL)
    XCTAssertEqual(APIConfiguration.defaultsStore.string(forKey: "turf.username"), "legacy-reader")
    XCTAssertEqual(APIConfiguration.defaultsStore.string(forKey: "turf.password"), "legacy-password")
  }

  func testFailedCredentialSaveKeepsExistingPersistedConfiguration() {
    let existing = APIConfiguration(
      serverURL: URL(string: "https://review.turfterrace.com")!,
      username: "existing-reader",
      password: "existing-password",
      useDemoOnFailure: true
    )
    XCTAssertTrue(existing.save())
    credentialStore.shouldFailWrites = true
    let replacement = APIConfiguration(
      serverURL: URL(string: "https://replacement.example.com")!,
      username: "replacement-reader",
      password: "replacement-password",
      useDemoOnFailure: false
    )

    XCTAssertFalse(replacement.save())

    XCTAssertEqual(APIConfiguration.load(), existing)
  }

  func testExplicitSignOutRemovesStoredCredentials() throws {
    let signedIn = APIConfiguration(
      serverURL: URL(string: "https://review.turfterrace.com")!,
      username: "reader",
      password: "private-password",
      useDemoOnFailure: false
    )
    XCTAssertTrue(signedIn.save())
    let signedOut = APIConfiguration(
      serverURL: signedIn.serverURL,
      username: "",
      password: "",
      useDemoOnFailure: signedIn.useDemoOnFailure
    )

    XCTAssertTrue(signedOut.save())

    XCTAssertNil(try credentialStore.load())
    XCTAssertTrue(APIConfiguration.load().authenticationHeaders(for: signedIn.serverURL).isEmpty)
  }

  func testSessionHeadersAreLimitedToConfiguredOriginAndCSRFMutations() {
    let serverURL = URL(string: "https://review.turfterrace.com")!
    sessionStore.storedSession = HostedSessionState(
      serverURL: serverURL,
      cookieName: HostedSessionState.cookieName,
      cookieValue: "signed-cookie",
      csrfToken: "csrf-token",
      expiresAt: Date().addingTimeInterval(3_600)
    )
    let configuration = APIConfiguration(
      serverURL: serverURL,
      username: "reader",
      password: "private-password",
      useDemoOnFailure: false
    )

    let readHeaders = configuration.authenticationHeaders(
      for: URL(string: "https://review.turfterrace.com/review/example/artifact/")!
    )
    XCTAssertEqual(readHeaders["Cookie"], "\(HostedSessionState.cookieName)=signed-cookie")
    XCTAssertEqual(readHeaders["Origin"], "https://review.turfterrace.com")
    XCTAssertNil(readHeaders["X-CSRF-Token"])
    XCTAssertEqual(
      configuration.authenticationHeaders(for: serverURL, method: "POST")["X-CSRF-Token"],
      "csrf-token"
    )
    XCTAssertTrue(configuration.authenticationHeaders(
      for: URL(string: "https://example.com/audio/example.mp3")!
    ).isEmpty)
    XCTAssertTrue(configuration.authenticationHeaders(
      for: URL(string: "http://review.turfterrace.com/audio/example.mp3")!
    ).isEmpty)
  }

  func testReadingPositionPersistsByDocumentAndRejectsChangedContent() throws {
    let suiteName = "DocumentReadingPositionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let positions = DocumentReadingPositionStore(defaults: defaults, keyPrefix: "test.")

    positions.save(progress: 0.72, documentID: "first-review", contentVersion: "v1")

    let restoredProgress = positions.progress(documentID: "first-review", contentVersion: "v1")
    XCTAssertEqual(try XCTUnwrap(restoredProgress), 0.72, accuracy: 0.000_001)
    XCTAssertNil(positions.progress(documentID: "second-review", contentVersion: "v1"))
    XCTAssertNil(positions.progress(documentID: "first-review", contentVersion: "v2"))
  }

  func testDocumentLoadStateReloadsWhenReadingIdentityChanges() {
    let current = HTMLDocumentLoadState(
      html: "<p>Same body</p>",
      baseURL: nil,
      documentID: "first-review",
      contentVersion: "v1"
    )

    XCTAssertTrue(current.needsReload(
      html: "<p>Same body</p>",
      baseURL: nil,
      documentID: "second-review",
      contentVersion: "v1"
    ))
    XCTAssertTrue(current.needsReload(
      html: "<p>Same body</p>",
      baseURL: nil,
      documentID: "first-review",
      contentVersion: "v2"
    ))
  }

  func testHTMLDocumentLoadStateReloadsWhenBaseURLChanges() {
    let html = #"<img src="/media/proof.png"><a href="relative-note">Note</a>"#
    let oldBase = URL(string: "http://old-server.local:3457")!
    let newBase = URL(string: "http://new-server.local:3457")!
    let current = HTMLDocumentLoadState(html: html, baseURL: oldBase)

    XCTAssertFalse(current.needsReload(html: html, baseURL: oldBase))
    XCTAssertTrue(current.needsReload(html: html, baseURL: newBase))
    XCTAssertTrue(current.needsReload(html: "<p>Different review body</p>", baseURL: oldBase))
  }

  func testHTMLDocumentNavigationPolicyAllowsDocumentLoads() {
    XCTAssertEqual(
      HTMLDocumentNavigationPolicy.decision(for: .other, url: URL(string: "about:blank")),
      .allow
    )
  }

  func testHTMLDocumentNavigationPolicyOpensWebLinksExternally() {
    let url = URL(string: "https://example.com/proof")!

    XCTAssertEqual(
      HTMLDocumentNavigationPolicy.decision(for: .linkActivated, url: url),
      .openExternally(url)
    )
  }

  func testHTMLDocumentNavigationPolicyCancelsUnsafeLinkSchemes() {
    XCTAssertEqual(
      HTMLDocumentNavigationPolicy.decision(for: .linkActivated, url: URL(string: "javascript:alert(1)")),
      .cancel
    )
    XCTAssertEqual(
      HTMLDocumentNavigationPolicy.decision(for: .linkActivated, url: URL(string: "file:///tmp/proof.html")),
      .cancel
    )
    XCTAssertEqual(
      HTMLDocumentNavigationPolicy.decision(for: .linkActivated, url: nil),
      .cancel
    )
  }

  @MainActor
  func testTextAnnotationAcrossParagraphsPreservesBlockStructure() async throws {
    let userContentController = WKUserContentController()
    userContentController.addUserScript(
      WKUserScript(
        source: HTMLDocumentView.selectionScript,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
      )
    )
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContentController
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let loadFinished = expectation(description: "HTML document finished loading")
    let navigationObserver = WebViewNavigationObserver(expectation: loadFinished)
    webView.navigationDelegate = navigationObserver
    webView.loadHTMLString(
      #"<main id="content"><p id="first">Alpha one.</p>\#n<p id="second">Beta two.</p></main>"#,
      baseURL: nil
    )
    await fulfillment(of: [loadFinished], timeout: 3)

    _ = try await webView.evaluateJavaScript(
      #"window.__turfApplyTextAnnotations([{ id: 1, quote: "one.\nBeta", anchorType: "text", anchorRef: "char:6", comment: "Keep these paragraphs." }]);"#
    )
    let snapshotValue = try await webView.evaluateJavaScript(
      """
      JSON.stringify({
        directChildren: Array.from(document.getElementById("content").children).map(function(node) { return node.tagName; }),
        paragraphsInsideMarks: document.querySelectorAll("mark.turf-native-annotation-highlight p").length,
        firstIDCount: document.querySelectorAll("#first").length,
        secondIDCount: document.querySelectorAll("#second").length,
        markCount: document.querySelectorAll("mark.turf-native-annotation-highlight").length,
        usesSelectionToken: (document.getElementById("turf-native-annotation-style").textContent || "").includes(
          "::selection { background: \(HTMLDocumentView.textSelectionBackgroundCSS); }"
        ),
        usesHighlightToken: (document.getElementById("turf-native-annotation-style").textContent || "").includes(
          "mark.turf-native-annotation-highlight { background: \(HTMLDocumentView.savedAnnotationBackgroundCSS)"
        ),
        settlingMarkCount: document.querySelectorAll("mark.turf-native-annotation-highlight.is-new").length
      });
      """
    )
    let snapshotJSON = try XCTUnwrap(snapshotValue as? String)
    let snapshot = try JSONDecoder().decode(AnnotationDOMSnapshot.self, from: Data(snapshotJSON.utf8))

    XCTAssertEqual(snapshot.directChildren, ["P", "P"])
    XCTAssertEqual(snapshot.paragraphsInsideMarks, 0)
    XCTAssertEqual(snapshot.firstIDCount, 1)
    XCTAssertEqual(snapshot.secondIDCount, 1)
    XCTAssertEqual(snapshot.markCount, 2)
    XCTAssertTrue(snapshot.usesSelectionToken)
    XCTAssertTrue(snapshot.usesHighlightToken)
    // Called without fresh IDs (a load or a reload), no mark settles.
    XCTAssertEqual(snapshot.settlingMarkCount, 0)

    webView.navigationDelegate = nil
  }

  @MainActor
  func testOnlyNewlyAddedAnnotationSettles() async throws {
    let webView = try await loadReaderScript(
      #"<main id="content"><p>Alpha one.</p>\#n<p>Beta two.</p></main>"#
    )
    let existing = #"{ id: 1, quote: "Alpha", anchorType: "text", anchorRef: "", comment: "Old." }"#
    let added = #"{ id: 2, quote: "Beta", anchorType: "text", anchorRef: "", comment: "New." }"#
    let settling = "JSON.stringify(Array.from(document.querySelectorAll('mark.is-new')).map(function(mark) { return Number(mark.dataset.annotationId); }))"

    _ = try await webView.evaluateJavaScript("window.__turfApplyTextAnnotations([\(existing)], []);")
    let afterLoadValue = try await webView.evaluateJavaScript(settling)
    let afterLoad = try XCTUnwrap(afterLoadValue as? String)
    XCTAssertEqual(afterLoad, "[]")

    _ = try await webView.evaluateJavaScript("window.__turfApplyTextAnnotations([\(existing), \(added)], [2]);")
    let afterSaveValue = try await webView.evaluateJavaScript(settling)
    let afterSave = try XCTUnwrap(afterSaveValue as? String)
    XCTAssertEqual(afterSave, "[2]")

    // Re-applying the same notes (for example after a refresh) settles nothing.
    _ = try await webView.evaluateJavaScript("window.__turfApplyTextAnnotations([\(existing), \(added)], []);")
    let afterReapplyValue = try await webView.evaluateJavaScript(settling)
    let afterReapply = try XCTUnwrap(afterReapplyValue as? String)
    XCTAssertEqual(afterReapply, "[]")

    webView.navigationDelegate = nil
  }

  @MainActor
  func testReviewTargetControlsSitUnderTheirOwnListItemsInDocumentOrder() async throws {
    // Whitespace between items, as in real documents: a label's range can start at the end of
    // the whitespace node that belongs to the <ul>, which used to stack every control after the list.
    let webView = try await loadReaderScript(
      """
      <main id="content">
        <ul id="list">
          <li id="first">Approve outbound copy</li>
          <li id="second">Approve Friday send timing</li>
        </ul>
        <p id="after">After the list.</p>
      </main>
      """
    )
    _ = try await webView.evaluateJavaScript(
      #"""
      window.__turfApplyReviewTargets([
        { key: "task:1", label: "Approve outbound copy", verdict: "unset", decisionKind: "approval", options: [] },
        { key: "task:2", label: "Approve Friday send timing", verdict: "approved", decisionKind: "approval", options: [] }
      ]);
      """#
    )
    let placementValue = try await webView.evaluateJavaScript(
      """
      JSON.stringify(Array.from(document.querySelectorAll(".turf-native-target-controls")).map(function(control) {
        return { key: control.dataset.targetKey, host: control.parentElement.id };
      }))
      """
    )
    let placementJSON = try XCTUnwrap(placementValue as? String)
    let placement = try JSONDecoder().decode([TargetControlPlacement].self, from: Data(placementJSON.utf8))

    XCTAssertEqual(placement, [
      TargetControlPlacement(key: "task:1", host: "first"),
      TargetControlPlacement(key: "task:2", host: "second"),
    ])

    webView.navigationDelegate = nil
  }

  /// Loads HTML into a web view that runs the reader's injected script, as the app does.
  @MainActor
  private func loadReaderScript(_ html: String) async throws -> WKWebView {
    let userContentController = WKUserContentController()
    userContentController.addUserScript(
      WKUserScript(
        source: HTMLDocumentView.selectionScript,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
      )
    )
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContentController
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let loadFinished = expectation(description: "HTML document finished loading")
    let navigationObserver = WebViewNavigationObserver(expectation: loadFinished)
    webView.navigationDelegate = navigationObserver
    webView.loadHTMLString(html, baseURL: nil)
    await fulfillment(of: [loadFinished], timeout: 3)
    withExtendedLifetime(navigationObserver) {}
    return webView
  }

  func testListItemsUsesHostedRouteAndPaginates() async throws {
    let client = makeClient()
    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      XCTAssertEqual(request.url?.path, "/api/reviews")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "\(HostedSessionState.cookieName)=signed-cookie")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://localhost:3457")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      let json: String
      if requestCount == 1 {
        XCTAssertNil(request.url?.query)
        json = #"{"data":{"items":[{"reviewId":"review_first_internal","slug":"first","title":"First review","category":"general","status":"pending","decision":null,"contentLength":120,"createdAt":"2026-09-22T09:00:00Z","updatedAt":"2026-09-22T09:05:00Z"}],"nextCursor":"cursor/2"}}"#
      } else {
        XCTAssertEqual(request.url?.query, "cursor=cursor/2")
        json = #"{"data":{"items":[{"reviewId":"review_second_internal","slug":"second","title":"Second review","category":"confirmation","status":"decided","decision":"Approve","contentLength":80,"createdAt":null,"updatedAt":null}],"nextCursor":null}}"#
      }
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(json.utf8))
    }

    let items = try await client.listItems()

    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(items.map(\.slug), ["first", "second"])
    XCTAssertEqual(items.first?.contentLength, 120)
    XCTAssertEqual(items.last?.decision, "Approve")
  }

  func testOfflineAssetsIncludeNestedStylesWithoutLeakingCredentials() async throws {
    let client = makeClient()
    var paths: [String] = []
    MockURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      paths.append(url.path)
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      let css = url.path.hasSuffix(".css")
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": css ? "text/css" : "image/png"])!
      return (response, Data((css ? "body { background: url('../images/paper.png') }" : "image bytes").utf8))
    }
    let html = "<link rel='stylesheet' href='https://assets.example/styles/reader.css'><img src='https://assets.example/photo.png'>"
    let saved = try await OfflineDocumentAssets.download(html: html, baseURL: URL(string: "http://localhost:3457")!, client: client)
    XCTAssertTrue(saved.contains("data:text/css;base64,"))
    XCTAssertTrue(saved.contains("data:image/png;base64,"))
    XCTAssertFalse(saved.contains("https://assets.example"))
    XCTAssertEqual(Set(paths), ["/styles/reader.css", "/images/paper.png", "/photo.png"])
  }

  func testOfflineAudioUsesHostedSession() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "\(HostedSessionState.cookieName)=signed-cookie")
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "audio/mpeg"])!
      return (response, Data("audio bytes".utf8))
    }
    let (data, mime) = try await client.downloadResource(URL(string: "http://localhost:3457/audio/example.mp3")!)
    XCTAssertEqual(data, Data("audio bytes".utf8))
    XCTAssertEqual(mime, "audio/mpeg")
  }

  func testGetItemLoadsAuthenticatedHostedDocument() async throws {
    let client = makeClient()
    var requestedPaths: [String] = []
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
      )
      requestedPaths.append(path)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "\(HostedSessionState.cookieName)=signed-cookie")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://localhost:3457")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": path.hasSuffix("/document") ? "text/html; charset=utf-8" : "application/json"]
      )!
      if path.hasSuffix("/document") {
        return (response, Data("<main><p>Hosted review body</p></main>".utf8))
      }
      return (
        response,
        Data(#"{"data":{"reviewId":"review_hosted_internal","slug":"space and/slash","title":"Hosted review","category":"general","status":"pending","createdAt":"2026-09-22T09:00:00Z","updatedAt":"2026-09-22T09:05:00Z","content":{"renderedHtml":{},"markdown":null},"customContentManifest":null,"targets":[],"nextTargetCursor":null}}"#.utf8)
      )
    }

    let item = try await client.getItem(slug: "space and/slash")

    XCTAssertEqual(
      requestedPaths,
      ["/api/reviews/space%20and%2Fslash", "/api/reviews/space%20and%2Fslash/document"]
    )
    XCTAssertEqual(item.slug, "space and/slash")
    XCTAssertEqual(item.renderedHTML, "<main><p>Hosted review body</p></main>")
  }

  func testCanonicalSlugAlignsHostedQueueDetailAndDeepLinkWhenReviewIDDiffers() async throws {
    let serverURL = URL(string: "https://review.turfterrace.com")!
    let client = makeClient(serverURL: serverURL)
    let slug = "production-push-smoke-signed-mac"
    var requestedPaths: [String] = []
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(request.url?.path)
      requestedPaths.append(path)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let json: String
      switch path {
      case "/api/reviews":
        json = #"{"data":{"items":[{"reviewId":"review_internal_123","slug":"production-push-smoke-signed-mac","title":"Push smoke","category":"general","status":"pending","decision":null,"contentLength":80,"createdAt":null,"updatedAt":null}],"nextCursor":null}}"#
      case "/api/reviews/\(slug)":
        json = #"{"data":{"reviewId":"review_internal_123","slug":"production-push-smoke-signed-mac","title":"Push smoke","category":"general","status":"pending","createdAt":null,"updatedAt":null,"content":null,"customContentManifest":null,"targets":[],"nextTargetCursor":null}}"#
      default:
        XCTFail("Unexpected hosted review route: \(path)")
        json = #"{"data":{}}"#
      }
      return (response, Data(json.utf8))
    }

    let queueItems = try await client.listItems()
    let queueItem = try XCTUnwrap(queueItems.first)
    let link = try XCTUnwrap(
      ReviewDeepLink(
        url: URL(string: "\(serverURL.absoluteString)/review/\(slug)")!,
        configuredServerURL: serverURL
      )
    )
    let detailItem = try await client.getItem(slug: link.slug)

    XCTAssertEqual(requestedPaths, ["/api/reviews", "/api/reviews/\(slug)"])
    XCTAssertEqual(queueItem.slug, slug)
    XCTAssertEqual(detailItem.slug, slug)
    XCTAssertEqual(link.slug, slug)
  }

  func testMissingSessionAcceptsFractionalExpiryAndPersistsCookieBeforeRequest() async throws {
    let client = makeClient(serverURL: URL(string: "https://review.example")!, username: "jimmy", password: "secret")
    sessionStore.storedSession = nil
    var requestedPaths: [String] = []
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(request.url?.path)
      requestedPaths.append(path)
      let response: HTTPURLResponse
      if path == "/api/session" {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://review.example")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try Self.requestBodyData(from: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["username": "jimmy", "password": "secret"])
        response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: [
            "Content-Type": "application/json",
            "Set-Cookie": "\(HostedSessionState.cookieName)=renewed-cookie; Path=/; Secure; HttpOnly; SameSite=Strict",
          ]
        )!
        return (
          response,
          Data(#"{"data":{"authenticated":true,"csrfToken":"renewed-csrf","expiresAt":"2030-09-22T12:00:00.945Z"}}"#.utf8)
        )
      }
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "\(HostedSessionState.cookieName)=renewed-cookie")
      response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"data":{"items":[],"nextCursor":null}}"#.utf8))
    }

    _ = try await client.listItems()

    XCTAssertEqual(requestedPaths, ["/api/session", "/api/reviews"])
    XCTAssertEqual(sessionStore.storedSession?.cookieValue, "renewed-cookie")
    XCTAssertEqual(sessionStore.storedSession?.csrfToken, "renewed-csrf")
  }

  func testUnauthorizedHostedRequestRenewsSessionOnce() async throws {
    let client = makeClient(serverURL: URL(string: "https://review.example")!, username: "jimmy", password: "secret")
    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      let path = try XCTUnwrap(request.url?.path)
      if requestCount == 1 {
        XCTAssertEqual(path, "/api/reviews")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 401,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(#"{"error":{"code":"session_expired","message":"Expired."}}"#.utf8))
      }
      if path == "/api/session" {
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: [
            "Content-Type": "application/json",
            "Set-Cookie": "\(HostedSessionState.cookieName)=renewed-cookie; Path=/; Secure; HttpOnly",
          ]
        )!
        return (
          response,
          Data(#"{"data":{"authenticated":true,"csrfToken":"renewed-csrf","expiresAt":"2030-09-22T12:00:00Z"}}"#.utf8)
        )
      }
      XCTAssertEqual(path, "/api/reviews")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "\(HostedSessionState.cookieName)=renewed-cookie")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"data":{"items":[],"nextCursor":null}}"#.utf8))
    }

    _ = try await client.listItems()

    XCTAssertEqual(requestCount, 3)
  }

  func testMissingSessionAndCredentialsFailsWithoutNetworkRequest() async {
    let client = makeClient()
    sessionStore.storedSession = nil
    MockURLProtocol.requestHandler = { request in
      XCTFail("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
      throw URLError(.badServerResponse)
    }

    do {
      _ = try await client.listItems()
      XCTFail("Expected authentication failure.")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Your Turf Review session expired. Sign in again in Settings."
      )
    }
  }

  func testGetAnnotationsPaginatesAndMapsHostedRows() async throws {
    let client = makeClient()
    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      if requestCount == 1 {
        XCTAssertNil(request.url?.query)
        return (
          response,
          Data(#"{"data":{"annotations":[{"id":41,"reviewId":"review_native_smoke_internal","quote":"First quote","anchorType":"text","anchorRef":"char:10","comment":"First note","imageData":null,"imageMime":null,"createdAt":"2026-09-22T09:00:00Z"}],"nextCursor":41}}"#.utf8)
        )
      }
      XCTAssertEqual(request.url?.query, "cursor=41")
      return (
        response,
        Data(#"{"data":{"annotations":[{"id":42,"reviewId":"review_native_smoke_internal","quote":null,"anchorType":"document","anchorRef":null,"comment":"Second note","imageData":null,"imageMime":null,"createdAt":null}],"nextCursor":null}}"#.utf8)
      )
    }

    let annotations = try await client.getAnnotations(slug: "native-smoke")

    XCTAssertEqual(annotations.map(\.id), [41, 42])
    XCTAssertEqual(annotations.first?.comment, "First note")
    XCTAssertEqual(annotations.last?.anchorType, "document")
  }

  func testCreateAnnotationUsesHostedMutationContract() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/reviews/native-smoke/annotations")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"), "csrf-token")
      let body = try Self.requestBodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertNotNil(json["mutationId"] as? String)
      XCTAssertEqual(json["quote"] as? String, "Quoted text")
      XCTAssertEqual(json["anchorType"] as? String, "text")
      XCTAssertEqual(json["anchorRef"] as? String, "char:12")
      XCTAssertEqual(json["comment"] as? String, "Keep this note.")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (
        response,
        Data(#"{"data":{"accepted":true,"replayed":false,"changeLogOperationId":"op-1","annotationId":"annotation-41","externalAnnotationId":41,"annotation":{"id":41,"reviewId":"review_native_smoke_internal","quote":"Quoted text","anchorType":"text","anchorRef":"char:12","comment":"Keep this note.","imageData":null,"imageMime":null,"createdAt":"2026-09-22T09:00:00Z"},"decisionId":null,"judgmentId":null,"job":null}}"#.utf8)
      )
    }

    let annotation = try await client.createAnnotation(
      slug: "native-smoke",
      quote: "Quoted text",
      anchorType: "text",
      anchorRef: "char:12",
      comment: "Keep this note."
    )

    XCTAssertEqual(annotation.id, 41)
    XCTAssertEqual(annotation.slug, "native-smoke")
    XCTAssertEqual(annotation.comment, "Keep this note.")
  }

  func testImageAnnotationFailsBeforeNetworkRequest() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTFail("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
      throw URLError(.badServerResponse)
    }

    do {
      _ = try await client.createAnnotation(
        slug: "native-smoke",
        quote: nil,
        anchorType: "image",
        anchorRef: "apple-pencil-sketch",
        comment: "Sketch",
        imageData: "c2tldGNo",
        imageMime: "image/png"
      )
      XCTFail("Expected unsupported image annotation failure.")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "The hosted Turf Review service does not support image annotation uploads."
      )
    }
  }

  func testDeleteAnnotationUsesHostedDeleteContract() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/reviews/native-smoke/annotations/41")
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"), "csrf-token")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"data":{"deleted":true,"annotationId":41}}"#.utf8))
    }

    let receipt = try await client.deleteAnnotation(slug: "native-smoke", id: 41)

    XCTAssertTrue(receipt.deleted)
  }

  func testReviewTargetsPaginatesAndBuildsSummary() async throws {
    let client = makeClient()
    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      if requestCount == 1 {
        XCTAssertNil(request.url?.query)
        return (
          response,
          Data(#"{"data":{"reviewId":"review_native_smoke_internal","slug":"native-smoke","title":"Review","category":"confirmation","status":"pending","createdAt":null,"updatedAt":null,"content":null,"customContentManifest":null,"targets":[{"id":"target-one","ordinal":1,"label":"First","state":"open","judgment":"approved","feedback":null}],"nextTargetCursor":"target/two"}}"#.utf8)
        )
      }
      XCTAssertEqual(request.url?.query, "targetCursor=target/two")
      return (
        response,
        Data(#"{"data":{"reviewId":"review_native_smoke_internal","slug":"native-smoke","title":"Review","category":"confirmation","status":"pending","createdAt":null,"updatedAt":null,"content":null,"customContentManifest":null,"targets":[{"id":"target-two","ordinal":2,"label":"Second","state":"open","judgment":"unset","feedback":"Needs review."}],"nextTargetCursor":null}}"#.utf8)
      )
    }

    let response = try await client.getReviewTargets(slug: "native-smoke")

    XCTAssertEqual(response.targets.map(\.key), ["target-one", "target-two"])
    XCTAssertEqual(response.summary.approved, 1)
    XCTAssertEqual(response.summary.undecided, 1)
    XCTAssertFalse(response.summary.complete)
  }

  func testUpdateReviewTargetUsesPutThenReloadsTargets() async throws {
    let client = makeClient()
    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
      requestCount += 1
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      if request.httpMethod == "PUT" {
        XCTAssertEqual(
          request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
          },
          "/api/reviews/native-smoke/targets/task%3Aapproval%3A001%3Aabc"
        )
        let body = try Self.requestBodyData(from: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["mutationId"] as? String)
        XCTAssertEqual(json["verdict"] as? String, "rejected")
        XCTAssertEqual(json["feedback"] as? String, "Needs source.")
        return (
          response,
          Data(#"{"data":{"accepted":true,"replayed":false,"changeLogOperationId":"op-target","annotationId":null,"externalAnnotationId":null,"annotation":null,"decisionId":null,"judgmentId":"judgment-1","job":null}}"#.utf8)
        )
      }
      XCTAssertEqual(request.url?.path, "/api/reviews/native-smoke")
      return (
        response,
        Data(#"{"data":{"reviewId":"review_native_smoke_internal","slug":"native-smoke","title":"Review","category":"confirmation","status":"pending","createdAt":null,"updatedAt":null,"content":null,"customContentManifest":null,"targets":[{"id":"task:approval:001:abc","ordinal":1,"label":"Approve candidate","state":"decided","judgment":"rejected","feedback":"Needs source."}],"nextTargetCursor":null}}"#.utf8)
      )
    }

    let response = try await client.updateReviewTarget(
      slug: "native-smoke",
      targetKey: "task:approval:001:abc",
      verdict: "rejected",
      feedback: " Needs source. "
    )

    XCTAssertEqual(requestCount, 2)
    XCTAssertEqual(response.target?.verdict, "rejected")
    XCTAssertEqual(response.target?.feedback, "Needs source.")
    XCTAssertTrue(response.summary.complete)
  }

  func testDecisionUsesHostedReceiptAndTrimmedNote() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/reviews/native-smoke/decisions")
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try Self.requestBodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertNotNil(json["mutationId"] as? String)
      XCTAssertEqual(json["decision"] as? String, "Execute")
      XCTAssertEqual(json["noteText"] as? String, "Ship it.")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 202,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (
        response,
        Data(#"{"data":{"accepted":true,"replayed":false,"changeLogOperationId":"op-decision","annotationId":null,"externalAnnotationId":null,"annotation":null,"decisionId":"decision-1","judgmentId":null,"job":{"id":"job-1","status":"queued","actionPayloadHash":"hash","actionType":"execute"}}}"#.utf8)
      )
    }

    let response = try await client.decide(
      slug: "native-smoke",
      decision: "Execute",
      actionId: nil,
      feedback: "  Ship it.\n"
    )

    XCTAssertEqual(response.status, "processed")
    XCTAssertTrue(response.queued)
    XCTAssertFalse(response.processed)
    XCTAssertEqual(response.action.status, "queued")
  }

  func testDecisionRejectsLegacyActionIdentifierBeforeNetworkRequest() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTFail("Unexpected request to \(request.url?.absoluteString ?? "unknown URL")")
      throw URLError(.badServerResponse)
    }

    do {
      _ = try await client.decide(
        slug: "native-smoke",
        decision: "Execute",
        actionId: "general.execute",
        feedback: nil
      )
      XCTFail("Expected unsupported action identifier failure.")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "The hosted Turf Review service does not support legacy action identifiers in hosted decisions."
      )
    }
  }

  @MainActor
  func testStoreArchivesThroughHostedClientWithoutDerivedActionIDs() async throws {
    let client = makeClient()
    var decisionBodies: [[String: Any]] = []
    var archived = false
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(request.url?.path)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      if request.httpMethod == "POST" {
        XCTAssertEqual(path, "/api/reviews/hosted-archive/decisions")
        let body = try Self.requestBodyData(from: request)
        decisionBodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any]))
        archived = true
        return (
          response,
          Data(#"{"data":{"accepted":true,"replayed":false,"changeLogOperationId":"op","annotationId":null,"externalAnnotationId":null,"annotation":null,"decisionId":"decision-1","judgmentId":null,"job":null}}"#.utf8)
        )
      }
      XCTAssertEqual(path, "/api/reviews")
      let status = archived ? "archived" : "pending"
      let decision = archived ? #""Noted""# : "null"
      return (
        response,
        Data(#"{"data":{"items":[{"reviewId":"r1","slug":"hosted-archive","title":"Archive me","category":"general","status":"\#(status)","decision":\#(decision),"contentLength":10,"createdAt":"2026-09-22T09:00:00.000Z","updatedAt":"2026-09-22T09:00:00.000Z"}],"nextCursor":null}}"#.utf8)
      )
    }
    let store = ReviewStore(configuration: client.configuration, clientFactory: { _ in client })

    await store.refresh()
    let didArchive = await store.archiveAllVisiblePendingItems()

    XCTAssertTrue(didArchive, store.bannerMessage ?? "")
    XCTAssertEqual(decisionBodies.count, 1)
    XCTAssertEqual(decisionBodies.first?["decision"] as? String, "Noted")
    XCTAssertEqual(store.bannerMessage, "Archived 1 review.")
  }

  @MainActor
  func testStoreOpensHostedReviewWhoseInternalIDDiffersFromSlug() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(request.url?.path)
      let isDocument = path.hasSuffix("/document")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": isDocument ? "text/html; charset=utf-8" : "application/json"]
      )!
      let json: String
      switch path {
      case "/api/reviews":
        json = #"{"data":{"items":[{"reviewId":"review_internal_9","slug":"hosted-open","title":"Open me","category":"general","status":"pending","decision":null,"contentLength":20,"createdAt":"2026-09-22T09:00:00.000Z","updatedAt":"2026-09-22T09:00:00.000Z"}],"nextCursor":null}}"#
      case "/api/reviews/hosted-open":
        json = #"{"data":{"reviewId":"review_internal_9","slug":"hosted-open","title":"Open me","category":"general","status":"pending","createdAt":"2026-09-22T09:00:00.000Z","updatedAt":"2026-09-22T09:00:00.000Z","content":{"renderedHtml":{}},"customContentManifest":null,"targets":[{"id":"t1","ordinal":1,"label":"First","state":"open","judgment":null,"feedback":null}],"nextTargetCursor":null,"media":{"tts":{"status":"missing","url":null,"summary":null},"context":{"status":"missing","url":null,"summary":null}}}}"#
      case "/api/reviews/hosted-open/document":
        return (response, Data("<p>Body text</p>".utf8))
      case "/api/reviews/hosted-open/annotations":
        json = #"{"data":{"annotations":[{"id":7,"reviewId":"review_internal_9","quote":"Body","anchorType":"text","anchorRef":"char:0","comment":"Note","imageData":null,"imageMime":null,"createdAt":null}],"nextCursor":null}}"#
      default:
        XCTFail("Unexpected route \(path)")
        json = #"{"data":{}}"#
      }
      return (response, Data(json.utf8))
    }
    let store = ReviewStore(configuration: client.configuration, clientFactory: { _ in client })

    await store.refresh()
    await store.selectItem(slug: "hosted-open")

    XCTAssertNil(store.bannerMessage)
    XCTAssertEqual(store.selectedItem?.renderedHTML, "<p>Body text</p>")
    XCTAssertEqual(store.annotations.map(\.id), [7])
    XCTAssertEqual(store.reviewTargets.map(\.key), ["t1"])
  }

  func testConcurrentDetailReadsShareOneHostedDetailRequest() async throws {
    let client = makeClient()
    var requestedPaths: [String] = []
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(request.url?.path)
      requestedPaths.append(path)
      let isDocument = path.hasSuffix("/document")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": isDocument ? "text/html; charset=utf-8" : "application/json"]
      )!
      if isDocument {
        return (response, Data("<p>Body</p>".utf8))
      }
      XCTAssertEqual(path, "/api/reviews/native-smoke")
      return (
        response,
        Data(#"{"data":{"reviewId":"review_native_smoke_internal","slug":"native-smoke","title":"Review","category":"general","status":"pending","createdAt":null,"updatedAt":null,"content":{"renderedHtml":{}},"customContentManifest":null,"targets":[{"id":"target-one","ordinal":1,"label":"First","state":"open","judgment":null,"feedback":null}],"nextTargetCursor":null,"media":{"tts":{"status":"ready","url":"/api/reviews/native-smoke/assets/tts-hash","summary":null},"context":{"status":"missing","url":null,"summary":"Context from server."}}}}"#.utf8)
      )
    }

    async let item = client.getItem(slug: "native-smoke")
    async let targets = client.getReviewTargets(slug: "native-smoke")
    async let tts = client.ttsStatus(slug: "native-smoke")
    async let context = client.contextStatus(slug: "native-smoke")
    let loaded = try await (item, targets, tts, context)

    XCTAssertEqual(requestedPaths.filter { $0 == "/api/reviews/native-smoke" }.count, 1)
    XCTAssertEqual(requestedPaths.filter { $0.hasSuffix("/document") }.count, 1)
    XCTAssertEqual(requestedPaths.count, 2)
    XCTAssertEqual(loaded.0.renderedHTML, "<p>Body</p>")
    XCTAssertEqual(loaded.1.targets.map(\.key), ["target-one"])
    XCTAssertEqual(loaded.2.url, "/api/reviews/native-smoke/assets/tts-hash")
    XCTAssertEqual(loaded.3.status, "missing")
    XCTAssertEqual(loaded.3.summary, "Context from server.")
  }

  func testReadAfterMutationDoesNotReuseEarlierDetailRequest() async throws {
    let client = makeClient()
    var detailRequests = 0
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      if request.httpMethod == "POST" {
        return (
          response,
          Data(#"{"data":{"accepted":true,"replayed":false,"changeLogOperationId":"op","annotationId":null,"externalAnnotationId":null,"annotation":null,"decisionId":"decision-1","judgmentId":null,"job":null}}"#.utf8)
        )
      }
      detailRequests += 1
      return (
        response,
        Data(#"{"data":{"reviewId":"r","slug":"native-smoke","title":"Review","category":"general","status":"pending","createdAt":null,"updatedAt":null,"content":null,"customContentManifest":null,"targets":[],"nextTargetCursor":null}}"#.utf8)
      )
    }

    _ = try await client.getReviewTargets(slug: "native-smoke")
    _ = try await client.decide(slug: "native-smoke", decision: "Execute", actionId: nil, feedback: nil)
    _ = try await client.getReviewTargets(slug: "native-smoke")

    XCTAssertEqual(detailRequests, 2)
  }

  func testAudioStatusFallsBackToMediaEndpointsWhenDetailOmitsMedia() async throws {
    let client = makeClient()
    var requestedPaths: [String] = []
    MockURLProtocol.requestHandler = { request in
      let path = try XCTUnwrap(request.url?.path)
      requestedPaths.append(path)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      if path == "/api/reviews/native-smoke" {
        return (
          response,
          Data(#"{"data":{"reviewId":"r","slug":"native-smoke","title":"Review","category":"general","status":"pending","createdAt":null,"updatedAt":null,"content":null,"customContentManifest":null,"targets":[],"nextTargetCursor":null}}"#.utf8)
        )
      }
      if path.hasSuffix("/tts") {
        return (
          response,
          Data(#"{"data":{"status":"ready","url":"/api/reviews/native-smoke/assets/tts-hash","summary":null}}"#.utf8)
        )
      }
      return (
        response,
        Data(#"{"data":{"status":"ready","url":"/api/reviews/native-smoke/assets/context-hash","context_summary":"Context from server."}}"#.utf8)
      )
    }

    let tts = try await client.ttsStatus(slug: "native-smoke")
    let context = try await client.contextStatus(slug: "native-smoke")

    XCTAssertEqual(
      requestedPaths,
      [
        "/api/reviews/native-smoke", "/api/reviews/native-smoke/tts",
        "/api/reviews/native-smoke", "/api/reviews/native-smoke/context",
      ]
    )
    XCTAssertEqual(tts.url, "/api/reviews/native-smoke/assets/tts-hash")
    XCTAssertEqual(context.summary, "Context from server.")
  }

  #if os(iOS)
  func testPencilAnnotationCommentKeepsStablePrefix() {
    XCTAssertEqual(PencilAnnotationPayload.comment(from: ""), "Apple Pencil sketch.")
    XCTAssertEqual(
      PencilAnnotationPayload.comment(from: "  Tighten this intro. \n"),
      "Apple Pencil sketch: Tighten this intro."
    )
  }
  #endif

  func testAbsoluteURLResolvesOnlyWebMediaURLs() {
    let client = makeClient(serverURL: URL(string: "https://turf.example.com/native")!)

    XCTAssertEqual(
      client.absoluteURL(for: "/api/reviews/native-smoke/assets/tts-hash?token=abc#clip")?.absoluteString,
      "https://turf.example.com/native/api/reviews/native-smoke/assets/tts-hash?token=abc#clip"
    )
    XCTAssertEqual(
      client.absoluteURL(for: "https://assets.example/native-smoke.mp3")?.absoluteString,
      "https://assets.example/native-smoke.mp3"
    )
    XCTAssertNil(client.absoluteURL(for: "file:///tmp/native-smoke.mp3"))
    XCTAssertNil(client.absoluteURL(for: "javascript:alert(1)"))
    XCTAssertNil(client.absoluteURL(for: "  "))
  }

  func testHostedErrorEnvelopeSuppliesServerMessage() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 409,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (
        response,
        Data(#"{"error":{"code":"review_conflict","message":"Review has already left pending."}}"#.utf8)
      )
    }

    do {
      _ = try await client.listItems()
      XCTFail("Expected structured server error.")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Server returned 409: Review has already left pending."
      )
    }
  }

  func testMalformedHostedEnvelopeThrowsUnreadableJSONError() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"data":{"items":"not-an-array"}}"#.utf8))
    }

    do {
      _ = try await client.listItems()
      XCTFail("Expected malformed hosted JSON to fail.")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "The server returned JSON with status 200, but the native app could not read it."
      )
    }
  }

  private func makeClient(
    serverURL: URL = URL(string: "http://localhost:3457")!,
    username: String = "",
    password: String = ""
  ) -> TurfReviewClient {
    sessionStore.storedSession = HostedSessionState(
      serverURL: serverURL,
      cookieName: HostedSessionState.cookieName,
      cookieValue: "signed-cookie",
      csrfToken: "csrf-token",
      expiresAt: Date().addingTimeInterval(3_600)
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return TurfReviewClient(
      configuration: APIConfiguration(
        serverURL: serverURL,
        username: username,
        password: password,
        useDemoOnFailure: false
      ),
      session: session
    )
  }

  private static func requestBodyData(from request: URLRequest) throws -> Data {
    if let httpBody = request.httpBody {
      return httpBody
    }

    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw stream.streamError ?? NSError(domain: "MockURLProtocol", code: -1)
      }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

}

private struct AnnotationDOMSnapshot: Decodable {
  let directChildren: [String]
  let paragraphsInsideMarks: Int
  let firstIDCount: Int
  let secondIDCount: Int
  let markCount: Int
  let usesSelectionToken: Bool
  let usesHighlightToken: Bool
  let settlingMarkCount: Int
}

private struct TargetControlPlacement: Decodable, Equatable {
  let key: String
  let host: String
}

@MainActor
private final class WebViewNavigationObserver: NSObject, WKNavigationDelegate {
  private let expectation: XCTestExpectation

  init(expectation: XCTestExpectation) {
    self.expectation = expectation
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    expectation.fulfill()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    XCTFail("HTML document failed to load: \(error)")
    expectation.fulfill()
  }
}

final class InMemoryCredentialStore: CredentialStoring {
  enum Failure: Error {
    case writeFailed
  }

  var storedCredentials: StoredBasicAuthCredentials?
  var shouldFailWrites = false

  func load() throws -> StoredBasicAuthCredentials? {
    storedCredentials
  }

  func save(_ credentials: StoredBasicAuthCredentials?) throws {
    if shouldFailWrites {
      throw Failure.writeFailed
    }
    storedCredentials = credentials
  }
}

final class InMemorySessionStore: SessionStoring {
  var storedSession: HostedSessionState?

  func load() throws -> HostedSessionState? {
    storedSession
  }

  func save(_ session: HostedSessionState?) throws {
    storedSession = session
  }
}

private final class MockURLProtocol: URLProtocol {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
