import Combine
import Foundation

@MainActor
final class ReviewStore: ObservableObject {
  private struct RetryItemActionOverride {
    let status: String
    let message: String
  }

  @Published var configuration: APIConfiguration
  @Published var selectedTab: ReviewTab = .pending
  @Published var items: [ReviewItem] = []
  @Published var selectedSlug: String?
  @Published var selectedItem: ReviewItem?
  @Published var annotations: [ReviewAnnotation] = []
  @Published var reviewTargets: [ReviewTarget] = []
  @Published var reviewTargetSummary: ReviewTargetSummary = .empty
  @Published var reviewTargetLoadError: String?
  @Published var decisionRequests: [DecisionRequest] = []
  @Published var decisionFollowups: [DecisionResponse.FollowupSummary] = []
  @Published var legacyActions: [LegacyAction] = []
  @Published var chatMessages: [ChatMessage] = []
  @Published var ttsStatus: AudioStatusResponse?
  @Published var contextStatus: AudioStatusResponse?
  @Published var isLoading = false
  @Published var detailLoading = false
  @Published var isUsingDemoData = false
  @Published var bannerMessage: String?

  private let clientFactory: (APIConfiguration) -> TurfReviewServicing
  private var configurationRevision = 0
  private var activeRefreshRequestID: UUID?
  private var activeDetailRequestID: UUID?
  private var userSelectionRevision = 0
  private var acceptedDecisionOverrides: [String: ReviewItem] = [:]
  private var acceptedRetryRequestOverrides: [String: [Int: DecisionRequest]] = [:]
  private var acceptedRetryActionOverrides: [String: [Int: LegacyAction]] = [:]
  private var acceptedRetryItemActionOverrides: [String: RetryItemActionOverride] = [:]
  private var acceptedReviewTargetOverrides: [String: [String: ReviewTarget]] = [:]
  private var hasLoadedLiveQueue = false
  @Published private var submittingDecisionSlugs: Set<String> = []
  @Published private var retryingActionSlugs: Set<String> = []
  @Published private var sendingChatSlugs: Set<String> = []
  @Published private var updatingReviewTargetKeys: Set<String> = []
  private var chatSessionKeys: [String: String] = [:]
  private var localChatErrorMessageIDs: Set<UUID> = []

  init(
    configuration: APIConfiguration = .load(),
    clientFactory: @escaping (APIConfiguration) -> TurfReviewServicing = { TurfReviewClient(configuration: $0) }
  ) {
    self.configuration = configuration
    self.clientFactory = clientFactory
  }

  private var client: TurfReviewServicing {
    clientFactory(configuration)
  }

  var visibleItems: [ReviewItem] {
    switch selectedTab {
    case .pending:
      return items.filter(\.isPending)
    case .parked:
      return items.filter(\.isParked)
    case .decided:
      return items.filter(\.isDecided)
    }
  }

  var counts: [ReviewTab: Int] {
    [
      .pending: items.filter(\.isPending).count,
      .parked: items.filter(\.isParked).count,
      .decided: items.filter(\.isDecided).count,
    ]
  }

  func selectTab(_ tab: ReviewTab) async {
    userSelectionRevision += 1
    selectedTab = tab
    ensureSelectedItemExists()
    if let selectedSlug {
      await loadDetail(slug: selectedSlug)
    }
  }

  func selectItem(slug: String?) async {
    userSelectionRevision += 1
    guard let slug else {
      selectedSlug = nil
      clearDetail()
      return
    }
    await loadDetail(slug: slug)
  }

  func openFollowupReview(_ followup: DecisionResponse.FollowupSummary) async {
    await selectItem(slug: followup.slug)
  }

  func openConfirmationReview(slug rawSlug: String?) async {
    guard let slug = rawSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
          !slug.isEmpty else { return }
    await selectItem(slug: slug)
  }

  func isSubmittingDecision(slug: String?) -> Bool {
    guard let slug else { return false }
    return submittingDecisionSlugs.contains(slug)
  }

  func isRetryingAction(slug: String?) -> Bool {
    guard let slug else { return false }
    return retryingActionSlugs.contains(slug)
  }

  func isSendingChat(slug: String?) -> Bool {
    guard let slug else { return false }
    return sendingChatSlugs.contains(slug)
  }

  func isUpdatingReviewTarget(_ target: ReviewTarget) -> Bool {
    guard let selectedSlug else { return false }
    return updatingReviewTargetKeys.contains(Self.reviewTargetUpdateKey(slug: selectedSlug, targetKey: target.key))
  }

  func refresh(useDemoFallback: Bool = true) async {
    let requestID = UUID()
    activeRefreshRequestID = requestID
    isLoading = true
    defer {
      finishRefreshLoading(requestID)
    }

    do {
      let loaded = try await client.listItems()
      guard activeRefreshRequestID == requestID else { return }
      items = queueItemsPreservingAcceptedState(from: loaded)
      isUsingDemoData = false
      hasLoadedLiveQueue = true
      bannerMessage = nil
      ensureSelectedItemExists()
      finishRefreshLoading(requestID)
      if let selectedSlug {
        await loadDetail(slug: selectedSlug)
      }
    } catch {
      guard activeRefreshRequestID == requestID else { return }
      if shouldUseDemoFallback(afterRefreshFailureWith: useDemoFallback) {
        items = normalizedQueueItems(DemoData.items)
        isUsingDemoData = true
        bannerMessage = "Showing demo data. \(error.localizedDescription)"
        ensureSelectedItemExists()
        finishRefreshLoading(requestID)
        if let selectedSlug {
          await loadDetail(slug: selectedSlug)
        }
      } else {
        bannerMessage = error.localizedDescription
      }
    }
  }

  func saveConfiguration(_ newConfiguration: APIConfiguration) async {
    configurationRevision += 1
    submittingDecisionSlugs = []
    retryingActionSlugs = []
    sendingChatSlugs = []
    chatSessionKeys = [:]
    acceptedDecisionOverrides = [:]
    acceptedRetryRequestOverrides = [:]
    acceptedRetryActionOverrides = [:]
    acceptedRetryItemActionOverrides = [:]
    acceptedReviewTargetOverrides = [:]
    hasLoadedLiveQueue = false
    updatingReviewTargetKeys = []
    configuration = newConfiguration
    configuration.save()
    items = []
    isUsingDemoData = false
    bannerMessage = nil
    selectedSlug = nil
    clearDetail()
    await refresh()
  }

  func loadDetail(slug: String) async {
    let isSameSelection = selectedSlug == slug && selectedItem?.slug == slug
    selectedSlug = slug
    if !isSameSelection {
      prepareDetailForLoading(slug: slug, clearBanner: !isUsingDemoData)
    }

    let requestID = UUID()
    activeDetailRequestID = requestID
    detailLoading = true
    defer {
      if activeDetailRequestID == requestID {
        detailLoading = false
      }
    }

    if isUsingDemoData {
      guard activeDetailRequestID == requestID, selectedSlug == slug else { return }
      selectedItem = items.first { $0.slug == slug }
      annotations = DemoData.annotations.filter { $0.slug == slug }
      let demoTargets = DemoData.reviewTargets[slug] ?? []
      reviewTargets = demoTargets
      reviewTargetSummary = Self.summary(for: demoTargets)
      reviewTargetLoadError = nil
      decisionRequests = DemoData.requests.filter { $0.slug == slug }
      decisionFollowups = []
      legacyActions = []
      chatMessages = [
        ChatMessage(role: "assistant", content: "Demo mode is ready. Ask what matters or add a decision note.", createdAt: nil)
      ]
      ttsStatus = AudioStatusResponse(status: selectedItem?.ttsStatus, url: nil, summary: nil)
      contextStatus = AudioStatusResponse(status: selectedItem?.contextStatus, url: nil, summary: selectedItem?.contextSummary)
      return
    }

    do {
      async let item = client.getItem(slug: slug)
      async let annotationResult = capture { try await client.getAnnotations(slug: slug) }
      async let targetResult = capture { try await client.getReviewTargets(slug: slug) }
      async let actionResult = capture { try await client.getActions(slug: slug) }
      async let ttsResult = capture { try await client.ttsStatus(slug: slug) }
      async let contextResult = capture { try await client.contextStatus(slug: slug) }

      let loadedItem = try await item
      try validateReviewItem(loadedItem, expectedSlug: slug)
      let loadedAnnotations = await annotationResult
      let loadedTargets = await targetResult
      let loadedActions = await actionResult
      let loadedTTS = await ttsResult
      let loadedContext = await contextResult
      guard activeDetailRequestID == requestID, selectedSlug == slug else { return }
      mergeLoadedDetailItemIntoQueue(loadedItem)
      let partialErrors = applyDetailSections(
        expectedSlug: slug,
        annotations: loadedAnnotations,
        targets: loadedTargets,
        actions: loadedActions,
        tts: loadedTTS,
        context: loadedContext
      )
      bannerMessage = partialErrors.isEmpty ? nil : "Some detail sections could not load: \(partialErrors.joined(separator: "; "))"
      await loadChat(slug: slug, requestID: requestID)
    } catch {
      if activeDetailRequestID == requestID, selectedSlug == slug {
        if !isSameSelection {
          prepareDetailForLoading(slug: slug, clearBanner: false)
        }
        bannerMessage = error.localizedDescription
      }
    }
  }

  @discardableResult
  func createAnnotation(quote: String?, anchorRef: String?, comment: String) async -> Bool {
    guard let slug = selectedSlug else { return false }
    return await createAnnotation(for: slug, quote: quote, anchorRef: anchorRef, comment: comment)
  }

  @discardableResult
  func createAnnotation(
    for slug: String?,
    quote: String?,
    anchorType: String = "text",
    anchorRef: String?,
    comment: String,
    imageData: String? = nil,
    imageMime: String? = nil
  ) async -> Bool {
    await createAnnotationRecord(
      for: slug,
      quote: quote,
      anchorType: anchorType,
      anchorRef: anchorRef,
      comment: comment,
      imageData: imageData,
      imageMime: imageMime
    ) != nil
  }

  @discardableResult
  func createAnnotationRecord(
    for slug: String?,
    quote: String?,
    anchorType: String = "text",
    anchorRef: String?,
    comment: String,
    imageData: String? = nil,
    imageMime: String? = nil
  ) async -> ReviewAnnotation? {
    guard let slug else { return nil }
    let revision = configurationRevision
    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if isUsingDemoData {
      guard selectedSlug == slug else { return nil }
      let next = (annotations.map(\.id).max() ?? 0) + 1
      let annotation = ReviewAnnotation(
        id: next,
        slug: slug,
        quote: quote,
        anchorType: anchorType,
        anchorRef: anchorRef,
        comment: trimmed,
        imageData: imageData,
        imageMime: imageMime,
        createdAt: nil
      )
      annotations.append(annotation)
      bannerMessage = nil
      return annotation
    }

    do {
      let annotation = try await client.createAnnotation(
        slug: slug,
        quote: quote,
        anchorType: anchorType,
        anchorRef: anchorRef,
        comment: trimmed,
        imageData: imageData,
        imageMime: imageMime
      )
      try validateAnnotation(annotation, expectedSlug: slug)
      guard configurationRevision == revision else { return nil }
      guard selectedSlug == slug else { return annotation }
      annotations.append(annotation)
      bannerMessage = nil
      return annotation
    } catch {
      guard isCurrent(revision: revision, slug: slug) else { return nil }
      bannerMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func deleteAnnotation(_ annotation: ReviewAnnotation) async -> Bool {
    guard let slug = selectedSlug else { return false }
    return await deleteAnnotation(annotation, for: slug)
  }

  @discardableResult
  func deleteAnnotation(_ annotation: ReviewAnnotation, for slug: String?) async -> Bool {
    guard let slug else { return false }
    let revision = configurationRevision
    do {
      try validateAnnotationDelete(annotation, expectedSlug: slug)
    } catch {
      guard isCurrent(revision: revision, slug: slug) else { return false }
      bannerMessage = error.localizedDescription
      return false
    }

    if isUsingDemoData {
      guard selectedSlug == slug else { return false }
      annotations.removeAll { $0.id == annotation.id }
      bannerMessage = nil
      return true
    }

    do {
      let response = try await client.deleteAnnotation(slug: slug, id: annotation.id)
      try validateDeletedAnnotation(response, annotationID: annotation.id)
      guard configurationRevision == revision else { return false }
      guard selectedSlug == slug else { return true }
      annotations.removeAll { $0.id == annotation.id }
      bannerMessage = nil
      return true
    } catch {
      guard isCurrent(revision: revision, slug: slug) else { return false }
      bannerMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func updateReviewTarget(_ target: ReviewTarget, verdict: String, feedback: String? = nil) async -> Bool {
    guard let slug = selectedSlug else { return false }
    return await updateReviewTarget(target, for: slug, verdict: verdict, feedback: feedback)
  }

  @discardableResult
  func updateReviewTarget(_ target: ReviewTarget, for slug: String?, verdict: String, feedback: String? = nil) async -> Bool {
    guard let slug else { return false }
    let revision = configurationRevision
    let normalizedVerdict = Self.normalizedVerdict(verdict)
    guard !normalizedVerdict.isEmpty else { return false }
    let updateKey = Self.reviewTargetUpdateKey(slug: slug, targetKey: target.key)
    guard !updatingReviewTargetKeys.contains(updateKey) else { return false }
    updatingReviewTargetKeys.insert(updateKey)
    defer {
      if configurationRevision == revision {
        updatingReviewTargetKeys.remove(updateKey)
      }
    }

    if isUsingDemoData {
      guard selectedSlug == slug else { return false }
      applyLocalReviewTarget(
        target: target,
        verdict: normalizedVerdict,
        feedback: feedback
      )
      bannerMessage = nil
      return true
    }

    do {
      let response = try await client.updateReviewTarget(
        slug: slug,
        targetKey: target.key,
        verdict: normalizedVerdict,
        feedback: feedback
      )
      try validateReviewTargetJudgment(response, expectedSlug: slug, expectedTargetKey: target.key)
      guard configurationRevision == revision else { return true }
      guard selectedSlug == slug else {
        if let acceptedTarget = response.target {
          acceptedReviewTargetOverrides[slug, default: [:]][acceptedTarget.key] = acceptedTarget
        }
        return true
      }
      if let acceptedTarget = response.target {
        replaceReviewTarget(acceptedTarget)
        acceptedReviewTargetOverrides[slug, default: [:]][acceptedTarget.key] = acceptedTarget
      }
      reviewTargetSummary = response.summary
      bannerMessage = nil
      return true
    } catch {
      guard isCurrent(revision: revision, slug: slug) else { return false }
      bannerMessage = error.localizedDescription
      return false
    }
  }

  func submitDecision(_ decision: String, feedback: String) async {
    guard let slug = selectedSlug else { return }
    await submitDecision(for: slug, decision, feedback: feedback)
  }

  func submitDecision(for slug: String, _ decision: String, feedback: String) async {
    let revision = configurationRevision
    let sourceTab = selectedTab
    let resolvedDecision = canonicalDecision(decision, for: slug)
    guard !resolvedDecision.isEmpty else { return }
    guard !submittingDecisionSlugs.contains(slug) else { return }
    submittingDecisionSlugs.insert(slug)
    defer {
      if configurationRevision == revision {
        submittingDecisionSlugs.remove(slug)
      }
    }

    if isUsingDemoData {
      guard selectedSlug == slug else { return }
      applyDemoDecision(resolvedDecision, feedback: feedback)
      return
    }

    do {
      let response = try await client.decide(slug: slug, decision: resolvedDecision, feedback: feedback)
      try validateAcceptedDecision(response, expectedSlug: slug, expectedDecision: resolvedDecision)
      let successMessage = response.action.message
      let acceptedRequests = decisionRequests(from: response, slug: slug)
      let acceptedFollowups = decisionFollowups(from: response)
      let acceptedItem = acceptedDecisionItem(
        slug: slug,
        decision: response.decision,
        feedback: feedback,
        itemStatus: response.status,
        actionStatus: response.action.status,
        actionMessage: successMessage
      )
      guard configurationRevision == revision else { return }
      guard selectedSlug == slug else {
        if let acceptedItem {
          mergeAcceptedDecisionIntoQueue(acceptedItem)
        }
        await refresh(useDemoFallback: false)
        if configurationRevision == revision,
           let acceptedItem {
          mergeAcceptedDecisionIntoQueue(acceptedItem)
        }
        if configurationRevision == revision {
          bannerMessage = successMessage
        }
        return
      }
      let acceptedSelectedItem = applyAcceptedDecision(
        response.decision,
        feedback: feedback,
        itemStatus: response.status,
        actionStatus: response.action.status,
        actionMessage: successMessage
      )
      clearLoadedDetailSectionsForSelectedItem()
      decisionRequests = acceptedRequests
      decisionFollowups = acceptedFollowups
      let selectionRevisionAfterAccept = userSelectionRevision
      await refresh(useDemoFallback: false)
      if configurationRevision == revision,
         let acceptedSelectedItem {
        if sourceTab == .pending, userSelectionRevision == selectionRevisionAfterAccept {
          preserveAcceptedDecisionIfNeeded(acceptedSelectedItem, preferredTab: .pending)
        } else if selectedSlug == slug {
          preserveAcceptedDecisionIfNeeded(acceptedSelectedItem, preferredTab: tabAfterDecision(response.decision))
        } else {
          mergeAcceptedDecisionIntoQueue(acceptedSelectedItem)
        }
      }
      if configurationRevision == revision,
         selectedSlug == slug {
        preserveAcceptedDecisionRequestsIfNeeded(acceptedRequests, slug: slug)
        preserveAcceptedDecisionFollowupsIfNeeded(acceptedFollowups, slug: slug)
      }
      bannerMessage = successMessage
    } catch {
      guard isCurrent(revision: revision, slug: slug) else { return }
      bannerMessage = error.localizedDescription
    }
  }

  func retryLatestAction() async {
    guard let slug = selectedSlug else { return }
    await retryLatestAction(for: slug)
  }

  func retryLatestAction(for slug: String) async {
    guard selectedSlug == slug else { return }
    let revision = configurationRevision
    guard !retryingActionSlugs.contains(slug) else { return }
    retryingActionSlugs.insert(slug)
    defer {
      if configurationRevision == revision {
        retryingActionSlugs.remove(slug)
      }
    }

    if isUsingDemoData {
      bannerMessage = "Demo retry queued."
      return
    }

    do {
      let expectedRetryTarget = latestRetryTarget()
      let response = try await client.retryLatestAction(slug: slug)
      guard isCurrent(revision: revision, slug: slug) else { return }
      try validateAcceptedRetry(response, expectedSlug: slug, expectedTarget: expectedRetryTarget)
      applyAcceptedRetry(response, slug: slug)
      let locallyQueuedRequests = decisionRequests
      let locallyQueuedLegacyActions = legacyActions
      await loadDetail(slug: slug)
      guard isCurrent(revision: revision, slug: slug) else { return }
      decisionRequests = locallyQueuedRequests
      legacyActions = locallyQueuedLegacyActions
      applyAcceptedRetry(response, slug: slug)
      bannerMessage = "Retry queued."
    } catch {
      guard isCurrent(revision: revision, slug: slug) else { return }
      bannerMessage = error.localizedDescription
    }
  }

  func loadChat(slug: String) async {
    await loadChat(slug: slug, requestID: activeDetailRequestID)
  }

  private func loadChat(slug: String, requestID: UUID?) async {
    if isUsingDemoData { return }
    do {
      let history = try await client.getChatHistory(slug: slug)
      guard selectedSlug == slug, activeDetailRequestID == requestID else { return }
      chatSessionKeys[slug] = history.sessionKey
      chatMessages = history.messages
      localChatErrorMessageIDs = []
    } catch {
      guard selectedSlug == slug, activeDetailRequestID == requestID else { return }
      let errorMessage = ChatMessage(role: "system", content: error.localizedDescription, createdAt: nil)
      if chatMessages.isEmpty {
        chatMessages = [errorMessage]
        localChatErrorMessageIDs = [errorMessage.id]
      } else {
        removeLocalChatErrorMessages()
        chatMessages.append(errorMessage)
        localChatErrorMessageIDs.insert(errorMessage.id)
      }
    }
  }

  @discardableResult
  func sendChat(_ text: String) async -> Bool {
    guard let slug = selectedSlug else { return false }
    return await sendChat(text, for: slug)
  }

  @discardableResult
  func sendChat(_ text: String, for slug: String?) async -> Bool {
    guard selectedSlug == slug else { return false }
    guard let slug else { return false }
    let revision = configurationRevision
    guard !sendingChatSlugs.contains(slug) else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    sendingChatSlugs.insert(slug)
    defer {
      if configurationRevision == revision {
        sendingChatSlugs.remove(slug)
      }
    }

    let userMessage = ChatMessage(role: "user", content: trimmed, createdAt: nil)
    chatMessages.append(userMessage)
    let userMessageID = userMessage.id

    if isUsingDemoData {
      chatMessages.append(ChatMessage(role: "assistant", content: "Demo reply: this review needs a concrete decision and any source-risk feedback you want Benji to carry downstream.", createdAt: nil))
      return true
    }

    do {
      let response = try await client.sendChat(slug: slug, message: trimmed)
      guard configurationRevision == revision else { return true }
      guard selectedSlug == slug else { return false }
      try validateChatSession(response.sessionKey, expected: chatSessionKeys[slug], slug: slug)
      chatSessionKeys[slug] = response.sessionKey
      removeLocalChatErrorMessages()
      chatMessages.append(response.message)
      return true
    } catch {
      guard configurationRevision == revision else { return true }
      guard selectedSlug == slug else { return false }
      chatMessages.removeAll { $0.id == userMessageID }
      removeLocalChatErrorMessages()
      let errorMessage = ChatMessage(role: "system", content: error.localizedDescription, createdAt: nil)
      chatMessages.append(errorMessage)
      localChatErrorMessageIDs.insert(errorMessage.id)
      return false
    }
  }

  func absoluteAudioURL(_ relativeOrAbsolute: String?) -> URL? {
    client.absoluteURL(for: relativeOrAbsolute)
  }

  func absoluteFollowupURL(_ relativeOrAbsolute: String?) -> URL? {
    client.absoluteURL(for: relativeOrAbsolute)
  }

  private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do {
      return .success(try await operation())
    } catch {
      return .failure(error)
    }
  }

  private func shouldUseDemoFallback(afterRefreshFailureWith useDemoFallback: Bool) -> Bool {
    useDemoFallback && configuration.useDemoOnFailure && !hasLoadedLiveQueue
  }

  private func finishRefreshLoading(_ requestID: UUID) {
    if activeRefreshRequestID == requestID {
      isLoading = false
    }
  }

  private func applyDetailSections(
    expectedSlug: String,
    annotations loadedAnnotations: Result<[ReviewAnnotation], Error>,
    targets loadedTargets: Result<ReviewTargetsResponse, Error>,
    actions loadedActions: Result<ReviewActionsResponse, Error>,
    tts loadedTTS: Result<AudioStatusResponse, Error>,
    context loadedContext: Result<AudioStatusResponse, Error>
  ) -> [String] {
    var errors: [String] = []

    switch loadedAnnotations {
    case .success(let loadedAnnotations):
      do {
        try validateAnnotations(loadedAnnotations, expectedSlug: expectedSlug)
        annotations = loadedAnnotations
      } catch {
        clearAnnotationsIfTheyDoNotBelong(to: expectedSlug)
        errors.append(error.localizedDescription)
      }
    case .failure(let error):
      clearAnnotationsIfTheyDoNotBelong(to: expectedSlug)
      errors.append(error.localizedDescription)
    }

    switch loadedTargets {
    case .success(let loadedTargets):
      do {
        try validateReviewTargets(loadedTargets, expectedSlug: expectedSlug)
        applyReviewTargets(reviewTargetsPreservingAcceptedJudgments(loadedTargets, slug: expectedSlug))
        reviewTargetLoadError = nil
      } catch {
        clearReviewTargetsIfTheyDoNotBelong(to: expectedSlug)
        reviewTargetLoadError = error.localizedDescription
        errors.append(error.localizedDescription)
      }
    case .failure(let error):
      clearReviewTargetsIfTheyDoNotBelong(to: expectedSlug)
      reviewTargetLoadError = error.localizedDescription
      errors.append(error.localizedDescription)
    }

    switch loadedActions {
    case .success(let actions):
      do {
        try validateActions(actions, expectedSlug: expectedSlug)
        let preservedActions = actionsPreservingAcceptedRetries(actions, slug: expectedSlug)
        decisionRequests = preservedActions.requests
        legacyActions = preservedActions.legacyActions
      } catch {
        clearActionsIfTheyDoNotBelong(to: expectedSlug)
        errors.append(error.localizedDescription)
      }
    case .failure(let error):
      clearActionsIfTheyDoNotBelong(to: expectedSlug)
      errors.append(error.localizedDescription)
    }

    switch loadedTTS {
    case .success(let loadedTTS):
      ttsStatus = loadedTTS
    case .failure(let error):
      ttsStatus = AudioStatusResponse(status: selectedItem?.ttsStatus, url: nil, summary: nil)
      errors.append(error.localizedDescription)
    }

    switch loadedContext {
    case .success(let loadedContext):
      contextStatus = loadedContext
    case .failure(let error):
      contextStatus = AudioStatusResponse(status: selectedItem?.contextStatus, url: nil, summary: selectedItem?.contextSummary)
      errors.append(error.localizedDescription)
    }

    return errors
  }

  private func clearAnnotationsIfTheyDoNotBelong(to expectedSlug: String) {
    guard !annotations.allSatisfy({ annotation in
      annotation.slug == nil || annotation.slug == expectedSlug
    }) else { return }
    annotations = []
  }

  private func clearReviewTargetsIfTheyDoNotBelong(to expectedSlug: String) {
    guard selectedSlug == expectedSlug else {
      reviewTargets = []
      reviewTargetSummary = .empty
      reviewTargetLoadError = nil
      return
    }
  }

  private func clearActionsIfTheyDoNotBelong(to expectedSlug: String) {
    let requestsMatch = decisionRequests.allSatisfy { request in
      request.slug == nil || request.slug == expectedSlug
    }
    let legacyActionsMatch = legacyActions.allSatisfy { action in
      action.slug == expectedSlug
    }
    guard requestsMatch && legacyActionsMatch else {
      decisionRequests = []
      legacyActions = []
      return
    }
  }

  private func sortNewestFirst(_ left: ReviewItem, _ right: ReviewItem) -> Bool {
    let leftTimestamp = sortTimestamp(for: left)
    let rightTimestamp = sortTimestamp(for: right)

    switch (leftTimestamp.date, rightTimestamp.date) {
    case (.some(let leftDate), .some(let rightDate)) where leftDate != rightDate:
      return leftDate > rightDate
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      if leftTimestamp.raw != rightTimestamp.raw {
        return leftTimestamp.raw > rightTimestamp.raw
      }
      return left.slug < right.slug
    }
  }

  private func normalizedQueueItems(_ loadedItems: [ReviewItem]) -> [ReviewItem] {
    var seenSlugs = Set<String>()
    return loadedItems
      .sorted(by: sortNewestFirst)
      .filter { item in
        seenSlugs.insert(item.slug).inserted
      }
  }

  private func sortTimestamp(for item: ReviewItem) -> (date: Date?, raw: String) {
    let raw = [item.updatedAt, item.createdAt]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""

    return (Self.parseServerDate(raw), raw)
  }

  private static func parseServerDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFormatter.date(from: trimmed) {
      return date
    }

    isoFormatter.formatOptions = [.withInternetDateTime]
    if let date = isoFormatter.date(from: trimmed) {
      return date
    }

    let sqliteFormatter = DateFormatter()
    sqliteFormatter.locale = Locale(identifier: "en_US_POSIX")
    sqliteFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    sqliteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let date = sqliteFormatter.date(from: trimmed) {
      return date
    }

    sqliteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    if let date = sqliteFormatter.date(from: trimmed) {
      return date
    }

    sqliteFormatter.dateFormat = "yyyy-MM-dd"
    return sqliteFormatter.date(from: trimmed)
  }

  private func ensureSelectedItemExists() {
    if let selectedSlug, visibleItems.contains(where: { $0.slug == selectedSlug }) {
      return
    }
    guard let firstVisible = visibleItems.first else {
      selectedSlug = nil
      clearDetail()
      return
    }
    selectedSlug = firstVisible.slug
  }

  private func clearDetail() {
    activeDetailRequestID = nil
    selectedItem = nil
    clearLoadedDetailSectionsForSelectedItem()
    detailLoading = false
  }

  private func isCurrent(revision: Int, slug: String) -> Bool {
    configurationRevision == revision && selectedSlug == slug
  }

  private func prepareDetailForLoading(slug: String, clearBanner: Bool = true) {
    selectedItem = items.first { $0.slug == slug }
    annotations = []
    reviewTargets = []
    reviewTargetSummary = .empty
    reviewTargetLoadError = nil
    decisionRequests = []
    decisionFollowups = []
    legacyActions = []
    chatMessages = []
    localChatErrorMessageIDs = []
    ttsStatus = AudioStatusResponse(status: selectedItem?.ttsStatus, url: nil, summary: nil)
    contextStatus = AudioStatusResponse(status: selectedItem?.contextStatus, url: nil, summary: selectedItem?.contextSummary)
    if clearBanner {
      bannerMessage = nil
    }
  }

  private func removeLocalChatErrorMessages() {
    guard !localChatErrorMessageIDs.isEmpty else { return }
    chatMessages.removeAll { localChatErrorMessageIDs.contains($0.id) }
    localChatErrorMessageIDs = []
  }

  private func clearLoadedDetailSectionsForSelectedItem() {
    annotations = []
    reviewTargets = []
    reviewTargetSummary = .empty
    reviewTargetLoadError = nil
    decisionRequests = []
    decisionFollowups = []
    legacyActions = []
    chatMessages = []
    localChatErrorMessageIDs = []
    ttsStatus = selectedItem.map { AudioStatusResponse(status: $0.ttsStatus, url: nil, summary: nil) }
    contextStatus = selectedItem.map { AudioStatusResponse(status: $0.contextStatus, url: nil, summary: $0.contextSummary) }
  }

  private func applyReviewTargets(_ response: ReviewTargetsResponse) {
    reviewTargets = response.targets
    reviewTargetSummary = response.summary
  }

  private func replaceReviewTarget(_ target: ReviewTarget) {
    if let index = reviewTargets.firstIndex(where: { $0.key == target.key }) {
      reviewTargets[index] = target
    } else {
      reviewTargets.append(target)
      reviewTargets.sort { $0.ordinal < $1.ordinal }
    }
  }

  private func applyLocalReviewTarget(target: ReviewTarget, verdict: String, feedback: String?) {
    let updated = ReviewTarget(
      databaseID: target.databaseID,
      key: target.key,
      label: target.label,
      sourceType: target.sourceType,
      anchorRef: target.anchorRef,
      ordinal: target.ordinal,
      verdict: verdict,
      feedback: Self.trimmedOptional(feedback),
      decided: verdict != "unset",
      decidedAt: nil,
      updatedAt: nil
    )
    replaceReviewTarget(updated)
    reviewTargetSummary = Self.summary(for: reviewTargets)
  }

  private func reviewTargetsPreservingAcceptedJudgments(_ response: ReviewTargetsResponse, slug: String) -> ReviewTargetsResponse {
    guard let overrides = acceptedReviewTargetOverrides[slug], !overrides.isEmpty else {
      return response
    }
    let targets = response.targets.map { target in
      overrides[target.key] ?? target
    }
    return ReviewTargetsResponse(
      slug: response.slug,
      targets: targets,
      summary: Self.summary(for: targets)
    )
  }

  private static func summary(for targets: [ReviewTarget]) -> ReviewTargetSummary {
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

  private static func normalizedVerdict(_ verdict: String) -> String {
    switch verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "yes", "approve", "approved", "accept", "accepted":
      return "approved"
    case "no", "reject", "rejected", "decline", "declined":
      return "rejected"
    case "unset", "clear":
      return "unset"
    default:
      return ""
    }
  }

  private static func trimmedOptional(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func reviewTargetUpdateKey(slug: String, targetKey: String) -> String {
    "\(slug)\u{1f}\(targetKey)"
  }

  private func tabAfterDecision(_ decision: String) -> ReviewTab {
    normalizedDecisionToken(decision) == "park" ? .parked : .decided
  }

  private func tab(for item: ReviewItem) -> ReviewTab {
    if item.isPending {
      return .pending
    }
    if item.isParked {
      return .parked
    }
    return .decided
  }

  private func mergeLoadedDetailItemIntoQueue(_ loadedItem: ReviewItem) {
    let item = itemPreservingAcceptedRetry(itemPreservingAcceptedDecision(loadedItem))
    if let index = items.firstIndex(where: { $0.slug == item.slug }) {
      items[index] = item
    } else {
      items.append(item)
    }
    items = normalizedQueueItems(items)
    selectedItem = items.first { $0.slug == item.slug } ?? item
    selectedTab = tab(for: item)
  }

  private func applyDemoDecision(_ decision: String, feedback: String) {
    applyAcceptedDecision(
      decision,
      feedback: feedback,
      itemStatus: serverStatus(for: decision),
      actionStatus: "succeeded",
      actionMessage: "\(decision) saved in demo mode."
    )
    bannerMessage = "\(decision) saved in demo mode."
  }

  @discardableResult
  private func applyAcceptedDecision(
    _ decision: String,
    feedback: String,
    itemStatus: String,
    actionStatus: String,
    actionMessage: String
  ) -> ReviewItem? {
    guard let slug = selectedSlug,
          let acceptedItem = acceptedDecisionItem(
            slug: slug,
            decision: decision,
            feedback: feedback,
            itemStatus: itemStatus,
            actionStatus: actionStatus,
            actionMessage: actionMessage
          ) else { return nil }
    mergeAcceptedDecisionIntoQueue(acceptedItem)
    selectedItem = items.first { $0.slug == slug } ?? acceptedItem
    return selectedItem
  }

  private func acceptedDecisionItem(
    slug: String,
    decision: String,
    feedback: String,
    itemStatus: String,
    actionStatus: String,
    actionMessage: String
  ) -> ReviewItem? {
    guard var item = items.first(where: { $0.slug == slug })
      ?? (selectedItem?.slug == slug ? selectedItem : nil) else { return nil }
    item.status = itemStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    item.decision = decision.trimmingCharacters(in: .whitespacesAndNewlines)
    item.feedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    item.actionStatus = actionStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    item.actionMessage = actionMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    return item
  }

  private func mergeAcceptedDecisionIntoQueue(_ acceptedItem: ReviewItem) {
    acceptedDecisionOverrides[acceptedItem.slug] = acceptedItem
    if let index = items.firstIndex(where: { $0.slug == acceptedItem.slug }) {
      items[index] = acceptedItem
    } else {
      items.append(acceptedItem)
    }
    items = normalizedQueueItems(items)
    if selectedItem?.slug == acceptedItem.slug {
      selectedItem = items.first { $0.slug == acceptedItem.slug } ?? acceptedItem
    }
  }

  private func decisionRequests(from response: DecisionResponse, slug: String) -> [DecisionRequest] {
    response.requests.map { request in
      DecisionRequest(
        id: request.id,
        slug: slug,
        kind: request.kind,
        summary: request.summary,
        sensitivity: nil,
        status: request.status,
        proofJSON: nil,
        confirmationSlug: nil,
        lastError: nil,
        updatedAt: nil
      )
    }
  }

  private func decisionFollowups(from response: DecisionResponse) -> [DecisionResponse.FollowupSummary] {
    response.followups.compactMap { followup in
      let slug = followup.slug.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = followup.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let url = followup.url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !slug.isEmpty,
            !title.isEmpty,
            client.absoluteURL(for: url) != nil else {
        return nil
      }
      return .init(slug: slug, title: title, url: url)
    }
  }

  private func preserveAcceptedDecisionRequestsIfNeeded(_ acceptedRequests: [DecisionRequest], slug: String) {
    guard selectedSlug == slug, !acceptedRequests.isEmpty else { return }
    let visibleRequestIDs = Set(decisionRequests.map(\.id))
    let missingRequests = acceptedRequests.filter { !visibleRequestIDs.contains($0.id) }
    guard !missingRequests.isEmpty else { return }
    decisionRequests = missingRequests + decisionRequests
  }

  private func preserveAcceptedDecisionFollowupsIfNeeded(_ acceptedFollowups: [DecisionResponse.FollowupSummary], slug: String) {
    guard selectedSlug == slug, !acceptedFollowups.isEmpty else { return }
    let visibleFollowupSlugs = Set(decisionFollowups.map(\.slug))
    let missingFollowups = acceptedFollowups.filter { !visibleFollowupSlugs.contains($0.slug) }
    guard !missingFollowups.isEmpty else { return }
    decisionFollowups = missingFollowups + decisionFollowups
  }

  private func preserveAcceptedDecisionIfNeeded(_ acceptedItem: ReviewItem, preferredTab: ReviewTab) {
    let previousSelectedSlug = selectedSlug
    acceptedDecisionOverrides[acceptedItem.slug] = acceptedItem

    if let index = items.firstIndex(where: { $0.slug == acceptedItem.slug }) {
      if shouldPreferAcceptedDecision(acceptedItem, over: items[index]) {
        items[index] = acceptedItem
        items = normalizedQueueItems(items)
      }
    } else {
      items.append(acceptedItem)
      items = normalizedQueueItems(items)
    }

    selectedTab = preferredTab
    selectedSlug = acceptedItem.slug
    selectedItem = items.first { $0.slug == acceptedItem.slug } ?? acceptedItem

    if previousSelectedSlug != acceptedItem.slug {
      clearLoadedDetailSectionsForSelectedItem()
    }
  }

  private func shouldPreferAcceptedDecision(_ acceptedItem: ReviewItem, over refreshedItem: ReviewItem) -> Bool {
    let refreshedDecision = refreshedItem.decision.map(normalizedDecisionToken) ?? ""
    let acceptedDecision = acceptedItem.decision.map(normalizedDecisionToken) ?? ""
    if refreshedItem.normalizedStatus == acceptedItem.normalizedStatus,
       refreshedDecision == acceptedDecision {
      return false
    }

    return refreshedItem.isPending || refreshedItem.decision == nil
  }

  private func queueItemsPreservingAcceptedState(from loadedItems: [ReviewItem]) -> [ReviewItem] {
    var mergedItems = loadedItems.map(itemPreservingAcceptedRetry)
    for acceptedItem in Array(acceptedDecisionOverrides.values) {
      if let index = mergedItems.firstIndex(where: { $0.slug == acceptedItem.slug }) {
        if shouldPreferAcceptedDecision(acceptedItem, over: mergedItems[index]) {
          mergedItems[index] = itemPreservingAcceptedRetry(acceptedItem)
        } else {
          acceptedDecisionOverrides[acceptedItem.slug] = nil
        }
      } else {
        mergedItems.append(itemPreservingAcceptedRetry(acceptedItem))
      }
    }
    return normalizedQueueItems(mergedItems)
  }

  private func itemPreservingAcceptedDecision(_ loadedItem: ReviewItem) -> ReviewItem {
    guard let acceptedItem = acceptedDecisionOverrides[loadedItem.slug] else {
      return loadedItem
    }
    if shouldPreferAcceptedDecision(acceptedItem, over: loadedItem) {
      return acceptedItem
    }
    acceptedDecisionOverrides[loadedItem.slug] = nil
    return loadedItem
  }

  private func actionsPreservingAcceptedRetries(_ actions: ReviewActionsResponse, slug: String) -> ReviewActionsResponse {
    var requests = actions.requests
    var legacyActions = actions.legacyActions

    if var requestOverrides = acceptedRetryRequestOverrides[slug] {
      for index in requests.indices {
        let request = requests[index]
        guard let acceptedRequest = requestOverrides[request.id] else { continue }
        if shouldPreferAcceptedRetry(status: acceptedRequest.status, over: request.status, refreshedLastError: request.lastError) {
          requests[index] = acceptedRequest
        } else {
          requestOverrides[request.id] = nil
        }
      }
      acceptedRetryRequestOverrides[slug] = requestOverrides.isEmpty ? nil : requestOverrides
    }

    if var actionOverrides = acceptedRetryActionOverrides[slug] {
      for index in legacyActions.indices {
        let action = legacyActions[index]
        guard let acceptedAction = actionOverrides[action.id] else { continue }
        if shouldPreferAcceptedRetry(status: acceptedAction.status, over: action.status, refreshedLastError: action.lastError) {
          legacyActions[index] = acceptedAction
        } else {
          actionOverrides[action.id] = nil
        }
      }
      acceptedRetryActionOverrides[slug] = actionOverrides.isEmpty ? nil : actionOverrides
    }

    return ReviewActionsResponse(slug: actions.slug, requests: requests, legacyActions: legacyActions)
  }

  private func itemPreservingAcceptedRetry(_ loadedItem: ReviewItem) -> ReviewItem {
    guard let acceptedRetry = acceptedRetryItemActionOverrides[loadedItem.slug] else {
      return loadedItem
    }

    if shouldPreferAcceptedRetry(status: acceptedRetry.status, over: loadedItem.effectiveActionStatus, refreshedLastError: nil) {
      var item = loadedItem
      item.actionStatus = acceptedRetry.status
      item.actionMessage = acceptedRetry.message
      return item
    }

    acceptedRetryItemActionOverrides[loadedItem.slug] = nil
    return loadedItem
  }

  private func shouldPreferAcceptedRetry(status acceptedStatus: String, over refreshedStatus: String?, refreshedLastError: String?) -> Bool {
    guard let refreshedStatus else { return true }
    let accepted = DownstreamStatus(acceptedStatus)
    let refreshed = DownstreamStatus(refreshedStatus)
    let hasRefreshedError = refreshedLastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

    if refreshed.normalizedValue == accepted.normalizedValue,
       !hasRefreshedError {
      return false
    }

    return refreshed.needsRetry || hasRefreshedError
  }

  private func applyAcceptedRetry(_ response: RetryResponse, slug: String) {
    if let request = response.request {
      applyAcceptedRequestRetry(request, slug: slug)
      let message = "Downstream action processing is queued or waiting for an authoritative system."
      acceptedRetryItemActionOverrides[slug] = RetryItemActionOverride(status: request.status, message: message)
      updateItemActionState(
        slug: slug,
        status: request.status,
        message: message
      )
    }

    if let action = response.action {
      let decision = action.decision
        ?? legacyActions.first(where: { $0.id == action.id })?.decision
        ?? selectedItem?.decision
        ?? "latest"
      applyAcceptedLegacyActionRetry(action, slug: slug)
      let message = "Queued \(decision) action for retry."
      acceptedRetryItemActionOverrides[slug] = RetryItemActionOverride(status: action.status, message: message)
      updateItemActionState(
        slug: slug,
        status: action.status,
        message: message
      )
    }
  }

  private func latestRetryTarget() -> RetryTarget? {
    if let request = decisionRequests.first {
      return .request(id: request.id)
    }

    if let action = legacyActions.first {
      return .legacyAction(id: action.id)
    }

    let item = selectedItem?.slug == selectedSlug
      ? selectedItem
      : items.first { $0.slug == selectedSlug }
    if item?.effectiveActionStatus.map({ DownstreamStatus($0).needsRetry }) == true {
      return .downstreamAction
    }

    return nil
  }

  private func applyAcceptedRequestRetry(_ request: RetryResponse.RequestSummary, slug: String) {
    guard let index = decisionRequests.firstIndex(where: { $0.id == request.id }) else { return }
    let existing = decisionRequests[index]
    let updated = DecisionRequest(
      id: existing.id,
      slug: existing.slug,
      kind: existing.kind,
      summary: existing.summary,
      sensitivity: existing.sensitivity,
      status: request.status,
      proofJSON: existing.proofJSON,
      confirmationSlug: existing.confirmationSlug,
      lastError: nil,
      updatedAt: existing.updatedAt
    )
    decisionRequests[index] = updated
    acceptedRetryRequestOverrides[slug, default: [:]][updated.id] = updated
  }

  private func applyAcceptedLegacyActionRetry(_ action: RetryResponse.ActionSummary, slug: String) {
    guard let index = legacyActions.firstIndex(where: { $0.id == action.id }) else { return }
    let existing = legacyActions[index]
    let updated = LegacyAction(
      id: existing.id,
      slug: existing.slug,
      decision: action.decision ?? existing.decision,
      status: action.status,
      lastError: nil
    )
    legacyActions[index] = updated
    acceptedRetryActionOverrides[slug, default: [:]][updated.id] = updated
  }

  private func updateItemActionState(slug: String, status: String, message: String) {
    guard let index = items.firstIndex(where: { $0.slug == slug }) else { return }
    items[index].actionStatus = status
    items[index].actionMessage = message
    if selectedItem?.slug == slug {
      selectedItem = items[index]
    }
  }

  private func validateReviewItem(_ item: ReviewItem, expectedSlug: String) throws {
    guard item.slug == expectedSlug else {
      throw ResponseIntegrityError.slugMismatch(resource: "review", expected: expectedSlug, actual: item.slug)
    }
  }

  private func validateAnnotation(_ annotation: ReviewAnnotation, expectedSlug: String) throws {
    if let annotationSlug = annotation.slug,
       annotationSlug != expectedSlug {
      throw ResponseIntegrityError.slugMismatch(resource: "annotation", expected: expectedSlug, actual: annotationSlug)
    }
  }

  private func validateAnnotations(_ annotations: [ReviewAnnotation], expectedSlug: String) throws {
    for annotation in annotations {
      try validateAnnotation(annotation, expectedSlug: expectedSlug)
    }
  }

  private func validateReviewTargets(_ response: ReviewTargetsResponse, expectedSlug: String) throws {
    guard response.slug == expectedSlug else {
      throw ResponseIntegrityError.slugMismatch(resource: "review targets", expected: expectedSlug, actual: response.slug)
    }
  }

  private func validateReviewTargetJudgment(
    _ response: ReviewTargetJudgmentResponse,
    expectedSlug: String,
    expectedTargetKey: String
  ) throws {
    guard response.slug == expectedSlug else {
      throw ResponseIntegrityError.slugMismatch(resource: "review target", expected: expectedSlug, actual: response.slug)
    }
    guard response.target?.key == expectedTargetKey else {
      throw ResponseIntegrityError.reviewTargetMismatch(expected: expectedTargetKey, actual: response.target?.key ?? "none")
    }
  }

  private func validateActions(_ actions: ReviewActionsResponse, expectedSlug: String) throws {
    guard actions.slug == expectedSlug else {
      throw ResponseIntegrityError.slugMismatch(resource: "proof", expected: expectedSlug, actual: actions.slug)
    }

    for request in actions.requests {
      if let requestSlug = request.slug,
         requestSlug != expectedSlug {
        throw ResponseIntegrityError.slugMismatch(resource: "proof request", expected: expectedSlug, actual: requestSlug)
      }
    }

    for action in actions.legacyActions where action.slug != expectedSlug {
      throw ResponseIntegrityError.slugMismatch(resource: "legacy action", expected: expectedSlug, actual: action.slug)
    }
  }

  private func validateAcceptedDecision(
    _ response: DecisionResponse,
    expectedSlug: String,
    expectedDecision: String
  ) throws {
    guard response.slug == expectedSlug else {
      throw ResponseIntegrityError.slugMismatch(resource: "decision", expected: expectedSlug, actual: response.slug)
    }

    guard normalizedDecisionToken(response.decision) == normalizedDecisionToken(expectedDecision) else {
      throw ResponseIntegrityError.decisionMismatch(expected: expectedDecision, actual: response.decision)
    }

    let expectedStatus = serverStatus(for: expectedDecision)
    guard normalizedDecisionToken(response.status) == expectedStatus else {
      throw ResponseIntegrityError.decisionStatusMismatch(expected: expectedStatus, actual: response.status)
    }
  }

  private func serverStatus(for decision: String) -> String {
    switch normalizedDecisionToken(decision) {
    case "park", "noted", "no further action":
      return "archived"
    case "kill":
      return "killed"
    default:
      return "processed"
    }
  }

  private func normalizedDecisionToken(_ decision: String) -> String {
    decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func canonicalDecision(_ decision: String, for slug: String) -> String {
    let trimmed = decision.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = normalizedDecisionToken(trimmed)
    guard !normalized.isEmpty else { return "" }

    let item = selectedItem?.slug == slug ? selectedItem : items.first { $0.slug == slug }
    return item?.allowedActions.first { normalizedDecisionToken($0) == normalized } ?? trimmed
  }

  private func validateDeletedAnnotation(_ response: DeleteAnnotationResponse, annotationID: Int) throws {
    guard response.deleted else {
      throw ResponseIntegrityError.annotationDeleteRejected(id: annotationID, message: response.rejectionMessage)
    }
  }

  private func validateAnnotationDelete(_ annotation: ReviewAnnotation, expectedSlug: String) throws {
    if let annotationSlug = annotation.slug,
       annotationSlug != expectedSlug {
      throw ResponseIntegrityError.annotationSelectionMismatch(expected: expectedSlug, actual: annotationSlug)
    }
  }

  private func validateChatSession(_ responseSessionKey: String, expected expectedSessionKey: String?, slug: String) throws {
    guard let expectedSessionKey else { return }
    guard responseSessionKey == expectedSessionKey else {
      throw ResponseIntegrityError.chatSessionMismatch(
        slug: slug,
        expected: expectedSessionKey,
        actual: responseSessionKey
      )
    }
  }

  private func validateAcceptedRetry(
    _ response: RetryResponse,
    expectedSlug: String,
    expectedTarget: RetryTarget?
  ) throws {
    guard response.ok else {
      throw RetryAcceptanceError.rejected(response.rejectionMessage)
    }

    if let responseSlug = response.slug,
       responseSlug != expectedSlug {
      throw RetryAcceptanceError.slugMismatch(expected: expectedSlug, actual: responseSlug)
    }

    guard let expectedTarget else { return }

    guard response.request != nil || response.action != nil else {
      throw RetryAcceptanceError.missingTarget(expected: expectedTarget.label)
    }

    if let request = response.request {
      let actualTarget = RetryTarget.request(id: request.id)
      guard expectedTarget == .downstreamAction || actualTarget == expectedTarget else {
        throw RetryAcceptanceError.targetMismatch(expected: expectedTarget.label, actual: actualTarget.label)
      }
    }

    if let action = response.action {
      let actualTarget = RetryTarget.legacyAction(id: action.id)
      guard expectedTarget == .downstreamAction || actualTarget == expectedTarget else {
        throw RetryAcceptanceError.targetMismatch(expected: expectedTarget.label, actual: actualTarget.label)
      }
    }
  }
}

private enum ResponseIntegrityError: LocalizedError {
  case slugMismatch(resource: String, expected: String, actual: String)
  case decisionMismatch(expected: String, actual: String)
  case decisionStatusMismatch(expected: String, actual: String)
  case annotationDeleteRejected(id: Int, message: String)
  case annotationSelectionMismatch(expected: String, actual: String)
  case reviewTargetMismatch(expected: String, actual: String)
  case chatSessionMismatch(slug: String, expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .slugMismatch(let resource, let expected, let actual):
      return "Server returned \(resource) data for \(actual), not \(expected)."
    case .decisionMismatch(let expected, let actual):
      return "Server returned decision \(actual), not \(expected)."
    case .decisionStatusMismatch(let expected, let actual):
      return "Server returned decision status \(actual), not \(expected)."
    case .annotationDeleteRejected(_, let message):
      return message
    case .annotationSelectionMismatch(let expected, let actual):
      return "Annotation belongs to \(actual), not \(expected)."
    case .reviewTargetMismatch(let expected, let actual):
      return "Server returned review target \(actual), not \(expected)."
    case .chatSessionMismatch(let slug, let expected, let actual):
      return "Server returned chat session \(actual) for \(slug), not \(expected)."
    }
  }
}

private enum RetryAcceptanceError: LocalizedError {
  case rejected(String)
  case slugMismatch(expected: String, actual: String)
  case missingTarget(expected: String)
  case targetMismatch(expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .rejected(let message):
      return message
    case .slugMismatch(let expected, let actual):
      return "Server returned retry state for \(actual), not \(expected)."
    case .missingTarget(let expected):
      return "Server accepted retry without returning \(expected)."
    case .targetMismatch(let expected, let actual):
      return "Server returned retry state for \(actual), not \(expected)."
    }
  }
}

private enum RetryTarget: Equatable {
  case request(id: Int)
  case legacyAction(id: Int)
  case downstreamAction

  var label: String {
    switch self {
    case .request(let id):
      return "request \(id)"
    case .legacyAction(let id):
      return "legacy action \(id)"
    case .downstreamAction:
      return "failed action proof"
    }
  }
}
