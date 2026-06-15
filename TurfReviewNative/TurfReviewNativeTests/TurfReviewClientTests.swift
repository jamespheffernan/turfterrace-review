import XCTest
import WebKit
@testable import TurfReviewNative

final class TurfReviewClientTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.requestHandler = nil
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

  func testListItemsDecodesServerPayload() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items")
      let data = Data(Self.itemsJSON.utf8)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json; charset=utf-8"]
      )!
      return (response, data)
    }

    let items = try await client.listItems()

    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].slug, "native-smoke")
    XCTAssertEqual(items[0].allowedActions, ["Send", "Edit", "Kill"])
    XCTAssertEqual(items[0].effectiveActionStatus, "queued")
  }

  func testListItemsDecodesParsedActionsArrayPayload() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"[{"slug":"array-actions","title":"Array actions","category":"general","status":"pending","actions":["  Noted  ","Execute",""]}]"#.utf8))
    }

    let items = try await client.listItems()

    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].slug, "array-actions")
    XCTAssertEqual(items[0].allowedActions, ["Noted", "Execute"])
  }

  func testCurrentSchemaItemsUseCanonicalActionsOverStoredActions() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (
        response,
        Data(#"[{"slug":"canonical-actions","title":"Canonical actions","category":"confirmation","status":"pending","decision_schema_version":3,"actions":"[\"Approve\",\"Reject\"]"}]"#.utf8)
      )
    }

    let items = try await client.listItems()

    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].slug, "canonical-actions")
    XCTAssertEqual(items[0].decisionSchemaVersion, 3)
    XCTAssertEqual(items[0].allowedActions, ["Approve", "Rework", "Kill", "No further action"])
  }

  func testSessionBackedItemsUseCanonicalActionsWithoutSchemaVersion() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (
        response,
        Data(#"[{"slug":"session-backed-actions","title":"Session backed actions","category":"confirmation","status":"pending","session_key":"review:session-backed-actions","actions":"[\"Approve\",\"Reject\"]"}]"#.utf8)
      )
    }

    let items = try await client.listItems()

    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0].slug, "session-backed-actions")
    XCTAssertEqual(items[0].sessionKey, "review:session-backed-actions")
    XCTAssertNil(items[0].decisionSchemaVersion)
    XCTAssertTrue(items[0].usesCanonicalRouting)
    XCTAssertEqual(items[0].allowedActions, ["Approve", "Rework", "Kill", "No further action"])
  }

  func testBasicAuthHeaderIsSentWhenConfigured() async throws {
    let client = makeClient(username: "jimmy", password: "secret")
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic amltbXk6c2VjcmV0")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data("[]".utf8))
    }

    _ = try await client.listItems()
  }

  func testSlugPathComponentsArePercentEncoded() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "http://localhost:3457/api/items/space%20and%2Fslash%3Fquery%23caf%C3%A9/actions"
      )
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"space and/slash?query#café","requests":[],"legacyActions":[]}"#.utf8))
    }

    let response = try await client.getActions(slug: "space and/slash?query#café")

    XCTAssertEqual(response.slug, "space and/slash?query#café")
  }

  func testRequestsPreserveConfiguredBasePathAndEncodedSlug() async throws {
    let client = makeClient(serverURL: URL(string: "https://turf.example.com/native")!)
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://turf.example.com/native/api/items/space%20and%2Fslash%3Fquery%23caf%C3%A9/actions"
      )
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"space and/slash?query#café","requests":[],"legacyActions":[]}"#.utf8))
    }

    let response = try await client.getActions(slug: "space and/slash?query#café")

    XCTAssertEqual(response.slug, "space and/slash?query#café")
  }

  func testActionsResponseDefaultsMissingLegacyActionsToEmpty() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/actions")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"native-smoke","requests":[]}"#.utf8))
    }

    let response = try await client.getActions(slug: "native-smoke")

    XCTAssertTrue(response.requests.isEmpty)
    XCTAssertTrue(response.legacyActions.isEmpty)
  }

  func testReviewTargetsResponseDecodesTargetRows() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/targets")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"native-smoke","targets":[{"id":1,"key":"task:approval:001:abc","label":"Approve candidate","sourceType":"task_list","anchorRef":"target:task:approval:001:abc","ordinal":1,"verdict":"unset","feedback":null,"decided":false,"decidedAt":null,"updatedAt":"2026-06-12 15:00:00"}],"summary":{"total":1,"approved":0,"rejected":0,"undecided":1,"decided":0,"complete":false}}"#.utf8))
    }

    let response = try await client.getReviewTargets(slug: "native-smoke")

    XCTAssertEqual(response.slug, "native-smoke")
    XCTAssertEqual(response.targets.first?.key, "task:approval:001:abc")
    XCTAssertEqual(response.targets.first?.label, "Approve candidate")
    XCTAssertTrue(response.targets.first?.isUnset == true)
    XCTAssertEqual(response.summary.undecided, 1)
    XCTAssertFalse(response.summary.complete)
  }

  func testUpdateReviewTargetSendsVerdictAndFeedback() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertTrue(request.url?.absoluteString.hasSuffix("/api/items/native-smoke/targets/task%3Aapproval%3A001%3Aabc") == true)
      XCTAssertEqual(request.httpMethod, "PATCH")
      let body = try Self.requestBodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["verdict"] as? String, "rejected")
      XCTAssertEqual(json["feedback"] as? String, "Needs source.")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"native-smoke","target":{"id":1,"key":"task:approval:001:abc","label":"Approve candidate","sourceType":"task_list","anchorRef":"target:task:approval:001:abc","ordinal":1,"verdict":"rejected","feedback":"Needs source.","decided":true,"decidedAt":"2026-06-12 15:00:00","updatedAt":"2026-06-12 15:00:00"},"summary":{"total":1,"approved":0,"rejected":1,"undecided":0,"decided":1,"complete":true}}"#.utf8))
    }

    let response = try await client.updateReviewTarget(
      slug: "native-smoke",
      targetKey: "task:approval:001:abc",
      verdict: "rejected",
      feedback: " Needs source. "
    )

    XCTAssertEqual(response.target?.verdict, "rejected")
    XCTAssertEqual(response.target?.feedback, "Needs source.")
    XCTAssertTrue(response.summary.complete)
  }

  func testActionsResponseDecodesLegacyActionsSnakeCase() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"native-smoke","requests":[],"legacy_actions":[{"id":17,"slug":"native-smoke","decision":"Execute","status":"failed","last_error":"Timed out"}]}"#.utf8))
    }

    let response = try await client.getActions(slug: "native-smoke")

    XCTAssertEqual(response.legacyActions.map(\.id), [17])
    XCTAssertEqual(response.legacyActions.first?.lastError, "Timed out")
  }

  func testRetryResponseDecodesRequestPayload() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/action/retry")
      XCTAssertEqual(request.httpMethod, "POST")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"ok":true,"slug":"native-smoke","request":{"id":42,"status":"queued","kind":"agent_followup"}}"#.utf8))
    }

    let response = try await client.retryLatestAction(slug: "native-smoke")

    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.slug, "native-smoke")
    XCTAssertEqual(response.request?.id, 42)
    XCTAssertEqual(response.request?.status, "queued")
    XCTAssertEqual(response.request?.kind, "agent_followup")
  }

  func testRetryResponseDecodesActionPayload() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/action/retry")
      XCTAssertEqual(request.httpMethod, "POST")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"ok":true,"slug":"native-smoke","action":{"id":17,"status":"queued","decision":"Execute"}}"#.utf8))
    }

    let response = try await client.retryLatestAction(slug: "native-smoke")

    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.slug, "native-smoke")
    XCTAssertEqual(response.action?.id, 17)
    XCTAssertEqual(response.action?.status, "queued")
    XCTAssertEqual(response.action?.decision, "Execute")
  }

  func testDecisionResponseDefaultsMissingAcceptedFields() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/decide")
      XCTAssertEqual(request.httpMethod, "POST")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"status":"ok","decision":"Execute","slug":"native-smoke","processed":true,"session_key":"legacy-session"}"#.utf8))
    }

    let response = try await client.decide(slug: "native-smoke", decision: "Execute", feedback: "Ship it.")

    XCTAssertEqual(response.status, "ok")
    XCTAssertEqual(response.decision, "Execute")
    XCTAssertEqual(response.slug, "native-smoke")
    XCTAssertFalse(response.queued)
    XCTAssertTrue(response.processed)
    XCTAssertEqual(response.sessionKey, "legacy-session")
    XCTAssertEqual(response.action.status, "succeeded")
    XCTAssertEqual(response.action.message, "Execute saved.")
    XCTAssertTrue(response.requests.isEmpty)
    XCTAssertTrue(response.followups.isEmpty)
  }

  func testDecisionRequestSendsTrimmedFeedbackBody() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/decide")
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try Self.requestBodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["decision"] as? String, "Execute")
      XCTAssertEqual(json["feedback"] as? String, "Ship it.")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"status":"processed","decision":"Execute","slug":"native-smoke","queued":false,"processed":true}"#.utf8))
    }

    _ = try await client.decide(slug: "native-smoke", decision: "Execute", feedback: "  Ship it.\n")
  }

  func testDecisionRequestOmitsFeedbackWhenBlank() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/decide")
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try Self.requestBodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["decision"] as? String, "Park")
      XCTAssertNil(json["feedback"])
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"status":"parked","decision":"Park","slug":"native-smoke","queued":false,"processed":true}"#.utf8))
    }

    _ = try await client.decide(slug: "native-smoke", decision: "Park", feedback: "  \n")
  }

  func testCreateAnnotationSendsImagePayload() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/annotate")
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try Self.requestBodyData(from: request)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertNil(json["quote"])
      XCTAssertEqual(json["anchor_type"] as? String, "image")
      XCTAssertEqual(json["anchor_ref"] as? String, "apple-pencil-sketch")
      XCTAssertEqual(json["comment"] as? String, "Apple Pencil sketch: Tighten intro.")
      XCTAssertEqual(json["image_data"] as? String, "c2tldGNo")
      XCTAssertEqual(json["image_mime"] as? String, "image/png")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"id":44,"slug":"native-smoke","quote":null,"anchor_type":"image","anchor_ref":"apple-pencil-sketch","comment":"Apple Pencil sketch: Tighten intro.","image_data":"c2tldGNo","image_mime":"image/png","created_at":"2026-06-12 09:00:00"}"#.utf8))
    }

    let annotation = try await client.createAnnotation(
      slug: "native-smoke",
      quote: nil,
      anchorType: "image",
      anchorRef: "apple-pencil-sketch",
      comment: "Apple Pencil sketch: Tighten intro.",
      imageData: "c2tldGNo",
      imageMime: "image/png"
    )

    XCTAssertEqual(annotation.id, 44)
    XCTAssertEqual(annotation.anchorType, "image")
    XCTAssertEqual(annotation.anchorRef, "apple-pencil-sketch")
    XCTAssertEqual(annotation.imageData, "c2tldGNo")
    XCTAssertEqual(annotation.imageMime, "image/png")
  }

  func testPencilAnnotationCommentKeepsStablePrefix() {
    XCTAssertEqual(PencilAnnotationPayload.comment(from: ""), "Apple Pencil sketch.")
    XCTAssertEqual(
      PencilAnnotationPayload.comment(from: "  Tighten this intro. \n"),
      "Apple Pencil sketch: Tighten this intro."
    )
  }

  func testChatHistoryDecodesSnakeCaseSessionKey() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/chat/history")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"session_key":"review:native-smoke","messages":[{"role":"assistant","content":"Ready.","created_at":"2026-06-11 09:15:00"}]}"#.utf8))
    }

    let response = try await client.getChatHistory(slug: "native-smoke")

    XCTAssertEqual(response.sessionKey, "review:native-smoke")
    XCTAssertEqual(response.messages.count, 1)
    XCTAssertEqual(response.messages.first?.role, "assistant")
    XCTAssertEqual(response.messages.first?.content, "Ready.")
  }

  func testChatSendDecodesSnakeCaseSessionKey() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/chat")
      XCTAssertEqual(request.httpMethod, "POST")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"session_key":"review:native-smoke","message":{"role":"assistant","content":"Done.","created_at":"2026-06-11 09:17:00"}}"#.utf8))
    }

    let response = try await client.sendChat(slug: "native-smoke", message: "Where are we?")

    XCTAssertEqual(response.sessionKey, "review:native-smoke")
    XCTAssertEqual(response.message.role, "assistant")
    XCTAssertEqual(response.message.content, "Done.")
  }

  func testContextStatusDecodesSnakeCaseSummary() async throws {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/api/items/native-smoke/context")
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"status":"ready","url":"/audio/native-smoke.mp3","context_summary":"Context from server."}"#.utf8))
    }

    let response = try await client.contextStatus(slug: "native-smoke")

    XCTAssertEqual(response.status, "ready")
    XCTAssertEqual(response.url, "/audio/native-smoke.mp3")
    XCTAssertEqual(response.summary, "Context from server.")
  }

  func testAbsoluteURLResolvesRelativeMediaPathAgainstServer() {
    let client = makeClient()

    XCTAssertEqual(
      client.absoluteURL(for: "/tts-cache/native-smoke.mp3")?.absoluteString,
      "http://localhost:3457/tts-cache/native-smoke.mp3"
    )
    XCTAssertEqual(
      client.absoluteURL(for: "https://assets.example/native-smoke.mp3")?.absoluteString,
      "https://assets.example/native-smoke.mp3"
    )
    XCTAssertNil(client.absoluteURL(for: nil))
  }

  func testAbsoluteURLResolvesFollowupReviewPathAgainstServer() {
    let client = makeClient()

    XCTAssertEqual(
      client.absoluteURL(for: "/review/followup-clarify-window")?.absoluteString,
      "http://localhost:3457/review/followup-clarify-window"
    )
  }

  func testAbsoluteURLPreservesMediaQueryAndFragment() {
    let client = makeClient()

    XCTAssertEqual(
      client.absoluteURL(for: "/tts-cache/native-smoke.mp3?token=abc#clip")?.absoluteString,
      "http://localhost:3457/tts-cache/native-smoke.mp3?token=abc#clip"
    )
    XCTAssertEqual(
      client.absoluteURL(for: "tts-cache/native-smoke.mp3?token=abc#clip")?.absoluteString,
      "http://localhost:3457/tts-cache/native-smoke.mp3?token=abc#clip"
    )
  }

  func testAbsoluteURLPreservesConfiguredBasePath() {
    let client = makeClient(serverURL: URL(string: "https://turf.example.com/native")!)

    XCTAssertEqual(
      client.absoluteURL(for: "/tts-cache/native-smoke.mp3?token=abc#clip")?.absoluteString,
      "https://turf.example.com/native/tts-cache/native-smoke.mp3?token=abc#clip"
    )
    XCTAssertEqual(
      client.absoluteURL(for: "tts-cache/native-smoke.mp3")?.absoluteString,
      "https://turf.example.com/native/tts-cache/native-smoke.mp3"
    )
  }

  func testAbsoluteURLTrimsBlankMediaValues() {
    let client = makeClient()

    XCTAssertEqual(
      client.absoluteURL(for: "  /tts-cache/native-smoke.mp3  ")?.absoluteString,
      "http://localhost:3457/tts-cache/native-smoke.mp3"
    )
    XCTAssertNil(client.absoluteURL(for: "  "))
  }

  func testAbsoluteURLRejectsNonWebSchemes() {
    let client = makeClient()

    XCTAssertNil(client.absoluteURL(for: "file:///tmp/native-smoke.mp3"))
    XCTAssertNil(client.absoluteURL(for: "javascript:alert(1)"))
  }

  func testLoginPageThrowsActionableError() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html; charset=utf-8"]
      )!
      return (response, Data("<html><body>Login</body></html>".utf8))
    }

    do {
      _ = try await client.listItems()
      XCTFail("Expected login-page response to fail.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Basic Auth credentials"), error.localizedDescription)
    }
  }

  func testUnauthorizedLoginPageThrowsActionableError() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html; charset=utf-8"]
      )!
      return (response, Data("<html><body>Unauthorized</body></html>".utf8))
    }

    do {
      _ = try await client.listItems()
      XCTFail("Expected unauthorized login-page response to fail.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Basic Auth credentials"), error.localizedDescription)
      XCTAssertFalse(error.localizedDescription.contains("<html>"), error.localizedDescription)
    }
  }

  func testLoginRedirectThrowsActionableError() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 302,
        httpVersion: nil,
        headerFields: ["Location": "/login"]
      )!
      return (response, Data())
    }

    do {
      _ = try await client.listItems()
      XCTFail("Expected login redirect to fail.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Basic Auth credentials"), error.localizedDescription)
      XCTAssertFalse(error.localizedDescription.contains("Server returned 302"), error.localizedDescription)
    }
  }

  func testBadStatusUsesStructuredDetailMessage() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 409,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"detail":"Review has already left pending."}"#.utf8))
    }

    do {
      _ = try await client.retryLatestAction(slug: "native-smoke")
      XCTFail("Expected structured server error to fail.")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Server returned 409: Review has already left pending.")
    }
  }

  func testMalformedJSONThrowsUnreadableJSONError() async {
    let client = makeClient()
    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"slug":"native-smoke","#.utf8))
    }

    do {
      _ = try await client.getActions(slug: "native-smoke")
      XCTFail("Expected malformed JSON to fail.")
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

  private static let itemsJSON = """
  [
    {
      "id": 7,
      "slug": "native-smoke",
      "title": "Native smoke",
      "category": "outreach",
      "status": "pending",
      "decision": null,
      "actions": "[\\"Send\\",\\"Edit\\",\\"Kill\\"]",
      "feedback": null,
      "rendered_html": "<p>Review body</p>",
      "markdown": null,
      "content_length": 120,
      "action_status": "queued",
      "action_message": "Queued for downstream work.",
      "approval_status": null,
      "approval_message": null,
      "tts_status": "ready",
      "context_status": "ready",
      "context_summary": "Short context.",
      "decision_schema_version": 3,
      "created_at": "2026-06-11 09:00:00",
      "updated_at": "2026-06-11 09:05:00"
    }
  ]
  """
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
