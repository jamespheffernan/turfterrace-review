import SwiftUI

@main
struct TurfReviewNativeApp: App {
  @State private var store = ReviewStore(downloadsEnabled: true)
  #if os(iOS)
  @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushNotificationDelegate
  #elseif os(macOS)
  @NSApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var pushNotificationDelegate
  #endif

  init() {
    WebViewWarmup.start()
  }

  var body: some Scene {
    #if os(macOS)
    macScenes
    #else
    WindowGroup {
      RootView(store: store)
        .tint(TurfTheme.accent)
    }
    #endif
  }

  #if os(macOS)
  @SceneBuilder
  private var macScenes: some Scene {
    WindowGroup {
      RootView(store: store)
        .tint(TurfTheme.accent)
    }
    .defaultSize(width: 1320, height: 860)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .sidebar) {
        Button("Refresh Reviews") {
          Task { await store.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
      }
    }

    Settings {
      SettingsView(configuration: store.configuration) { configuration in
        await store.saveConfiguration(configuration)
      }
      .frame(width: 520, height: 420)
      .tint(TurfTheme.accent)
    }
  }
  #endif
}
