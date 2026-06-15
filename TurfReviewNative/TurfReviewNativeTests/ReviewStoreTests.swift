import XCTest
@testable import TurfReviewNative

@MainActor
final class ReviewStoreTests: XCTestCase {
  private var defaultsSuiteName: String?

  override func setUp() {
    super.setUp()
    let suiteName = "TurfReviewNativeTests.\(UUID().uuidString)"
    defaultsSuiteName = suiteName
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    APIConfiguration.defaultsStore = defaults
    Self.clearSavedConfiguration()
  }

  override func tearDown() {
    Self.clearSavedConfiguration()
    if let defaultsSuiteName {
      UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }
    APIConfiguration.defaultsStore = .standard
    defaultsSuiteName = nil
    super.tearDown()
  }

  func testReviewItemContentLengthLabelUsesReadableText() {
    var short = Fixture.item(slug: "short", title: "Short", status: "pending")
    short.contentLength = 120
    XCTAssertEqual(short.contentLengthLabel, "120 chars")

    var singular = Fixture.item(slug: "singular", title: "Singular", status: "pending")
    singular.contentLength = 1
    XCTAssertEqual(singular.contentLengthLabel, "1 char")

    var long = Fixture.item(slug: "long", title: "Long", status: "pending")
    long.contentLength = 2480
    XCTAssertEqual(long.contentLengthLabel, "2.5k chars")

    var fallback = Fixture.item(slug: "fallback", title: "Fallback", status: "pending")
    fallback.contentLength = nil
    fallback.renderedHTML = nil
    fallback.markdown = String(repeating: "a", count: 1200)
    XCTAssertEqual(fallback.contentLengthLabel, "1.2k chars")

    var empty = Fixture.item(slug: "empty", title: "Empty", status: "pending")
    empty.contentLength = nil
    empty.renderedHTML = nil
    empty.markdown = nil
    XCTAssertEqual(empty.contentLengthLabel, "No body")
  }

  func testDecisionActionPresentationNormalizesFeedbackRequiredActions() {
    XCTAssertTrue(DecisionActionPresentation.requiresFeedback(for: "Rework"))
    XCTAssertTrue(DecisionActionPresentation.requiresFeedback(for: " rework "))
    XCTAssertTrue(DecisionActionPresentation.requiresFeedback(for: "EDIT"))
    XCTAssertFalse(DecisionActionPresentation.requiresFeedback(for: "Execute"))
    XCTAssertFalse(DecisionActionPresentation.requiresFeedback(for: nil))
  }

  func testDecisionActionPresentationNormalizesIcons() {
    XCTAssertEqual(DecisionActionPresentation.icon(for: " send "), "paperplane.fill")
    XCTAssertEqual(DecisionActionPresentation.icon(for: "REWORK"), "pencil.and.outline")
    XCTAssertEqual(DecisionActionPresentation.icon(for: "kill"), "xmark.octagon.fill")
    XCTAssertEqual(DecisionActionPresentation.icon(for: "no further action"), "checkmark.circle.fill")
  }

  func testDecisionActionPresentationUsesReadableLabels() {
    XCTAssertEqual(DecisionActionPresentation.label(for: "no further action"), "No Further Action")
    XCTAssertEqual(DecisionActionPresentation.label(for: "custom_worker_step"), "Custom Worker Step")
    XCTAssertEqual(DecisionActionPresentation.label(for: "  execute  "), "Execute")
  }

  func testReviewDisplayTextLabelsServerTokens() {
    XCTAssertEqual(ReviewDisplayText.statusLabel("pending"), "Pending")
    XCTAssertEqual(ReviewDisplayText.statusLabel("processed"), "Processed")
    XCTAssertEqual(ReviewDisplayText.statusLabel("blocked_decision"), "Blocked Decision")
    XCTAssertEqual(ReviewDisplayText.statusLabel("blocked_system"), "Blocked System")
    XCTAssertEqual(ReviewDisplayText.statusLabel(" waiting_external "), "Waiting External")
    XCTAssertEqual(ReviewDisplayText.kindLabel("agent_build"), "Agent Build")
    XCTAssertEqual(ReviewDisplayText.kindLabel("agent_followup"), "Agent Follow-Up")
    XCTAssertEqual(ReviewDisplayText.kindLabel("create_omnifocus_task"), "OmniFocus Task")
    XCTAssertEqual(ReviewDisplayText.actionLabel("no further action"), "No Further Action")
    XCTAssertEqual(ReviewDisplayText.kindLabel("custom_worker_step"), "Custom Worker Step")
    XCTAssertEqual(ReviewDisplayText.statusLabel("  "), "Unknown")
  }

  func testDecisionRequestProofSummaryUsesPreferredJSONFields() {
    let request = Fixture.request(
      slug: "proof-summary",
      proofJSON: #"{"summary":"Feedback log updated","status":"ok"}"#
    )

    XCTAssertEqual(request.proofSummary, "Feedback log updated")
  }

  func testDecisionRequestProofSummaryFallsBackToCompactJSONFields() {
    let request = Fixture.request(
      slug: "proof-fields",
      proofJSON: #"{"task_count":3,"written":true,"empty":" "}"#
    )

    XCTAssertEqual(request.proofSummary, "Task Count: 3 | Written: true")
  }

  func testDecisionRequestProofSummaryIgnoresMalformedJSON() {
    let request = Fixture.request(slug: "proof-broken", proofJSON: #"{"summary":"unfinished""#)

    XCTAssertNil(request.proofSummary)
  }

  func testRefreshLoadsLiveItemsAndSelectedDetail() async {
    let pending = Fixture.item(slug: "pending-new", title: "Pending new", status: "pending", updatedAt: "2026-06-11 10:00:00")
    let decided = Fixture.item(slug: "decided-old", title: "Decided old", status: "archived", updatedAt: "2026-06-10 10:00:00")
    let service = MockReviewService(items: [decided, pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertFalse(store.isUsingDemoData)
    XCTAssertNil(store.bannerMessage)
    XCTAssertEqual(store.counts[ReviewTab.pending], 1)
    XCTAssertEqual(store.counts[ReviewTab.decided], 1)
    XCTAssertEqual(store.selectedSlug, "pending-new")
    XCTAssertEqual(store.selectedItem?.title, "Pending new")
    XCTAssertEqual(store.contextStatus?.summary, "Context for pending-new")
  }

  func testRefreshSortsMixedServerDateFormatsByActualDate() async {
    let sqliteNewer = Fixture.item(slug: "sqlite-newer", title: "SQLite newer", status: "pending", updatedAt: "2026-06-11 10:00:00")
    let isoOlder = Fixture.item(slug: "iso-older", title: "ISO older", status: "pending", updatedAt: "2026-06-11T09:00:00Z")
    let service = MockReviewService(items: [isoOlder, sqliteNewer])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.items.map(\.slug), ["sqlite-newer", "iso-older"])
    XCTAssertEqual(store.selectedSlug, "sqlite-newer")
    XCTAssertEqual(store.selectedItem?.title, "SQLite newer")
  }

  func testRefreshKeepsNewestItemWhenServerReturnsDuplicateSlugs() async {
    let olderDuplicate = Fixture.item(slug: "duplicate-slug", title: "Older duplicate", status: "pending", updatedAt: "2026-06-11 08:00:00")
    let newerDuplicate = Fixture.item(slug: "duplicate-slug", title: "Newer duplicate", status: "processed", updatedAt: "2026-06-11 10:00:00")
    let otherPending = Fixture.item(slug: "other-pending", title: "Other pending", status: "pending", updatedAt: "2026-06-11 09:00:00")
    let service = MockReviewService(items: [olderDuplicate, otherPending, newerDuplicate])
    service.getItemResponses["duplicate-slug"] = newerDuplicate
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.items.map(\.slug), ["duplicate-slug", "other-pending"])
    XCTAssertEqual(store.items.first?.title, "Newer duplicate")
    XCTAssertEqual(store.counts[.pending], 1)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertEqual(store.selectedSlug, "other-pending")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["other-pending"])

    await store.selectTab(.decided)
    XCTAssertEqual(store.selectedSlug, "duplicate-slug")
    XCTAssertEqual(store.selectedItem?.title, "Newer duplicate")
  }

  func testRefreshNormalizesStatusesForQueueCountsAndSelection() async {
    let pending = Fixture.item(slug: "pending-case", title: "Pending case", status: " PENDING ", updatedAt: "2026-06-11 10:00:00")
    let parked = Fixture.item(slug: "parked-case", title: "Parked case", status: "Parked", updatedAt: "2026-06-11 09:00:00")
    let decided = Fixture.item(slug: "decided-case", title: "Decided case", status: "PROCESSED", updatedAt: "2026-06-11 08:00:00")
    let service = MockReviewService(items: [decided, parked, pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.counts[.pending], 1)
    XCTAssertEqual(store.counts[.parked], 1)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertEqual(store.selectedSlug, "pending-case")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["pending-case"])

    await store.selectTab(.parked)
    XCTAssertEqual(store.selectedSlug, "parked-case")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["parked-case"])

    await store.selectTab(.decided)
    XCTAssertEqual(store.selectedSlug, "decided-case")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["decided-case"])
  }

  func testRefreshTreatsArchivedParkDecisionAsParked() async {
    var parked = Fixture.item(slug: "archived-park", title: "Archived park", status: "archived", updatedAt: "2026-06-11 10:00:00")
    parked.decision = "Park"
    var noted = Fixture.item(slug: "archived-noted", title: "Archived noted", status: "archived", updatedAt: "2026-06-11 09:00:00")
    noted.decision = "Noted"
    let service = MockReviewService(items: [parked, noted])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.counts[.parked], 1)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertEqual(store.selectedSlug, nil)

    await store.selectTab(.parked)
    XCTAssertEqual(store.selectedSlug, "archived-park")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["archived-park"])

    await store.selectTab(.decided)
    XCTAssertEqual(store.selectedSlug, "archived-noted")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["archived-noted"])
  }

  func testRefreshFallsBackToDemoDataWhenConfigured() async {
    let service = MockReviewService(items: [])
    service.listItemsError = TestError("Server unavailable")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: true),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertTrue(store.isUsingDemoData)
    XCTAssertTrue(store.bannerMessage?.contains("Showing demo data.") == true)
    XCTAssertEqual(store.selectedSlug, DemoData.items.first?.slug)
    XCTAssertEqual(store.selectedItem?.slug, DemoData.items.first?.slug)
    XCTAssertEqual(store.chatMessages.first?.role, "assistant")
  }

  func testRefreshFailureKeepsLiveQueueInsteadOfDemoFallbackAfterLiveLoad() async {
    let live = Fixture.item(slug: "live-before-outage", title: "Live before outage", status: "pending")
    let service = MockReviewService(items: [live])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: true),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("Server unavailable")

    await store.refresh()

    XCTAssertFalse(store.isUsingDemoData)
    XCTAssertEqual(store.items.map(\.slug), ["live-before-outage"])
    XCTAssertEqual(store.selectedSlug, "live-before-outage")
    XCTAssertEqual(store.selectedItem?.slug, "live-before-outage")
    XCTAssertEqual(store.bannerMessage, "Server unavailable")
  }

  func testSavingConfigurationClearsOldQueueWhenNewServerRefreshFails() async {
    let old = Fixture.item(slug: "old-server", title: "Old server", status: "pending")
    let service = MockReviewService(items: [old])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("New server unavailable")
    defer { Self.clearSavedConfiguration() }

    await store.saveConfiguration(
      APIConfiguration(
        serverURL: URL(string: "http://new-server.local:3457")!,
        username: "",
        password: "",
        useDemoOnFailure: false
      )
    )

    XCTAssertEqual(store.configuration.serverURL.absoluteString, "http://new-server.local:3457")
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertNil(store.selectedSlug)
    XCTAssertNil(store.selectedItem)
    XCTAssertEqual(store.counts[.pending], 0)
    XCTAssertEqual(store.bannerMessage, "New server unavailable")
    XCTAssertFalse(store.isUsingDemoData)
  }

  func testSavingConfigurationCanStillFallBackToDemoData() async {
    let old = Fixture.item(slug: "old-server-demo", title: "Old server demo", status: "pending")
    let service = MockReviewService(items: [old])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("New server unavailable")
    defer { Self.clearSavedConfiguration() }

    await store.saveConfiguration(
      APIConfiguration(
        serverURL: URL(string: "http://new-server.local:3457")!,
        username: "",
        password: "",
        useDemoOnFailure: true
      )
    )

    XCTAssertTrue(store.isUsingDemoData)
    XCTAssertEqual(store.selectedSlug, DemoData.items.first?.slug)
    XCTAssertEqual(store.selectedItem?.slug, DemoData.items.first?.slug)
    XCTAssertTrue(store.bannerMessage?.contains("Showing demo data.") == true)
  }

  func testSlowDecisionDoesNotMutateSameSlugAfterConfigurationChange() async {
    let old = Fixture.item(slug: "shared-decision", title: "Old server decision", status: "pending")
    let new = Fixture.item(slug: "shared-decision", title: "New server decision", status: "pending")
    let oldService = MockReviewService(items: [old])
    let newService = MockReviewService(items: [new])
    oldService.delayedDecisionSlug = "shared-decision"
    let slowDecisionStarted = expectation(description: "slow decision started before configuration change")
    oldService.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let oldConfiguration = APIConfiguration(
      serverURL: URL(string: "http://old-server.local:3457")!,
      username: "",
      password: "",
      useDemoOnFailure: false
    )
    let newConfiguration = APIConfiguration(
      serverURL: URL(string: "http://new-server.local:3457")!,
      username: "",
      password: "",
      useDemoOnFailure: false
    )
    let store = ReviewStore(
      configuration: oldConfiguration,
      clientFactory: { configuration in
        configuration.serverURL.host == "new-server.local" ? newService : oldService
      }
    )
    defer { Self.clearSavedConfiguration() }
    await store.refresh()

    let slowTask = Task {
      await store.submitDecision("Execute", feedback: "Ship it.")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)
    await store.saveConfiguration(newConfiguration)

    XCTAssertEqual(store.selectedSlug, "shared-decision")
    XCTAssertEqual(store.selectedItem?.title, "New server decision")

    oldService.releaseDelayedDecision()
    await slowTask.value

    XCTAssertEqual(oldService.decisions.map(\.decision), ["Execute"])
    XCTAssertTrue(newService.decisions.isEmpty)
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "shared-decision")
    XCTAssertEqual(store.selectedItem?.title, "New server decision")
    XCTAssertEqual(store.selectedItem?.status, "pending")
    XCTAssertNil(store.selectedItem?.decision)
    XCTAssertNil(store.bannerMessage)
  }

  func testSlowAnnotationCreateDoesNotAppendToSameSlugAfterConfigurationChange() async {
    let old = Fixture.item(slug: "shared-note", title: "Old server note", status: "pending")
    let new = Fixture.item(slug: "shared-note", title: "New server note", status: "pending")
    let oldService = MockReviewService(items: [old])
    let newService = MockReviewService(items: [new])
    oldService.annotationIDs = ["shared-note": 1]
    newService.annotationIDs = ["shared-note": 2]
    oldService.delayedCreateAnnotationSlug = "shared-note"
    let slowCreateStarted = expectation(description: "slow annotation create started before configuration change")
    oldService.delayedCreateAnnotationStarted = {
      slowCreateStarted.fulfill()
    }
    let oldConfiguration = APIConfiguration(
      serverURL: URL(string: "http://old-server.local:3457")!,
      username: "",
      password: "",
      useDemoOnFailure: false
    )
    let newConfiguration = APIConfiguration(
      serverURL: URL(string: "http://new-server.local:3457")!,
      username: "",
      password: "",
      useDemoOnFailure: false
    )
    let store = ReviewStore(
      configuration: oldConfiguration,
      clientFactory: { configuration in
        configuration.serverURL.host == "new-server.local" ? newService : oldService
      }
    )
    defer { Self.clearSavedConfiguration() }
    await store.refresh()

    let slowTask = Task {
      await store.createAnnotation(quote: nil, anchorRef: nil, comment: "Old server note")
    }
    await fulfillment(of: [slowCreateStarted], timeout: 1)
    await store.saveConfiguration(newConfiguration)

    XCTAssertEqual(store.selectedSlug, "shared-note")
    XCTAssertEqual(store.selectedItem?.title, "New server note")
    XCTAssertEqual(store.annotations.map(\.id), [2])

    oldService.releaseDelayedCreateAnnotation()
    let didSave = await slowTask.value

    XCTAssertFalse(didSave)
    XCTAssertEqual(store.annotations.map(\.id), [2])
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for shared-note"])
    XCTAssertNil(store.bannerMessage)
  }

  func testConfigurationChangeClearsInFlightDecisionGateForSameSlug() async {
    let old = Fixture.item(slug: "shared-gate-decision", title: "Old gate decision", status: "pending")
    let new = Fixture.item(slug: "shared-gate-decision", title: "New gate decision", status: "pending")
    let oldService = MockReviewService(items: [old])
    let newService = MockReviewService(items: [new])
    oldService.delayedDecisionSlug = "shared-gate-decision"
    let slowDecisionStarted = expectation(description: "old decision started before configuration change")
    oldService.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let oldConfiguration = APIConfiguration.test(serverHost: "old-server.local", useDemoOnFailure: false)
    let newConfiguration = APIConfiguration.test(serverHost: "new-server.local", useDemoOnFailure: false)
    let store = ReviewStore(
      configuration: oldConfiguration,
      clientFactory: { configuration in
        configuration.serverURL.host == "new-server.local" ? newService : oldService
      }
    )
    defer { Self.clearSavedConfiguration() }
    await store.refresh()

    let oldTask = Task {
      await store.submitDecision("Execute", feedback: "Old server")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)
    await store.saveConfiguration(newConfiguration)

    await store.submitDecision("Kill", feedback: "New server")

    XCTAssertEqual(newService.decisions.map(\.decision), ["Kill"])
    XCTAssertEqual(store.selectedSlug, "shared-gate-decision")
    XCTAssertEqual(store.selectedItem?.title, "New gate decision")
    XCTAssertEqual(store.selectedItem?.decision, "Kill")
    XCTAssertEqual(store.bannerMessage, "Kill saved.")

    oldService.releaseDelayedDecision()
    await oldTask.value

    XCTAssertEqual(oldService.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(newService.decisions.map(\.decision), ["Kill"])
    XCTAssertEqual(store.selectedItem?.title, "New gate decision")
    XCTAssertEqual(store.selectedItem?.decision, "Kill")
  }

  func testConfigurationChangeClearsInFlightRetryGateForSameSlug() async {
    let old = Fixture.item(slug: "shared-gate-retry", title: "Old gate retry", status: "processed")
    let new = Fixture.item(slug: "shared-gate-retry", title: "New gate retry", status: "processed")
    let oldService = MockReviewService(items: [old])
    let newService = MockReviewService(items: [new])
    oldService.delayedRetrySlug = "shared-gate-retry"
    let slowRetryStarted = expectation(description: "old retry started before configuration change")
    oldService.delayedRetryStarted = {
      slowRetryStarted.fulfill()
    }
    let oldConfiguration = APIConfiguration.test(serverHost: "old-server.local", useDemoOnFailure: false)
    let newConfiguration = APIConfiguration.test(serverHost: "new-server.local", useDemoOnFailure: false)
    let store = ReviewStore(
      configuration: oldConfiguration,
      clientFactory: { configuration in
        configuration.serverURL.host == "new-server.local" ? newService : oldService
      }
    )
    defer { Self.clearSavedConfiguration() }
    await store.refresh()
    await store.selectTab(.decided)

    let oldTask = Task {
      await store.retryLatestAction()
    }
    await fulfillment(of: [slowRetryStarted], timeout: 1)
    await store.saveConfiguration(newConfiguration)

    await store.retryLatestAction()

    XCTAssertEqual(newService.retryCalls, ["shared-gate-retry"])
    XCTAssertEqual(store.selectedSlug, "shared-gate-retry")
    XCTAssertEqual(store.selectedItem?.title, "New gate retry")
    XCTAssertEqual(store.bannerMessage, "Retry queued.")

    oldService.releaseDelayedRetry()
    await oldTask.value

    XCTAssertEqual(oldService.retryCalls, ["shared-gate-retry"])
    XCTAssertEqual(newService.retryCalls, ["shared-gate-retry"])
    XCTAssertEqual(store.selectedItem?.title, "New gate retry")
    XCTAssertEqual(store.bannerMessage, "Retry queued.")
  }

  func testConfigurationChangeClearsInFlightChatGateForSameSlug() async {
    let old = Fixture.item(slug: "shared-gate-chat", title: "Old gate chat", status: "pending")
    let new = Fixture.item(slug: "shared-gate-chat", title: "New gate chat", status: "pending")
    let oldService = MockReviewService(items: [old])
    let newService = MockReviewService(items: [new])
    oldService.delayedSendChatSlug = "shared-gate-chat"
    let slowSendStarted = expectation(description: "old chat send started before configuration change")
    oldService.delayedSendChatStarted = {
      slowSendStarted.fulfill()
    }
    let oldConfiguration = APIConfiguration.test(serverHost: "old-server.local", useDemoOnFailure: false)
    let newConfiguration = APIConfiguration.test(serverHost: "new-server.local", useDemoOnFailure: false)
    let store = ReviewStore(
      configuration: oldConfiguration,
      clientFactory: { configuration in
        configuration.serverURL.host == "new-server.local" ? newService : oldService
      }
    )
    defer { Self.clearSavedConfiguration() }
    await store.refresh()

    let oldTask = Task {
      await store.sendChat("Old server question")
    }
    await fulfillment(of: [slowSendStarted], timeout: 1)
    await store.saveConfiguration(newConfiguration)

    let didSend = await store.sendChat("New server question")

    XCTAssertTrue(didSend)
    XCTAssertEqual(newService.sendChatCalls.map(\.message), ["New server question"])
    XCTAssertEqual(store.selectedSlug, "shared-gate-chat")
    XCTAssertEqual(store.selectedItem?.title, "New gate chat")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for shared-gate-chat", "New server question", "Reply for shared-gate-chat"])

    oldService.releaseDelayedSendChat()
    let oldDidSend = await oldTask.value

    XCTAssertTrue(oldDidSend)
    XCTAssertEqual(oldService.sendChatCalls.map(\.message), ["Old server question"])
    XCTAssertEqual(newService.sendChatCalls.map(\.message), ["New server question"])
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for shared-gate-chat", "New server question", "Reply for shared-gate-chat"])
  }

  func testSlowRefreshDoesNotReplaceNewerRefresh() async {
    let stale = Fixture.item(slug: "stale", title: "Stale item", status: "pending", updatedAt: "2026-06-11 09:00:00")
    let fresh = Fixture.item(slug: "fresh", title: "Fresh item", status: "pending", updatedAt: "2026-06-11 10:00:00")
    let service = MockReviewService(items: [])
    service.listResponses = [[stale], [fresh]]
    service.delayNextList = true
    let slowListStarted = expectation(description: "slow list request started")
    service.delayedListStarted = {
      slowListStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    let staleTask = Task {
      await store.refresh()
    }
    await fulfillment(of: [slowListStarted], timeout: 1)

    await store.refresh()
    service.releaseDelayedList()
    await staleTask.value

    XCTAssertEqual(store.items.map(\.slug), ["fresh"])
    XCTAssertEqual(store.selectedSlug, "fresh")
    XCTAssertEqual(store.selectedItem?.title, "Fresh item")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for fresh"])
    XCTAssertFalse(store.isLoading)
  }

  func testRefreshClearsQueueLoadingBeforeSlowDetailCompletes() async {
    let pending = Fixture.item(slug: "slow-detail-after-list", title: "Slow detail after list", status: "pending")
    let service = MockReviewService(items: [pending])
    service.delayedItemSlug = "slow-detail-after-list"
    let detailStarted = expectation(description: "detail request started")
    service.delayedItemStarted = {
      detailStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    let refreshTask = Task {
      await store.refresh()
    }
    await fulfillment(of: [detailStarted], timeout: 1)

    XCTAssertEqual(store.items.map(\.slug), ["slow-detail-after-list"])
    XCTAssertEqual(store.selectedSlug, "slow-detail-after-list")
    XCTAssertFalse(store.isLoading)
    XCTAssertTrue(store.detailLoading)

    service.releaseDelayedItem()
    await refreshTask.value

    XCTAssertEqual(store.selectedItem?.slug, "slow-detail-after-list")
    XCTAssertFalse(store.isLoading)
    XCTAssertFalse(store.detailLoading)
  }

  func testSlowDetailResponseDoesNotReplaceNewerSelection() async {
    let slow = Fixture.item(slug: "slow", title: "Slow item", status: "pending")
    let fast = Fixture.item(slug: "fast", title: "Fast item", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedItemSlug = "slow"
    let slowStarted = expectation(description: "slow detail request started")
    service.delayedItemStarted = {
      slowStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    let slowTask = Task {
      await store.loadDetail(slug: "slow")
    }
    await fulfillment(of: [slowStarted], timeout: 1)

    await store.loadDetail(slug: "fast")
    service.releaseDelayedItem()
    await slowTask.value

    XCTAssertEqual(store.selectedSlug, "fast")
    XCTAssertEqual(store.selectedItem?.title, "Fast item")
    XCTAssertEqual(store.annotations.map { $0.comment }, ["Annotation for fast"])
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for fast"])
    XCTAssertFalse(store.detailLoading)
  }

  func testDetailLoadsReviewTargetsAndSummary() async {
    let pending = Fixture.item(slug: "target-review", title: "Target review", status: "pending")
    let targets = [
      Fixture.target(key: "target-a", label: "Approve venue list"),
      Fixture.target(key: "target-b", label: "Reject unverified supplier", verdict: "approved"),
    ]
    let service = MockReviewService(items: [pending])
    service.targetResponses["target-review"] = ReviewTargetsResponse(
      slug: "target-review",
      targets: targets,
      summary: ReviewStoreSummaryFactory.summary(for: targets)
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.reviewTargets.map(\.key), ["target-a", "target-b"])
    XCTAssertEqual(store.reviewTargetSummary.total, 2)
    XCTAssertEqual(store.reviewTargetSummary.approved, 1)
    XCTAssertEqual(store.reviewTargetSummary.undecided, 1)
    XCTAssertFalse(store.reviewTargetSummary.complete)
  }

  func testUpdateReviewTargetUpdatesRowAndSummary() async {
    let pending = Fixture.item(slug: "target-update", title: "Target update", status: "pending")
    let target = Fixture.target(key: "target-update-a", label: "Approve send list")
    let service = MockReviewService(items: [pending])
    service.targetResponses["target-update"] = ReviewTargetsResponse(
      slug: "target-update",
      targets: [target],
      summary: ReviewStoreSummaryFactory.summary(for: [target])
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSave = await store.updateReviewTarget(target, verdict: "rejected", feedback: "Missing source.")

    XCTAssertTrue(didSave)
    XCTAssertEqual(service.updateTargetCalls.map(\.slug), ["target-update"])
    XCTAssertEqual(service.updateTargetCalls.map(\.targetKey), ["target-update-a"])
    XCTAssertEqual(service.updateTargetCalls.map(\.verdict), ["rejected"])
    XCTAssertEqual(store.reviewTargets.first?.verdict, "rejected")
    XCTAssertEqual(store.reviewTargets.first?.feedback, "Missing source.")
    XCTAssertEqual(store.reviewTargetSummary.rejected, 1)
    XCTAssertTrue(store.reviewTargetSummary.complete)
  }

  func testSlowReviewTargetUpdateDoesNotMutateNewerSelection() async {
    let slow = Fixture.item(slug: "slow-target", title: "Slow target", status: "pending")
    let fast = Fixture.item(slug: "fast-target", title: "Fast target", status: "pending")
    let slowTarget = Fixture.target(key: "slow-target-a", label: "Approve slow list")
    let fastTarget = Fixture.target(key: "fast-target-a", label: "Approve fast list")
    let service = MockReviewService(items: [slow, fast])
    service.targetResponses["slow-target"] = ReviewTargetsResponse(
      slug: "slow-target",
      targets: [slowTarget],
      summary: ReviewStoreSummaryFactory.summary(for: [slowTarget])
    )
    service.targetResponses["fast-target"] = ReviewTargetsResponse(
      slug: "fast-target",
      targets: [fastTarget],
      summary: ReviewStoreSummaryFactory.summary(for: [fastTarget])
    )
    service.delayedUpdateTargetKey = "slow-target-a"
    let slowUpdateStarted = expectation(description: "slow target update started")
    service.delayedUpdateTargetStarted = {
      slowUpdateStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "slow-target")
    let slowTask = Task {
      await store.updateReviewTarget(slowTarget, verdict: "approved")
    }
    await fulfillment(of: [slowUpdateStarted], timeout: 1)

    await store.loadDetail(slug: "fast-target")
    service.releaseDelayedUpdateTarget()
    let didSave = await slowTask.value

    XCTAssertTrue(didSave)
    XCTAssertEqual(service.updateTargetCalls.map(\.slug), ["slow-target"])
    XCTAssertEqual(store.selectedSlug, "fast-target")
    XCTAssertEqual(store.selectedItem?.title, "Fast target")
    XCTAssertEqual(store.reviewTargets.map(\.key), ["fast-target-a"])
    XCTAssertTrue(store.reviewTargets.first?.isUnset == true)
  }

  func testReviewTargetUpdatingStateIsScopedBySlug() async {
    let slow = Fixture.item(slug: "same-key-slow", title: "Same key slow", status: "pending")
    let fast = Fixture.item(slug: "same-key-fast", title: "Same key fast", status: "pending")
    let sharedSlowTarget = Fixture.target(key: "shared-target-key", label: "Approve shared label")
    let sharedFastTarget = Fixture.target(key: "shared-target-key", label: "Approve shared label")
    let service = MockReviewService(items: [slow, fast])
    service.targetResponses["same-key-slow"] = ReviewTargetsResponse(
      slug: "same-key-slow",
      targets: [sharedSlowTarget],
      summary: ReviewStoreSummaryFactory.summary(for: [sharedSlowTarget])
    )
    service.targetResponses["same-key-fast"] = ReviewTargetsResponse(
      slug: "same-key-fast",
      targets: [sharedFastTarget],
      summary: ReviewStoreSummaryFactory.summary(for: [sharedFastTarget])
    )
    service.delayedUpdateTargetKey = "shared-target-key"
    let slowUpdateStarted = expectation(description: "same-key slow target update started")
    service.delayedUpdateTargetStarted = {
      slowUpdateStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "same-key-slow")
    let slowTask = Task {
      await store.updateReviewTarget(sharedSlowTarget, verdict: "approved")
    }
    await fulfillment(of: [slowUpdateStarted], timeout: 1)

    service.delayedUpdateTargetKey = nil
    await store.loadDetail(slug: "same-key-fast")
    let didSaveFastTarget = await store.updateReviewTarget(sharedFastTarget, verdict: "rejected", feedback: "Fast rejected.")

    XCTAssertTrue(didSaveFastTarget)
    XCTAssertEqual(service.updateTargetCalls.map(\.slug), ["same-key-slow", "same-key-fast"])
    XCTAssertEqual(store.selectedSlug, "same-key-fast")
    XCTAssertEqual(store.reviewTargets.first?.verdict, "rejected")

    service.releaseDelayedUpdateTarget()
    _ = await slowTask.value

    XCTAssertEqual(store.selectedSlug, "same-key-fast")
    XCTAssertEqual(store.reviewTargets.first?.verdict, "rejected")
  }

  func testConfigurationChangeClearsInFlightReviewTargetGateForSameSlug() async {
    let old = Fixture.item(slug: "shared-target", title: "Old target server", status: "pending")
    let new = Fixture.item(slug: "shared-target", title: "New target server", status: "pending")
    let target = Fixture.target(key: "shared-target-a", label: "Approve shared list")
    let oldService = MockReviewService(items: [old])
    let newService = MockReviewService(items: [new])
    oldService.targetResponses["shared-target"] = ReviewTargetsResponse(
      slug: "shared-target",
      targets: [target],
      summary: ReviewStoreSummaryFactory.summary(for: [target])
    )
    newService.targetResponses["shared-target"] = ReviewTargetsResponse(
      slug: "shared-target",
      targets: [target],
      summary: ReviewStoreSummaryFactory.summary(for: [target])
    )
    oldService.delayedUpdateTargetKey = "shared-target-a"
    let slowUpdateStarted = expectation(description: "old target update started before configuration change")
    oldService.delayedUpdateTargetStarted = {
      slowUpdateStarted.fulfill()
    }
    let oldConfiguration = APIConfiguration.test(serverHost: "old-server.local", useDemoOnFailure: false)
    let newConfiguration = APIConfiguration.test(serverHost: "new-server.local", useDemoOnFailure: false)
    let store = ReviewStore(
      configuration: oldConfiguration,
      clientFactory: { configuration in
        configuration.serverURL.host == "new-server.local" ? newService : oldService
      }
    )
    defer { Self.clearSavedConfiguration() }
    await store.refresh()

    let oldTask = Task {
      await store.updateReviewTarget(target, verdict: "approved")
    }
    await fulfillment(of: [slowUpdateStarted], timeout: 1)
    await store.saveConfiguration(newConfiguration)

    let didSaveNewTarget = await store.updateReviewTarget(target, verdict: "rejected", feedback: "New server rejected.")

    XCTAssertTrue(didSaveNewTarget)
    XCTAssertEqual(newService.updateTargetCalls.map(\.targetKey), ["shared-target-a"])
    XCTAssertEqual(store.selectedSlug, "shared-target")
    XCTAssertEqual(store.selectedItem?.title, "New target server")
    XCTAssertEqual(store.reviewTargets.first?.verdict, "rejected")
    XCTAssertEqual(store.reviewTargets.first?.feedback, "New server rejected.")

    oldService.releaseDelayedUpdateTarget()
    _ = await oldTask.value

    XCTAssertEqual(oldService.updateTargetCalls.map(\.targetKey), ["shared-target-a"])
    XCTAssertEqual(newService.updateTargetCalls.map(\.verdict), ["rejected"])
    XCTAssertEqual(store.selectedItem?.title, "New target server")
    XCTAssertEqual(store.reviewTargets.first?.verdict, "rejected")
  }

  func testFailedDetailSelectionClearsStaleDetail() async {
    let old = Fixture.item(slug: "old", title: "Old item", status: "pending", updatedAt: "2026-06-11 10:00:00")
    let broken = Fixture.item(slug: "broken", title: "Broken item", status: "pending", updatedAt: "2026-06-11 09:00:00")
    let service = MockReviewService(items: [old, broken])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.getItemErrors["broken"] = TestError("Detail unavailable")

    await store.selectItem(slug: "broken")

    XCTAssertEqual(store.selectedSlug, "broken")
    XCTAssertEqual(store.selectedItem?.title, "Broken item")
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.chatMessages.isEmpty)
    XCTAssertEqual(store.ttsStatus?.status, "ready")
    XCTAssertEqual(store.contextStatus?.summary, "Context for broken")
    XCTAssertEqual(store.bannerMessage, "Detail unavailable")
    XCTAssertFalse(store.detailLoading)
  }

  func testWrongSlugDetailResponseKeepsQueueItemAndClearsDetailSections() async {
    let requested = Fixture.item(slug: "detail-mismatch", title: "Requested item", status: "pending")
    let wrong = Fixture.item(slug: "other-detail", title: "Wrong item", status: "pending")
    let service = MockReviewService(items: [requested])
    service.getItemResponses["detail-mismatch"] = wrong
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.selectedSlug, "detail-mismatch")
    XCTAssertEqual(store.selectedItem?.title, "Requested item")
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertTrue(store.chatMessages.isEmpty)
    XCTAssertEqual(store.bannerMessage, "Server returned review data for other-detail, not detail-mismatch.")
    XCTAssertFalse(store.detailLoading)
  }

  func testFailedSameSlugDetailReloadKeepsExistingDetail() async {
    let pending = Fixture.item(slug: "same-broken", title: "Same broken", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for same-broken"])
    XCTAssertEqual(store.decisionRequests.count, 0)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for same-broken"])
    XCTAssertEqual(store.ttsStatus?.url, "/tts-cache/same-broken.mp3")
    XCTAssertEqual(store.contextStatus?.url, "/audio/same-broken.mp3")

    service.getItemErrors["same-broken"] = TestError("Detail reload unavailable")
    await store.loadDetail(slug: "same-broken")

    XCTAssertEqual(store.selectedSlug, "same-broken")
    XCTAssertEqual(store.selectedItem?.title, "Same broken")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for same-broken"])
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for same-broken"])
    XCTAssertEqual(store.ttsStatus?.status, "ready")
    XCTAssertEqual(store.ttsStatus?.url, "/tts-cache/same-broken.mp3")
    XCTAssertEqual(store.contextStatus?.status, "ready")
    XCTAssertEqual(store.contextStatus?.url, "/audio/same-broken.mp3")
    XCTAssertEqual(store.contextStatus?.summary, "Context for same-broken")
    XCTAssertEqual(store.bannerMessage, "Detail reload unavailable")
    XCTAssertFalse(store.detailLoading)
  }

  func testChatHistoryReloadFailureKeepsExistingSameReviewMessages() async {
    let pending = Fixture.item(slug: "chat-history-reload", title: "Chat history reload", status: "pending")
    let service = MockReviewService(items: [pending])
    service.chatHistoryResponses["chat-history-reload"] = ChatHistoryResponse(
      sessionKey: "session-chat-history-reload",
      messages: [
        ChatMessage(role: "assistant", content: "Existing answer", createdAt: nil),
        ChatMessage(role: "user", content: "Existing question", createdAt: nil),
      ]
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    XCTAssertEqual(store.chatMessages.map(\.content), ["Existing answer", "Existing question"])
    service.chatHistoryErrors["chat-history-reload"] = TestError("Chat history unavailable")
    await store.loadDetail(slug: "chat-history-reload")

    XCTAssertEqual(store.selectedSlug, "chat-history-reload")
    XCTAssertEqual(
      store.chatMessages.map(\.content),
      ["Existing answer", "Existing question", "Chat history unavailable"]
    )
  }

  func testPartialDetailFailuresKeepCoreReviewUsable() async {
    let pending = Fixture.item(slug: "partial-detail", title: "Partial detail", status: "pending")
    let service = MockReviewService(items: [pending])
    service.annotationErrors["partial-detail"] = TestError("Annotations unavailable")
    service.actionErrors["partial-detail"] = TestError("Proof unavailable")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.selectedSlug, "partial-detail")
    XCTAssertEqual(store.selectedItem?.title, "Partial detail")
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.ttsStatus?.url, "/tts-cache/partial-detail.mp3")
    XCTAssertEqual(store.contextStatus?.summary, "Context for partial-detail")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for partial-detail"])
    XCTAssertEqual(store.bannerMessage, "Some detail sections could not load: Annotations unavailable; Proof unavailable")
    XCTAssertFalse(store.detailLoading)
  }

  func testReviewTargetReloadFailureKeepsRowsAndShowsTargetError() async {
    let pending = Fixture.item(slug: "target-reload", title: "Target reload", status: "pending")
    let target = Fixture.target(key: "target-a", label: "Approve shortlist")
    let service = MockReviewService(items: [pending])
    service.targetResponses["target-reload"] = ReviewTargetsResponse(
      slug: "target-reload",
      targets: [target],
      summary: ReviewStoreSummaryFactory.summary(for: [target])
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    XCTAssertEqual(store.reviewTargets.map(\.label), ["Approve shortlist"])
    service.targetErrors["target-reload"] = TestError("Review targets unavailable")
    await store.loadDetail(slug: "target-reload")

    XCTAssertEqual(store.selectedSlug, "target-reload")
    XCTAssertEqual(store.reviewTargets.map(\.label), ["Approve shortlist"])
    XCTAssertEqual(store.reviewTargetLoadError, "Review targets unavailable")
    XCTAssertEqual(store.bannerMessage, "Some detail sections could not load: Review targets unavailable")
  }

  func testAnnotationReloadFailureKeepsExistingSameReviewAnnotations() async {
    let pending = Fixture.item(slug: "annotation-reload", title: "Annotation reload", status: "pending")
    let service = MockReviewService(items: [pending])
    service.annotationIDs["annotation-reload"] = 37
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for annotation-reload"])
    service.annotationErrors["annotation-reload"] = TestError("Annotations unavailable")
    await store.loadDetail(slug: "annotation-reload")

    XCTAssertEqual(store.selectedSlug, "annotation-reload")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for annotation-reload"])
    XCTAssertEqual(store.annotations.map(\.id), [37])
    XCTAssertEqual(store.bannerMessage, "Some detail sections could not load: Annotations unavailable")
  }

  func testProofReloadFailureKeepsExistingSameReviewActions() async {
    let pending = Fixture.item(slug: "proof-reload", title: "Proof reload", status: "processed")
    let request = DecisionRequest(
      id: 82,
      slug: "proof-reload",
      kind: "agent_followup",
      summary: "Run downstream proof",
      sensitivity: nil,
      status: "queued",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: nil,
      updatedAt: nil
    )
    let action = LegacyAction(
      id: 83,
      slug: "proof-reload",
      decision: "Execute",
      status: "queued",
      lastError: nil
    )
    let service = MockReviewService(items: [pending])
    service.actionResponses["proof-reload"] = ReviewActionsResponse(slug: "proof-reload", requests: [request], legacyActions: [action])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)

    XCTAssertEqual(store.decisionRequests.map(\.id), [82])
    XCTAssertEqual(store.legacyActions.map(\.id), [83])
    service.actionErrors["proof-reload"] = TestError("Proof unavailable")
    await store.loadDetail(slug: "proof-reload")

    XCTAssertEqual(store.selectedSlug, "proof-reload")
    XCTAssertEqual(store.decisionRequests.map(\.id), [82])
    XCTAssertEqual(store.legacyActions.map(\.id), [83])
    XCTAssertEqual(store.bannerMessage, "Some detail sections could not load: Proof unavailable")
  }

  func testWrongSlugActionsAreDroppedWhileCoreDetailStaysLoaded() async {
    let pending = Fixture.item(slug: "proof-mismatch", title: "Proof mismatch", status: "pending")
    let request = DecisionRequest(
      id: 45,
      slug: "another-proof",
      kind: "agent_followup",
      summary: "Wrong proof",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Wrong review",
      updatedAt: nil
    )
    let service = MockReviewService(items: [pending])
    service.actionResponses["proof-mismatch"] = ReviewActionsResponse(slug: "another-proof", requests: [request], legacyActions: [])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.selectedSlug, "proof-mismatch")
    XCTAssertEqual(store.selectedItem?.title, "Proof mismatch")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for proof-mismatch"])
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for proof-mismatch"])
    XCTAssertEqual(store.bannerMessage, "Some detail sections could not load: Server returned proof data for another-proof, not proof-mismatch.")
  }

  func testWrongSlugDecisionRequestIsDroppedWhileCoreDetailStaysLoaded() async {
    let pending = Fixture.item(slug: "request-row-mismatch", title: "Request row mismatch", status: "pending")
    let request = DecisionRequest(
      id: 46,
      slug: "another-request",
      kind: "agent_followup",
      summary: "Wrong proof request",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Wrong review",
      updatedAt: nil
    )
    let service = MockReviewService(items: [pending])
    service.actionResponses["request-row-mismatch"] = ReviewActionsResponse(
      slug: "request-row-mismatch",
      requests: [request],
      legacyActions: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.selectedSlug, "request-row-mismatch")
    XCTAssertEqual(store.selectedItem?.title, "Request row mismatch")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for request-row-mismatch"])
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for request-row-mismatch"])
    XCTAssertEqual(
      store.bannerMessage,
      "Some detail sections could not load: Server returned proof request data for another-request, not request-row-mismatch."
    )
  }

  func testWrongSlugLegacyActionIsDroppedWhileCoreDetailStaysLoaded() async {
    let pending = Fixture.item(slug: "legacy-row-mismatch", title: "Legacy row mismatch", status: "pending")
    let action = LegacyAction(
      id: 47,
      slug: "another-legacy",
      decision: "Execute",
      status: "failed",
      lastError: "Wrong review"
    )
    let service = MockReviewService(items: [pending])
    service.actionResponses["legacy-row-mismatch"] = ReviewActionsResponse(
      slug: "legacy-row-mismatch",
      requests: [],
      legacyActions: [action]
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.selectedSlug, "legacy-row-mismatch")
    XCTAssertEqual(store.selectedItem?.title, "Legacy row mismatch")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for legacy-row-mismatch"])
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for legacy-row-mismatch"])
    XCTAssertEqual(
      store.bannerMessage,
      "Some detail sections could not load: Server returned legacy action data for another-legacy, not legacy-row-mismatch."
    )
  }

  func testAudioDetailFailuresClearStalePlaybackURLs() async {
    let pending = Fixture.item(slug: "stale-audio", title: "Stale audio", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    XCTAssertEqual(store.ttsStatus?.url, "/tts-cache/stale-audio.mp3")
    XCTAssertEqual(store.contextStatus?.url, "/audio/stale-audio.mp3")

    service.ttsErrors["stale-audio"] = TestError("TTS unavailable")
    service.contextErrors["stale-audio"] = TestError("Context unavailable")
    await store.loadDetail(slug: "stale-audio")

    XCTAssertEqual(store.selectedSlug, "stale-audio")
    XCTAssertEqual(store.selectedItem?.title, "Stale audio")
    XCTAssertEqual(store.ttsStatus?.status, "ready")
    XCTAssertNil(store.ttsStatus?.url)
    XCTAssertEqual(store.contextStatus?.status, "ready")
    XCTAssertNil(store.contextStatus?.url)
    XCTAssertEqual(store.contextStatus?.summary, "Context for stale-audio")
    XCTAssertEqual(store.bannerMessage, "Some detail sections could not load: TTS unavailable; Context unavailable")
  }

  func testSlowChatResponseDoesNotReplaceNewerSelection() async {
    let slow = Fixture.item(slug: "slow-chat", title: "Slow chat", status: "pending")
    let fast = Fixture.item(slug: "fast-chat", title: "Fast chat", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedChatSlug = "slow-chat"
    let slowChatStarted = expectation(description: "slow chat request started")
    service.delayedChatStarted = {
      slowChatStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    let slowTask = Task {
      await store.loadDetail(slug: "slow-chat")
    }
    await fulfillment(of: [slowChatStarted], timeout: 1)

    await store.loadDetail(slug: "fast-chat")
    service.releaseDelayedChat()
    await slowTask.value

    XCTAssertEqual(store.selectedSlug, "fast-chat")
    XCTAssertEqual(store.selectedItem?.title, "Fast chat")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for fast-chat"])
  }

  func testSlowAudioResponseDoesNotReplaceNewerSelection() async {
    let slow = Fixture.item(slug: "slow-audio", title: "Slow audio", status: "pending")
    let fast = Fixture.item(slug: "fast-audio", title: "Fast audio", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedTTSSlug = "slow-audio"
    let slowTTSStarted = expectation(description: "slow audio request started")
    service.delayedTTSStarted = {
      slowTTSStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    let slowTask = Task {
      await store.loadDetail(slug: "slow-audio")
    }
    await fulfillment(of: [slowTTSStarted], timeout: 1)

    await store.loadDetail(slug: "fast-audio")
    service.releaseDelayedTTS()
    await slowTask.value

    XCTAssertEqual(store.selectedSlug, "fast-audio")
    XCTAssertEqual(store.selectedItem?.title, "Fast audio")
    XCTAssertEqual(store.ttsStatus?.url, "/tts-cache/fast-audio.mp3")
    XCTAssertEqual(store.contextStatus?.summary, "Context for fast-audio")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for fast-audio"])
  }

  func testSlowSendChatResponseDoesNotAppendToNewerSelection() async {
    let slow = Fixture.item(slug: "slow-send", title: "Slow send", status: "pending")
    let fast = Fixture.item(slug: "fast-send", title: "Fast send", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedSendChatSlug = "slow-send"
    let slowSendStarted = expectation(description: "slow send request started")
    service.delayedSendChatStarted = {
      slowSendStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "slow-send")
    let slowTask = Task {
      await store.sendChat("What should change?")
    }
    await fulfillment(of: [slowSendStarted], timeout: 1)

    await store.loadDetail(slug: "fast-send")
    service.releaseDelayedSendChat()
    let didSend = await slowTask.value

    XCTAssertFalse(didSend)
    XCTAssertEqual(store.selectedSlug, "fast-send")
    XCTAssertEqual(store.selectedItem?.title, "Fast send")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for fast-send"])
  }

  func testFailedSendChatReportsFailureAndKeepsMessageRecoverable() async {
    let pending = Fixture.item(slug: "broken-send", title: "Broken send", status: "pending")
    let service = MockReviewService(items: [pending])
    service.sendChatErrors["broken-send"] = TestError("Chat unavailable")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSend = await store.sendChat("Keep this question")

    XCTAssertFalse(didSend)
    XCTAssertEqual(service.sendChatCalls.map(\.message), ["Keep this question"])
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for broken-send", "Chat unavailable"])
  }

  func testSuccessfulSendChatClearsOnlyLocalFailureMessage() async {
    let pending = Fixture.item(slug: "recover-send", title: "Recover send", status: "pending")
    let service = MockReviewService(items: [pending])
    service.chatHistoryResponses["recover-send"] = ChatHistoryResponse(
      sessionKey: "session-recover-send",
      messages: [
        ChatMessage(role: "system", content: "Server system note", createdAt: nil),
        ChatMessage(role: "assistant", content: "History for recover-send", createdAt: nil),
      ]
    )
    service.sendChatErrors["recover-send"] = TestError("Chat unavailable")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let failedSend = await store.sendChat("First question")
    service.sendChatErrors.removeValue(forKey: "recover-send")
    let recoveredSend = await store.sendChat("Recovered question")

    XCTAssertFalse(failedSend)
    XCTAssertTrue(recoveredSend)
    XCTAssertEqual(service.sendChatCalls.map(\.message), ["First question", "Recovered question"])
    XCTAssertEqual(
      store.chatMessages.map(\.content),
      [
        "Server system note",
        "History for recover-send",
        "Recovered question",
        "Reply for recover-send",
      ]
    )
  }

  func testRepeatedSendChatFailuresKeepOnlyLatestLocalFailureMessage() async {
    let pending = Fixture.item(slug: "repeat-send", title: "Repeat send", status: "pending")
    let service = MockReviewService(items: [pending])
    service.sendChatErrors["repeat-send"] = TestError("First chat failure")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let firstSend = await store.sendChat("First question")
    service.sendChatErrors["repeat-send"] = TestError("Second chat failure")
    let secondSend = await store.sendChat("Second question")

    XCTAssertFalse(firstSend)
    XCTAssertFalse(secondSend)
    XCTAssertEqual(service.sendChatCalls.map(\.message), ["First question", "Second question"])
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for repeat-send", "Second chat failure"])
  }

  func testWrongSessionChatReplyDoesNotAppendAssistantMessage() async {
    let pending = Fixture.item(slug: "wrong-session-chat", title: "Wrong session chat", status: "pending")
    let service = MockReviewService(items: [pending])
    service.sendChatResponses["wrong-session-chat"] = ChatSendResponse(
      sessionKey: "session-other-review",
      message: ChatMessage(role: "assistant", content: "Wrong reply", createdAt: nil)
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSend = await store.sendChat("Keep this question")

    XCTAssertFalse(didSend)
    XCTAssertEqual(service.sendChatCalls.map(\.message), ["Keep this question"])
    XCTAssertEqual(
      store.chatMessages.map(\.content),
      [
        "History for wrong-session-chat",
        "Server returned chat session session-other-review for wrong-session-chat, not session-wrong-session-chat.",
      ]
    )
  }

  func testSendChatReportsSuccessWhenReplyArrives() async {
    let pending = Fixture.item(slug: "good-send", title: "Good send", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSend = await store.sendChat("What matters?")

    XCTAssertTrue(didSend)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for good-send", "What matters?", "Reply for good-send"])
  }

  func testDuplicateChatSendsAreIgnoredWhileInFlight() async {
    let pending = Fixture.item(slug: "duplicate-send", title: "Duplicate send", status: "pending")
    let service = MockReviewService(items: [pending])
    service.delayedSendChatSlug = "duplicate-send"
    let slowSendStarted = expectation(description: "slow send started")
    service.delayedSendChatStarted = {
      slowSendStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let firstTask = Task {
      await store.sendChat("First question")
    }
    await fulfillment(of: [slowSendStarted], timeout: 1)
    let duplicateDidSend = await store.sendChat("Second question")
    service.releaseDelayedSendChat()
    let firstDidSend = await firstTask.value

    XCTAssertTrue(firstDidSend)
    XCTAssertFalse(duplicateDidSend)
    XCTAssertEqual(service.sendChatCalls.map(\.message), ["First question"])
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for duplicate-send", "First question", "Reply for duplicate-send"])
  }

  func testSlowAnnotationCreateDoesNotAppendToNewerSelection() async {
    let slow = Fixture.item(slug: "slow-note", title: "Slow note", status: "pending")
    let fast = Fixture.item(slug: "fast-note", title: "Fast note", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedCreateAnnotationSlug = "slow-note"
    let slowCreateStarted = expectation(description: "slow annotation create started")
    service.delayedCreateAnnotationStarted = {
      slowCreateStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "slow-note")
    let slowTask = Task {
      await store.createAnnotation(quote: nil, anchorRef: nil, comment: "Old note")
    }
    await fulfillment(of: [slowCreateStarted], timeout: 1)

    await store.loadDetail(slug: "fast-note")
    service.releaseDelayedCreateAnnotation()
    let didSave = await slowTask.value

    XCTAssertTrue(didSave)
    XCTAssertEqual(store.selectedSlug, "fast-note")
    XCTAssertEqual(store.selectedItem?.title, "Fast note")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for fast-note"])
    XCTAssertEqual(service.createAnnotationCalls.map(\.slug), ["slow-note"])
  }

  func testFailedAnnotationCreateReportsFailureAndKeepsDraftRecoverable() async {
    let pending = Fixture.item(slug: "broken-note", title: "Broken note", status: "pending")
    let service = MockReviewService(items: [pending])
    service.createAnnotationErrors["broken-note"] = TestError("Could not save annotation")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSave = await store.createAnnotation(quote: "Quoted text", anchorRef: "p:1", comment: "Keep this draft")

    XCTAssertFalse(didSave)
    XCTAssertEqual(store.bannerMessage, "Could not save annotation")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for broken-note"])
  }

  func testWrongSlugAnnotationCreateDoesNotAppendAnnotation() async {
    let pending = Fixture.item(slug: "note-mismatch", title: "Note mismatch", status: "pending")
    let service = MockReviewService(items: [pending])
    service.createAnnotationResponses["note-mismatch"] = ReviewAnnotation(
      id: 99,
      slug: "other-note",
      quote: nil,
      anchorType: "text",
      anchorRef: nil,
      comment: "Wrong note",
      createdAt: nil
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSave = await store.createAnnotation(quote: nil, anchorRef: nil, comment: "Useful note")

    XCTAssertFalse(didSave)
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for note-mismatch"])
    XCTAssertEqual(store.bannerMessage, "Server returned annotation data for other-note, not note-mismatch.")
  }

  func testAnnotationCreateReportsSuccessWhenAnnotationIsSaved() async {
    let pending = Fixture.item(slug: "good-note", title: "Good note", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let didSave = await store.createAnnotation(quote: nil, anchorRef: nil, comment: "Useful note")

    XCTAssertTrue(didSave)
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for good-note", "Useful note"])
  }

  func testImageAnnotationCreateSendsPencilPayloadAndAppendsResponse() async {
    let pending = Fixture.item(slug: "pencil-note", title: "Pencil note", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let annotation = await store.createAnnotationRecord(
      for: "pencil-note",
      quote: nil,
      anchorType: "image",
      anchorRef: "apple-pencil-sketch",
      comment: "Apple Pencil sketch: Move this paragraph.",
      imageData: "c2tldGNo",
      imageMime: "image/png"
    )

    XCTAssertEqual(annotation?.anchorType, "image")
    XCTAssertEqual(annotation?.anchorRef, "apple-pencil-sketch")
    XCTAssertEqual(annotation?.imageData, "c2tldGNo")
    XCTAssertEqual(annotation?.imageMime, "image/png")
    XCTAssertEqual(service.createAnnotationCalls.map(\.slug), ["pencil-note"])
    XCTAssertEqual(service.createAnnotationCalls.first?.anchorType, "image")
    XCTAssertEqual(service.createAnnotationCalls.first?.imageData, "c2tldGNo")
    XCTAssertEqual(service.createAnnotationCalls.first?.imageMime, "image/png")
    XCTAssertEqual(store.annotations.last?.comment, "Apple Pencil sketch: Move this paragraph.")
  }

  func testSuccessfulAnnotationCreateClearsStaleFailureBanner() async {
    let pending = Fixture.item(slug: "recover-note", title: "Recover note", status: "pending")
    let service = MockReviewService(items: [pending])
    service.createAnnotationErrors["recover-note"] = TestError("Could not save annotation")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let failedSave = await store.createAnnotation(quote: nil, anchorRef: nil, comment: "First try")
    service.createAnnotationErrors.removeValue(forKey: "recover-note")
    let recoveredSave = await store.createAnnotation(quote: nil, anchorRef: nil, comment: "Recovered note")

    XCTAssertFalse(failedSave)
    XCTAssertTrue(recoveredSave)
    XCTAssertNil(store.bannerMessage)
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for recover-note", "Recovered note"])
  }

  func testExplicitAnnotationCreateTargetIsPreservedAfterSelectionMoves() async {
    let first = Fixture.item(slug: "explicit-note-a", title: "Explicit note A", status: "pending")
    let second = Fixture.item(slug: "explicit-note-b", title: "Explicit note B", status: "pending")
    let service = MockReviewService(items: [first, second])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectItem(slug: "explicit-note-b")

    let didSave = await store.createAnnotation(
      for: "explicit-note-a",
      quote: "Original quote",
      anchorRef: "p:1",
      comment: "Save to A"
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(service.createAnnotationCalls.map(\.slug), ["explicit-note-a"])
    XCTAssertEqual(service.createAnnotationCalls.first?.quote, "Original quote")
    XCTAssertEqual(service.createAnnotationCalls.first?.anchorRef, "p:1")
    XCTAssertEqual(service.createAnnotationCalls.first?.comment, "Save to A")
    XCTAssertEqual(store.selectedSlug, "explicit-note-b")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for explicit-note-b"])
  }

  func testSlowAnnotationDeleteDoesNotRemoveFromNewerSelection() async {
    let slow = Fixture.item(slug: "slow-delete", title: "Slow delete", status: "pending")
    let fast = Fixture.item(slug: "fast-delete", title: "Fast delete", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.annotationIDs = ["slow-delete": 42, "fast-delete": 42]
    service.delayedDeleteAnnotationSlug = "slow-delete"
    let slowDeleteStarted = expectation(description: "slow annotation delete started")
    service.delayedDeleteAnnotationStarted = {
      slowDeleteStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "slow-delete")
    guard let annotation = store.annotations.first else {
      XCTFail("Missing slow annotation")
      return
    }
    let slowTask = Task {
      await store.deleteAnnotation(annotation)
    }
    await fulfillment(of: [slowDeleteStarted], timeout: 1)

    await store.loadDetail(slug: "fast-delete")
    service.releaseDelayedDeleteAnnotation()
    _ = await slowTask.value

    XCTAssertEqual(store.selectedSlug, "fast-delete")
    XCTAssertEqual(store.selectedItem?.title, "Fast delete")
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for fast-delete"])
    XCTAssertEqual(store.annotations.map(\.id), [42])
  }

  func testExplicitAnnotationDeleteTargetIsPreservedAfterSelectionMoves() async {
    let first = Fixture.item(slug: "explicit-delete-a", title: "Explicit delete A", status: "pending")
    let second = Fixture.item(slug: "explicit-delete-b", title: "Explicit delete B", status: "pending")
    let service = MockReviewService(items: [first, second])
    service.annotationIDs = ["explicit-delete-a": 17, "explicit-delete-b": 23]
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.loadDetail(slug: "explicit-delete-a")
    guard let annotation = store.annotations.first else {
      XCTFail("Missing annotation")
      return
    }
    await store.loadDetail(slug: "explicit-delete-b")

    let didDelete = await store.deleteAnnotation(annotation, for: "explicit-delete-a")

    XCTAssertTrue(didDelete)
    XCTAssertEqual(service.deleteAnnotationCalls.map(\.slug), ["explicit-delete-a"])
    XCTAssertEqual(service.deleteAnnotationCalls.map(\.id), [17])
    XCTAssertEqual(store.selectedSlug, "explicit-delete-b")
    XCTAssertEqual(store.annotations.map(\.id), [23])
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for explicit-delete-b"])
  }

  func testRejectedAnnotationDeleteKeepsAnnotationVisible() async {
    let pending = Fixture.item(slug: "reject-delete", title: "Reject delete", status: "pending")
    let service = MockReviewService(items: [pending])
    service.annotationIDs = ["reject-delete": 7]
    service.deleteAnnotationResponses["reject-delete"] = DeleteAnnotationResponse(
      deleted: false,
      detail: "Annotation was already locked."
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    guard let annotation = store.annotations.first else {
      XCTFail("Missing annotation")
      return
    }

    await store.deleteAnnotation(annotation)

    XCTAssertEqual(store.annotations.map(\.id), [7])
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for reject-delete"])
    XCTAssertEqual(store.bannerMessage, "Annotation was already locked.")
  }

  func testMismatchedAnnotationDeleteIsRejectedBeforeServerCall() async {
    let pending = Fixture.item(slug: "current-delete", title: "Current delete", status: "pending")
    let service = MockReviewService(items: [pending])
    service.annotationIDs = ["current-delete": 7]
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    let staleAnnotation = ReviewAnnotation(
      id: 7,
      slug: "other-delete",
      quote: nil,
      anchorType: "text",
      anchorRef: nil,
      comment: "Stale annotation",
      createdAt: nil
    )

    await store.deleteAnnotation(staleAnnotation)

    XCTAssertTrue(service.deleteAnnotationCalls.isEmpty)
    XCTAssertEqual(store.annotations.map(\.id), [7])
    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for current-delete"])
    XCTAssertEqual(store.bannerMessage, "Annotation belongs to other-delete, not current-delete.")
  }

  func testSuccessfulAnnotationDeleteClearsStaleFailureBanner() async {
    let pending = Fixture.item(slug: "recover-delete", title: "Recover delete", status: "pending")
    let service = MockReviewService(items: [pending])
    service.annotationIDs = ["recover-delete": 9]
    service.deleteAnnotationResponses["recover-delete"] = DeleteAnnotationResponse(
      deleted: false,
      detail: "Annotation was already locked."
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    guard let annotation = store.annotations.first else {
      XCTFail("Missing annotation")
      return
    }

    await store.deleteAnnotation(annotation)
    service.deleteAnnotationResponses.removeValue(forKey: "recover-delete")
    await store.deleteAnnotation(annotation)

    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertNil(store.bannerMessage)
  }

  func testSlowDecisionDoesNotOverrideNewerSelection() async {
    let slow = Fixture.item(slug: "slow-decision", title: "Slow decision", status: "pending")
    let fast = Fixture.item(slug: "fast-decision", title: "Fast decision", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedDecisionSlug = "slow-decision"
    let slowDecisionStarted = expectation(description: "slow decision started")
    service.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "slow-decision")
    let slowTask = Task {
      await store.submitDecision("Execute", feedback: "Ship it.")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)

    await store.loadDetail(slug: "fast-decision")
    service.releaseDelayedDecision()
    await slowTask.value

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "fast-decision")
    XCTAssertEqual(store.selectedItem?.title, "Fast decision")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["fast-decision"])
  }

  func testSlowRetryDoesNotReloadOlderSelection() async {
    let slow = Fixture.item(slug: "slow-retry", title: "Slow retry", status: "pending")
    let fast = Fixture.item(slug: "fast-retry", title: "Fast retry", status: "pending")
    let service = MockReviewService(items: [slow, fast])
    service.delayedRetrySlug = "slow-retry"
    let slowRetryStarted = expectation(description: "slow retry started")
    service.delayedRetryStarted = {
      slowRetryStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.loadDetail(slug: "slow-retry")
    let slowTask = Task {
      await store.retryLatestAction()
    }
    await fulfillment(of: [slowRetryStarted], timeout: 1)

    await store.loadDetail(slug: "fast-retry")
    service.releaseDelayedRetry()
    await slowTask.value

    XCTAssertEqual(service.retryCalls, ["slow-retry"])
    XCTAssertEqual(store.selectedSlug, "fast-retry")
    XCTAssertEqual(store.selectedItem?.title, "Fast retry")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for fast-retry"])
  }

  func testSuccessfulRequestRetryStaysLocallyQueuedWhenDetailReloadFails() async {
    let decided = Fixture.item(slug: "retry-request", title: "Retry request", status: "processed")
    let request = DecisionRequest(
      id: 42,
      slug: "retry-request",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-request"] = ReviewActionsResponse(slug: "retry-request", requests: [request], legacyActions: [])
    service.retryResponses["retry-request"] = RetryResponse(
      ok: true,
      slug: "retry-request",
      request: .init(id: 42, status: "queued", kind: "agent_followup")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.getItemErrors["retry-request"] = TestError("Detail reload unavailable")

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-request"])
    XCTAssertEqual(store.selectedSlug, "retry-request")
    XCTAssertEqual(store.decisionRequests.first?.status, "queued")
    XCTAssertNil(store.decisionRequests.first?.lastError)
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Downstream action processing is queued or waiting for an authoritative system.")
    XCTAssertEqual(store.bannerMessage, "Retry queued.")
  }

  func testSuccessfulRequestRetryStaysQueuedWhenDetailReloadReturnsStaleFailedProof() async {
    var decided = Fixture.item(slug: "retry-request-stale", title: "Retry request stale", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let request = DecisionRequest(
      id: 242,
      slug: "retry-request-stale",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-request-stale"] = ReviewActionsResponse(slug: "retry-request-stale", requests: [request], legacyActions: [])
    service.retryResponses["retry-request-stale"] = RetryResponse(
      ok: true,
      slug: "retry-request-stale",
      request: .init(id: 242, status: "queued", kind: "agent_followup")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)

    await store.retryLatestAction()
    await store.loadDetail(slug: "retry-request-stale")

    XCTAssertEqual(service.retryCalls, ["retry-request-stale"])
    XCTAssertEqual(store.selectedSlug, "retry-request-stale")
    XCTAssertEqual(store.decisionRequests.first?.status, "queued")
    XCTAssertNil(store.decisionRequests.first?.lastError)
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Downstream action processing is queued or waiting for an authoritative system.")
  }

  func testSuccessfulRequestRetrySurvivesStaleQueueRefreshWhenDetailReloadFails() async {
    var decided = Fixture.item(slug: "retry-request-refresh-stale", title: "Retry request refresh stale", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let request = DecisionRequest(
      id: 342,
      slug: "retry-request-refresh-stale",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-request-refresh-stale"] = ReviewActionsResponse(slug: "retry-request-refresh-stale", requests: [request], legacyActions: [])
    service.retryResponses["retry-request-refresh-stale"] = RetryResponse(
      ok: true,
      slug: "retry-request-refresh-stale",
      request: .init(id: 342, status: "queued", kind: "agent_followup")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    await store.retryLatestAction()
    service.getItemErrors["retry-request-refresh-stale"] = TestError("Detail reload unavailable")

    await store.refresh(useDemoFallback: false)

    XCTAssertEqual(service.retryCalls, ["retry-request-refresh-stale"])
    XCTAssertEqual(store.selectedSlug, "retry-request-refresh-stale")
    XCTAssertEqual(store.items.first { $0.slug == "retry-request-refresh-stale" }?.actionStatus, "queued")
    XCTAssertEqual(
      store.items.first { $0.slug == "retry-request-refresh-stale" }?.actionMessage,
      "Downstream action processing is queued or waiting for an authoritative system."
    )
    XCTAssertEqual(store.decisionRequests.first?.status, "queued")
    XCTAssertNil(store.decisionRequests.first?.lastError)
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.bannerMessage, "Detail reload unavailable")
  }

  func testSuccessfulLegacyRetryStaysLocallyQueuedWhenDetailReloadFails() async {
    let decided = Fixture.item(slug: "retry-action", title: "Retry action", status: "processed")
    let action = LegacyAction(id: 7, slug: "retry-action", decision: "Execute", status: "failed", lastError: "Timed out")
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-action"] = ReviewActionsResponse(slug: "retry-action", requests: [], legacyActions: [action])
    service.retryResponses["retry-action"] = RetryResponse(
      ok: true,
      slug: "retry-action",
      action: .init(id: 7, status: "queued", decision: "Execute")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.getItemErrors["retry-action"] = TestError("Detail reload unavailable")

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-action"])
    XCTAssertEqual(store.selectedSlug, "retry-action")
    XCTAssertEqual(store.legacyActions.first?.status, "queued")
    XCTAssertNil(store.legacyActions.first?.lastError)
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Queued Execute action for retry.")
    XCTAssertEqual(store.bannerMessage, "Retry queued.")
  }

  func testSuccessfulLegacyRetryStaysQueuedWhenDetailReloadReturnsStaleFailedProof() async {
    var decided = Fixture.item(slug: "retry-action-stale", title: "Retry action stale", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let action = LegacyAction(id: 207, slug: "retry-action-stale", decision: "Execute", status: "failed", lastError: "Timed out")
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-action-stale"] = ReviewActionsResponse(slug: "retry-action-stale", requests: [], legacyActions: [action])
    service.retryResponses["retry-action-stale"] = RetryResponse(
      ok: true,
      slug: "retry-action-stale",
      action: .init(id: 207, status: "queued", decision: "Execute")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)

    await store.retryLatestAction()
    await store.loadDetail(slug: "retry-action-stale")

    XCTAssertEqual(service.retryCalls, ["retry-action-stale"])
    XCTAssertEqual(store.selectedSlug, "retry-action-stale")
    XCTAssertEqual(store.legacyActions.first?.status, "queued")
    XCTAssertNil(store.legacyActions.first?.lastError)
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Queued Execute action for retry.")
  }

  func testRejectedRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-rejected", title: "Retry rejected", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let request = DecisionRequest(
      id: 43,
      slug: "retry-rejected",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-rejected"] = ReviewActionsResponse(slug: "retry-rejected", requests: [request], legacyActions: [])
    service.retryResponses["retry-rejected"] = RetryResponse(
      ok: false,
      slug: "retry-rejected",
      detail: "Retry refused by queue."
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-rejected"])
    XCTAssertEqual(store.selectedSlug, "retry-rejected")
    XCTAssertEqual(store.decisionRequests.first?.status, "failed")
    XCTAssertEqual(store.decisionRequests.first?.lastError, "Timed out")
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Retry refused by queue.")
    XCTAssertEqual(service.getItemCalls["retry-rejected"] ?? 0, 0)
  }

  func testWrongSlugRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-wrong-slug", title: "Retry wrong slug", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let request = DecisionRequest(
      id: 44,
      slug: "retry-wrong-slug",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-wrong-slug"] = ReviewActionsResponse(slug: "retry-wrong-slug", requests: [request], legacyActions: [])
    service.retryResponses["retry-wrong-slug"] = RetryResponse(
      ok: true,
      slug: "another-review",
      request: .init(id: 44, status: "queued", kind: "agent_followup")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-wrong-slug"])
    XCTAssertEqual(store.selectedSlug, "retry-wrong-slug")
    XCTAssertEqual(store.decisionRequests.first?.status, "failed")
    XCTAssertEqual(store.decisionRequests.first?.lastError, "Timed out")
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Server returned retry state for another-review, not retry-wrong-slug.")
    XCTAssertEqual(service.getItemCalls["retry-wrong-slug"] ?? 0, 0)
  }

  func testWrongRequestRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-wrong-request", title: "Retry wrong request", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let request = DecisionRequest(
      id: 45,
      slug: "retry-wrong-request",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-wrong-request"] = ReviewActionsResponse(
      slug: "retry-wrong-request",
      requests: [request],
      legacyActions: []
    )
    service.retryResponses["retry-wrong-request"] = RetryResponse(
      ok: true,
      slug: "retry-wrong-request",
      request: .init(id: 404, status: "queued", kind: "agent_followup")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-wrong-request"])
    XCTAssertEqual(store.selectedSlug, "retry-wrong-request")
    XCTAssertEqual(store.decisionRequests.first?.status, "failed")
    XCTAssertEqual(store.decisionRequests.first?.lastError, "Timed out")
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Server returned retry state for request 404, not request 45.")
    XCTAssertEqual(service.getItemCalls["retry-wrong-request"] ?? 0, 0)
  }

  func testWrongLegacyActionRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-wrong-action", title: "Retry wrong action", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let action = LegacyAction(
      id: 8,
      slug: "retry-wrong-action",
      decision: "Execute",
      status: "failed",
      lastError: "Timed out"
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-wrong-action"] = ReviewActionsResponse(
      slug: "retry-wrong-action",
      requests: [],
      legacyActions: [action]
    )
    service.retryResponses["retry-wrong-action"] = RetryResponse(
      ok: true,
      slug: "retry-wrong-action",
      action: .init(id: 405, status: "queued", decision: "Execute")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-wrong-action"])
    XCTAssertEqual(store.selectedSlug, "retry-wrong-action")
    XCTAssertEqual(store.legacyActions.first?.status, "failed")
    XCTAssertEqual(store.legacyActions.first?.lastError, "Timed out")
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Server returned retry state for legacy action 405, not legacy action 8.")
    XCTAssertEqual(service.getItemCalls["retry-wrong-action"] ?? 0, 0)
  }

  func testTargetlessRequestRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-targetless-request", title: "Retry targetless request", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let request = DecisionRequest(
      id: 46,
      slug: "retry-targetless-request",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-targetless-request"] = ReviewActionsResponse(
      slug: "retry-targetless-request",
      requests: [request],
      legacyActions: []
    )
    service.retryResponses["retry-targetless-request"] = RetryResponse(ok: true, slug: "retry-targetless-request")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-targetless-request"])
    XCTAssertEqual(store.selectedSlug, "retry-targetless-request")
    XCTAssertEqual(store.decisionRequests.first?.status, "failed")
    XCTAssertEqual(store.decisionRequests.first?.lastError, "Timed out")
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Server accepted retry without returning request 46.")
    XCTAssertEqual(service.getItemCalls["retry-targetless-request"] ?? 0, 0)
  }

  func testTargetlessLegacyActionRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-targetless-action", title: "Retry targetless action", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let action = LegacyAction(
      id: 9,
      slug: "retry-targetless-action",
      decision: "Execute",
      status: "failed",
      lastError: "Timed out"
    )
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-targetless-action"] = ReviewActionsResponse(
      slug: "retry-targetless-action",
      requests: [],
      legacyActions: [action]
    )
    service.retryResponses["retry-targetless-action"] = RetryResponse(ok: true, slug: "retry-targetless-action")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-targetless-action"])
    XCTAssertEqual(store.selectedSlug, "retry-targetless-action")
    XCTAssertEqual(store.legacyActions.first?.status, "failed")
    XCTAssertEqual(store.legacyActions.first?.lastError, "Timed out")
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Server accepted retry without returning legacy action 9.")
    XCTAssertEqual(service.getItemCalls["retry-targetless-action"] ?? 0, 0)
  }

  func testTargetlessItemActionRetryResponseDoesNotMarkRetryQueued() async {
    var decided = Fixture.item(slug: "retry-targetless-item", title: "Retry targetless item", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-targetless-item"] = ReviewActionsResponse(slug: "retry-targetless-item", requests: [], legacyActions: [])
    service.retryResponses["retry-targetless-item"] = RetryResponse(ok: true, slug: "retry-targetless-item")
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    service.resetDetailCallCounts()

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-targetless-item"])
    XCTAssertEqual(store.selectedSlug, "retry-targetless-item")
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.selectedItem?.actionStatus, "failed")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Timed out")
    XCTAssertEqual(store.bannerMessage, "Server accepted retry without returning failed action proof.")
    XCTAssertEqual(service.getItemCalls["retry-targetless-item"] ?? 0, 0)
  }

  func testItemActionRetryAcceptsReturnedRequestPayloadWithoutLoadedProofRows() async {
    var decided = Fixture.item(slug: "retry-item-request", title: "Retry item request", status: "processed")
    decided.actionStatus = "failed"
    decided.actionMessage = "Timed out"
    let service = MockReviewService(items: [decided])
    service.actionResponses["retry-item-request"] = ReviewActionsResponse(slug: "retry-item-request", requests: [], legacyActions: [])
    service.retryResponses["retry-item-request"] = RetryResponse(
      ok: true,
      slug: "retry-item-request",
      request: .init(id: 77, status: "queued", kind: "agent_followup")
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)

    await store.retryLatestAction()

    XCTAssertEqual(service.retryCalls, ["retry-item-request"])
    XCTAssertEqual(store.selectedSlug, "retry-item-request")
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.legacyActions.isEmpty)
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Downstream action processing is queued or waiting for an authoritative system.")
    XCTAssertEqual(store.bannerMessage, "Retry queued.")
  }

  func testDownstreamRetryStateNormalizesRequestAndLegacyStatuses() {
    let request = DecisionRequest(
      id: 8,
      slug: "needs-retry",
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: " BLOCKED_DECISION ",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Needs more context",
      updatedAt: nil
    )
    let legacyAction = LegacyAction(
      id: 9,
      slug: "legacy-retry",
      decision: "Execute",
      status: " Failed ",
      lastError: "Timed out"
    )

    XCTAssertTrue(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [request], legacyActions: []))
    XCTAssertTrue(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [], legacyActions: [legacyAction]))
    XCTAssertTrue(DownstreamRetryState.needsRetry(itemStatus: " blocked_system ", decisionRequests: [], legacyActions: []))
    XCTAssertFalse(DownstreamRetryState.needsRetry(itemStatus: "queued", decisionRequests: [], legacyActions: []))
    XCTAssertFalse(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [], legacyActions: []))
  }

  func testDownstreamRetryStateOnlyUsesLatestRetryTarget() {
    let latestRequest = DecisionRequest(
      id: 10,
      slug: "latest-request",
      kind: "agent_followup",
      summary: "Already queued",
      sensitivity: nil,
      status: "queued",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: nil,
      updatedAt: nil
    )
    let olderRequest = DecisionRequest(
      id: 9,
      slug: "older-request",
      kind: "agent_followup",
      summary: "Older failure",
      sensitivity: nil,
      status: "failed",
      proofJSON: nil,
      confirmationSlug: nil,
      lastError: "Timed out",
      updatedAt: nil
    )
    let failedLegacyAction = LegacyAction(
      id: 7,
      slug: "legacy-failure",
      decision: "Execute",
      status: "failed",
      lastError: "Timed out"
    )
    let queuedLegacyAction = LegacyAction(
      id: 8,
      slug: "legacy-queued",
      decision: "Execute",
      status: "queued",
      lastError: nil
    )

    XCTAssertFalse(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [latestRequest, olderRequest], legacyActions: []))
    XCTAssertFalse(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [latestRequest], legacyActions: [failedLegacyAction]))
    XCTAssertFalse(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [], legacyActions: [queuedLegacyAction, failedLegacyAction]))
    XCTAssertTrue(DownstreamRetryState.needsRetry(itemStatus: nil, decisionRequests: [olderRequest, latestRequest], legacyActions: []))
  }

  func testDuplicateDecisionSubmissionsAreIgnoredWhileInFlight() async {
    let pending = Fixture.item(slug: "duplicate-decision", title: "Duplicate decision", status: "pending")
    let service = MockReviewService(items: [pending])
    service.delayedDecisionSlug = "duplicate-decision"
    let slowDecisionStarted = expectation(description: "slow decision started")
    service.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let firstTask = Task {
      await store.submitDecision("Execute", feedback: "First")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)
    await store.submitDecision("Kill", feedback: "Second")
    service.releaseDelayedDecision()
    await firstTask.value

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
  }

  func testDuplicateRetriesAreIgnoredWhileInFlight() async {
    let pending = Fixture.item(slug: "duplicate-retry", title: "Duplicate retry", status: "pending")
    let service = MockReviewService(items: [pending])
    service.delayedRetrySlug = "duplicate-retry"
    let slowRetryStarted = expectation(description: "slow retry started")
    service.delayedRetryStarted = {
      slowRetryStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let firstTask = Task {
      await store.retryLatestAction()
    }
    await fulfillment(of: [slowRetryStarted], timeout: 1)
    XCTAssertTrue(store.isRetryingAction(slug: "duplicate-retry"))
    await store.retryLatestAction()
    service.releaseDelayedRetry()
    await firstTask.value

    XCTAssertEqual(service.retryCalls, ["duplicate-retry"])
    XCTAssertFalse(store.isRetryingAction(slug: "duplicate-retry"))
  }

  func testDecisionSubmittingStateIsScopedToStartingSlug() async {
    let first = Fixture.item(slug: "decision-gate-a", title: "Decision gate A", status: "pending")
    let second = Fixture.item(slug: "decision-gate-b", title: "Decision gate B", status: "pending")
    let service = MockReviewService(items: [first, second])
    service.delayedDecisionSlug = "decision-gate-a"
    let slowDecisionStarted = expectation(description: "decision gate started")
    service.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let decisionTask = Task {
      await store.submitDecision("Execute", feedback: "Ship it.")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)

    XCTAssertTrue(store.isSubmittingDecision(slug: "decision-gate-a"))
    XCTAssertFalse(store.isSubmittingDecision(slug: "decision-gate-b"))

    await store.selectItem(slug: "decision-gate-b")

    XCTAssertTrue(store.isSubmittingDecision(slug: "decision-gate-a"))
    XCTAssertFalse(store.isSubmittingDecision(slug: "decision-gate-b"))

    service.releaseDelayedDecision()
    await decisionTask.value

    XCTAssertFalse(store.isSubmittingDecision(slug: "decision-gate-a"))
    XCTAssertFalse(store.isSubmittingDecision(slug: "decision-gate-b"))
  }

  func testChatSendingStateIsScopedToStartingSlug() async {
    let first = Fixture.item(slug: "chat-gate-a", title: "Chat gate A", status: "pending")
    let second = Fixture.item(slug: "chat-gate-b", title: "Chat gate B", status: "pending")
    let service = MockReviewService(items: [first, second])
    service.delayedSendChatSlug = "chat-gate-a"
    let slowSendStarted = expectation(description: "chat gate started")
    service.delayedSendChatStarted = {
      slowSendStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let sendTask = Task {
      await store.sendChat("Question for A")
    }
    await fulfillment(of: [slowSendStarted], timeout: 1)

    XCTAssertTrue(store.isSendingChat(slug: "chat-gate-a"))
    XCTAssertFalse(store.isSendingChat(slug: "chat-gate-b"))

    await store.selectItem(slug: "chat-gate-b")

    XCTAssertTrue(store.isSendingChat(slug: "chat-gate-a"))
    XCTAssertFalse(store.isSendingChat(slug: "chat-gate-b"))

    service.releaseDelayedSendChat()
    _ = await sendTask.value

    XCTAssertFalse(store.isSendingChat(slug: "chat-gate-a"))
    XCTAssertFalse(store.isSendingChat(slug: "chat-gate-b"))
  }

  func testExplicitDecisionTargetIsPreservedAfterSelectionMoves() async {
    let first = Fixture.item(slug: "explicit-decision-a", title: "Explicit decision A", status: "pending")
    let second = Fixture.item(slug: "explicit-decision-b", title: "Explicit decision B", status: "pending")
    let service = MockReviewService(items: [first, second])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectItem(slug: "explicit-decision-b")

    await store.submitDecision(for: "explicit-decision-a", "Execute", feedback: "Ship A.")

    XCTAssertEqual(service.decisions.map(\.slug), ["explicit-decision-a"])
    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedSlug, "explicit-decision-b")
    XCTAssertEqual(store.selectedItem?.slug, "explicit-decision-b")
    XCTAssertEqual(store.items.first { $0.slug == "explicit-decision-a" }?.status, "processed")
    XCTAssertEqual(store.items.first { $0.slug == "explicit-decision-a" }?.decision, "Execute")
  }

  func testExplicitRetryTargetDoesNotRunAfterSelectionMoves() async {
    var first = Fixture.item(slug: "explicit-retry-a", title: "Explicit retry A", status: "processed")
    first.actionStatus = "failed"
    first.actionMessage = "Timed out"
    var second = Fixture.item(slug: "explicit-retry-b", title: "Explicit retry B", status: "processed")
    second.actionStatus = "failed"
    second.actionMessage = "Still blocked"
    let service = MockReviewService(items: [first, second])
    service.actionResponses["explicit-retry-a"] = ReviewActionsResponse(
      slug: "explicit-retry-a",
      requests: [Fixture.request(slug: "explicit-retry-a", proofJSON: nil, status: "failed")],
      legacyActions: []
    )
    service.actionResponses["explicit-retry-b"] = ReviewActionsResponse(
      slug: "explicit-retry-b",
      requests: [Fixture.request(slug: "explicit-retry-b", proofJSON: nil, status: "failed")],
      legacyActions: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectTab(.decided)
    await store.selectItem(slug: "explicit-retry-b")

    await store.retryLatestAction(for: "explicit-retry-a")

    XCTAssertTrue(service.retryCalls.isEmpty)
    XCTAssertEqual(store.selectedSlug, "explicit-retry-b")
    XCTAssertEqual(store.selectedItem?.slug, "explicit-retry-b")
    XCTAssertNil(store.bannerMessage)
  }

  func testExplicitChatTargetDoesNotSendAfterSelectionMoves() async {
    let first = Fixture.item(slug: "explicit-chat-a", title: "Explicit chat A", status: "pending")
    let second = Fixture.item(slug: "explicit-chat-b", title: "Explicit chat B", status: "pending")
    let service = MockReviewService(items: [first, second])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    await store.selectItem(slug: "explicit-chat-b")

    let didSend = await store.sendChat("Question for A", for: "explicit-chat-a")

    XCTAssertFalse(didSend)
    XCTAssertTrue(service.sendChatCalls.isEmpty)
    XCTAssertEqual(store.selectedSlug, "explicit-chat-b")
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for explicit-chat-b"])
  }

  func testSubmitDecisionStaysOnPendingAndKeepsSuccessBanner() async {
    let pending = Fixture.item(slug: "ship", title: "Ship item", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.resetDetailCallCounts()

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
    XCTAssertEqual(service.getItemCalls["ship"] ?? 0, 0)
    XCTAssertEqual(service.chatHistoryCalls["ship"] ?? 0, 0)
  }

  func testWrongSlugDecisionResponseDoesNotMoveReviewOutOfPending() async {
    let pending = Fixture.item(slug: "decision-mismatch", title: "Decision mismatch", status: "pending")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["decision-mismatch"] = DecisionResponse(
      status: "processed",
      decision: "Execute",
      slug: "other-decision",
      queued: false,
      processed: true,
      sessionKey: "session-other-decision",
      action: .init(status: "succeeded", message: "Execute saved."),
      requests: [],
      followups: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.resetDetailCallCounts()

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "decision-mismatch")
    XCTAssertEqual(store.selectedItem?.status, "pending")
    XCTAssertNil(store.selectedItem?.decision)
    XCTAssertEqual(store.visibleItems.map(\.slug), ["decision-mismatch"])
    XCTAssertEqual(store.bannerMessage, "Server returned decision data for other-decision, not decision-mismatch.")
    XCTAssertEqual(service.getItemCalls["decision-mismatch"] ?? 0, 0)
  }

  func testWrongStatusDecisionResponseDoesNotMoveReviewOutOfPending() async {
    let pending = Fixture.item(slug: "decision-status-mismatch", title: "Decision status mismatch", status: "pending")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["decision-status-mismatch"] = DecisionResponse(
      status: "pending",
      decision: "Execute",
      slug: "decision-status-mismatch",
      queued: false,
      processed: true,
      sessionKey: "session-decision-status-mismatch",
      action: .init(status: "succeeded", message: "Execute saved."),
      requests: [],
      followups: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.resetDetailCallCounts()

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "decision-status-mismatch")
    XCTAssertEqual(store.selectedItem?.status, "pending")
    XCTAssertNil(store.selectedItem?.decision)
    XCTAssertEqual(store.visibleItems.map(\.slug), ["decision-status-mismatch"])
    XCTAssertEqual(store.bannerMessage, "Server returned decision status pending, not processed.")
    XCTAssertEqual(service.getItemCalls["decision-status-mismatch"] ?? 0, 0)
  }

  func testSuccessfulDecisionStaysLocallyDecidedWhenRefreshFails() async {
    let pending = Fixture.item(slug: "ship-no-refresh", title: "Ship without refresh", status: "pending")
    let service = MockReviewService(items: [pending])
    service.actionResponses["ship-no-refresh"] = ReviewActionsResponse(
      slug: "ship-no-refresh",
      requests: [Fixture.request(slug: "ship-no-refresh", proofJSON: #"{"summary":"Old proof"}"#)],
      legacyActions: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    XCTAssertEqual(store.annotations.map(\.comment), ["Annotation for ship-no-refresh"])
    XCTAssertEqual(store.decisionRequests.map(\.summary), ["Run downstream work"])
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for ship-no-refresh"])
    XCTAssertNotNil(store.ttsStatus?.url)
    XCTAssertEqual(store.contextStatus?.summary, "Context for ship-no-refresh")

    service.listItemsError = TestError("Refresh unavailable")

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-no-refresh")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.selectedItem?.feedback, "Ship it.")
    XCTAssertEqual(store.selectedItem?.actionStatus, "succeeded")
    XCTAssertEqual(store.selectedItem?.actionMessage, "Execute saved.")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.chatMessages.isEmpty)
    XCTAssertNil(store.ttsStatus?.url)
    XCTAssertNil(store.contextStatus?.url)
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testSuccessfulDecisionStaysLocallyDecidedWhenRefreshReturnsStalePendingItem() async {
    let pending = Fixture.item(slug: "ship-stale-refresh", title: "Ship with stale refresh", status: "pending")
    let stalePending = Fixture.item(slug: "ship-stale-refresh", title: "Ship with stale refresh", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listResponses = [[stalePending]]

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-stale-refresh")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.selectedItem?.feedback, "Ship it.")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testManualRefreshKeepsAcceptedDecisionWhenServerStillReturnsStalePendingItem() async {
    let pending = Fixture.item(slug: "ship-stale-manual-refresh", title: "Ship with stale manual refresh", status: "pending")
    let stalePending = Fixture.item(slug: "ship-stale-manual-refresh", title: "Ship with stale manual refresh", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listResponses = [[stalePending], [stalePending]]

    await store.submitDecision("Execute", feedback: "Ship it.")
    await store.refresh()

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertNil(store.selectedSlug)
    XCTAssertNil(store.selectedItem)
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
  }

  func testManualRefreshKeepsAcceptedDecisionWhenServerStillDropsItem() async {
    let pending = Fixture.item(slug: "ship-dropped-manual-refresh", title: "Ship with dropped manual refresh", status: "pending")
    let otherDecided = Fixture.item(slug: "other-manual-decided", title: "Other manual decided", status: "processed")
    let service = MockReviewService(items: [pending, otherDecided])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listResponses = [[otherDecided], [otherDecided]]

    await store.submitDecision("Execute", feedback: "Ship it.")
    await store.refresh()

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertNil(store.selectedSlug)
    XCTAssertNil(store.selectedItem)
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
  }

  func testManualRefreshFailureKeepsAcceptedDecisionInsteadOfDemoFallback() async {
    let pending = Fixture.item(slug: "ship-outage-after-accept", title: "Ship before outage", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: true),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.submitDecision("Execute", feedback: "Ship it.")
    service.listItemsError = TestError("Server unavailable")
    await store.refresh()

    XCTAssertFalse(store.isUsingDemoData)
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-outage-after-accept")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.selectedItem?.feedback, "Ship it.")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertEqual(store.bannerMessage, "Server unavailable")
  }

  func testSuccessfulDecisionKeepsResponseRequestsWhenRefreshFails() async {
    let pending = Fixture.item(slug: "ship-with-request", title: "Ship with request", status: "pending")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["ship-with-request"] = DecisionResponse(
      status: "processed",
      decision: "Execute",
      slug: "ship-with-request",
      queued: true,
      processed: true,
      sessionKey: "session-ship-with-request",
      action: .init(status: "queued", message: "Created 1 downstream request(s)."),
      requests: [
        .init(id: 99, kind: "agent_followup", status: "queued", summary: "Run the native smoke proof")
      ],
      followups: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("Refresh unavailable")

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-with-request")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.actionStatus, "queued")
    XCTAssertEqual(store.decisionRequests.map(\.id), [99])
    XCTAssertEqual(store.decisionRequests.first?.slug, "ship-with-request")
    XCTAssertEqual(store.decisionRequests.first?.kind, "agent_followup")
    XCTAssertEqual(store.decisionRequests.first?.status, "queued")
    XCTAssertEqual(store.decisionRequests.first?.summary, "Run the native smoke proof")
    XCTAssertEqual(store.bannerMessage, "Created 1 downstream request(s).")
  }

  func testSuccessfulDecisionKeepsResponseRequestsWhenDetailRefreshReturnsOlderRequests() async {
    let pending = Fixture.item(slug: "ship-stale-request", title: "Ship stale request", status: "pending")
    var staleProcessed = Fixture.item(slug: "ship-stale-request", title: "Ship stale request", status: "processed")
    staleProcessed.decision = "Execute"
    staleProcessed.actionStatus = "queued"
    staleProcessed.actionMessage = "Created 1 downstream request(s)."
    let service = MockReviewService(items: [pending])
    service.actionResponses["ship-stale-request"] = ReviewActionsResponse(
      slug: "ship-stale-request",
      requests: [Fixture.request(slug: "ship-stale-request", proofJSON: nil)],
      legacyActions: []
    )
    service.decisionResponses["ship-stale-request"] = DecisionResponse(
      status: "processed",
      decision: "Execute",
      slug: "ship-stale-request",
      queued: true,
      processed: true,
      sessionKey: "session-ship-stale-request",
      action: .init(status: "queued", message: "Created 1 downstream request(s)."),
      requests: [
        .init(id: 99, kind: "agent_followup", status: "queued", summary: "Run the accepted downstream request")
      ],
      followups: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listResponses = [[staleProcessed]]

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-stale-request")
    XCTAssertEqual(store.decisionRequests.map(\.id), [99])
    XCTAssertEqual(store.decisionRequests.first?.summary, "Run the accepted downstream request")
    XCTAssertEqual(store.decisionRequests.last?.summary, "Run the accepted downstream request")
    XCTAssertEqual(store.bannerMessage, "Created 1 downstream request(s).")
  }

  func testSuccessfulDecisionKeepsFollowupReviewsWhenRefreshFails() async {
    let pending = Fixture.item(slug: "ship-with-followup", title: "Ship with follow-up", status: "pending")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["ship-with-followup"] = DecisionResponse(
      status: "processed",
      decision: "Execute",
      slug: "ship-with-followup",
      queued: true,
      processed: true,
      sessionKey: "session-ship-with-followup",
      action: .init(status: "queued", message: "Created 1 downstream request(s)."),
      requests: [],
      followups: [
        .init(
          slug: "followup-clarify-window",
          title: "Clarify delivery window",
          url: "/review/followup-clarify-window"
        )
      ]
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("Refresh unavailable")

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-with-followup")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertEqual(store.decisionFollowups.map(\.slug), ["followup-clarify-window"])
    XCTAssertEqual(store.decisionFollowups.first?.title, "Clarify delivery window")
    XCTAssertEqual(store.decisionFollowups.first?.url, "/review/followup-clarify-window")
    XCTAssertEqual(store.bannerMessage, "Created 1 downstream request(s).")
  }

  func testSuccessfulDecisionKeepsOnlyUsableFollowupReviewsWhenRefreshFails() async {
    let pending = Fixture.item(slug: "ship-with-filtered-followups", title: "Ship with filtered follow-ups", status: "pending")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["ship-with-filtered-followups"] = DecisionResponse(
      status: "processed",
      decision: "Execute",
      slug: "ship-with-filtered-followups",
      queued: true,
      processed: true,
      sessionKey: "session-ship-with-filtered-followups",
      action: .init(status: "queued", message: "Created 1 downstream request(s)."),
      requests: [],
      followups: [
        .init(slug: " ", title: "Missing slug", url: "/review/missing-slug"),
        .init(slug: "followup-missing-title", title: " ", url: "/review/followup-missing-title"),
        .init(slug: "followup-unsafe-url", title: "Unsafe URL", url: "javascript:alert(1)"),
        .init(slug: " followup-usable ", title: " Usable follow-up ", url: " /review/followup-usable ")
      ]
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("Refresh unavailable")

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-with-filtered-followups")
    XCTAssertEqual(store.decisionFollowups.map(\.slug), ["followup-usable"])
    XCTAssertEqual(store.decisionFollowups.first?.title, "Usable follow-up")
    XCTAssertEqual(store.decisionFollowups.first?.url, "/review/followup-usable")
    XCTAssertEqual(store.bannerMessage, "Created 1 downstream request(s).")
  }

  func testOpeningFollowupReviewLoadsNativeDetailEvenWhenMissingFromQueue() async {
    let pending = Fixture.item(slug: "parent-with-followup", title: "Parent with follow-up", status: "pending")
    let followup = Fixture.item(slug: "followup-native-detail", title: "Follow-up native detail", status: "pending", category: "clarification")
    let service = MockReviewService(items: [pending])
    service.getItemResponses["followup-native-detail"] = followup
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.openFollowupReview(
      .init(
        slug: "followup-native-detail",
        title: "Follow-up native detail",
        url: "/review/followup-native-detail"
      )
    )

    XCTAssertEqual(Set(store.items.map(\.slug)), Set(["parent-with-followup", "followup-native-detail"]))
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "followup-native-detail")
    XCTAssertEqual(store.selectedItem?.title, "Follow-up native detail")
    XCTAssertEqual(store.selectedItem?.category, "clarification")
    XCTAssertEqual(store.counts[.pending], 2)
    XCTAssertTrue(store.visibleItems.contains { $0.slug == "followup-native-detail" })
    XCTAssertEqual(service.getItemCalls["followup-native-detail"], 1)
    XCTAssertEqual(store.chatMessages.map(\.content), ["History for followup-native-detail"])
  }

  func testLoadedDetailStatusMovesSelectionToMatchingTab() async {
    let stalePending = Fixture.item(slug: "detail-status-moved", title: "Detail status moved", status: "pending")
    var processed = Fixture.item(slug: "detail-status-moved", title: "Detail status moved", status: "processed")
    processed.decision = "Execute"
    processed.actionStatus = "succeeded"
    processed.actionMessage = "Execute saved."
    let service = MockReviewService(items: [stalePending])
    service.getItemResponses["detail-status-moved"] = processed
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )

    await store.refresh()

    XCTAssertEqual(store.selectedTab, .decided)
    XCTAssertEqual(store.selectedSlug, "detail-status-moved")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.counts[.pending], 0)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertTrue(store.visibleItems.contains { $0.slug == "detail-status-moved" })
  }

  func testOpeningConfirmationReviewLoadsNativeDetailEvenWhenMissingFromQueue() async {
    let parent = Fixture.item(slug: "parent-with-confirmation", title: "Parent with confirmation", status: "processed")
    let confirmation = Fixture.item(slug: "confirmation-native-detail", title: "Confirmation native detail", status: "pending", category: "confirmation")
    let service = MockReviewService(items: [parent])
    service.getItemResponses["confirmation-native-detail"] = confirmation
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.openConfirmationReview(slug: " confirmation-native-detail ")

    XCTAssertEqual(Set(store.items.map(\.slug)), Set(["parent-with-confirmation", "confirmation-native-detail"]))
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "confirmation-native-detail")
    XCTAssertEqual(store.selectedItem?.title, "Confirmation native detail")
    XCTAssertEqual(store.selectedItem?.category, "confirmation")
    XCTAssertEqual(store.counts[.pending], 1)
    XCTAssertTrue(store.visibleItems.contains { $0.slug == "confirmation-native-detail" })
    XCTAssertEqual(service.getItemCalls["confirmation-native-detail"], 1)
  }

  func testOpeningBlankConfirmationReviewKeepsCurrentSelection() async {
    let pending = Fixture.item(slug: "current-review", title: "Current review", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.resetDetailCallCounts()

    await store.openConfirmationReview(slug: "  ")

    XCTAssertEqual(store.selectedSlug, "current-review")
    XCTAssertEqual(store.selectedItem?.title, "Current review")
    XCTAssertTrue(service.getItemCalls.isEmpty)
  }

  func testSuccessfulDecisionStaysLocallyDecidedWhenRefreshTemporarilyDropsItem() async {
    let pending = Fixture.item(slug: "ship-dropped-refresh", title: "Ship with dropped refresh", status: "pending")
    let otherDecided = Fixture.item(slug: "other-decided", title: "Other decided", status: "processed")
    let service = MockReviewService(items: [pending, otherDecided])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listResponses = [[otherDecided]]

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-dropped-refresh")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.chatMessages.isEmpty)
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testSuccessfulDecisionSelectedAwayStillUpdatesQueueWhenRefreshFails() async {
    let deciding = Fixture.item(
      slug: "ship-selected-away",
      title: "Ship selected away",
      status: "pending",
      updatedAt: "2026-06-11 10:00:00"
    )
    let next = Fixture.item(
      slug: "next-pending-after-decision",
      title: "Next pending after decision",
      status: "pending",
      updatedAt: "2026-06-11 09:00:00"
    )
    let service = MockReviewService(items: [deciding, next])
    service.delayedDecisionSlug = "ship-selected-away"
    let slowDecisionStarted = expectation(description: "decision started before selection changed")
    service.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let decisionTask = Task {
      await store.submitDecision("Execute", feedback: "Ship it.")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)
    await store.selectItem(slug: "next-pending-after-decision")
    service.listItemsError = TestError("Refresh unavailable")
    service.releaseDelayedDecision()
    await decisionTask.value

    let acceptedItem = store.items.first { $0.slug == "ship-selected-away" }
    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "next-pending-after-decision")
    XCTAssertEqual(store.selectedItem?.slug, "next-pending-after-decision")
    XCTAssertEqual(acceptedItem?.status, "processed")
    XCTAssertEqual(acceptedItem?.decision, "Execute")
    XCTAssertEqual(acceptedItem?.feedback, "Ship it.")
    XCTAssertEqual(store.counts[.pending], 1)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertEqual(store.visibleItems.map(\.slug), ["next-pending-after-decision"])
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testSuccessfulDecisionSelectedAwayKeepsAcceptedQueueStateWhenRefreshIsStale() async {
    let deciding = Fixture.item(
      slug: "ship-selected-away-stale",
      title: "Ship selected away stale",
      status: "pending",
      updatedAt: "2026-06-11 10:00:00"
    )
    let next = Fixture.item(
      slug: "next-pending-after-stale",
      title: "Next pending after stale",
      status: "pending",
      updatedAt: "2026-06-11 09:00:00"
    )
    let service = MockReviewService(items: [deciding, next])
    service.delayedDecisionSlug = "ship-selected-away-stale"
    let slowDecisionStarted = expectation(description: "decision started before stale refresh")
    service.delayedDecisionStarted = {
      slowDecisionStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    let decisionTask = Task {
      await store.submitDecision("Execute", feedback: "Ship it.")
    }
    await fulfillment(of: [slowDecisionStarted], timeout: 1)
    await store.selectItem(slug: "next-pending-after-stale")
    service.listResponses = [[deciding, next]]
    service.releaseDelayedDecision()
    await decisionTask.value

    let acceptedItem = store.items.first { $0.slug == "ship-selected-away-stale" }
    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "next-pending-after-stale")
    XCTAssertEqual(store.selectedItem?.slug, "next-pending-after-stale")
    XCTAssertEqual(acceptedItem?.status, "processed")
    XCTAssertEqual(acceptedItem?.decision, "Execute")
    XCTAssertEqual(store.counts[.pending], 1)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertEqual(store.visibleItems.map(\.slug), ["next-pending-after-stale"])
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testSuccessfulDecisionDoesNotReselectReviewWhenUserMovesDuringRefresh() async {
    let deciding = Fixture.item(
      slug: "ship-refresh-race",
      title: "Ship refresh race",
      status: "pending",
      updatedAt: "2026-06-11 10:00:00"
    )
    let next = Fixture.item(
      slug: "next-pending-during-refresh",
      title: "Next pending during refresh",
      status: "pending",
      updatedAt: "2026-06-11 09:00:00"
    )
    let service = MockReviewService(items: [deciding, next])
    let refreshStarted = expectation(description: "post-decision refresh started")
    service.delayedListStarted = {
      refreshStarted.fulfill()
    }
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listResponses = [[deciding, next]]
    service.delayNextList = true

    let decisionTask = Task {
      await store.submitDecision("Execute", feedback: "Ship it.")
    }
    await fulfillment(of: [refreshStarted], timeout: 1)
    await store.selectItem(slug: "next-pending-during-refresh")
    service.releaseDelayedList()
    await decisionTask.value

    let acceptedItem = store.items.first { $0.slug == "ship-refresh-race" }
    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "next-pending-during-refresh")
    XCTAssertEqual(store.selectedItem?.slug, "next-pending-during-refresh")
    XCTAssertEqual(acceptedItem?.status, "processed")
    XCTAssertEqual(acceptedItem?.decision, "Execute")
    XCTAssertEqual(acceptedItem?.feedback, "Ship it.")
    XCTAssertEqual(store.counts[.pending], 1)
    XCTAssertEqual(store.counts[.decided], 1)
    XCTAssertEqual(store.visibleItems.map(\.slug), ["next-pending-during-refresh"])
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testSuccessfulDecisionDoesNotFallBackToDemoWhenConfiguredAndRefreshFails() async {
    let pending = Fixture.item(slug: "ship-no-demo", title: "Ship without demo fallback", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: true),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("Refresh unavailable")

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertFalse(store.isUsingDemoData)
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "ship-no-demo")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testParkDecisionAcceptsCanonicalServerDecisionAndRoutesToParked() async {
    let pending = Fixture.item(slug: "park-canonical-response", title: "Park canonical response", status: "pending", category: "kitchenlux")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["park-canonical-response"] = DecisionResponse(
      status: "archived",
      decision: "Park",
      slug: "park-canonical-response",
      queued: false,
      processed: true,
      sessionKey: "session-park-canonical-response",
      action: .init(status: "succeeded", message: "Park saved."),
      requests: [],
      followups: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.submitDecision(" park ", feedback: "")

    XCTAssertEqual(service.decisions.map(\.decision), ["Park"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "park-canonical-response")
    XCTAssertEqual(store.selectedItem?.status, "archived")
    XCTAssertEqual(store.selectedItem?.decision, "Park")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertEqual(store.bannerMessage, "Park saved.")
  }

  func testDecisionCanonicalizesAllowedActionBeforeSubmit() async {
    let pending = Fixture.item(slug: "canonicalize-decision", title: "Canonicalize decision", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.submitDecision(" execute \n", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "canonicalize-decision")
    XCTAssertEqual(store.selectedItem?.status, "processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.selectedItem?.feedback, "Ship it.")
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testDecisionAcceptsServerStatusCaseAndWhitespaceVariants() async {
    let pending = Fixture.item(slug: "status-variant-response", title: "Status variant response", status: "pending")
    let service = MockReviewService(items: [pending])
    service.decisionResponses["status-variant-response"] = DecisionResponse(
      status: " Processed ",
      decision: " Execute ",
      slug: "status-variant-response",
      queued: false,
      processed: true,
      sessionKey: "session-status-variant-response",
      action: .init(status: "succeeded", message: "Execute saved."),
      requests: [],
      followups: []
    )
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.submitDecision("Execute", feedback: "Ship it.")

    XCTAssertEqual(service.decisions.map(\.decision), ["Execute"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "status-variant-response")
    XCTAssertEqual(store.selectedItem?.status, "Processed")
    XCTAssertEqual(store.selectedItem?.decision, "Execute")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertEqual(store.bannerMessage, "Execute saved.")
  }

  func testParkDecisionStaysLocallyParkedWhenRefreshFails() async {
    let pending = Fixture.item(slug: "park-no-refresh", title: "Park without refresh", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()
    service.listItemsError = TestError("Refresh unavailable")

    await store.submitDecision("Park", feedback: "")

    XCTAssertEqual(service.decisions.map(\.decision), ["Park"])
    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "park-no-refresh")
    XCTAssertEqual(store.selectedItem?.status, "archived")
    XCTAssertEqual(store.selectedItem?.decision, "Park")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
    XCTAssertEqual(store.bannerMessage, "Park saved.")
  }

  func testParkDecisionMovesToParkedQueue() async {
    let pending = Fixture.item(slug: "park-me", title: "Park me", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.submitDecision("Park", feedback: "")

    XCTAssertEqual(store.selectedTab, .pending)
    XCTAssertEqual(store.selectedSlug, "park-me")
    XCTAssertEqual(store.selectedItem?.status, "archived")
    XCTAssertEqual(store.selectedItem?.decision, "Park")
    XCTAssertEqual(store.visibleItems.map(\.slug), [])
  }

  func testSelectingEmptyTabClearsDetail() async {
    let pending = Fixture.item(slug: "only-pending", title: "Only pending", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.selectTab(.parked)

    XCTAssertEqual(store.selectedTab, .parked)
    XCTAssertNil(store.selectedSlug)
    XCTAssertNil(store.selectedItem)
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.chatMessages.isEmpty)
    XCTAssertNil(store.ttsStatus)
    XCTAssertNil(store.contextStatus)
    XCTAssertFalse(store.detailLoading)
  }

  func testSelectingPopulatedTabChoosesFirstVisibleItem() async {
    let pending = Fixture.item(slug: "pending", title: "Pending", status: "pending", updatedAt: "2026-06-11 10:00:00")
    let decided = Fixture.item(slug: "decided", title: "Decided", status: "processed", updatedAt: "2026-06-11 09:00:00")
    let service = MockReviewService(items: [pending, decided])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.selectTab(.decided)

    XCTAssertEqual(store.selectedTab, .decided)
    XCTAssertEqual(store.selectedSlug, "decided")
    XCTAssertEqual(store.selectedItem?.title, "Decided")
    XCTAssertEqual(store.visibleItems.map(\.slug), ["decided"])
  }

  func testSelectingNilItemClearsDetail() async {
    let pending = Fixture.item(slug: "pending", title: "Pending", status: "pending")
    let service = MockReviewService(items: [pending])
    let store = ReviewStore(
      configuration: .test(useDemoOnFailure: false),
      clientFactory: { _ in service }
    )
    await store.refresh()

    await store.selectItem(slug: nil)

    XCTAssertNil(store.selectedSlug)
    XCTAssertNil(store.selectedItem)
    XCTAssertTrue(store.annotations.isEmpty)
    XCTAssertTrue(store.decisionRequests.isEmpty)
    XCTAssertTrue(store.chatMessages.isEmpty)
    XCTAssertNil(store.ttsStatus)
    XCTAssertNil(store.contextStatus)
  }

  private static func clearSavedConfiguration() {
    let defaults = APIConfiguration.defaultsStore
    defaults.removeObject(forKey: "turf.serverURL")
    defaults.removeObject(forKey: "turf.username")
    defaults.removeObject(forKey: "turf.password")
    defaults.removeObject(forKey: "turf.useDemoOnFailure")
  }
}

private final class MockReviewService: TurfReviewServicing {
  var items: [ReviewItem]
  var listItemsError: Error?
  var listResponses: [[ReviewItem]] = []
  var delayNextList = false
  var delayedListStarted: (() -> Void)?
  var delayedItemSlug: String?
  var delayedItemStarted: (() -> Void)?
  var delayedChatSlug: String?
  var delayedChatStarted: (() -> Void)?
  var delayedTTSSlug: String?
  var delayedTTSStarted: (() -> Void)?
  var delayedSendChatSlug: String?
  var delayedSendChatStarted: (() -> Void)?
  var delayedCreateAnnotationSlug: String?
  var delayedCreateAnnotationStarted: (() -> Void)?
  var delayedDeleteAnnotationSlug: String?
  var delayedDeleteAnnotationStarted: (() -> Void)?
  var delayedUpdateTargetKey: String?
  var delayedUpdateTargetStarted: (() -> Void)?
  var delayedDecisionSlug: String?
  var delayedDecisionStarted: (() -> Void)?
  var delayedRetrySlug: String?
  var delayedRetryStarted: (() -> Void)?
  var annotationIDs: [String: Int] = [:]
  var getItemErrors: [String: Error] = [:]
  var getItemResponses: [String: ReviewItem] = [:]
  var annotationErrors: [String: Error] = [:]
  var targetErrors: [String: Error] = [:]
  var actionErrors: [String: Error] = [:]
  var ttsErrors: [String: Error] = [:]
  var contextErrors: [String: Error] = [:]
  var createAnnotationErrors: [String: Error] = [:]
  var createAnnotationResponses: [String: ReviewAnnotation] = [:]
  var deleteAnnotationResponses: [String: DeleteAnnotationResponse] = [:]
  var targetResponses: [String: ReviewTargetsResponse] = [:]
  var updateTargetErrors: [String: Error] = [:]
  var updateTargetResponses: [String: ReviewTargetJudgmentResponse] = [:]
  var sendChatErrors: [String: Error] = [:]
  var sendChatResponses: [String: ChatSendResponse] = [:]
  var chatHistoryErrors: [String: Error] = [:]
  var chatHistoryResponses: [String: ChatHistoryResponse] = [:]
  var actionResponses: [String: ReviewActionsResponse] = [:]
  var retryResponses: [String: RetryResponse] = [:]
  var decisionResponses: [String: DecisionResponse] = [:]
  var decisions: [(slug: String, decision: String, feedback: String?)] = []
  var retryCalls: [String] = []
  var createAnnotationCalls: [(slug: String, quote: String?, anchorType: String, anchorRef: String?, comment: String, imageData: String?, imageMime: String?)] = []
  var updateTargetCalls: [(slug: String, targetKey: String, verdict: String, feedback: String?)] = []
  var sendChatCalls: [(slug: String, message: String)] = []
  var deleteAnnotationCalls: [(slug: String, id: Int)] = []
  var getItemCalls: [String: Int] = [:]
  var chatHistoryCalls: [String: Int] = [:]

  private var delayedListContinuation: CheckedContinuation<Void, Never>?
  private var delayedItemContinuation: CheckedContinuation<Void, Never>?
  private var delayedChatContinuation: CheckedContinuation<Void, Never>?
  private var delayedTTSContinuation: CheckedContinuation<Void, Never>?
  private var delayedSendChatContinuation: CheckedContinuation<Void, Never>?
  private var delayedCreateAnnotationContinuation: CheckedContinuation<Void, Never>?
  private var delayedDeleteAnnotationContinuation: CheckedContinuation<Void, Never>?
  private var delayedUpdateTargetContinuation: CheckedContinuation<Void, Never>?
  private var delayedDecisionContinuation: CheckedContinuation<Void, Never>?
  private var delayedRetryContinuation: CheckedContinuation<Void, Never>?

  init(items: [ReviewItem]) {
    self.items = items
  }

  func releaseDelayedList() {
    delayedListContinuation?.resume()
    delayedListContinuation = nil
  }

  func releaseDelayedItem() {
    delayedItemContinuation?.resume()
    delayedItemContinuation = nil
  }

  func releaseDelayedChat() {
    delayedChatContinuation?.resume()
    delayedChatContinuation = nil
  }

  func releaseDelayedTTS() {
    delayedTTSContinuation?.resume()
    delayedTTSContinuation = nil
  }

  func releaseDelayedSendChat() {
    delayedSendChatContinuation?.resume()
    delayedSendChatContinuation = nil
  }

  func releaseDelayedCreateAnnotation() {
    delayedCreateAnnotationContinuation?.resume()
    delayedCreateAnnotationContinuation = nil
  }

  func releaseDelayedDeleteAnnotation() {
    delayedDeleteAnnotationContinuation?.resume()
    delayedDeleteAnnotationContinuation = nil
  }

  func releaseDelayedUpdateTarget() {
    delayedUpdateTargetContinuation?.resume()
    delayedUpdateTargetContinuation = nil
  }

  func releaseDelayedDecision() {
    delayedDecisionContinuation?.resume()
    delayedDecisionContinuation = nil
  }

  func releaseDelayedRetry() {
    delayedRetryContinuation?.resume()
    delayedRetryContinuation = nil
  }

  func resetDetailCallCounts() {
    getItemCalls = [:]
    chatHistoryCalls = [:]
  }

  func listItems() async throws -> [ReviewItem] {
    if let listItemsError { throw listItemsError }
    let response = listResponses.isEmpty ? items : listResponses.removeFirst()
    items = response
    if delayNextList {
      delayNextList = false
      delayedListStarted?()
      await withCheckedContinuation { continuation in
        delayedListContinuation = continuation
      }
    }
    return response
  }

  func getItem(slug: String) async throws -> ReviewItem {
    getItemCalls[slug, default: 0] += 1
    if let error = getItemErrors[slug] {
      throw error
    }
    if slug == delayedItemSlug {
      delayedItemStarted?()
      await withCheckedContinuation { continuation in
        delayedItemContinuation = continuation
      }
    }
    if let response = getItemResponses[slug] {
      return response
    }
    return try item(slug)
  }

  func getAnnotations(slug: String) async throws -> [ReviewAnnotation] {
    if let error = annotationErrors[slug] {
      throw error
    }
    return [ReviewAnnotation(id: annotationIDs[slug] ?? slug.hashValue, slug: slug, quote: nil, anchorType: "text", anchorRef: nil, comment: "Annotation for \(slug)", createdAt: nil)]
  }

  func getReviewTargets(slug: String) async throws -> ReviewTargetsResponse {
    if let error = targetErrors[slug] {
      throw error
    }
    return targetResponses[slug] ?? ReviewTargetsResponse(slug: slug, targets: [], summary: .empty)
  }

  func updateReviewTarget(slug: String, targetKey: String, verdict: String, feedback: String?) async throws -> ReviewTargetJudgmentResponse {
    updateTargetCalls.append((slug, targetKey, verdict, feedback))
    if targetKey == delayedUpdateTargetKey {
      delayedUpdateTargetStarted?()
      await withCheckedContinuation { continuation in
        delayedUpdateTargetContinuation = continuation
      }
    }
    if let error = updateTargetErrors[targetKey] {
      throw error
    }
    if let response = updateTargetResponses[targetKey] {
      return response
    }

    var targets = targetResponses[slug]?.targets ?? []
    let existing = targets.first { $0.key == targetKey } ?? ReviewTarget(
      key: targetKey,
      label: "Target \(targetKey)",
      ordinal: targets.count + 1
    )
    let updated = ReviewTarget(
      databaseID: existing.databaseID,
      key: existing.key,
      label: existing.label,
      sourceType: existing.sourceType,
      anchorRef: existing.anchorRef,
      ordinal: existing.ordinal,
      verdict: verdict,
      feedback: feedback,
      decided: verdict != "unset",
      decidedAt: nil,
      updatedAt: nil
    )
    if let index = targets.firstIndex(where: { $0.key == targetKey }) {
      targets[index] = updated
    } else {
      targets.append(updated)
    }
    let summary = ReviewStoreSummaryFactory.summary(for: targets)
    targetResponses[slug] = ReviewTargetsResponse(slug: slug, targets: targets, summary: summary)
    return ReviewTargetJudgmentResponse(slug: slug, target: updated, summary: summary)
  }

  func createAnnotation(
    slug: String,
    quote: String?,
    anchorType: String,
    anchorRef: String?,
    comment: String,
    imageData: String?,
    imageMime: String?
  ) async throws -> ReviewAnnotation {
    if slug == delayedCreateAnnotationSlug {
      delayedCreateAnnotationStarted?()
      await withCheckedContinuation { continuation in
        delayedCreateAnnotationContinuation = continuation
      }
    }
    createAnnotationCalls.append((
      slug: slug,
      quote: quote,
      anchorType: anchorType,
      anchorRef: anchorRef,
      comment: comment,
      imageData: imageData,
      imageMime: imageMime
    ))
    if let error = createAnnotationErrors[slug] {
      throw error
    }
    if let response = createAnnotationResponses[slug] {
      return response
    }
    return ReviewAnnotation(
      id: annotationIDs[slug] ?? 10,
      slug: slug,
      quote: quote,
      anchorType: anchorType,
      anchorRef: anchorRef,
      comment: comment,
      imageData: imageData,
      imageMime: imageMime,
      createdAt: nil
    )
  }

  func deleteAnnotation(slug: String, id: Int) async throws -> DeleteAnnotationResponse {
    deleteAnnotationCalls.append((slug, id))
    if slug == delayedDeleteAnnotationSlug {
      delayedDeleteAnnotationStarted?()
      await withCheckedContinuation { continuation in
        delayedDeleteAnnotationContinuation = continuation
      }
    }
    if let response = deleteAnnotationResponses[slug] {
      return response
    }
    return DeleteAnnotationResponse(deleted: true)
  }

  func decide(slug: String, decision: String, feedback: String?) async throws -> DecisionResponse {
    if slug == delayedDecisionSlug {
      delayedDecisionStarted?()
      await withCheckedContinuation { continuation in
        delayedDecisionContinuation = continuation
      }
    }
    decisions.append((slug, decision, feedback))
    if let response = decisionResponses[slug] {
      return response
    }
    let responseStatus = Self.serverStatus(for: decision)
    if let index = items.firstIndex(where: { $0.slug == slug }) {
      items[index].status = responseStatus
      items[index].decision = decision
      items[index].feedback = feedback
      items[index].actionStatus = "succeeded"
      items[index].actionMessage = "\(decision) saved."
      items[index].updatedAt = "2026-06-11 11:00:00"
    }

    return DecisionResponse(
      status: responseStatus,
      decision: decision,
      slug: slug,
      queued: false,
      processed: true,
      sessionKey: "session-\(slug)",
      action: .init(status: "succeeded", message: "\(decision) saved."),
      requests: [],
      followups: []
    )
  }

  private static func serverStatus(for decision: String) -> String {
    switch decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "park", "noted", "no further action":
      return "archived"
    case "kill":
      return "killed"
    default:
      return "processed"
    }
  }

  func getActions(slug: String) async throws -> ReviewActionsResponse {
    if let error = actionErrors[slug] {
      throw error
    }
    return actionResponses[slug] ?? ReviewActionsResponse(slug: slug, requests: [], legacyActions: [])
  }

  func retryLatestAction(slug: String) async throws -> RetryResponse {
    if slug == delayedRetrySlug {
      delayedRetryStarted?()
      await withCheckedContinuation { continuation in
        delayedRetryContinuation = continuation
      }
    }
    retryCalls.append(slug)
    return retryResponses[slug] ?? RetryResponse(ok: true, slug: slug)
  }

  func getChatHistory(slug: String) async throws -> ChatHistoryResponse {
    chatHistoryCalls[slug, default: 0] += 1
    if let error = chatHistoryErrors[slug] {
      throw error
    }
    if slug == delayedChatSlug {
      delayedChatStarted?()
      await withCheckedContinuation { continuation in
        delayedChatContinuation = continuation
      }
    }
    if let response = chatHistoryResponses[slug] {
      return response
    }
    return ChatHistoryResponse(
      sessionKey: "session-\(slug)",
      messages: [ChatMessage(role: "assistant", content: "History for \(slug)", createdAt: nil)]
    )
  }

  func sendChat(slug: String, message: String) async throws -> ChatSendResponse {
    sendChatCalls.append((slug, message))
    if slug == delayedSendChatSlug {
      delayedSendChatStarted?()
      await withCheckedContinuation { continuation in
        delayedSendChatContinuation = continuation
      }
    }
    if let error = sendChatErrors[slug] {
      throw error
    }
    if let response = sendChatResponses[slug] {
      return response
    }
    return ChatSendResponse(
      sessionKey: "session-\(slug)",
      message: ChatMessage(role: "assistant", content: "Reply for \(slug)", createdAt: nil)
    )
  }

  func ttsStatus(slug: String) async throws -> AudioStatusResponse {
    if slug == delayedTTSSlug {
      delayedTTSStarted?()
      await withCheckedContinuation { continuation in
        delayedTTSContinuation = continuation
      }
    }
    if let error = ttsErrors[slug] {
      throw error
    }
    return AudioStatusResponse(status: "ready", url: "/tts-cache/\(slug).mp3", summary: nil)
  }

  func contextStatus(slug: String) async throws -> AudioStatusResponse {
    if let error = contextErrors[slug] {
      throw error
    }
    return AudioStatusResponse(status: "ready", url: "/audio/\(slug).mp3", summary: "Context for \(slug)")
  }

  func absoluteURL(for relativeOrAbsolute: String?) -> URL? {
    guard let relativeOrAbsolute = relativeOrAbsolute?.trimmingCharacters(in: .whitespacesAndNewlines),
          !relativeOrAbsolute.isEmpty else { return nil }
    if let url = URL(string: relativeOrAbsolute),
       let scheme = url.scheme?.lowercased() {
      return ["http", "https"].contains(scheme) ? url : nil
    }
    return URL(string: relativeOrAbsolute, relativeTo: URL(string: "http://localhost:3457")!)?.absoluteURL
  }

  private func item(_ slug: String) throws -> ReviewItem {
    guard let item = items.first(where: { $0.slug == slug }) else {
      throw TestError("Missing item \(slug)")
    }
    return item
  }
}

private enum ReviewStoreSummaryFactory {
  static func summary(for targets: [ReviewTarget]) -> ReviewTargetSummary {
    let approved = targets.filter(\.isApproved).count
    let rejected = targets.filter(\.isRejected).count
    let undecided = targets.filter(\.isUnset).count
    let decided = approved + rejected
    return ReviewTargetSummary(
      total: targets.count,
      approved: approved,
      rejected: rejected,
      undecided: undecided,
      decided: decided,
      complete: targets.isEmpty || undecided == 0
    )
  }
}

private enum Fixture {
  static func request(
    slug: String,
    proofJSON: String?,
    status: String = "succeeded"
  ) -> DecisionRequest {
    DecisionRequest(
      id: 1,
      slug: slug,
      kind: "agent_followup",
      summary: "Run downstream work",
      sensitivity: nil,
      status: status,
      proofJSON: proofJSON,
      confirmationSlug: nil,
      lastError: nil,
      updatedAt: nil
    )
  }

  static func item(
    slug: String,
    title: String,
    status: String,
    category: String = "general",
    updatedAt: String = "2026-06-11 09:00:00"
  ) -> ReviewItem {
    ReviewItem(
      databaseID: nil,
      slug: slug,
      title: title,
      category: category,
      status: status,
      decision: nil,
      actions: nil,
      feedback: nil,
      renderedHTML: "<p>\(title)</p>",
      markdown: nil,
      contentLength: 120,
      actionStatus: nil,
      actionMessage: nil,
      approvalStatus: nil,
      approvalMessage: nil,
      ttsStatus: "ready",
      contextStatus: "ready",
      contextSummary: "Context for \(slug)",
      decisionSchemaVersion: 3,
      createdAt: "2026-06-11 08:00:00",
      updatedAt: updatedAt
    )
  }

  static func target(
    key: String,
    label: String,
    verdict: String = "unset",
    ordinal: Int = 1
  ) -> ReviewTarget {
    ReviewTarget(
      key: key,
      label: label,
      sourceType: "task_list",
      anchorRef: "target:\(key)",
      ordinal: ordinal,
      verdict: verdict
    )
  }
}

private extension APIConfiguration {
  static func test(serverHost: String = "localhost", useDemoOnFailure: Bool) -> APIConfiguration {
    APIConfiguration(
      serverURL: URL(string: "http://\(serverHost):3457")!,
      username: "",
      password: "",
      useDemoOnFailure: useDemoOnFailure
    )
  }
}

private struct TestError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    message
  }
}
