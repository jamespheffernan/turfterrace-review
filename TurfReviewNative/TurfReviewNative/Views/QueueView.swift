import SwiftUI

struct QueueView: View {
  let store: ReviewStore
  let onOpenItem: ((String) -> Void)?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var searchText = ""
  @State private var showingSettings = false
  @State private var confirmingArchiveAll = false
  @State private var confirmingArchiveSelected = false

  init(store: ReviewStore, onOpenItem: ((String) -> Void)? = nil) {
    self.store = store
    self.onOpenItem = onOpenItem
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      tabPicker
      // The banner animates in its own container so a refresh that also changes the rows
      // does not animate the List through this modifier.
      VStack(spacing: 0) {
        if let banner = store.bannerMessage {
          BannerView(message: banner, isWarning: store.isUsingDemoData)
            .padding(.horizontal, screenInset)
            .padding(.bottom, TurfSpacing.s)
            .transition(.turfLift(reduceMotion: reduceMotion))
        }
      }
      .turfAnimation(TurfMotion.content, value: store.bannerMessage)
      list
    }
    #if os(iOS)
    .background(TurfTheme.paper)
    #endif
    .toolbar {
      #if os(iOS)
      ToolbarItemGroup(placement: .turfTrailing) {
        Menu {
          Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
            .disabled(store.isLoading)
          Button("Retry downloads", systemImage: "arrow.down.circle") { store.retryDownloads() }
          if store.selectedTab == .pending {
            Divider()
            Button(store.isArchiveSelectionMode ? "Done selecting" : "Select reviews", systemImage: "checkmark.circle") {
              if store.isArchiveSelectionMode { exitSelectionMode() }
              else { enterSelectionMode() }
            }
            if store.isArchiveSelectionMode {
              Button("Archive selected", systemImage: "archivebox") { confirmingArchiveSelected = true }
                .disabled(!store.canArchiveSelectedItems)
            } else {
              Button("Archive all pending", systemImage: "archivebox") { confirmingArchiveAll = true }
                .disabled(!store.canArchiveAllVisiblePending)
            }
          }
          Divider()
          Button("Settings", systemImage: "gearshape") { showingSettings = true }
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Library options")
      }
      #endif
    }
    .searchable(text: $searchText, prompt: "Find a review")
    .sheet(isPresented: $showingSettings) {
      SettingsView(configuration: store.configuration) { configuration in
        await store.saveConfiguration(configuration)
      }
    }
    .confirmationDialog(
      "Archive \(reviewLabel(store.visibleArchiveableItems.count))?",
      isPresented: $confirmingArchiveAll,
      titleVisibility: .visible
    ) {
      Button("Archive \(reviewLabel(store.visibleArchiveableItems.count))", role: .destructive) {
        Task { await store.archiveAllVisiblePendingItems() }
      }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Archive \(reviewLabel(store.selectedArchiveableCount))?",
      isPresented: $confirmingArchiveSelected,
      titleVisibility: .visible
    ) {
      Button("Archive \(reviewLabel(store.selectedArchiveableCount))", role: .destructive) {
        Task { await store.archiveSelectedItems() }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Header

  @ViewBuilder
  private var header: some View {
    if isCompact {
      compactHeader
    } else {
      regularHeader
    }
  }

  /// On iPhone the system large title reads "Library"; the status row sits under it.
  private var compactHeader: some View {
    statusRow
      .padding(.horizontal, screenInset)
      .padding(.top, TurfSpacing.s)
      .padding(.bottom, TurfSpacing.s)
  }

  /// Regular width matches compact: the title first, then the status row.
  private var regularHeader: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
      HStack(alignment: .firstTextBaseline, spacing: TurfSpacing.m) {
        Text("Library")
          .font(TurfType.screenTitle)
          .foregroundStyle(TurfTheme.ink)

        Spacer(minLength: 0)

        #if os(macOS)
        queueMenu
        #endif
      }

      statusRow
    }
    .padding(.horizontal, screenInset)
    .padding(.top, TurfSpacing.l)
    .padding(.bottom, TurfSpacing.s)
  }

  #if os(macOS)
  private var queueMenu: some View {
    Menu {
      Button {
        Task { await store.refresh() }
      } label: {
        Label("Refresh queue", systemImage: "arrow.clockwise")
      }
      .disabled(store.isLoading)

      if store.selectedTab == .pending {
        Divider()

        if store.isArchiveSelectionMode {
          Button {
            exitSelectionMode()
          } label: {
            Label("Cancel selection", systemImage: "xmark.circle")
          }
          .disabled(store.isBulkArchiving)

          Button {
            confirmingArchiveSelected = true
          } label: {
            Label("Archive selected", systemImage: "archivebox.fill")
          }
          .disabled(!store.canArchiveSelectedItems)
        } else {
          Button {
            enterSelectionMode()
          } label: {
            Label("Select reviews", systemImage: "checkmark.circle")
          }
          .disabled(store.visibleArchiveableItems.isEmpty || store.isBulkArchiving)

          Button {
            confirmingArchiveAll = true
          } label: {
            Label("Archive all pending", systemImage: "archivebox")
          }
          .disabled(!store.canArchiveAllVisiblePending)
        }
      }

      Divider()

      Button {
        showingSettings = true
      } label: {
        Label("Settings…", systemImage: "gearshape")
      }
    } label: {
      Label("Queue", systemImage: "ellipsis.circle")
        .font(TurfType.control)
    }
    .fixedSize()
    .help("Queue actions")
  }
  #endif

  private var statusRow: some View {
    HStack(spacing: TurfSpacing.s) {
      if store.isUsingDemoData {
        Label("Preview library", systemImage: "book")
      } else if store.isDownloading {
        ProgressView().controlSize(.mini)
        countingText(store.downloadSummary)
      } else if !store.downloadSummary.isEmpty {
        Label {
          countingText(store.downloadSummary)
        } icon: {
          Image(systemName: store.downloadFailures > 0 ? "arrow.down.circle" : "checkmark.icloud")
        }
      } else {
        countingText(store.items.isEmpty ? "Syncing your library…" : "\(store.items.count) reviews")
      }
      Spacer(minLength: 0)
    }
    .font(TurfType.meta)
    .foregroundStyle(TurfTheme.muted)
    .accessibilityElement(children: .combine)
  }

  /// Status text whose digits roll in place when the count changes (a crossfade under Reduce Motion).
  private func countingText(_ text: String) -> some View {
    Text(text)
      .monospacedDigit()
      .contentTransition(reduceMotion ? .opacity : .numericText())
      .turfAnimation(TurfMotion.quick, value: text)
  }

  private var tabPicker: some View {
    Picker("Queue", selection: Binding(
      get: { store.selectedTab },
      set: { tab in
        Task { await store.selectTab(tab) }
      }
    )) {
      ForEach(ReviewTab.allCases) { tab in
        Text("\(tab.title) \(store.counts[tab] ?? 0)")
          .monospacedDigit()
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, screenInset)
    .padding(.bottom, TurfSpacing.m)
  }

  // MARK: List

  private var filteredItems: [ReviewItem] {
    guard !searchText.isEmpty else { return store.visibleItems }
    return store.visibleItems.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.category.localizedCaseInsensitiveContains(searchText) }
  }

  private var list: some View {
    let items = filteredItems
    return List(selection: listSelection) {
      if items.isEmpty {
        emptyState
          .listRowBackground(Color.clear)
      } else {
        ForEach(items) { item in
          queueRow(for: item)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .listStyle(.plain)
    // Archive and refresh fade rows in and out; tab switches crossfade. Instant under Reduce Motion.
    // Keyed on the store's list, not the search-filtered one, so typing in search applies instantly.
    .turfAnimation(TurfMotion.content, reduced: nil, value: store.visibleItems.map(\.slug))
    .turfAnimation(TurfMotion.content, reduced: nil, value: store.selectedTab)
    .refreshable {
      await store.refresh()
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if isInitialLoading {
      ContentUnavailableView {
        Label {
          Text("Loading queue")
        } icon: {
          ProgressView()
        }
      } description: {
        Text("Your reviews will appear here.")
      }
    } else {
      ContentUnavailableView(
        "No \(store.selectedTab.title.lowercased()) items",
        systemImage: "tray",
        description: Text("New reviews will appear here when they are ready.")
      )
    }
  }

  @ViewBuilder
  private func queueRow(for item: ReviewItem) -> some View {
    if let onOpenItem {
      compactRow(for: item, onOpenItem: onOpenItem)
    } else if store.isArchiveSelectionMode {
      archiveSelectionRow(for: item)
    } else {
      NavigationLink(value: item.slug) {
        QueueRow(item: item, isDownloaded: isDownloaded(item))
      }
      .tag(item.slug)
      .listRowBackground(Color.clear)
      .listRowInsets(rowInsets)
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        archiveSwipeButton(for: item)
      }
    }
  }

  /// iPhone row. One button for both modes, so the selection mark can slide in beside the row
  /// instead of the whole row being replaced.
  private func compactRow(for item: ReviewItem, onOpenItem: @escaping (String) -> Void) -> some View {
    let isSelecting = store.isArchiveSelectionMode
    let canSelect = item.archiveAction != nil
    let isSelected = isSelecting && store.isArchiveSelected(slug: item.slug)
    let isDownloaded = isDownloaded(item)
    return Button {
      if isSelecting {
        store.toggleArchiveSelection(slug: item.slug)
      } else {
        onOpenItem(item.slug)
      }
    } label: {
      HStack(alignment: .center, spacing: TurfSpacing.m) {
        if isSelecting {
          ArchiveSelectionMark(isSelected: isSelected, isEnabled: canSelect)
            .transition(selectionMarkTransition)
        }
        QueueRow(item: item, isDownloaded: isDownloaded)
        Spacer(minLength: 0)
        if !isSelecting {
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(TurfTheme.faint)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isSelecting && (!canSelect || store.isSubmittingDecision(slug: item.slug)))
    .listRowBackground(Color.clear)
    .listRowInsets(rowInsets)
    .accessibilityLabel(item.title)
    .accessibilityValue(compactAccessibilityValue(isSelecting: isSelecting, isSelected: isSelected, isDownloaded: isDownloaded))
    .accessibilityHint(isSelecting ? "" : "Open review")
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if !isSelecting {
        archiveSwipeButton(for: item)
      }
    }
  }

  private func compactAccessibilityValue(isSelecting: Bool, isSelected: Bool, isDownloaded: Bool) -> String {
    if isSelecting { return isSelected ? "Selected" : "Not selected" }
    return isDownloaded ? "" : "Not downloaded yet"
  }

  /// iPad and Mac selection row (the normal row there is a `NavigationLink`).
  private func archiveSelectionRow(for item: ReviewItem) -> some View {
    let canSelect = item.archiveAction != nil
    return Button {
      store.toggleArchiveSelection(slug: item.slug)
    } label: {
      HStack(alignment: .center, spacing: TurfSpacing.m) {
        ArchiveSelectionMark(
          isSelected: store.isArchiveSelected(slug: item.slug),
          isEnabled: canSelect
        )
        .transition(selectionMarkTransition)
        QueueRow(item: item, isDownloaded: isDownloaded(item))
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!canSelect || store.isSubmittingDecision(slug: item.slug))
    .listRowBackground(Color.clear)
    .listRowInsets(rowInsets)
    .accessibilityLabel(item.title)
    .accessibilityValue(store.isArchiveSelected(slug: item.slug) ? "Selected" : "Not selected")
  }

  @ViewBuilder
  private func archiveSwipeButton(for item: ReviewItem) -> some View {
    if store.selectedTab == .pending,
       let archiveAction = item.archiveAction {
      Button {
        Task { await store.submitDecision(for: item.slug, archiveAction, feedback: "") }
      } label: {
        Label("Archive", systemImage: "archivebox.fill")
      }
      .tint(TurfTheme.muted)
      .disabled(store.isSubmittingDecision(slug: item.slug))
    }
  }

  private var listSelection: Binding<String?>? {
    guard onOpenItem == nil, !store.isArchiveSelectionMode else { return nil }
    return Binding(
      get: { store.selectedSlug },
      set: { slug in
        Task { await store.selectItem(slug: slug) }
      }
    )
  }

  // MARK: Helpers

  private func enterSelectionMode() {
    withTurfAnimation(TurfMotion.content, reduceMotion: reduceMotion) {
      store.enterArchiveSelectionMode()
    }
  }

  private func exitSelectionMode() {
    withTurfAnimation(TurfMotion.content, reduceMotion: reduceMotion) {
      store.exitArchiveSelectionMode()
    }
  }

  /// The preview library has nothing to download, so its rows never show the glyph.
  private func isDownloaded(_ item: ReviewItem) -> Bool {
    store.isUsingDemoData || store.downloadedSlugs.contains(item.slug)
  }

  private var selectionMarkTransition: AnyTransition {
    reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)
  }

  private var isInitialLoading: Bool {
    store.isLoading && store.items.isEmpty
  }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  private var screenInset: CGFloat {
    TurfSpacing.screenInset(compact: isCompact)
  }

  /// Rows share the header's leading edge; the row's own padding sets its height.
  private var rowInsets: EdgeInsets {
    EdgeInsets(top: 0, leading: screenInset, bottom: 0, trailing: screenInset)
  }

  private func reviewLabel(_ count: Int) -> String {
    "\(count) Review\(count == 1 ? "" : "s")"
  }
}

private struct ArchiveSelectionMark: View {
  let isSelected: Bool
  let isEnabled: Bool

  @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 28
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: systemImage)
      .font(.title2)
      .foregroundStyle(foregroundStyle)
      .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
      .frame(width: size, height: size)
      .turfAnimation(TurfMotion.quick, value: isSelected)
      .accessibilityHidden(true)
  }

  private var systemImage: String {
    if !isEnabled { return "circle.slash" }
    return isSelected ? "checkmark.circle.fill" : "circle"
  }

  private var foregroundStyle: Color {
    guard isEnabled else { return TurfTheme.faint }
    return isSelected ? TurfTheme.accent : TurfTheme.faint
  }
}

struct QueueRow: View {
  let item: ReviewItem
  /// When false, a faint glyph says the review is not on the device yet. Downloaded rows stay clean.
  var isDownloaded = true

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
      Text(item.title)
        .font(TurfType.rowTitle)
        .foregroundStyle(TurfTheme.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: TurfSpacing.xxs) {
        HStack(spacing: TurfSpacing.s) {
          Text(metadata)
          Spacer(minLength: 0)
          if !isDownloaded {
            Image(systemName: "icloud.and.arrow.down")
              .font(.footnote)
              .foregroundStyle(TurfTheme.faint)
              .accessibilityLabel("Not downloaded yet")
              .transition(.opacity)
          }
        }
        .font(TurfType.meta)
        .foregroundStyle(TurfTheme.muted)
        .turfAnimation(TurfMotion.content, value: isDownloaded)
        if let decision = item.decision, !decision.isEmpty {
          Text(decision)
            .font(TurfType.meta)
            .foregroundStyle(TurfTheme.muted)
        }
        if let message = item.effectiveActionMessage, item.effectiveActionStatus != "succeeded" {
          Label(message, systemImage: "exclamationmark.circle")
            .font(TurfType.meta)
            .foregroundStyle(TurfTheme.destructive)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, TurfSpacing.rowVertical)
  }

  private var metadata: String {
    var parts: [String] = []
    if item.category.lowercased() != "general" { parts.append(item.category.capitalized) }
    parts.append(readingTime)
    if let raw = item.createdAt, let date = Self.dateParser.date(from: String(raw.prefix(10))) {
      parts.append(date.formatted(.dateTime.month(.abbreviated).day()))
    }
    return parts.joined(separator: " · ")
  }

  private static let dateParser: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private var readingTime: String {
    let characters = item.contentLength ?? 0
    return characters > 0 ? "\(max(1, characters / 1200)) min read" : "Review"
  }
}

/// A small status capsule: tone text on the tone's soft fill.
struct BadgeText: View {
  let text: String
  let tone: TurfTone

  init(_ text: String, tone: TurfTone) {
    self.text = text
    self.tone = tone
  }

  var body: some View {
    Text(text)
      .font(TurfType.badge)
      .foregroundStyle(tone.text)
      .padding(.horizontal, TurfSpacing.s)
      .padding(.vertical, TurfSpacing.xxs)
      .background(tone.soft, in: Capsule())
  }
}

/// The library's one-line notice: ink text on a soft tone card, with a tone icon.
struct BannerView: View {
  let message: String
  let isWarning: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: TurfSpacing.s) {
      Image(systemName: isWarning ? "wifi.slash" : "info.circle.fill")
        .foregroundStyle(isWarning ? TurfTheme.attention : TurfTheme.accent)
        .accessibilityHidden(true)
      Text(message)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .font(TurfType.meta)
    .padding(TurfSpacing.cardInset)
    .background(
      isWarning ? TurfTheme.attentionSoft : TurfTheme.accentSoft,
      in: RoundedRectangle(cornerRadius: TurfRadius.card, style: .continuous)
    )
  }
}
