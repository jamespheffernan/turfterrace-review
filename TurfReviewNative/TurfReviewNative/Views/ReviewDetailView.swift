import SwiftUI

struct ReviewDetailView: View {
  let store: ReviewStore
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var playGlyphWidth: CGFloat = 16
  @State private var webSelection = WebSelection()
  @State private var annotationSelection = WebSelection()
  @State private var annotationDraft: AnnotationDraft?
  @State private var selectionFeedback: SelectionCaptureFeedback?
  @State private var showsLoadingBadge = false
  /// Whether the reader column is under the CSS 600pt breakpoint, so the native insets switch with
  /// the reader CSS. Nil until first measured.
  @State private var readerIsNarrow: Bool?
  /// Bumped when a note save starts, so the reader settles only the mark that save adds.
  @State private var newAnnotationToken = 0
  /// Set to the save's token when that save fails, so a later mark does not settle in its place.
  @State private var cancelledAnnotationToken = 0

  @State private var showListening = false
  @State private var showItems = false
  @State private var showNotes = false
  @State private var showAsk = false
  @State private var showProof = false
  @State private var showDecisionMore = false

  var body: some View {
    Group {
      if let item = store.selectedItem {
        readerWorkspace(for: item)
      } else {
        ContentUnavailableView(
          "Select a review",
          systemImage: "rectangle.and.text.magnifyingglass",
          description: Text("Choose something from your library to start reading.")
        )
        .background(TurfTheme.paper)
      }
    }
    .navigationTitle(navigationTitle)
    .turfInlineNavigationTitle()
    .toolbar { summonToolbar }
    .overlay(alignment: .topTrailing) {
      if showsLoadingBadge {
        DetailLoadingBadge()
          .padding(.top, TurfSpacing.m)
          .padding(.trailing, TurfSpacing.l)
          .transition(.opacity)
      }
    }
    .task(id: store.detailLoading) {
      // Show the badge only when loading lasts longer than the reveal delay.
      guard store.detailLoading else {
        if showsLoadingBadge {
          withTurfAnimation(TurfMotion.exit, reduceMotion: reduceMotion) { showsLoadingBadge = false }
        }
        return
      }
      try? await Task.sleep(for: TurfMotion.loadingRevealDelay)
      guard !Task.isCancelled, store.detailLoading else { return }
      withTurfAnimation(TurfMotion.content, reduceMotion: reduceMotion) { showsLoadingBadge = true }
    }
    .onChange(of: store.selectedItem?.slug) { _, _ in
      webSelection = WebSelection()
      annotationSelection = WebSelection()
      annotationDraft = nil
      selectionFeedback = nil
      showItems = false
      showNotes = false
      showAsk = false
      showProof = false
      showDecisionMore = false
    }
    .onChange(of: webSelection) { _, selection in
      if !selection.isEmpty {
        annotationSelection = selection
        beginTextAnnotation(selection)
      }
    }
    .sheet(isPresented: $showListening) {
      if let item = store.selectedItem {
        NavigationStack {
          List {
            Section {
              contextMemoControl(for: item, url: store.absoluteAudioURL(store.contextStatus?.url ?? item.contextURL))
              readAloudControl(for: item, url: store.absoluteAudioURL(store.ttsStatus?.url ?? item.ttsURL))
            }
            if let summary = store.contextStatus?.summary ?? item.contextSummary, !summary.isEmpty {
              Section("About this review") { Text(summary).font(.body) }
            }
          }
          .scrollContentBackground(.hidden)
          .background(TurfTheme.panel)
          .navigationTitle("Listen")
          .turfInlineNavigationTitle()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showListening = false } } }
        }
        .presentationDetents([.medium, .large])
        // Opaque panel canvas: the iOS 26 glass sheet otherwise shows the reader through the rows.
        .presentationBackground(TurfTheme.panel)
      }
    }
    // On iPad (regular) the Items, Ask and Proof popovers hang from their toolbar buttons and the
    // decision popover from the dock; these detail-level ones serve compact (as sheets) and the Mac.
    .modifier(DetailPopover(isPresented: $showItems, isEnabled: usesDetailPopovers) {
      if let item = store.selectedItem {
        summonPanel { ReviewTargetsPanel(store: store, item: item) }
      }
    })
    #if os(iOS)
    .sheet(isPresented: $showNotes) {
      NavigationStack {
        ScrollView {
          AnnotationPanel(store: store, selection: annotationSelection)
            .padding(TurfSpacing.panelInset(compact: isCompact))
        }
        .background(TurfTheme.panel)
        // AnnotationPanel's own header is the title; the bar keeps only Done.
        .navigationTitle("")
        .turfInlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { showNotes = false }
          }
        }
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(TurfTheme.panel)
    }
    #else
    .modifier(DetailPopover(isPresented: $showNotes, isEnabled: true) {
      summonPanel { AnnotationPanel(store: store, selection: annotationSelection) }
    })
    #endif
    .modifier(DetailPopover(isPresented: $showAsk, isEnabled: usesDetailPopovers) {
      summonPanel { ChatPanel(store: store) }
    })
    .modifier(DetailPopover(isPresented: $showProof, isEnabled: usesDetailPopovers) {
      if let item = store.selectedItem {
        summonPanel { StatusPanel(store: store, item: item) }
      }
    })
    .modifier(DetailPopover(isPresented: $showDecisionMore, isEnabled: usesDetailPopovers) {
      decisionPanel
    })
    .sheet(item: $annotationDraft) { draft in
      AnnotationComposer(quote: draft.selection.text, autofocus: true) { comment in
        webSelection = WebSelection()
        annotationSelection = WebSelection()
        newAnnotationToken &+= 1
        let saveToken = newAnnotationToken
        let didSave = await store.createAnnotation(
          for: draft.slug,
          quote: draft.selection.text,
          anchorRef: draft.selection.anchorRef,
          comment: comment
        )
        if didSave {
          showNotes = true
        } else {
          cancelledAnnotationToken = saveToken
        }
        return didSave
      }
    }
  }

  // MARK: Reader (full-bleed)

  @ViewBuilder
  private func readerWorkspace(for item: ReviewItem) -> some View {
    #if os(macOS)
    readerWithPlayback(for: item)
    #else
    readerWithPlayback(for: item)
      // Inside the dock's inset, so the pulse always sits just above the dock.
      .overlay(alignment: .bottom) {
        if let selectionFeedback, isCompact {
          SelectionCapturePulse(feedback: selectionFeedback)
            .padding(.horizontal, readerInset)
            .padding(.bottom, TurfSpacing.l)
            .transition(.turfSettle(reduceMotion: reduceMotion))
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        dockContainer(for: item)
      }
      .background(TurfTheme.paper)
    #endif
  }

  #if os(iOS)
  @ViewBuilder
  private func dockContainer(for item: ReviewItem) -> some View {
    if #available(iOS 26.0, *) {
      // A floating glass capsule, matching the system toolbar glass. Pills sit dockInner inside it,
      // which puts their edges on the reader text edge.
      decisionDock(for: item)
        .padding(TurfSpacing.dockInner)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, readerInset - TurfSpacing.dockInner)
        .padding(.vertical, TurfSpacing.dockInner)
        .frame(maxWidth: isCompact ? .infinity : readerColumnWidth)
        .frame(maxWidth: .infinity)
        .modifier(DecisionPopoverAnchor(isPresented: $showDecisionMore, isEnabled: !usesDetailPopovers) {
          decisionPanel
        })
    } else {
      // iOS 17–25: the system bar material as a full-width band under a hairline.
      decisionDock(for: item)
        .padding(.horizontal, readerInset)
        .padding(.vertical, TurfSpacing.dockInner)
        .frame(maxWidth: isCompact ? .infinity : readerColumnWidth)
        .frame(maxWidth: .infinity)
        .modifier(DecisionPopoverAnchor(isPresented: $showDecisionMore, isEnabled: !usesDetailPopovers) {
          decisionPanel
        })
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
  }
  #endif

  private func readerWithPlayback(for item: ReviewItem) -> some View {
    VStack(spacing: 0) {
      playbackControls(for: item)
      Divider()
      reader(for: item)
    }
    // Transforms to a Bool so the view updates only when the width crosses the CSS
    // breakpoint, not on every frame of a split-view drag or window resize.
    .onGeometryChange(for: Bool.self) { proxy in
      proxy.size.width < 600
    } action: { isNarrow in
      readerIsNarrow = isNarrow
    }
  }

  @ViewBuilder
  private func playbackControls(for item: ReviewItem) -> some View {
    let contextURL = store.absoluteAudioURL(store.contextStatus?.url ?? item.contextURL)
    let readAloudURL = store.absoluteAudioURL(store.ttsStatus?.url ?? item.ttsURL)
    if contextURL != nil || readAloudURL != nil || localSpeechContent(for: item) != nil {
      HStack(spacing: 0) {
        if contextURL != nil { contextMemoControl(for: item, url: contextURL) }
        else { readAloudControl(for: item, url: readAloudURL) }
        Button { showListening = true } label: {
          Image(systemName: "ellipsis").frame(width: TurfSpacing.hitTarget, height: TurfSpacing.hitTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Listening options")
      }
      // The play glyph (not its 44pt hit box) sits on the reader text edge.
      .padding(.horizontal, max(0, readerInset - (TurfSpacing.hitTarget - playGlyphWidth) / 2))
      .padding(.vertical, TurfSpacing.xs)
      .frame(maxWidth: isCompact ? .infinity : readerColumnWidth)
      .frame(maxWidth: .infinity)
      .background(TurfTheme.paper)
    }
  }

  private func readAloudControl(for item: ReviewItem, url: URL?) -> some View {
    AudioPlayerBar(
      title: "Read aloud",
      subtitle: nil,
      url: url,
      status: store.ttsStatus?.status ?? item.ttsStatus,
      requestHeaders: url.map { store.configuration.authenticationHeaders(for: $0) } ?? [:],
      localSpeechContent: localSpeechContent(for: item)
    )
  }
  private func localSpeechContent(for item: ReviewItem) -> LocalSpeechContent? {
    if let renderedHTML = item.renderedHTML, !renderedHTML.isEmpty {
      return LocalSpeechContent(source: renderedHTML, isHTML: true)
    }
    if let markdown = item.markdown, !markdown.isEmpty {
      return LocalSpeechContent(source: markdown, isHTML: false)
    }
    return nil
  }


  private func contextMemoControl(for item: ReviewItem, url: URL?) -> some View {
    AudioPlayerBar(
      title: "Audio briefing",
      subtitle: store.contextStatus?.summary ?? item.contextSummary,
      url: url,
      status: store.contextStatus?.status ?? item.contextStatus,
      requestHeaders: url.map { store.configuration.authenticationHeaders(for: $0) } ?? [:]
    )
  }

  private func reader(for item: ReviewItem) -> some View {
    let remoteURL = item.artifactPath.flatMap { store.absoluteFollowupURL($0) }
    return HTMLDocumentView(
      html: item.displayHTML,
      baseURL: store.configuration.serverURL,
      remoteURL: remoteURL,
      requestHeaders: remoteURL.map { store.configuration.authenticationHeaders(for: $0) } ?? [:],
      documentID: item.slug,
      contentVersion: documentContentVersion(for: item, remoteURL: remoteURL),
      annotations: store.annotations,
      reviewTargets: item.isCustomHTMLArtifact ? [] : store.reviewTargets,
      newAnnotationToken: newAnnotationToken,
      cancelledAnnotationToken: cancelledAnnotationToken,
      selection: $webSelection,
      onPencilSelection: beginTextAnnotation,
      onReviewTargetDecision: { key, verdict in
        updateInlineReviewTarget(key: key, verdict: verdict, item: item)
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TurfTheme.paper)
  }

  private func decisionDock(for item: ReviewItem) -> some View {
    DecisionDock(store: store, item: item) {
      showDecisionMore = true
    }
    // A fresh dock per review, so switching reviews never plays the decision-landing moment.
    .id(item.slug)
  }

  @ViewBuilder
  private var decisionPanel: some View {
    if let item = store.selectedItem {
      summonPanel { DecisionPanel(store: store, item: item) }
    }
  }

  private func documentContentVersion(for item: ReviewItem, remoteURL: URL?) -> String {
    guard item.isCustomHTMLArtifact else {
      return DocumentContentVersion.make(item.displayHTML)
    }
    let identity = [
      remoteURL?.absoluteString,
      item.contentLength.map(String.init),
      item.updatedAt ?? item.createdAt,
    ]
      .compactMap { $0 }
      .joined(separator: "\u{0}")
    return DocumentContentVersion.make(identity)
  }

  // MARK: Summon toolbar (Items · Notes · Ask · Proof)

  @ToolbarContentBuilder
  private var summonToolbar: some ToolbarContent {
    if let item = store.selectedItem {
      #if os(macOS)
      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItem(placement: .primaryAction) {
        MacReviewToolbar(
          store: store,
          item: item,
          onDecisionDetails: { showDecisionMore = true },
          onItems: { showItems = true },
          onNotes: { showNotes = true },
          onAsk: { showAsk = true },
          onProof: { showProof = true }
        )
      }
      #else
      if isCompact {
        ToolbarItemGroup(placement: .turfTrailing) {
          Button {
            showNotes = true
          } label: {
            Image(systemName: "note.text")
          }
          .accessibilityLabel("Notes and annotations")

          Menu {
            Button {
              showItems = true
            } label: {
              Label(panelTitle("Items", badge: store.reviewTargetSummary.undecided), systemImage: "checklist")
            }
            Button { showListening = true } label: { Label("Listen", systemImage: "headphones") }
            Button {
              showAsk = true
            } label: {
              Label(panelTitle("Ask", badge: store.chatMessages.count), systemImage: "bubble.left.and.bubble.right")
            }
            Button {
              showProof = true
            } label: {
              Label("Proof", systemImage: "waveform.path.ecg")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("More review tools")
        }
      } else {
        ToolbarItemGroup(placement: .turfTrailing) {
          SummonButton(
            title: "Items",
            systemImage: "checklist",
            badge: store.reviewTargetSummary.undecided,
            isPresented: $showItems
          ) {
            if let item = store.selectedItem {
              summonPanel { ReviewTargetsPanel(store: store, item: item) }
            }
          }

          // Notes is a sheet on iOS, so its button presents nothing itself.
          SummonButton(
            title: "Notes",
            systemImage: "note.text",
            badge: store.annotations.count,
            isPresented: $showNotes
          )

          SummonButton(
            title: "Ask",
            systemImage: "bubble.left.and.bubble.right",
            badge: store.chatMessages.count,
            isPresented: $showAsk
          ) {
            summonPanel { ChatPanel(store: store) }
          }

          SummonButton(
            title: "Proof",
            systemImage: "waveform.path.ecg",
            badge: 0,
            isPresented: $showProof
          ) {
            if let item = store.selectedItem {
              summonPanel { StatusPanel(store: store, item: item) }
            }
          }
        }
      }
      #endif
    }
  }

  @ViewBuilder
  private func summonPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if isCompact {
      ScrollView {
        content()
          .padding(TurfSpacing.panelInset(compact: true))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(TurfTheme.panel)
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    } else {
      ScrollView {
        content()
          .padding(TurfSpacing.panelInset(compact: false))
      }
      .frame(minWidth: 360, idealWidth: 380, maxWidth: 440, minHeight: 440, idealHeight: 560)
      .background(TurfTheme.panel)
      .presentationDetents([.medium, .large])
    }
  }

  private var navigationTitle: String {
    guard let item = store.selectedItem else { return "Review" }
    // iPhone keeps the document's name in the bar while you scroll. The iPad and Mac detail
    // column stays untitled so its four toolbar buttons never fold into an overflow menu.
    return isCompact ? item.title : ""
  }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  /// Detail-level popovers serve compact (where they become sheets) and the Mac. On iPad regular
  /// each popover hangs from the control that opens it.
  private var usesDetailPopovers: Bool {
    #if os(macOS)
    true
    #else
    isCompact
    #endif
  }

  /// Matches the reader CSS: `--turf-reader-inline` is 20px below a 600px viewport and 32px at or
  /// above it. Keying on the measured width (not the size class) keeps the audio glyph, the text and
  /// the dock pills on one edge in a narrow iPad split column.
  private var readerInset: CGFloat {
    TurfSpacing.readerInset(compact: readerIsNarrow ?? isCompact)
  }

  /// The reading column (text measure plus both insets) that the audio row and dock share on regular.
  private var readerColumnWidth: CGFloat {
    TurfLayout.readerColumnWidth(readerSize: TurfType.readerBodySize(for: dynamicTypeSize))
  }

  private func panelTitle(_ title: String, badge: Int) -> String {
    badge > 0 ? "\(title) (\(min(badge, 99)))" : title
  }

  // MARK: Inline interactions

  private func updateInlineReviewTarget(key: String, verdict: String, item: ReviewItem) {
    guard let target = store.reviewTargets.first(where: { $0.key == key }) else { return }
    Task {
      await store.updateReviewTarget(
        target,
        for: item.slug,
        verdict: verdict,
        feedback: verdict == "rejected" ? target.feedback : nil
      )
    }
  }

  private func beginTextAnnotation(_ selection: WebSelection) {
    guard !selection.isEmpty,
          let slug = store.selectedSlug else { return }
    guard annotationDraft?.slug != slug || annotationDraft?.selection != selection else { return }
    presentSelectionFeedback(for: selection)
    webSelection = selection
    annotationSelection = selection
    annotationDraft = AnnotationDraft(slug: slug, selection: selection)
  }

  private func presentSelectionFeedback(for selection: WebSelection) {
    let feedback = SelectionCaptureFeedback(selection: selection)
    TurfPlatformFeedback.selectionCaptured()
    withTurfAnimation(TurfMotion.panel, reduceMotion: reduceMotion) {
      selectionFeedback = feedback
    }
    Task { @MainActor in
      try? await Task.sleep(for: AnnotationInteractionMotion.captureVisibleDuration)
      guard selectionFeedback?.id == feedback.id else { return }
      withTurfAnimation(TurfMotion.exit, reduceMotion: reduceMotion) {
        selectionFeedback = nil
      }
    }
  }
}

private enum AnnotationInteractionMotion {
  static let captureVisibleDuration: Duration = .milliseconds(620)
}

/// A detail-level popover that can be switched off (iPad regular presents from the control instead).
private struct DetailPopover<PopoverContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let isEnabled: Bool
  @ViewBuilder let popoverContent: () -> PopoverContent

  func body(content: Content) -> some View {
    #if os(macOS)
    // Hang from the toolbar corner rather than the detail view's leading edge.
    content.popover(
      isPresented: $isPresented,
      attachmentAnchor: .point(.topTrailing),
      arrowEdge: .top,
      content: popoverContent
    )
    #else
    content.popover(
      isPresented: Binding(
        get: { isEnabled && isPresented },
        set: { isPresented = $0 }
      ),
      content: popoverContent
    )
    #endif
  }
}

#if os(iOS)
/// The decision popover on iPad regular, hanging from the dock that opens it.
private struct DecisionPopoverAnchor<PopoverContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let isEnabled: Bool
  @ViewBuilder let popoverContent: () -> PopoverContent

  func body(content: Content) -> some View {
    content.popover(
      isPresented: Binding(
        get: { isEnabled && isPresented },
        set: { isPresented = $0 }
      ),
      content: popoverContent
    )
  }
}
#endif

/// A toolbar summon icon with a count badge. When it has popover content, the popover hangs
/// from this button (iPad regular), so its arrow points at the control that opened it.
private struct SummonButton<PopoverContent: View>: View {
  let title: String
  let systemImage: String
  let badge: Int
  @Binding var isPresented: Bool
  let popover: (() -> PopoverContent)?

  init(
    title: String,
    systemImage: String,
    badge: Int,
    isPresented: Binding<Bool>,
    @ViewBuilder popover: @escaping () -> PopoverContent
  ) {
    self.title = title
    self.systemImage = systemImage
    self.badge = badge
    _isPresented = isPresented
    self.popover = popover
  }

  var body: some View {
    if let popover {
      button.popover(isPresented: $isPresented, content: popover)
    } else {
      button
    }
  }

  private var button: some View {
    Button {
      isPresented = true
    } label: {
      Image(systemName: systemImage)
        .overlay(alignment: .topTrailing) {
          TurfCountBadge(count: badge)
            .offset(x: TurfSpacing.s, y: -TurfSpacing.s)
        }
    }
    .accessibilityLabel(badge > 0 ? "\(title), \(badge)" : title)
  }
}

extension SummonButton where PopoverContent == EmptyView {
  init(title: String, systemImage: String, badge: Int, isPresented: Binding<Bool>) {
    self.title = title
    self.systemImage = systemImage
    self.badge = badge
    _isPresented = isPresented
    self.popover = nil
  }
}

private struct AnnotationDraft: Identifiable, Equatable {
  let id = UUID()
  let slug: String
  let selection: WebSelection
}

private struct SelectionCaptureFeedback: Identifiable, Equatable {
  let id = UUID()
  let selection: WebSelection

  var preview: String {
    let text = selection.text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > 76 else { return text }
    return String(text.prefix(73)) + "…"
  }
}

private struct SelectionCapturePulse: View {
  let feedback: SelectionCaptureFeedback

  var body: some View {
    HStack(spacing: TurfSpacing.s) {
      Image(systemName: "text.quote")
        .font(.body.weight(.semibold))
        .foregroundStyle(TurfTheme.accent)

      Text(feedback.preview)
        .font(TurfType.quote)
        .foregroundStyle(TurfTheme.ink)
        .lineLimit(2)
        .multilineTextAlignment(.leading)

      Spacer(minLength: 0)
    }
    .padding(TurfSpacing.cardInset)
    .background(TurfTheme.card, in: RoundedRectangle(cornerRadius: TurfRadius.card, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Selection captured")
  }
}

private struct DetailLoadingBadge: View {
  var body: some View {
    HStack(spacing: TurfSpacing.s) {
      ProgressView()
        .controlSize(.small)
      Text("Loading review")
        .font(TurfType.meta)
    }
    .padding(.horizontal, TurfSpacing.m)
    .padding(.vertical, TurfSpacing.s)
    .foregroundStyle(TurfTheme.ink)
    .background(TurfTheme.card, in: Capsule(style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Loading review")
  }
}
