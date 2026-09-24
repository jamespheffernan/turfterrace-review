#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import TurfReviewNative

@MainActor
final class NativeDesignSnapshotTests: XCTestCase {
  func testLibraryAndReaderVisuals() async throws {
    let store = ReviewStore(configuration: .defaults)
    store.items = DemoData.items
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DesignSnapshots")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for dark in [false, true] {
      let library = NavigationStack {
        QueueView(store: store, onOpenItem: { _ in }).navigationTitle("Library")
      }.tint(TurfTheme.accent).preferredColorScheme(dark ? .dark : .light)
      try await capture(library, size: CGSize(width: 393, height: 852), name: "library-\(dark ? "dark" : "light")", directory: directory)
      var item = DemoData.items[0]
      item.renderedHTML = """
      <h1>A quieter place to review your work</h1>
      <p>This is the reading view. The document takes centre stage, with your notes and decisions close at hand.</p>
      <h2>What needs your attention</h2>
      <p>Read the details, highlight a passage to leave a note, then choose what happens next.</p>
      <ul><li>Review the proposed changes</li><li>Check the supporting evidence</li><li>Approve when you are ready</li></ul>
      <blockquote>A good review makes the next step clear.</blockquote>
      <h2>Supporting details</h2><p>Longer documents stay readable, without oversized headings or crowded controls.</p>
      """
      store.selectedItem = item
      store.selectedSlug = item.slug
      store.contextStatus = .init(status: "ready", url: "https://example.com/context.mp3", summary: nil)
      let reader = NavigationStack { ReviewDetailView(store: store) }
        .tint(TurfTheme.accent).preferredColorScheme(dark ? .dark : .light)
      try await capture(reader, size: CGSize(width: 393, height: 852), name: "reader-\(dark ? "dark" : "light")", directory: directory)
      if !dark {
        try await capture(reader, size: CGSize(width: 1024, height: 1366), name: "reader-ipad", directory: directory, compact: false)
        try await capture(library.dynamicTypeSize(.accessibility2), size: CGSize(width: 393, height: 852), name: "library-large-type", directory: directory)
      }
    }
    print("DESIGN_SNAPSHOTS: \(directory.path)")
  }

  private func descendants(_ view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }

  private func capture<V: View>(_ view: V, size: CGSize, name: String, directory: URL, compact: Bool = true) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let controller = UIHostingController(rootView: view.environment(\.horizontalSizeClass, compact ? .compact : .regular))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(900))
    let webViews = descendants(window).compactMap { $0 as? WKWebView }
    var webImages: [(CGRect, UIImage)] = []
    for webView in webViews {
      for _ in 0..<50 {
        if !webView.isLoading, (try? await webView.evaluateJavaScript("document.body.innerText.length") as? Int) ?? 0 > 20 { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let textCount = try await webView.evaluateJavaScript("document.body.innerText.length") as? Int ?? 0
      XCTAssertGreaterThan(textCount, 20, "Reader must render its saved document")
      let snapshot = try await webView.takeSnapshot(configuration: nil)
      webImages.append((webView.convert(webView.bounds, to: window), snapshot))
    }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      for (rect, snapshot) in webImages { snapshot.draw(in: rect) }
    }
    let data = try XCTUnwrap(image.pngData())
    try data.write(to: directory.appendingPathComponent(name + ".png"))
    window.isHidden = true
  }
}
#endif
