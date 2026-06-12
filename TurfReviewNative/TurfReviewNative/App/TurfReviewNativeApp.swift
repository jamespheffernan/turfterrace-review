import SwiftUI

@main
struct TurfReviewNativeApp: App {
  @StateObject private var store = ReviewStore()

  var body: some Scene {
    WindowGroup {
      RootView(store: store)
        .tint(TurfTheme.accent)
    }
  }
}
