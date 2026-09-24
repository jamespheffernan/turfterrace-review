import Foundation
import Observation

@MainActor
@Observable
final class ReviewStore {
  private struct RetryItemActionOverride {
    let status: String
    let message: String
  }

  private struct BulkArchiveCandidate {
    let slug: String
    let decision: String
    let actionID: String?
  }

  private struct BulkArchiveSummary {
    var archived = 0
    var failed = 0
    var skipped = 0
    var archivedSlugs: Set<String> = []
    var firstFailureMessage: String?
  }

  var configuration: APIConfiguration
  var selectedTab: ReviewTab = .pending
  var items: [ReviewItem] = []
  var selectedSlug: String?
  var selectedItem: ReviewItem?
  var annotations: [ReviewAnnotation] = []
  var reviewTargets: [ReviewTarget] = []
  var reviewTargetSummary: ReviewTargetSummary = .empty
  var reviewTargetLoadError: String?
  var decisionRequests: [DecisionRequest] = []
  var decisionFollowups: [DecisionResponse.FollowupSummary] = []
  var legacyActions: [LegacyAction] = []
  var chatMessages: [ChatMessage] = []
  var ttsStatus: AudioStatusResponse?
  var contextStatus: AudioStatusResponse?
  var isLoading = false
  var detailLoading = false
  var isUsingDemoData = false
  var bannerMessage: String?
  var isArchiveSelectionMode = false
  var selectedArchiveSlugs: Set<String> = []

  private(set) var downloadedSlugs: Set<String> = []
  private(set) var downloadTotal = 0
  private(set) var downloadCompleted = 0
  private(set) var downloadFailures = 0
  private(set) var isDownloading = false
  private var offlineLibrary: ReviewOfflineLibrary?
  private let downloadsEnabled: Bool
  private var downloadTask: Task<Void, Never>?
  private var downloadID = UUID()
  private var restoredLibrary = false
  private var queueVersions: [String: String] = [:]
  private var downloadMutationCount = 0

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
  private var lastLiveRefreshAt: Date?
  /// Returning to the app within this window keeps the queue it already has.
  static let foregroundRefreshInterval: TimeInterval = 30
  private var submittingDecisionSlugs: Set<String> = []
  private var bulkArchiveSlugs: Set<String> = []
  private var retryingActionSlugs: Set<String> = []
  private var sendingChatSlugs: Set<String> = []
  private var updatingReviewTargetKeys: Set<String> = []
  private var chatSessionKeys: [String: String] = [:]
  private var localChatErrorMessageIDs: Set<UUID> = []

  init(
    configuration: APIConfiguration = .load(),
    downloadsEnabled: Bool = false,
    offlineLibrary: ReviewOfflineLibrary? = nil,
    clientFactory: @escaping (APIConfiguration) -> TurfReviewServicing = { TurfReviewClient(configuration: $0) }
  ) {
    self.configuration = configuration
    self.clientFactory = clientFactory
    self.downloadsEnabled = downloadsEnabled
    self.offlineLibrary = offlineLibrary ?? (downloadsEnabled && configuration.hasCredentials
      ? .application(configuration: configuration) : nil)
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

  var visibleArchiveableItems: [ReviewItem] {
    guard selectedTab == .pending else { return [] }
    return visibleItems.filter { $0.archiveAction != nil }
  }

  var selectedArchiveableCount: Int {
    selectedArchiveItems.count
  }

  private var selectedArchiveItems: [ReviewItem] {
    visibleArchiveableItems.filter { selectedArchiveSlugs.contains($0.slug) }
  }

  var canArchiveAllVisiblePending: Bool {
    selectedTab == .pending && !visibleArchiveableItems.isEmpty && !isBulkArchiving
  }

  var canArchiveSelectedItems: Bool {
    selectedTab == .pending && selectedArchiveableCount > 0 && !isBulkArchiving
  }

  var isBulkArchiving: Bool {
    !bulkArchiveSlugs.isEmpty
  }

  func selectTab(_ tab: ReviewTab) async {
    userSelectionRevision += 1
    selectedTab = tab
    reconcileArchiveSelectionForVisibleItems()
    clearSelectionIfNotVisible()
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

  @discardableResult
  func openReviewLink(_ url: URL) async -> String? {
    guard let link = ReviewDeepLink(url: url, configuredServerURL: configuration.serverURL) else {
      return nil
    }

    // Detail loading fetches the linked review directly. A queue refresh is not
    // required and must not transiently select a different item.
    await selectItem(slug: link.slug)
    return selectedItem?.slug == link.slug ? link.slug : nil
  }

  func isSubmittingDecision(slug: String?) -> Bool {
    guard let slug else { return false }
    return submittingDecisionSlugs.contains(slug) || bulkArchiveSlugs.contains(slug)
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

  func refresh(useDemoFallback: Bool = false) async {
    if !restoredLibrary, let offlineLibrary {
      let revision = configurationRevision
      restoredLibrary = true
      let saved = await offlineLibrary.queue()
      guard revision == configurationRevision else { return }
      if items.isEmpty {
        items = normalizedQueueItems(saved)
        queueVersions = Dictionary(saved.map { ($0.slug, ReviewOfflineLibrary.version($0)) }, uniquingKeysWith: { _, new in new })
      }
    }
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
      queueVersions = Dictionary(loaded.map { ($0.slug, ReviewOfflineLibrary.version($0)) }, uniquingKeysWith: { _, new in new })
      isUsingDemoData = false
      hasLoadedLiveQueue = true
      lastLiveRefreshAt = Date()
      bannerMessage = nil
      reconcileArchiveSelectionForVisibleItems()
      if let offlineLibrary {
        try? await offlineLibrary.saveQueue(items)
        downloadTask?.cancel()
        let downloadableSlugs = Set(items.lazy.filter { !$0.isDecided }.map(\.slug))
        await offlineLibrary.pruneDownloads(keeping: downloadableSlugs)
        startDownloads()
      }
      finishRefreshLoading(requestID)
      if let selectedSlug {
        await loadDetail(slug: selectedSlug, forceRefresh: true)
      }
    } catch {
      guard activeRefreshRequestID == requestID else { return }
      if shouldUseDemoFallback(afterRefreshFailureWith: useDemoFallback) {
        items = normalizedQueueItems(DemoData.items)
        isUsingDemoData = true
        bannerMessage = "Showing demo data. \(error.localizedDescription)"
        reconcileArchiveSelectionForVisibleItems()
        finishRefreshLoading(requestID)
        if let selectedSlug {
          await loadDetail(slug: selectedSlug)
        }
      } else {
        bannerMessage = error.localizedDescription
      }
    }
  }

  /// App activation refresh. Skipped while the last live queue is recent, so switching
  /// between apps does not reload every page of the queue each time.
  func refreshOnForeground(now: Date = Date()) async {
    guard !isLoading else { return }
    if let lastLiveRefreshAt, now.timeIntervalSince(lastLiveRefreshAt) < Self.foregroundRefreshInterval {
      return
    }
    await refresh()
  }

  @discardableResult
  func saveConfiguration(_ newConfiguration: APIConfiguration) async -> Bool {
    guard newConfiguration.save() else {
      bannerMessage = "Settings were not changed because the credentials could not be saved securely."
      return false
    }

    downloadTask?.cancel()
    downloadID = UUID()
    configurationRevision += 1
    activeRefreshRequestID = nil
    activeDetailRequestID = nil
    if let offlineLibrary { await offlineLibrary.clear() }
    offlineLibrary = downloadsEnabled && newConfiguration.hasCredentials
      ? .application(configuration: newConfiguration) : nil
    restoredLibrary = false
    downloadedSlugs = []
    isDownloading = false
    queueVersions = [:]
    downloadMutationCount = 0
    downloadTotal = 0
    downloadCompleted = 0
    downloadFailures = 0
    submittingDecisionSlugs = []
    bulkArchiveSlugs = []
    retryingActionSlugs = []
    sendingChatSlugs = []
    isArchiveSelectionMode = false
    selectedArchiveSlugs = []
    chatSessionKeys = [:]
    acceptedDecisionOverrides = [:]
    acceptedRetryRequestOverrides = [:]
    acceptedRetryActionOverrides = [:]
    acceptedRetryItemActionOverrides = [:]
    acceptedReviewTargetOverrides = [:]
    hasLoadedLiveQueue = false
    lastLiveRefreshAt = nil
    updatingReviewTargetKeys = []
    configuration = newConfiguration
    items = []
    isUsingDemoData = false
    bannerMessage = nil
    selectedSlug = nil
    clearDetail()
    await refresh()
    return true
  }

  func loadDetail(slug: String, forceRefresh: Bool = false) async {
    let isSameSelection = selectedSlug == slug && selectedItem?.slug == slug
    selectedSlug = slug
    if !isSameSelection {
      prepareDetailForLoading(slug: slug, clearBanner: !isUsingDemoData)
    }

    let requestID = UUID()
    activeDetailRequestID = requestID
    if !isUsingDemoData, let offlineLibrary,
       let snapshot = await offlineLibrary.snapshot(slug: slug),
       activeDetailRequestID == requestID, selectedSlug == slug {
      let queued = items.first { $0.slug == slug }
      applyDownloaded(snapshot, queueItem: queued)
      if !forceRefresh, snapshot.sectionsComplete, queued == nil || snapshot.version == (queueVersions[slug] ?? ReviewOfflineLibrary.version(queued!)) {
        detailLoading = false
        return
      }
    }
    detailLoading = selectedItem?.renderedHTML == nil && selectedItem?.markdown == nil
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
      guard activeDetailRequestID == requestID, selectedSlug == slug else { return }
      mergeLoadedDetailItemIntoQueue(loadedItem)
      detailLoading = false
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
        if !isSameSelection && selectedItem?.renderedHTML == nil && selectedItem?.markdown == nil {
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
    var invalidatedDownload = false
    defer {
      if configurationRevision == revision, invalidatedDownload {
        downloadMutationCount -= 1
        if downloadMutationCount == 0 { startDownloads() }
      }
    }
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
      if !invalidatedDownload { invalidatedDownload = true; downloadMutationCount += 1 }
      await invalidateDownload(slug)
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
    var invalidatedDownload = false
    defer {
      if configurationRevision == revision, invalidatedDownload {
        downloadMutationCount -= 1
        if downloadMutationCount == 0 { startDownloads() }
      }
    }
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
      if !invalidatedDownload { invalidatedDownload = true; downloadMutationCount += 1 }
      await invalidateDownload(slug)
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
    var invalidatedDownload = false
    defer {
      if configurationRevision == revision, invalidatedDownload {
        downloadMutationCount -= 1
        if downloadMutationCount == 0 { startDownloads() }
      }
    }
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
      if !invalidatedDownload { invalidatedDownload = true; downloadMutationCount += 1 }
      await invalidateDownload(slug)
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
    var invalidatedDownload = false
    defer {
      if configurationRevision == revision, invalidatedDownload {
        downloadMutationCount -= 1
        if downloadMutationCount == 0 { startDownloads() }
      }
    }
    let sourceTab = selectedTab
    let resolvedDecision = canonicalDecision(decision, for: slug)
    let resolvedActionID = canonicalActionID(for: resolvedDecision, slug: slug)
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
      if !invalidatedDownload { invalidatedDownload = true; downloadMutationCount += 1 }
      await invalidateDownload(slug)
      let response = try await client.decide(slug: slug, decision: resolvedDecision, actionId: resolvedActionID, feedback: feedback)
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

  func enterArchiveSelectionMode() {
    guard selectedTab == .pending else { return }
    isArchiveSelectionMode = true
    reconcileArchiveSelectionForVisibleItems()
  }

  func exitArchiveSelectionMode() {
    isArchiveSelectionMode = false
    selectedArchiveSlugs = []
  }

  func toggleArchiveSelection(slug: String) {
    guard isArchiveSelectionMode,
          selectedTab == .pending,
          let item = visibleItems.first(where: { $0.slug == slug }),
          item.archiveAction != nil else { return }

    if selectedArchiveSlugs.contains(slug) {
      selectedArchiveSlugs.remove(slug)
    } else {
      selectedArchiveSlugs.insert(slug)
    }
  }

  func isArchiveSelected(slug: String) -> Bool {
    selectedArchiveSlugs.contains(slug)
  }

  @discardableResult
  func archiveSelectedItems() async -> Bool {
    reconcileArchiveSelectionForVisibleItems()
    let selectedSlugs = selectedArchiveSlugs
    let selectedItems = visibleItems.filter { selectedSlugs.contains($0.slug) }
    return await archivePendingItems(selectedItems, skippedCount: 0)
  }

  @discardableResult
  func archiveAllVisiblePendingItems() async -> Bool {
    guard selectedTab == .pending else { return false }
    let pendingItems = visibleItems
    let skippedCount = pendingItems.filter { $0.archiveAction == nil }.count
    return await archivePendingItems(pendingItems, skippedCount: skippedCount)
  }

  @discardableResult
  private func archivePendingItems(_ sourceItems: [ReviewItem], skippedCount: Int) async -> Bool {
    guard !isBulkArchiving else { return false }
    var summary = BulkArchiveSummary()
    summary.skipped = skippedCount

    let initialCandidates = archiveCandidates(from: sourceItems)
    let candidates = initialCandidates.filter { !submittingDecisionSlugs.contains($0.slug) }
    summary.skipped += initialCandidates.count - candidates.count

    guard !candidates.isEmpty else {
      reconcileArchiveSelectionForVisibleItems()
      bannerMessage = "No pending reviews can be archived."
      return false
    }

    let revision = configurationRevision
    var invalidatedDownload = false
    defer {
      if configurationRevision == revision, invalidatedDownload {
        downloadMutationCount -= 1
        if downloadMutationCount == 0 { startDownloads() }
      }
    }
    let candidateSlugs = Set(candidates.map(\.slug))
    submittingDecisionSlugs.formUnion(candidateSlugs)
    bulkArchiveSlugs.formUnion(candidateSlugs)
    defer {
      if configurationRevision == revision {
        submittingDecisionSlugs.subtract(candidateSlugs)
        bulkArchiveSlugs.subtract(candidateSlugs)
      }
    }

    if isUsingDemoData {
      for candidate in candidates {
        let didArchive = acceptBulkArchiveDecision(
          slug: candidate.slug,
          decision: candidate.decision,
          feedback: "",
          itemStatus: serverStatus(for: candidate.decision),
          actionStatus: "succeeded",
          actionMessage: "\(candidate.decision) saved in demo mode.",
          summary: &summary
        )
        if !didArchive {
          summary.failed += 1
          summary.firstFailureMessage = summary.firstFailureMessage ?? "Review could not be found in the local queue."
        }
      }
      await finishBulkArchive(summary)
      return summary.archived > 0 && summary.failed == 0
    }

    for candidate in candidates {
      do {
        if !invalidatedDownload { invalidatedDownload = true; downloadMutationCount += 1 }
        await invalidateDownload(candidate.slug)
        let response = try await client.decide(
          slug: candidate.slug,
          decision: candidate.decision,
          actionId: candidate.actionID,
          feedback: ""
        )
        try validateAcceptedDecision(
          response,
          expectedSlug: candidate.slug,
          expectedDecision: candidate.decision
        )
        guard configurationRevision == revision else { return summary.archived > 0 }
        let didArchive = acceptBulkArchiveDecision(
          slug: candidate.slug,
          decision: response.decision,
          feedback: "",
          itemStatus: response.status,
          actionStatus: response.action.status,
          actionMessage: response.action.message,
          summary: &summary
        )
        if !didArchive {
          summary.failed += 1
          summary.firstFailureMessage = summary.firstFailureMessage ?? "Review could not be found in the local queue."
        }
      } catch {
        guard configurationRevision == revision else { return summary.archived > 0 }
        summary.failed += 1
        summary.firstFailureMessage = summary.firstFailureMessage ?? error.localizedDescription
      }
    }

    guard configurationRevision == revision else { return summary.archived > 0 }
    if summary.archived > 0 {
      await refresh(useDemoFallback: false)
    }
    guard configurationRevision == revision else { return summary.archived > 0 }
    await finishBulkArchive(summary)
    return summary.archived > 0 && summary.failed == 0
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
    if let value = relativeOrAbsolute, let url = URL(string: value), url.isFileURL {
      guard let root = offlineLibrary?.root,
            url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
            FileManager.default.fileExists(atPath: url.path) else { return nil }
      return url
    }
    return client.absoluteURL(for: relativeOrAbsolute)
  }

  func absoluteFollowupURL(_ relativeOrAbsolute: String?) -> URL? {
    client.absoluteURL(for: relativeOrAbsolute)
  }

  var downloadSummary: String {
    if isDownloading { return "Downloading \(downloadCompleted) of \(downloadTotal)" }
    if downloadFailures > 0 { return "\(downloadFailures) downloads need retrying" }
    if downloadTotal > 0 { return "Available offline" }
    return ""
  }

  func retryDownloads() { startDownloads() }

  private func isUnsupported(_ error: Error) -> Bool {
    if case TurfReviewClientError.unsupportedOperation = error { return true }
    return false
  }

  private func applyDownloaded(_ snapshot: ReviewOfflineLibrary.Snapshot, queueItem: ReviewItem?) {
    var item = snapshot.item
    // Queue metadata is authoritative for status; downloaded bodies must not resurrect decisions.
    if let queueItem {
      item.status = queueItem.status
      item.decision = queueItem.decision
      item.updatedAt = queueItem.updatedAt
    }
    mergeLoadedDetailItemIntoQueue(item)
    annotations = snapshot.annotations
    applyReviewTargets(reviewTargetsPreservingAcceptedJudgments(snapshot.targets, slug: item.slug))
    ttsStatus = snapshot.tts
    contextStatus = snapshot.context
    reviewTargetLoadError = nil
    if snapshot.complete { downloadedSlugs.insert(item.slug) }
  }

  private func invalidateDownload(_ slug: String) async {
    downloadTask?.cancel()
    downloadID = UUID()
    isDownloading = false
    downloadedSlugs.remove(slug)
    await offlineLibrary?.remove(slug: slug)
  }

  private func startDownloads() {
    guard let offlineLibrary, !isUsingDemoData, downloadMutationCount == 0 else { return }
    downloadTask?.cancel()
    let id = UUID()
    downloadID = id
    let revision = configurationRevision
    let service = client
    let baseURL = configuration.serverURL
    let versions = queueVersions
    let queue = items.filter { !$0.isDecided }
      .sorted { ($0.isPending ? 0 : 1) < ($1.isPending ? 0 : 1) }
    downloadTotal = queue.count
    downloadCompleted = 0
    downloadFailures = 0
    isDownloading = true
    downloadTask = Task { [weak self] in
      await withTaskGroup(of: (String, Bool).self) { group in
        var iterator = queue.makeIterator()
        func enqueue(_ item: ReviewItem) {
          group.addTask {
            do {
              try Task.checkCancellation()
              let version = versions[item.slug] ?? ReviewOfflineLibrary.version(item)
              let generation = await offlineLibrary.generation(slug: item.slug)
              if let saved = await offlineLibrary.snapshot(slug: item.slug), saved.version == version, saved.complete {
                return (item.slug, true)
              }
              // Start every read together so the client can serve them from one detail request.
              async let loadedDetail = service.getItem(slug: item.slug)
              async let annotations = service.getAnnotations(slug: item.slug)
              async let targets = service.getReviewTargets(slug: item.slug)
              async let tts = service.ttsStatus(slug: item.slug)
              async let context = service.contextStatus(slug: item.slug)
              var detail = try await loadedDetail
              guard detail.slug == item.slug else { return (item.slug, false) }
              // Save readable content even if an optional endpoint or media download fails.
              var snapshot = ReviewOfflineLibrary.Snapshot(
                item: detail, annotations: [], targets: .init(slug: item.slug, targets: [], summary: .empty),
                version: version, savedAt: Date()
              )
              try await offlineLibrary.save(snapshot, generation: generation)
              snapshot.annotations = try await annotations
              snapshot.targets = try await targets
              snapshot.sectionsComplete = true
              try await offlineLibrary.save(snapshot, generation: generation)
              snapshot.tts = try await tts
              snapshot.context = try await context
              try await offlineLibrary.save(snapshot, generation: generation)
              if let html = detail.renderedHTML {
                detail.renderedHTML = try await OfflineDocumentAssets.download(html: html, baseURL: baseURL, client: service)
              }
              var savedTTS = try await tts
              var savedContext = try await context
              for kind in 0..<2 {
                var audio = kind == 0 ? savedTTS : savedContext
                if audio.status == "ready", let url = service.absoluteURL(for: audio.url) {
                  let local: URL
                  if let existing = await offlineLibrary.mediaURL(remote: url, version: version) {
                    local = existing
                  } else {
                    let (data, mime) = try await service.downloadResource(url)
                    guard mime.hasPrefix("audio/") || mime == "application/octet-stream" else {
                      return (item.slug, false)
                    }
                    local = try await offlineLibrary.saveMedia(data, remote: url, version: version)
                  }
                  audio = AudioStatusResponse(status: audio.status, url: local.absoluteString, summary: audio.summary)
                }
                if kind == 0 { savedTTS = audio } else { savedContext = audio }
              }
              snapshot.item = detail
              snapshot.tts = savedTTS
              snapshot.context = savedContext
              snapshot.complete = true
              try Task.checkCancellation()
              try await offlineLibrary.save(snapshot, generation: generation)
              return (item.slug, true)
            } catch { return (item.slug, false) }
          }
        }
        for _ in 0..<3 { if let item = iterator.next() { enqueue(item) } }
        for await (slug, success) in group {
          guard let self, !Task.isCancelled, self.downloadID == id, self.configurationRevision == revision else {
            group.cancelAll()
            return
          }
          self.downloadCompleted += 1
          if success { self.downloadedSlugs.insert(slug) } else { self.downloadFailures += 1 }
          if let item = iterator.next() { enqueue(item) }
        }
      }
      guard let self, self.downloadID == id else { return }
      self.isDownloading = false
    }
  }

  private func archiveCandidates(from sourceItems: [ReviewItem]) -> [BulkArchiveCandidate] {
    var seenSlugs = Set<String>()
    return sourceItems.compactMap { item in
      guard seenSlugs.insert(item.slug).inserted,
            item.isPending,
            let archiveAction = item.archiveAction else { return nil }

      let decision = canonicalDecision(archiveAction, for: item.slug)
      guard !decision.isEmpty else { return nil }
      return BulkArchiveCandidate(
        slug: item.slug,
        decision: decision,
        actionID: item.actionID(for: decision)
      )
    }
  }

  @discardableResult
  private func acceptBulkArchiveDecision(
    slug: String,
    decision: String,
    feedback: String,
    itemStatus: String,
    actionStatus: String,
    actionMessage: String,
    summary: inout BulkArchiveSummary
  ) -> Bool {
    guard let acceptedItem = acceptedDecisionItem(
      slug: slug,
      decision: decision,
      feedback: feedback,
      itemStatus: itemStatus,
      actionStatus: actionStatus,
      actionMessage: actionMessage
    ) else { return false }
    mergeAcceptedDecisionIntoQueue(acceptedItem)
    summary.archived += 1
    summary.archivedSlugs.insert(slug)
    return true
  }

  private func finishBulkArchive(_ summary: BulkArchiveSummary) async {
    selectedArchiveSlugs.subtract(summary.archivedSlugs)
    reconcileArchiveSelectionForVisibleItems()
    if summary.failed == 0 || selectedArchiveSlugs.isEmpty {
      exitArchiveSelectionMode()
    }

    let previousSelectedSlug = selectedSlug
    if let selectedSlug, summary.archivedSlugs.contains(selectedSlug) {
      selectedTab = .pending
      self.selectedSlug = nil
      clearDetail()
    } else if selectedTab == .pending {
      clearSelectionIfNotVisible()
    }

    if let selectedSlug, selectedSlug != previousSelectedSlug {
      await loadDetail(slug: selectedSlug)
    }

    bannerMessage = bulkArchiveMessage(summary)
  }

  private func reconcileArchiveSelectionForVisibleItems() {
    guard selectedTab == .pending else {
      isArchiveSelectionMode = false
      selectedArchiveSlugs = []
      return
    }

    let archiveableSlugs = Set(visibleArchiveableItems.map(\.slug))
    selectedArchiveSlugs = selectedArchiveSlugs.intersection(archiveableSlugs)
    if archiveableSlugs.isEmpty {
      isArchiveSelectionMode = false
    }
  }

  private func bulkArchiveMessage(_ summary: BulkArchiveSummary) -> String {
    var parts: [String] = []
    if summary.archived > 0 {
      parts.append("Archived \(Self.reviewCountLabel(summary.archived)).")
    } else {
      parts.append("No reviews archived.")
    }

    if summary.skipped > 0 {
      parts.append("\(Self.reviewCountLabel(summary.skipped)) skipped because no archive action is available.")
    }

    if summary.failed > 0 {
      let suffix = summary.firstFailureMessage.map { ": \($0)" } ?? "."
      parts.append("\(Self.reviewCountLabel(summary.failed)) failed\(suffix)")
    }

    return parts.joined(separator: " ")
  }

  private static func reviewCountLabel(_ count: Int) -> String {
    "\(count) review\(count == 1 ? "" : "s")"
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
        if !isUnsupported(error) { errors.append(error.localizedDescription) }
      }
    case .failure(let error):
      clearAnnotationsIfTheyDoNotBelong(to: expectedSlug)
      if !isUnsupported(error) { errors.append(error.localizedDescription) }
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
        if !isUnsupported(error) { errors.append(error.localizedDescription) }
      }
    case .failure(let error):
      clearReviewTargetsIfTheyDoNotBelong(to: expectedSlug)
      reviewTargetLoadError = error.localizedDescription
      if !isUnsupported(error) { errors.append(error.localizedDescription) }
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
        if !isUnsupported(error) { errors.append(error.localizedDescription) }
      }
    case .failure(let error):
      clearActionsIfTheyDoNotBelong(to: expectedSlug)
      if !isUnsupported(error) { errors.append(error.localizedDescription) }
    }

    switch loadedTTS {
    case .success(let loadedTTS):
      ttsStatus = loadedTTS
    case .failure(let error):
      ttsStatus = AudioStatusResponse(status: selectedItem?.ttsStatus, url: selectedItem?.ttsURL, summary: nil)
      if !isUnsupported(error) { errors.append(error.localizedDescription) }
    }

    switch loadedContext {
    case .success(let loadedContext):
      contextStatus = loadedContext
    case .failure(let error):
      contextStatus = AudioStatusResponse(status: selectedItem?.contextStatus, url: selectedItem?.contextURL, summary: selectedItem?.contextSummary)
      if !isUnsupported(error) { errors.append(error.localizedDescription) }
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

  private typealias SortTimestamp = (date: Date?, raw: String)

  private static func sortNewestFirst(
    _ left: (timestamp: SortTimestamp, item: ReviewItem),
    _ right: (timestamp: SortTimestamp, item: ReviewItem)
  ) -> Bool {
    let leftTimestamp = left.timestamp
    let rightTimestamp = right.timestamp

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
      return left.item.slug < right.item.slug
    }
  }

  private func normalizedQueueItems(_ loadedItems: [ReviewItem]) -> [ReviewItem] {
    // Parse each timestamp once; the comparator runs O(n log n) times on the main actor.
    var seenSlugs = Set<String>()
    return loadedItems
      .map { (timestamp: Self.sortTimestamp(for: $0), item: $0) }
      .sorted(by: Self.sortNewestFirst)
      .map(\.item)
      .filter { item in
        seenSlugs.insert(item.slug).inserted
      }
  }

  private static func sortTimestamp(for item: ReviewItem) -> SortTimestamp {
    let raw = [item.updatedAt, item.createdAt]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? ""

    return (ServerDate.parse(raw), raw)
  }

  private func clearSelectionIfNotVisible() {
    guard let selectedSlug else { return }
    guard !visibleItems.contains(where: { $0.slug == selectedSlug }) else { return }
    self.selectedSlug = nil
    clearDetail()
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
    ttsStatus = AudioStatusResponse(status: selectedItem?.ttsStatus, url: selectedItem?.ttsURL, summary: nil)
    contextStatus = AudioStatusResponse(status: selectedItem?.contextStatus, url: selectedItem?.contextURL, summary: selectedItem?.contextSummary)
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
    ttsStatus = selectedItem.map { AudioStatusResponse(status: $0.ttsStatus, url: $0.ttsURL, summary: nil) }
    contextStatus = selectedItem.map { AudioStatusResponse(status: $0.contextStatus, url: $0.contextURL, summary: $0.contextSummary) }
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
      decisionKind: target.decisionKind,
      options: target.options,
      selectedOption: target.options?.first(where: { verdict == "choice:\($0.value)" }),
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
    let decided = targets.count - undecided
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
    let normalized = verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "yes", "approve", "approved", "accept", "accepted":
      return "approved"
    case "no", "reject", "rejected", "decline", "declined":
      return "rejected"
    case "unset", "clear":
      return "unset"
    default:
      return normalized.hasPrefix("choice:") && normalized.count > "choice:".count ? normalized : ""
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
    decisionRequests = acceptedRequests
  }

  private func preserveAcceptedDecisionFollowupsIfNeeded(_ acceptedFollowups: [DecisionResponse.FollowupSummary], slug: String) {
    guard selectedSlug == slug, !acceptedFollowups.isEmpty else { return }
    decisionFollowups = acceptedFollowups
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

    // Legacy servers report a per-decision status; the hosted service reports `processed` for all.
    let expectedStatus = serverStatus(for: expectedDecision)
    let actualStatus = normalizedDecisionToken(response.status)
    guard actualStatus == expectedStatus || actualStatus == "processed" else {
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

  private func canonicalActionID(for decision: String, slug: String) -> String? {
    let item = selectedItem?.slug == slug ? selectedItem : items.first { $0.slug == slug }
    return item?.actionID(for: decision)
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

/// Parses server timestamps without allocating formatters per call.
/// Strict SQLite and whole-second UTC ISO forms take an arithmetic fast path that
/// returns the same instant as the formatter chain; everything else falls through to it.
enum ServerDate {
  static func parse(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return fastParse(trimmed)
      ?? fractionalISO8601.date(from: trimmed)
      ?? iso8601.date(from: trimmed)
      ?? sqliteSeconds.date(from: trimmed)
      ?? sqliteMilliseconds.date(from: trimmed)
      ?? sqliteDay.date(from: trimmed)
  }

  private static let fractionalISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let sqliteSeconds = sqliteFormatter("yyyy-MM-dd HH:mm:ss")
  private static let sqliteMilliseconds = sqliteFormatter("yyyy-MM-dd HH:mm:ss.SSS")
  private static let sqliteDay = sqliteFormatter("yyyy-MM-dd")

  private static func sqliteFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
  }

  /// Accepts exactly `yyyy-MM-dd`, `yyyy-MM-dd HH:mm:ss`, `yyyy-MM-ddTHH:mm:ssZ` or
  /// `yyyy-MM-ddTHH:mm:ss.SSSZ` (the hosted API's form) with valid fields.
  static func fastParse(_ value: String) -> Date? {
    var value = value
    return value.withUTF8 { bytes -> Date? in
      let count = bytes.count
      var milliseconds = 0
      if count == 24 {
        guard bytes[19] == UInt8(ascii: "."), bytes[23] == UInt8(ascii: "Z"),
              let fraction = digits(bytes, 20, 3) else { return nil }
        milliseconds = fraction
      }
      guard count == 10 || count == 19 || count == 24 || (count == 20 && bytes[19] == UInt8(ascii: "Z")),
            bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
            let year = digits(bytes, 0, 4), let month = digits(bytes, 5, 2), let day = digits(bytes, 8, 2),
            year >= 1, (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month) else {
        return nil
      }
      var seconds = 0
      if count >= 19 {
        let separator = count == 19 ? UInt8(ascii: " ") : UInt8(ascii: "T")
        guard bytes[10] == separator, bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let hour = digits(bytes, 11, 2), let minute = digits(bytes, 14, 2), let second = digits(bytes, 17, 2),
              hour < 24, minute < 60, second < 60 else {
          return nil
        }
        seconds = hour * 3600 + minute * 60 + second
      }
      let unixSeconds = daysFromCivil(year: year, month: month, day: day) * 86_400 + seconds
      // This exact expression reproduces ISO8601DateFormatter's millisecond result bit for bit.
      return Date(timeIntervalSince1970: TimeInterval(unixSeconds) + TimeInterval(milliseconds) / 1000)
    }
  }

  private static func digits(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ length: Int) -> Int? {
    var value = 0
    for index in start..<(start + length) {
      let digit = Int(bytes[index]) - Int(UInt8(ascii: "0"))
      guard (0...9).contains(digit) else { return nil }
      value = value * 10 + digit
    }
    return value
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
  private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
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
