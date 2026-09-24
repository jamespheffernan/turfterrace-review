#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import TurfReviewNative

/// Captures every main screen for design review. Opt-in: runs only when TR_SCREENSHOTS=1.
///
/// Run on a simulator with the variables in xcodebuild's environment (not as build settings):
///   TEST_RUNNER_TR_SCREENSHOTS=1 TEST_RUNNER_TR_SCREENSHOT_SET=before xcodebuild test ... \
///     -only-testing:TurfReviewNativeTests/NativeScreenSnapshotTests
/// PNGs land in the app's Documents/NativeScreenSnapshots/<set>/ directory.
///
/// Uses the device's real screen size and horizontal size class, so the same test produces
/// iPhone output (NavigationStack) and iPad output (NavigationSplitView, popovers).
///
/// ReviewDetailView presents its panels from private @State, so the containers below
/// (summonPanel, the Notes sheet, the Listen sheet) replicate ReviewDetailView's wrappers.
/// The panel views themselves are the production views. If those wrappers change,
/// update `summonPanel`, `notesSheet` and `listenSheet` here to match.
@MainActor
final class NativeScreenSnapshotTests: XCTestCase {
  private var directory: URL!
  private var failures: [String] = []

  override func setUp() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TR_SCREENSHOTS"] == "1" else {
      throw XCTSkip("Set TR_SCREENSHOTS=1 to capture design screenshots.")
    }
    let set = environment["TR_SCREENSHOT_SET"].flatMap { $0.isEmpty ? nil : $0 } ?? "before"
    directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeScreenSnapshots")
      .appendingPathComponent(set)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func testCaptureMainScreens() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let regular = scene.traitCollection.horizontalSizeClass == .regular

    for dark in [false, true] {
      let mode = dark ? "dark" : "light"

      // Library: no review selected.
      let libraryStore = Self.makeStore(selecting: false)
      await capture("library-\(mode)", dark: dark, expectsWeb: false) {
        Workspace(store: libraryStore, regular: regular, showsReader: false) {
          ReviewDetailView(store: libraryStore)
        }
      }

      // Reader with the decision dock, saved annotation and open review targets.
      let store = Self.makeStore(selecting: true)
      await capture("reader-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
        }
      }
      await capture("reader-middle-\(mode)", dark: dark, expectsWeb: true, readerScroll: .checklist) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
        }
      }
      await capture("reader-lower-\(mode)", dark: dark, expectsWeb: true, readerScroll: .end) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
        }
      }
      if regular {
        await capture("reader-focus-\(mode)", dark: dark, expectsWeb: true) {
          Workspace(store: store, regular: regular, showsReader: true, columnVisibility: .detailOnly) {
            ReviewDetailView(store: store)
          }
        }
      }

      // Panels presented from the reader, in the same containers ReviewDetailView uses.
      await capture("notes-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
            .sheet(isPresented: .constant(true)) { Self.notesSheet(store: store, regular: regular) }
        }
      }
      await capture("items-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
            .popover(isPresented: .constant(true)) {
              SummonPanel(regular: regular) { ReviewTargetsPanel(store: store, item: store.selectedItem!) }
            }
        }
      }
      await capture("ask-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
            .popover(isPresented: .constant(true)) {
              SummonPanel(regular: regular) { ChatPanel(store: store) }
            }
        }
      }
      await capture("proof-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
            .popover(isPresented: .constant(true)) {
              SummonPanel(regular: regular) { StatusPanel(store: store, item: store.selectedItem!) }
            }
        }
      }
      await capture("decision-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
            .popover(isPresented: .constant(true)) {
              SummonPanel(regular: regular) { DecisionPanel(store: store, item: store.selectedItem!) }
            }
        }
      }
      await capture("listen-\(mode)", dark: dark, expectsWeb: true) {
        Workspace(store: store, regular: regular, showsReader: true) {
          ReviewDetailView(store: store)
            .sheet(isPresented: .constant(true)) { Self.listenSheet(store: store) }
        }
      }

      // Settings is a sheet from the library menu.
      let settingsStore = Self.makeStore(selecting: false)
      await capture("settings-\(mode)", dark: dark, expectsWeb: false) {
        Workspace(store: settingsStore, regular: regular, showsReader: false) {
          ReviewDetailView(store: settingsStore)
        }
        .sheet(isPresented: .constant(true)) {
          SettingsView(configuration: Self.settingsConfiguration) { _ in true }
        }
      }
    }

    // Dynamic Type accessibility3, light only.
    let largeLibraryStore = Self.makeStore(selecting: false)
    await capture("library-a11y3-light", dark: false, expectsWeb: false, largeType: true) {
      Workspace(store: largeLibraryStore, regular: regular, showsReader: false) {
        ReviewDetailView(store: largeLibraryStore)
      }
    }
    let largeReaderStore = Self.makeStore(selecting: true)
    await capture("reader-a11y3-light", dark: false, expectsWeb: true, largeType: true) {
      Workspace(store: largeReaderStore, regular: regular, showsReader: true) {
        ReviewDetailView(store: largeReaderStore)
      }
    }

    print("NATIVE_SCREEN_SNAPSHOTS: \(regular ? "ipad" : "iphone") \(directory.path)")
    if !failures.isEmpty {
      XCTFail("Some screens could not be captured:\n" + failures.joined(separator: "\n"))
    }
  }

  // MARK: Containers (mirror RootView and ReviewDetailView)

  /// Mirrors RootView: NavigationStack on compact, NavigationSplitView on regular.
  private struct Workspace<Detail: View>: View {
    let store: ReviewStore
    let regular: Bool
    let showsReader: Bool
    var columnVisibility: NavigationSplitViewVisibility = .all
    @ViewBuilder let detail: () -> Detail

    var body: some View {
      Group {
        if regular {
          NavigationSplitView(columnVisibility: .constant(columnVisibility)) {
            QueueView(store: store)
              .navigationTitle("Library")
              .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 430)
          } detail: {
            detail()
          }
          .navigationSplitViewStyle(.balanced)
        } else {
          NavigationStack(path: .constant(showsReader ? [store.selectedSlug ?? ""] : [String]())) {
            QueueView(store: store) { _ in }
              .navigationTitle("Library")
              .navigationDestination(for: String.self) { _ in detail() }
          }
        }
      }
      .background(TurfTheme.paper.ignoresSafeArea())
    }
  }

  /// Mirrors ReviewDetailView.summonPanel.
  private struct SummonPanel<Content: View>: View {
    let regular: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
      if !regular {
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
  }

  /// Mirrors ReviewDetailView's iOS Notes sheet (AnnotationPanel's header is the title).
  private static func notesSheet(store: ReviewStore, regular: Bool) -> some View {
    NavigationStack {
      ScrollView {
        AnnotationPanel(store: store, selection: WebSelection())
          .padding(TurfSpacing.panelInset(compact: !regular))
      }
      .background(TurfTheme.panel)
      .navigationTitle("")
      .turfInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {}
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(TurfTheme.panel)
  }

  /// Mirrors ReviewDetailView's Listen sheet.
  private static func listenSheet(store: ReviewStore) -> some View {
    let item = store.selectedItem!
    let summary = store.contextStatus?.summary ?? item.contextSummary
    let contextURL = store.absoluteAudioURL(store.contextStatus?.url ?? item.contextURL)
    let ttsURL = store.absoluteAudioURL(store.ttsStatus?.url ?? item.ttsURL)
    return NavigationStack {
      List {
        Section {
          AudioPlayerBar(
            title: "Audio briefing",
            subtitle: summary,
            url: contextURL,
            status: store.contextStatus?.status ?? item.contextStatus
          )
          AudioPlayerBar(
            title: "Read aloud",
            subtitle: nil,
            url: ttsURL,
            status: store.ttsStatus?.status ?? item.ttsStatus,
            localSpeechContent: LocalSpeechContent(source: item.displayHTML, isHTML: true)
          )
        }
        if let summary, !summary.isEmpty {
          Section("About this review") { Text(summary).font(.body) }
        }
      }
      .scrollContentBackground(.hidden)
      .background(TurfTheme.panel)
      .navigationTitle("Listen")
      .turfInlineNavigationTitle()
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") {} } }
    }
    .presentationDetents([.medium, .large])
    .presentationBackground(TurfTheme.panel)
  }

  // MARK: Capture

  private func descendants(_ view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }

  private func capture<V: View>(
    _ name: String,
    dark: Bool,
    expectsWeb: Bool,
    largeType: Bool = false,
    readerScroll: ReaderScroll = .top,
    @ViewBuilder _ content: () -> V
  ) async {
    do {
      try await performCapture(
        name,
        dark: dark,
        expectsWeb: expectsWeb,
        largeType: largeType,
        readerScroll: readerScroll,
        view: content()
      )
    } catch {
      failures.append("\(name): \(error)")
    }
  }

  private func performCapture<V: View>(
    _ name: String,
    dark: Bool,
    expectsWeb: Bool,
    largeType: Bool,
    readerScroll: ReaderScroll,
    view: V
  ) async throws {
    Self.clearReadingPositions()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = scene.screen.bounds
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    // Pin text size on the window so sheets and popovers match, whatever the simulator's setting.
    window.traitOverrides.preferredContentSizeCategory = largeType ? .accessibilityExtraLarge : .large
    window.traitOverrides.userInterfaceStyle = dark ? .dark : .light
    let root = view
      .tint(TurfTheme.accent)
      .preferredColorScheme(dark ? .dark : .light)
      .dynamicTypeSize(largeType ? .accessibility3 : .large)
    let controller = UIHostingController(rootView: root)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.layoutIfNeeded()
    defer {
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
    }
    // Let navigation, sheets and popovers finish presenting.
    try await Task.sleep(for: .milliseconds(1600))

    let webViews = descendants(window).compactMap { $0 as? WKWebView }
    if expectsWeb && webViews.isEmpty {
      failures.append("\(name): expected a reader web view but found none")
    }
    var overlays: [UIView] = []
    for webView in webViews {
      for _ in 0..<100 {
        let length = (try? await webView.evaluateJavaScript("document.body.innerText.length") as? Int) ?? 0
        if !webView.isLoading, length > 20 { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      // Give the annotation and review-target scripts time to apply and settle.
      try await Task.sleep(for: .milliseconds(700))
      // Reading position is restored per document, so pin the scroll explicitly.
      _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(readerScroll.scrollYExpression)); 0")
      try await Task.sleep(for: .milliseconds(400))
      let textCount = try await webView.evaluateJavaScript("document.body.innerText.length") as? Int ?? 0
      XCTAssertGreaterThan(textCount, 20, "\(name): reader must render its document")
      let snapshot = try await webView.takeSnapshot(configuration: nil)
      // drawHierarchy does not render WebKit content, so lay the snapshot over the web view.
      // This keeps z-order correct when a sheet or popover covers the reader.
      let overlay = UIImageView(image: snapshot)
      overlay.frame = webView.bounds
      webView.addSubview(overlay)
      overlays.append(overlay)
    }

    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    overlays.forEach { $0.removeFromSuperview() }
    let data = try XCTUnwrap(image.pngData())
    try data.write(to: directory.appendingPathComponent(name + ".png"))
  }

  enum ReaderScroll {
    case top, checklist, end

    var scrollYExpression: String {
      switch self {
      case .top: return "0"
      case .checklist:
        return "(function(){ var h = document.querySelector('h2'); return h ? h.getBoundingClientRect().top + window.scrollY - 12 : 0; })()"
      case .end: return "document.documentElement.scrollHeight"
      }
    }
  }

  // MARK: Fixture state

  private static func clearReadingPositions() {
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("turf.review.reading-position.") {
      defaults.removeObject(forKey: key)
    }
  }

  private static let settingsConfiguration = APIConfiguration(
    serverURL: URL(string: "https://review.turfterrace.com")!,
    username: "reviewer",
    password: "not-a-real-password",
    useDemoOnFailure: false
  )

  private static func makeStore(selecting: Bool) -> ReviewStore {
    let store = ReviewStore(configuration: .defaults)
    store.items = DemoData.items + extraItems
    guard selecting else { return store }

    var item = DemoData.items[0]
    item.renderedHTML = readerHTML
    item.contentLength = 3200
    item.actionStatus = "failed"
    item.actionMessage = "The send request timed out before the mail provider confirmed it."
    store.selectedItem = item
    store.selectedSlug = item.slug
    store.annotations = [
      ReviewAnnotation(
        id: 1,
        slug: item.slug,
        quote: "the follow-up timing still matches the current campaign window",
        anchorType: "text",
        anchorRef: nil,
        comment: "Check this against the live calendar before approving.",
        createdAt: "2026-06-11 09:20:00"
      ),
      ReviewAnnotation(
        id: 2,
        slug: item.slug,
        quote: nil,
        anchorType: "general",
        anchorRef: nil,
        comment: "Overall this reads well. Keep the subject line short on mobile.",
        createdAt: "2026-06-11 09:24:00"
      ),
    ]
    store.reviewTargets = [
      ReviewTarget(
        databaseID: 1,
        key: "task:approval-checklist:001:kitchenlux-copy",
        label: "Approve outbound copy",
        sourceType: "task_list",
        ordinal: 1
      ),
      ReviewTarget(
        databaseID: 2,
        key: "task:approval-checklist:002:kitchenlux-timing",
        label: "Approve Friday send timing",
        sourceType: "task_list",
        ordinal: 2,
        verdict: "approved"
      ),
      ReviewTarget(
        databaseID: 3,
        key: "task:approval-checklist:003:kitchenlux-segment",
        label: "Confirm the chef-owner segment",
        sourceType: "task_list",
        ordinal: 3,
        verdict: "rejected",
        feedback: "Exclude accounts that bought in the last 90 days."
      ),
      ReviewTarget(
        databaseID: 4,
        key: "choice:followup-cadence:004",
        label: "Choose the follow-up cadence",
        sourceType: "choice",
        ordinal: 4,
        decisionKind: "choice",
        options: [
          ReviewTargetOption(value: "3d", label: "3 days", description: nil),
          ReviewTargetOption(value: "7d", label: "1 week", description: nil),
        ]
      ),
    ]
    store.reviewTargetSummary = ReviewTargetSummary(
      total: 4, approved: 1, rejected: 1, undecided: 2, decided: 2, complete: false
    )
    store.chatMessages = [
      ChatMessage(role: "user", content: "What is the riskiest part of this send?", createdAt: "2026-06-11 09:30:00"),
      ChatMessage(
        role: "assistant",
        content: "The timing. Friday morning overlaps the campaign window closing, so confirm the calendar before you approve.",
        createdAt: "2026-06-11 09:30:05"
      ),
    ]
    store.decisionRequests = DemoData.requests + [
      DecisionRequest(
        id: 43,
        slug: item.slug,
        kind: "send_email",
        summary: "Send the KitchenLux outbound batch.",
        sensitivity: "external",
        status: "failed",
        proofJSON: nil,
        confirmationSlug: nil,
        lastError: "Mail provider timed out after 30 seconds.",
        updatedAt: "2026-06-11 09:40:00"
      ),
    ]
    store.legacyActions = [
      LegacyAction(id: 7, slug: item.slug, decision: "Send", status: "running", lastError: nil),
    ]
    store.decisionFollowups = [
      DecisionResponse.FollowupSummary(
        slug: "kitchenlux-followup-copy",
        title: "KitchenLux follow-up copy",
        url: "/review/kitchenlux-followup-copy"
      ),
    ]
    store.contextStatus = AudioStatusResponse(
      status: "ready",
      url: "/audio/kitchenlux-send-plan/context.mp3",
      summary: item.contextSummary
    )
    store.ttsStatus = AudioStatusResponse(status: "ready", url: "/audio/kitchenlux-send-plan/tts.mp3", summary: nil)
    return store
  }

  private static let extraItems: [ReviewItem] = [
    extraItem(
      id: 4, slug: "q3-pricing-memo", title: "Q3 pricing memo for the wholesale tier",
      category: "strategy", created: "2026-06-10 18:05:00", length: 8400
    ),
    extraItem(
      id: 5, slug: "plume-release-notes", title: "Plume 2.4 release notes draft",
      category: "general", created: "2026-06-10 11:40:00", length: 3100
    ),
    extraItem(
      id: 6, slug: "vendor-contract-renewal", title: "Vendor contract renewal: freight and returns",
      category: "admin", created: "2026-06-09 15:20:00", length: 12600
    ),
  ]

  private static func extraItem(
    id: Int, slug: String, title: String, category: String, created: String, length: Int
  ) -> ReviewItem {
    ReviewItem(
      databaseID: id,
      slug: slug,
      title: title,
      category: category,
      status: "pending",
      decision: nil,
      actions: ReviewActionList(["Noted", "Execute", "Inbox", "Rework", "Kill"]),
      feedback: nil,
      renderedHTML: "<p>\(title).</p>",
      markdown: nil,
      contentLength: length,
      actionStatus: nil,
      actionMessage: nil,
      approvalStatus: nil,
      approvalMessage: nil,
      ttsStatus: "skipped",
      contextStatus: "ready",
      contextSummary: "A short summary of \(title.lowercased()).",
      decisionSchemaVersion: 3,
      createdAt: created,
      updatedAt: created
    )
  }

  static let readerHTML = """
  <h1>KitchenLux outbound send plan</h1>
  <p>Approve the outbound email copy, visible recipients, and target send date. The plan is ready, but the send should only proceed if the follow-up timing still matches the current campaign window. See the <a href="https://review.turfterrace.com/help/campaigns">campaign calendar</a> for the dates.</p>
  <h2>Approval checklist</h2>
  <ul>
    <li>Approve outbound copy</li>
    <li>Approve Friday send timing</li>
    <li>Confirm the chef-owner segment</li>
    <li>Choose the follow-up cadence</li>
  </ul>
  <h2>Send plan</h2>
  <table>
    <thead><tr><th>Field</th><th>Value</th></tr></thead>
    <tbody>
      <tr><td>To</td><td>Warm KitchenLux leads in the chef-owner segment</td></tr>
      <tr><td>Subject</td><td>A cleaner way to stock premium home kitchens</td></tr>
      <tr><td>Target send date</td><td>Friday morning</td></tr>
    </tbody>
  </table>
  <h3>Copy</h3>
  <p>Hi <code>{{first_name}}</code>, I noticed your team is expanding the private dining side of the business. KitchenLux can package the premium cookware set, delivery, and replenishment workflow so the kitchen team has less admin before each event.</p>
  <blockquote>Recommended decision: Send, with a short note if the Friday timing should move.</blockquote>
  <h3>Open questions</h3>
  <ol>
    <li>Should the follow-up mention the spring menu launch?</li>
    <li>Do we hold the send if fewer than 40 leads remain after exclusions?</li>
  </ol>
  <p>Longer documents stay readable, without oversized headings or crowded controls. The decision dock below stays in reach while you read.</p>
  """
}
#endif
