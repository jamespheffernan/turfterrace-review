import SwiftUI

struct ReviewDetailView: View {
  @ObservedObject var store: ReviewStore
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var webSelection = WebSelection()
  @State private var inspectorMode: InspectorMode = .decide
  @State private var pencilAnnotationDraft: PencilAnnotationDraft?

  enum InspectorMode: String, CaseIterable, Identifiable {
    case decide
    case notes
    case chat
    case status

    var id: String { rawValue }

    var title: String {
      switch self {
      case .decide: return "Decide"
      case .notes: return "Notes"
      case .chat: return "Chat"
      case .status: return "Status"
      }
    }

    var icon: String {
      switch self {
      case .decide: return "checkmark.circle"
      case .notes: return "text.quote"
      case .chat: return "bubble.left.and.bubble.right"
      case .status: return "waveform.path.ecg"
      }
    }
  }

  var body: some View {
    Group {
      if let item = store.selectedItem {
        content(for: item)
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
          inspectorMode = .notes
        }
        return didSave
      }
    }
  }

  @ViewBuilder
  private func content(for item: ReviewItem) -> some View {
    if horizontalSizeClass == .regular {
      GeometryReader { proxy in
        if proxy.size.width >= 760 {
          HStack(spacing: 0) {
            reader(for: item)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
              .background(TurfTheme.hairline)
            inspector(for: item)
              .frame(width: min(360, max(320, proxy.size.width * 0.3)))
              .background(TurfTheme.panel)
          }
          .background(TurfTheme.paper)
        } else {
          VStack(spacing: 0) {
            readerBody(for: item)
              .frame(minHeight: 680)
            Divider()
            ScrollView {
              mobileInspector(for: item)
                .padding(16)
            }
            .frame(maxHeight: 360)
            .background(TurfTheme.panel)
          }
          .background(TurfTheme.paper)
        }
      }
    } else {
      ScrollView {
        VStack(spacing: 14) {
          readerBody(for: item)
            .frame(minHeight: 560)
          mobileInspector(for: item)
        }
        .padding(12)
      }
      .background(TurfTheme.paper)
    }
  }

  private func reader(for item: ReviewItem) -> some View {
    readerBody(for: item)
      .background(TurfTheme.paper)
  }

  private func readerBody(for item: ReviewItem) -> some View {
    HTMLDocumentView(
      html: item.displayHTML,
      baseURL: store.configuration.serverURL,
      annotations: store.annotations,
      selection: $webSelection,
      onPencilSelection: beginPencilAnnotation
    )
    .background(TurfTheme.paper)
    .ignoresSafeArea(.container, edges: .bottom)
  }

  private func beginPencilAnnotation(_ selection: WebSelection) {
    guard !selection.isEmpty,
          let slug = store.selectedSlug else { return }
    webSelection = selection
    pencilAnnotationDraft = PencilAnnotationDraft(slug: slug, selection: selection)
  }

  private func inspector(for item: ReviewItem) -> some View {
    VStack(spacing: 0) {
      Picker("Inspector", selection: $inspectorMode) {
        ForEach(InspectorMode.allCases) { mode in
          Label(mode.title, systemImage: mode.icon).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(14)

      Divider()

      ScrollView {
        inspectorContent(for: item)
          .padding(14)
      }
    }
  }

  private func mobileInspector(for item: ReviewItem) -> some View {
    VStack(spacing: 12) {
      Picker("Inspector", selection: $inspectorMode) {
        ForEach(InspectorMode.allCases) { mode in
          Label(mode.title, systemImage: mode.icon).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      inspectorContent(for: item)
    }
  }

  @ViewBuilder
  private func inspectorContent(for item: ReviewItem) -> some View {
    switch inspectorMode {
    case .decide:
      DecisionPanel(store: store, item: item)
    case .notes:
      AnnotationPanel(store: store, selection: webSelection)
    case .chat:
      ChatPanel(store: store)
    case .status:
      StatusPanel(store: store, item: item)
    }
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
