import SwiftUI

struct RootView: View {
  @ObservedObject var store: ReviewStore

  var body: some View {
    NavigationSplitView {
      QueueView(store: store)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 430)
    } detail: {
      ReviewDetailView(store: store)
    }
    .background(TurfTheme.paper)
    .task {
      await store.refresh()
    }
  }
}
