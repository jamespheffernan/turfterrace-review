import SwiftUI

struct ReviewDetailView: View {
  @ObservedObject var store: ReviewStore
  @State private var webSelection = WebSelection()
  @State private var pencilAnnotationDraft: PencilAnnotationDraft?

  @State private var showItems = false
  @State private var showNotes = false
  @State private var showAsk = false
  @State private var showProof = false
  @State private var showDecisionMore = false

  var body: some View {
    Group {
      if let item = store.selectedItem {
        reader(for: item)
          .overlay(alignment: .bottom) {
            DecisionDock(store: store, item: item) {
              showDecisionMore = true
            }
            .popover(isPresented: $showDecisionMore) {
              summonPanel { DecisionPanel(store: store, item: item) }
            }
            .padding(.bottom, 24)
          }
      } else {
        ContentUnavailableView(
          "Select a review",
          systemImage: "rectangle.and.text.magnifyingglass",
          description: Text("Choose a queue item to inspect the native review workspace.")
        )
        .background(TurfTheme.paper)
      }
    }
    .navigationTitle(store.selectedItem == nil ? "Review" : "")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { summonToolbar }
    .overlay(alignment: .topTrailing) {
      if store.detailLoading {
        DetailLoadingBadge()
          .padding(.top, 12)
          .padding(.trailing, 14)
      }
    }
    .onChange(of: store.selectedItem?.slug) { _, _ in
      webSelection = WebSelection()
      pencilAnnotationDraft = nil
      showItems = false
      showNotes = false
      showAsk = false
      showProof = false
      showDecisionMore = false
    }
    .sheet(item: $pencilAnnotationDraft) { draft in
      AnnotationComposer(quote: draft.selection.text) { comment in
        let didSave = await store.createAnnotation(
          for: draft.slug,
          quote: draft.selection.text,
          anchorRef: draft.selection.anchorRef,
          comment: comment
        )
        if didSave {
          showNotes = true
        }
        return didSave
      }
    }
  }

  // MARK: Reader (full-bleed)

  private func reader(for item: ReviewItem) -> some View {
    HTMLDocumentView(
      html: item.displayHTML,
      baseURL: store.configuration.serverURL,
      annotations: store.annotations,
      reviewTargets: store.reviewTargets,
      selection: $webSelection,
      onPencilSelection: beginPencilAnnotation,
      onReviewTargetDecision: { key, verdict in
        updateInlineReviewTarget(key: key, verdict: verdict, item: item)
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TurfTheme.paper)
    .ignoresSafeArea(.container, edges: .bottom)
  }

  // MARK: Summon toolbar (Items · Notes · Ask · Proof)

  @ToolbarContentBuilder
  private var summonToolbar: some ToolbarContent {
    if let item = store.selectedItem {
      ToolbarItemGroup(placement: .topBarTrailing) {
        SummonButton(
          title: "Items",
          systemImage: "checklist",
          badge: store.reviewTargetSummary.undecided,
          isPresented: $showItems
        ) {
          summonPanel { ReviewTargetsPanel(store: store, item: item) }
        }

        SummonButton(
          title: "Notes",
          systemImage: "text.quote",
          badge: store.annotations.count,
          isPresented: $showNotes
        ) {
          summonPanel { AnnotationPanel(store: store, selection: webSelection) }
        }

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
          summonPanel { StatusPanel(store: store, item: item) }
        }
      }
    }
  }

  private func summonPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      content()
        .padding(18)
    }
    .frame(minWidth: 360, idealWidth: 380, maxWidth: 440, minHeight: 440, idealHeight: 560)
    .background(TurfTheme.panel)
    .presentationDetents([.medium, .large])
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

  private func beginPencilAnnotation(_ selection: WebSelection) {
    guard !selection.isEmpty,
          let slug = store.selectedSlug else { return }
    webSelection = selection
    pencilAnnotationDraft = PencilAnnotationDraft(slug: slug, selection: selection)
  }
}

/// A toolbar summon icon with a count badge and an attached popover (sheet on compact).
private struct SummonButton<Panel: View>: View {
  let title: String
  let systemImage: String
  let badge: Int
  @Binding var isPresented: Bool
  @ViewBuilder var panel: () -> Panel

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Image(systemName: systemImage)
        .overlay(alignment: .topTrailing) {
          if badge > 0 {
            Text("\(min(badge, 99))")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 4)
              .frame(minWidth: 15, minHeight: 15)
              .background(TurfTheme.accent, in: Capsule())
              .offset(x: 9, y: -9)
          }
        }
    }
    .accessibilityLabel(badge > 0 ? "\(title), \(badge)" : title)
    .popover(isPresented: $isPresented) { panel() }
  }
}

private struct PencilAnnotationDraft: Identifiable, Equatable {
  let id = UUID()
  let slug: String
  let selection: WebSelection
}

private struct DetailLoadingBadge: View {
  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading review")
        .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .foregroundStyle(TurfTheme.ink)
    .background(TurfTheme.panel.opacity(0.94))
    .clipShape(Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .stroke(TurfTheme.hairline, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Loading review")
  }
}
