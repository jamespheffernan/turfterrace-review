import SwiftUI

#if os(iOS)
import UIKit
typealias TurfPlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias TurfPlatformImage = NSImage
#endif

extension Image {
  init(turfPlatformImage image: TurfPlatformImage) {
    #if os(iOS)
    self.init(uiImage: image)
    #else
    self.init(nsImage: image)
    #endif
  }
}

extension ToolbarItemPlacement {
  static var turfTrailing: ToolbarItemPlacement {
    #if os(iOS)
    return .topBarTrailing
    #else
    return .primaryAction
    #endif
  }
}

extension View {
  @ViewBuilder
  func turfInlineNavigationTitle() -> some View {
    #if os(iOS)
    navigationBarTitleDisplayMode(.inline)
    #else
    self
    #endif
  }

  @ViewBuilder
  func turfMacWindowSurface() -> some View {
    #if os(macOS)
    background(TurfMacWindowSurface())
    #else
    self
    #endif
  }
}

#if os(macOS)
private struct TurfMacWindowSurface: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    configureWindow(for: view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    configureWindow(for: view)
  }

  private func configureWindow(for view: NSView) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      // The window follows the system appearance and keeps the system window background.
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
    }
  }
}
#endif

enum TurfPlatformFeedback {
  static func selectionCaptured() {
    #if os(iOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.72)
    #endif
  }

  static func saveStarted() {
    #if os(iOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.78)
    #endif
  }

  static func saveSucceeded() {
    #if os(iOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #elseif os(macOS)
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    #endif
  }
}
