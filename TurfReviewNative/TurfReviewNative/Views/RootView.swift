import Combine
import SwiftUI

struct RootView: View {
  let store: ReviewStore
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var compactPath: [String] = []
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    Group {
      if horizontalSizeClass == .compact {
        compactWorkspace
      } else {
        regularWorkspace
      }
    }
    #if os(iOS)
    .background(TurfTheme.paper.ignoresSafeArea())
    #endif
    .turfMacWindowSurface()
    .task {
      await store.refresh()
      if let pendingURL = PushNotificationTapRouter.takePendingURL() {
        openReview(pendingURL)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active, !store.items.isEmpty {
        Task { await store.refreshOnForeground() }
      }
    }
    .onOpenURL(perform: openReview)
    .onReceive(NotificationCenter.default.publisher(for: .turfReviewNotificationTapped)) { notification in
      guard let url = notification.object as? URL else { return }
      PushNotificationTapRouter.consume(url)
      openReview(url)
    }
  }
  private func openReview(_ url: URL) {
    Task {
      guard let slug = await store.openReviewLink(url) else { return }
      if horizontalSizeClass == .compact {
        compactPath = [slug]
      }
    }
  }


  private var compactWorkspace: some View {
    NavigationStack(path: $compactPath) {
      QueueView(store: store) { slug in
        compactPath = [slug]
      }
        .navigationTitle("Library")
        .navigationDestination(for: String.self) { slug in
          CompactReviewRouteView(store: store, slug: slug)
        }
    }
  }

  private var regularWorkspace: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      QueueView(store: store)
        #if os(iOS)
        // The iPad sidebar reports a compact size class, so QueueView shows its compact header and
        // relies on the system large title, as on iPhone.
        .navigationTitle("Library")
        #endif
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 430)
    } detail: {
      ReviewDetailView(store: store)
    }
    .navigationSplitViewStyle(.balanced)
  }
}

private struct CompactReviewRouteView: View {
  let store: ReviewStore
  let slug: String

  var body: some View {
    Group {
      if store.selectedSlug == slug || store.selectedItem?.slug == slug {
        ReviewDetailView(store: store)
      } else {
        RouteLoadingView()
      }
    }
    .task(id: slug) {
      await store.selectItem(slug: slug)
    }
  }
}

/// Plain paper for the first `loadingRevealDelay`, then a quiet spinner fades in.
/// Fast opens never flash a loading state. The swap to the review itself is not animated,
/// so the web view never fades.
private struct RouteLoadingView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isRevealed = false

  var body: some View {
    ZStack {
      if isRevealed {
        VStack(spacing: TurfSpacing.m) {
          ProgressView()
          Text("Loading review")
            .font(TurfType.meta)
            .foregroundStyle(TurfTheme.muted)
        }
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TurfTheme.paper)
    .navigationTitle("Review")
    .turfInlineNavigationTitle()
    .task {
      try? await Task.sleep(for: TurfMotion.loadingRevealDelay)
      guard !Task.isCancelled else { return }
      withTurfAnimation(TurfMotion.content, reduceMotion: reduceMotion) {
        isRevealed = true
      }
    }
  }
}
