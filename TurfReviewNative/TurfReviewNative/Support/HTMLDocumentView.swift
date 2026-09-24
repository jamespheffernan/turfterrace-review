import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import WebKit

struct WebSelection: Equatable {
  var text: String = ""
  var anchorRef: String?

  var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

struct HTMLDocumentLoadState: Equatable {
  let html: String
  let baseURL: URL?
  let remoteURL: URL?
  let requestHeaders: [String: String]
  let documentID: String?
  let contentVersion: String?

  init(
    html: String,
    baseURL: URL?,
    remoteURL: URL? = nil,
    requestHeaders: [String: String] = [:],
    documentID: String? = nil,
    contentVersion: String? = nil
  ) {
    self.html = html
    self.baseURL = baseURL
    self.remoteURL = remoteURL
    self.requestHeaders = requestHeaders
    self.documentID = documentID
    self.contentVersion = contentVersion
  }

  func needsReload(
    html: String,
    baseURL: URL?,
    remoteURL: URL? = nil,
    requestHeaders: [String: String] = [:],
    documentID: String? = nil,
    contentVersion: String? = nil
  ) -> Bool {
    self != HTMLDocumentLoadState(
      html: html,
      baseURL: baseURL,
      remoteURL: remoteURL,
      requestHeaders: requestHeaders,
      documentID: documentID,
      contentVersion: contentVersion
    )
  }
}

enum HTMLDocumentNavigationDecision: Equatable {
  case allow
  case cancel
  case openExternally(URL)
}

struct HTMLDocumentNavigationPolicy {
  static func decision(for navigationType: WKNavigationType, url: URL?) -> HTMLDocumentNavigationDecision {
    guard navigationType == .linkActivated else {
      return .allow
    }

    guard let url,
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else {
      return .cancel
    }

    return .openExternally(url)
  }
}

#if os(iOS)
private typealias HTMLDocumentRepresentable = UIViewRepresentable
#else
private typealias HTMLDocumentRepresentable = NSViewRepresentable
#endif

struct HTMLDocumentView: HTMLDocumentRepresentable {
  static let textSelectionBackgroundCSS = "var(--turf-selection)"
  static let savedAnnotationBackgroundCSS = "var(--turf-highlight)"

  let html: String
  let baseURL: URL?
  let remoteURL: URL?
  let requestHeaders: [String: String]
  let documentID: String?
  let contentVersion: String?
  let annotations: [ReviewAnnotation]
  let reviewTargets: [ReviewTarget]
  /// Bumped by the reader when a note save starts. Only annotations that appear while a bump is
  /// unconsumed get the one-time `.is-new` settle, so marks never animate on load or on a reload.
  let newAnnotationToken: Int
  /// The token of a save that failed. When it equals `newAnnotationToken`, no save is outstanding.
  let cancelledAnnotationToken: Int
  let onPencilSelection: (WebSelection) -> Void
  let onReviewTargetDecision: (String, String) -> Void
  @Binding var selection: WebSelection

  init(
    html: String,
    baseURL: URL?,
    remoteURL: URL? = nil,
    requestHeaders: [String: String] = [:],
    documentID: String? = nil,
    contentVersion: String? = nil,
    annotations: [ReviewAnnotation] = [],
    reviewTargets: [ReviewTarget] = [],
    newAnnotationToken: Int = 0,
    cancelledAnnotationToken: Int = 0,
    selection: Binding<WebSelection>,
    onPencilSelection: @escaping (WebSelection) -> Void = { _ in },
    onReviewTargetDecision: @escaping (String, String) -> Void = { _, _ in }
  ) {
    self.html = html
    self.baseURL = baseURL
    self.remoteURL = remoteURL
    self.requestHeaders = requestHeaders
    self.documentID = documentID
    self.contentVersion = contentVersion
    self.annotations = annotations
    self.reviewTargets = reviewTargets
    self.newAnnotationToken = newAnnotationToken
    self.cancelledAnnotationToken = cancelledAnnotationToken
    _selection = selection
    self.onPencilSelection = onPencilSelection
    self.onReviewTargetDecision = onReviewTargetDecision
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      selection: $selection,
      documentID: documentID,
      contentVersion: contentVersion,
      onPencilSelection: onPencilSelection,
      onReviewTargetDecision: onReviewTargetDecision
    )
  }

  #if os(iOS)
  func makeUIView(context: Context) -> WKWebView {
    makeWebView(context: context)
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    updateWebView(webView, context: context)
  }

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    dismantle(uiView, coordinator: coordinator)
  }
  #else
  func makeNSView(context: Context) -> WKWebView {
    makeWebView(context: context)
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    updateWebView(webView, context: context)
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    dismantle(nsView, coordinator: coordinator)
  }
  #endif

  private func makeWebView(context: Context) -> WKWebView {
    let userContent = WKUserContentController()
    userContent.add(context.coordinator, name: "selection")
    userContent.add(context.coordinator, name: "reviewTarget")
    userContent.add(context.coordinator, name: "readingPosition")

    userContent.addUserScript(WKUserScript(
      source: Self.selectionScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    ))
    userContent.addUserScript(WKUserScript(
      source: Self.readingPositionScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    ))

    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContent

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    #if os(iOS)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
    // Overscroll and native selection handles match the page and the tint.
    webView.underPageBackgroundColor = TurfPalette.paper
    webView.tintColor = TurfPalette.accent
    context.coordinator.installPencilSelectionGesture(on: webView)
    #else
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = TurfPalette.paper
    webView.allowsMagnification = true
    webView.magnification = 1
    #endif
    let readerSize = Self.readerSize(for: context)
    context.coordinator.readerSize = readerSize
    context.coordinator.documentReaderSize = readerSize
    context.coordinator.beginAnnotationSettleTracking(token: newAnnotationToken)
    loadDocument(in: webView, readerSize: readerSize)
    context.coordinator.currentLoadState = HTMLDocumentLoadState(
      html: html,
      baseURL: baseURL,
      remoteURL: remoteURL,
      requestHeaders: requestHeaders,
      documentID: documentID,
      contentVersion: contentVersion
    )
    context.coordinator.updateAnnotations(annotations, in: webView)
    if remoteURL == nil {
      context.coordinator.updateReviewTargets(reviewTargets, in: webView)
    }
    return webView
  }

  private func updateWebView(_ webView: WKWebView, context: Context) {
    context.coordinator.onPencilSelection = onPencilSelection
    context.coordinator.onReviewTargetDecision = onReviewTargetDecision
    context.coordinator.newAnnotationToken = newAnnotationToken
    if cancelledAnnotationToken == newAnnotationToken {
      context.coordinator.cancelAnnotationSettle(token: newAnnotationToken)
    }
    let readerSize = Self.readerSize(for: context)
    context.coordinator.readerSize = readerSize
    if context.coordinator.currentLoadState?.needsReload(
      html: html,
      baseURL: baseURL,
      remoteURL: remoteURL,
      requestHeaders: requestHeaders,
      documentID: documentID,
      contentVersion: contentVersion
    ) != false {
      context.coordinator.persistCurrentReadingPosition(in: webView)
      context.coordinator.currentLoadState = HTMLDocumentLoadState(
        html: html,
        baseURL: baseURL,
        remoteURL: remoteURL,
        requestHeaders: requestHeaders,
        documentID: documentID,
        contentVersion: contentVersion
      )
      context.coordinator.noteDocumentWillReload()
      context.coordinator.documentReaderSize = readerSize
      loadDocument(in: webView, readerSize: readerSize)
    } else {
      // Dynamic Type changed: restyle in place, never reload (keeps the reading position).
      context.coordinator.applyReaderSizeIfNeeded(in: webView)
    }
    context.coordinator.updateReadingContext(documentID: documentID, contentVersion: contentVersion)
    context.coordinator.syncDocumentSelection(selection, in: webView)
    context.coordinator.updateAnnotations(annotations, in: webView)
    if remoteURL == nil {
      context.coordinator.updateReviewTargets(reviewTargets, in: webView)
    }
  }

  private static func readerSize(for context: Context) -> CGFloat {
    TurfType.readerBodySize(for: context.environment.dynamicTypeSize)
  }

  private func loadDocument(in webView: WKWebView, readerSize: CGFloat) {
    if let remoteURL {
      var request = URLRequest(url: remoteURL)
      for (header, value) in requestHeaders {
        request.setValue(value, forHTTPHeaderField: header)
      }
      webView.load(request)
    } else {
      webView.loadHTMLString(Self.wrap(html, readerSize: readerSize), baseURL: baseURL)
    }
  }

  private static func dismantle(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.persistCurrentReadingPosition(in: webView)
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "selection")
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "reviewTarget")
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingPosition")
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Binding var selection: WebSelection
    var onPencilSelection: (WebSelection) -> Void
    var onReviewTargetDecision: (String, String) -> Void
    var currentLoadState: HTMLDocumentLoadState?
    private var latestAnnotations: [ReviewAnnotation] = []
    private var latestReviewTargets: [ReviewTarget] = []
    private var renderedAnnotationPayload: String?
    private var renderedReviewTargetPayload: String?
    /// Annotation IDs drawn by the last apply; nil until the first apply after a load.
    private var appliedAnnotationIDs: Set<Int>?
    /// The reader's save token, and the last value that has settled a new mark (or was cleared by a load).
    var newAnnotationToken = 0
    private var consumedAnnotationToken = 0
    /// Reader body size wanted by Dynamic Type, and the size the loaded document currently uses.
    var readerSize: CGFloat = 18
    var documentReaderSize: CGFloat = 18
    private var documentLoaded = false
    private var documentSelection = WebSelection()
    private var ignoreSelectionMessagesUntil: Date?
    private var documentID: String?
    private var contentVersion: String?
    private let readingPositionStore: DocumentReadingPositionStore

    #if os(iOS)
    private weak var pencilSelectionRecognizer: UIPanGestureRecognizer?
    private var pencilStartPoint: CGPoint?
    private var lastPreviewSelectionTime: CFTimeInterval = 0
    #endif

    init(
      selection: Binding<WebSelection>,
      documentID: String?,
      contentVersion: String?,
      readingPositionStore: DocumentReadingPositionStore = .shared,
      onPencilSelection: @escaping (WebSelection) -> Void,
      onReviewTargetDecision: @escaping (String, String) -> Void
    ) {
      _selection = selection
      self.documentID = documentID
      self.contentVersion = contentVersion
      self.readingPositionStore = readingPositionStore
      self.onPencilSelection = onPencilSelection
      self.onReviewTargetDecision = onReviewTargetDecision
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let payload = message.body as? [String: Any] else { return }
      switch message.name {
      case "selection":
        if let ignoreSelectionMessagesUntil, Date() < ignoreSelectionMessagesUntil {
          return
        }
        let text = payload["text"] as? String ?? ""
        let offset = payload["offset"] as? Int
        let incomingSelection = WebSelection(text: text, anchorRef: offset.map { "char:\($0)" })
        documentSelection = incomingSelection
        selection = incomingSelection
      case "reviewTarget":
        guard let key = payload["key"] as? String,
              let verdict = payload["verdict"] as? String else { return }
        onReviewTargetDecision(key, verdict)
      case "readingPosition":
        guard let progress = Self.doubleValue(payload["progress"]) else { return }
        saveReadingPosition(progress)
      default:
        return
      }
    }

    #if os(iOS)
    func installPencilSelectionGesture(on webView: WKWebView) {
      guard pencilSelectionRecognizer == nil else { return }
      let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePencilSelectionPan(_:)))
      recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
      recognizer.maximumNumberOfTouches = 1
      recognizer.cancelsTouchesInView = true
      recognizer.delaysTouchesBegan = false
      recognizer.delaysTouchesEnded = false
      recognizer.delegate = self
      webView.addGestureRecognizer(recognizer)
      pencilSelectionRecognizer = recognizer
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      guard let pencilSelectionRecognizer else { return true }
      return gestureRecognizer !== pencilSelectionRecognizer && otherGestureRecognizer !== pencilSelectionRecognizer
    }

    @objc private func handlePencilSelectionPan(_ recognizer: UIPanGestureRecognizer) {
      guard let webView = recognizer.view as? WKWebView else { return }
      let point = recognizer.location(in: webView)

      switch recognizer.state {
      case .began:
        pencilStartPoint = point
        lastPreviewSelectionTime = 0
      case .changed:
        guard let start = pencilStartPoint,
              start.distance(to: point) >= 10 else { return }
        let now = CACurrentMediaTime()
        guard now - lastPreviewSelectionTime > 0.08 else { return }
        lastPreviewSelectionTime = now
        evaluatePencilSelection(in: webView, from: start, to: point, commit: false)
      case .ended:
        guard let start = pencilStartPoint,
              start.distance(to: point) >= 10 else {
          pencilStartPoint = nil
          return
        }
        evaluatePencilSelection(in: webView, from: start, to: point, commit: true)
        pencilStartPoint = nil
      case .cancelled, .failed:
        pencilStartPoint = nil
      default:
        break
      }
    }

    private func evaluatePencilSelection(in webView: WKWebView, from start: CGPoint, to end: CGPoint, commit: Bool) {
      let script = HTMLDocumentView.pencilSelectionScript(from: start, to: end, commit: commit)
      webView.evaluateJavaScript(script) { [weak self] result, _ in
        guard commit,
              let self,
              let payload = result as? [String: Any] else { return }
        let text = payload["text"] as? String ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let offset = payload["offset"] as? Int
        let selection = WebSelection(text: trimmed, anchorRef: offset.map { "char:\($0)" })
        self.selection = selection
        self.onPencilSelection(selection)
      }
    }
    #endif

    func beginAnnotationSettleTracking(token: Int) {
      newAnnotationToken = token
      consumedAnnotationToken = token
      appliedAnnotationIDs = nil
    }

    /// A failed save leaves no mark to settle; consume its token so a later mark does not settle.
    func cancelAnnotationSettle(token: Int) {
      consumedAnnotationToken = token
    }

    func applyReaderSizeIfNeeded(in webView: WKWebView) {
      // Before didFinish the new document is not there yet; didFinish applies the latest size.
      guard documentLoaded, currentLoadState?.remoteURL == nil, readerSize != documentReaderSize else { return }
      documentReaderSize = readerSize
      webView.evaluateJavaScript(HTMLDocumentView.readerSizeScript(readerSize))
    }

    func noteDocumentWillReload() {
      renderedAnnotationPayload = nil
      renderedReviewTargetPayload = nil
      appliedAnnotationIDs = nil
      consumedAnnotationToken = newAnnotationToken
      documentLoaded = false
      documentSelection = WebSelection()
      ignoreSelectionMessagesUntil = nil
    }

    func updateReadingContext(documentID: String?, contentVersion: String?) {
      self.documentID = documentID
      self.contentVersion = contentVersion
    }

    func persistCurrentReadingPosition(in webView: WKWebView) {
      guard let documentID, let contentVersion else { return }
      webView.evaluateJavaScript("window.__turfCurrentReadingProgress && window.__turfCurrentReadingProgress();") { [weak self] result, _ in
        guard let self,
              let progress = Self.doubleValue(result) else { return }
        self.readingPositionStore.save(
          progress: progress,
          documentID: documentID,
          contentVersion: contentVersion
        )
      }
    }

    private func saveReadingPosition(_ progress: Double) {
      guard let documentID, let contentVersion else { return }
      readingPositionStore.save(
        progress: progress,
        documentID: documentID,
        contentVersion: contentVersion
      )
    }

    private func restoreReadingPosition(in webView: WKWebView) {
      guard let documentID,
            let contentVersion,
            let progress = readingPositionStore.progress(
              documentID: documentID,
              contentVersion: contentVersion
            ) else { return }
      let value = String(format: "%.8f", progress)
      webView.evaluateJavaScript("window.__turfRestoreReadingPosition && window.__turfRestoreReadingPosition(\(value));")
    }

    private static func doubleValue(_ value: Any?) -> Double? {
      if let value = value as? Double {
        return value
      }
      return (value as? NSNumber)?.doubleValue
    }

    func syncDocumentSelection(_ selection: WebSelection, in webView: WKWebView) {
      guard selection.isEmpty, !documentSelection.isEmpty else {
        documentSelection = selection
        return
      }
      documentSelection = selection
      clearDocumentSelection(in: webView)
    }

    func updateAnnotations(_ annotations: [ReviewAnnotation], in webView: WKWebView) {
      latestAnnotations = annotations
      applyAnnotationsIfNeeded(in: webView)
    }

    func updateReviewTargets(_ reviewTargets: [ReviewTarget], in webView: WKWebView) {
      latestReviewTargets = reviewTargets
      applyReviewTargetsIfNeeded(in: webView)
    }

    private func applyAnnotationsIfNeeded(in webView: WKWebView) {
      let payload = HTMLDocumentView.textAnnotationPayloadJSON(for: latestAnnotations)
      guard payload != renderedAnnotationPayload else { return }
      renderedAnnotationPayload = payload
      let ids = Set(latestAnnotations.map(\.id))
      var freshIDs: [Int] = []
      // Settle only marks added since the previous apply, and only while a note save is outstanding,
      // so the first apply after a load and a reload of existing notes never animate.
      if let previous = appliedAnnotationIDs, newAnnotationToken != consumedAnnotationToken {
        freshIDs = ids.subtracting(previous).sorted()
        if !freshIDs.isEmpty { consumedAnnotationToken = newAnnotationToken }
      }
      appliedAnnotationIDs = ids
      let fresh = "[" + freshIDs.map(String.init).joined(separator: ",") + "]"
      webView.evaluateJavaScript("window.__turfApplyTextAnnotations && window.__turfApplyTextAnnotations(\(payload), \(fresh));")
    }

    private func clearDocumentSelection(in webView: WKWebView) {
      ignoreSelectionMessagesUntil = Date().addingTimeInterval(0.8)
      webView.evaluateJavaScript("window.__turfClearSelection && window.__turfClearSelection();")
    }

    private func applyReviewTargetsIfNeeded(in webView: WKWebView) {
      let payload = HTMLDocumentView.reviewTargetPayloadJSON(for: latestReviewTargets)
      guard payload != renderedReviewTargetPayload else { return }
      renderedReviewTargetPayload = payload
      webView.evaluateJavaScript("window.__turfApplyReviewTargets && window.__turfApplyReviewTargets(\(payload));")
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      switch HTMLDocumentNavigationPolicy.decision(
        for: navigationAction.navigationType,
        url: navigationAction.request.url
      ) {
      case .allow:
        decisionHandler(.allow)
      case .cancel:
        decisionHandler(.cancel)
      case .openExternally(let url):
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      WebViewWarmup.finish()
      renderedAnnotationPayload = nil
      renderedReviewTargetPayload = nil
      appliedAnnotationIDs = nil
      consumedAnnotationToken = newAnnotationToken
      documentLoaded = true
      applyReaderSizeIfNeeded(in: webView)
      applyAnnotationsIfNeeded(in: webView)
      applyReviewTargetsIfNeeded(in: webView)
      restoreReadingPosition(in: webView)
    }
  }

  static let selectionScript = """
  (function() {
    function installNativeAnnotationStyles() {
      if (document.getElementById("turf-native-annotation-style")) return;
      var style = document.createElement("style");
      style.id = "turf-native-annotation-style";
      // The token block comes first so remote custom-HTML artifacts get the same --turf-* values.
      style.textContent = [
        \(javaScriptStringLiteral(TurfTheme.cssVariables)),
        "mark.turf-native-annotation-highlight { background: \(savedAnnotationBackgroundCSS) !important; color: inherit; border-radius: var(--turf-radius-mark); box-decoration-break: clone; -webkit-box-decoration-break: clone; }",
        "mark.turf-native-annotation-highlight.is-new { animation: turf-annotation-settle var(--turf-duration-settle) var(--turf-ease-out); }",
        "@keyframes turf-annotation-settle { from { background-color: var(--turf-highlight-active); } to { background-color: var(--turf-highlight); } }",
        "@media (prefers-reduced-motion: reduce) { mark.turf-native-annotation-highlight.is-new { animation: turf-annotation-settle 300ms linear; } }",
        "::selection { background: \(textSelectionBackgroundCSS); }"
      ].join("\\n");
      (document.head || document.documentElement).appendChild(style);
    }

    installNativeAnnotationStyles();

    function payloadFromRange(range) {
      var content = document.getElementById("content") || document.body;
      var text = range ? range.toString().trim() : "";
      var offset = 0;
      if (range) {
        var preRange = document.createRange();
        preRange.selectNodeContents(content);
        try {
          preRange.setEnd(range.startContainer, range.startOffset);
          offset = preRange.toString().length;
        } catch (e) {
          offset = 0;
        }
      }
      return { text: text.slice(0, 2000), offset: offset };
    }

    function selectionPayload() {
      if (Date.now() < (window.__turfIgnoreSelectionUntil || 0)) return;
      var selection = window.getSelection();
      var text = selection ? selection.toString().trim() : "";
      if (selection && selection.rangeCount > 0) {
        var payload = payloadFromRange(selection.getRangeAt(0));
        window.webkit.messageHandlers.selection.postMessage(payload);
        return;
      }
      window.webkit.messageHandlers.selection.postMessage({
        text: text.slice(0, 2000),
        offset: 0
      });
    }

    window.__turfClearSelection = function() {
      window.__turfSelectionGestureActive = false;
      window.__turfIgnoreSelectionUntil = Date.now() + 800;
      window.clearTimeout(window.__turfSelectionTimer);
      var selection = window.getSelection();
      if (selection) selection.removeAllRanges();
      window.clearTimeout(window.__turfSelectionTimer);
      return true;
    };

    function nodeInsideContent(node) {
      var content = document.getElementById("content") || document.body;
      var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
      return !!element && content.contains(element);
    }

    function rangeAtPoint(x, y) {
      if (document.caretRangeFromPoint) {
        return document.caretRangeFromPoint(x, y);
      }
      if (document.caretPositionFromPoint) {
        var position = document.caretPositionFromPoint(x, y);
        if (!position) return null;
        var range = document.createRange();
        range.setStart(position.offsetNode, position.offset);
        range.collapse(true);
        return range;
      }
      return null;
    }

    function selectionRangeFromPoints(startX, startY, endX, endY) {
      var start = rangeAtPoint(startX, startY);
      var end = rangeAtPoint(endX, endY);
      if (!start || !end || !nodeInsideContent(start.startContainer) || !nodeInsideContent(end.startContainer)) {
        return null;
      }

      var startProbe = document.createRange();
      startProbe.setStart(start.startContainer, start.startOffset);
      startProbe.collapse(true);
      var endProbe = document.createRange();
      endProbe.setStart(end.startContainer, end.startOffset);
      endProbe.collapse(true);

      var forward = startProbe.compareBoundaryPoints(Range.START_TO_START, endProbe) <= 0;
      var range = document.createRange();
      if (forward) {
        range.setStart(start.startContainer, start.startOffset);
        range.setEnd(end.startContainer, end.startOffset);
      } else {
        range.setStart(end.startContainer, end.startOffset);
        range.setEnd(start.startContainer, start.startOffset);
      }
      return range;
    }

    window.__turfSelectRangeFromPoints = function(startX, startY, endX, endY, commit) {
      var range = selectionRangeFromPoints(startX, startY, endX, endY);
      var selection = window.getSelection();
      if (!range || range.collapsed) {
        if (commit && selection) selection.removeAllRanges();
        return { text: "", offset: 0 };
      }
      if (selection) {
        selection.removeAllRanges();
        selection.addRange(range);
      }
      return payloadFromRange(range);
    };

    function removeHighlights(selector) {
      document.querySelectorAll(selector).forEach(function(mark) {
        var parent = mark.parentNode;
        if (!parent) return;
        while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
        parent.removeChild(mark);
        parent.normalize();
      });
    }

    function removeReviewTargetControls() {
      document.querySelectorAll(".turf-native-target-controls").forEach(function(control) {
        control.remove();
      });
    }

    function textNodesUnder(root) {
      var nodes = [];
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      var node;
      while ((node = walker.nextNode())) nodes.push(node);
      return nodes;
    }

    // Text nodes under content with their character offsets, built once per highlight pass
    // and patched locally after each DOM change, so a pass costs O(document) instead of
    // O(document x highlights). Offsets and text always equal content.textContent.
    function TextIndex(content) {
      this.content = content;
      this.nodes = textNodesUnder(content);
      this.starts = new Array(this.nodes.length);
      var parts = new Array(this.nodes.length);
      var cursor = 0;
      for (var i = 0; i < this.nodes.length; i++) {
        this.starts[i] = cursor;
        parts[i] = this.nodes[i].data;
        cursor += parts[i].length;
      }
      this.text = parts.join("");
    }

    // First node whose end reaches the position, as a front-to-back scan would find it.
    TextIndex.prototype.nodeIndexAt = function(position) {
      var low = 0;
      var high = this.nodes.length - 1;
      var found = -1;
      while (low <= high) {
        var mid = (low + high) >> 1;
        if (this.starts[mid] + this.nodes[mid].data.length >= position) {
          found = mid;
          high = mid - 1;
        } else {
          low = mid + 1;
        }
      }
      return found;
    };

    // Replaces the entry at index with the text nodes that now occupy its place.
    TextIndex.prototype.refreshAt = function(index, nextNode) {
      var walker = document.createTreeWalker(this.content, NodeFilter.SHOW_TEXT);
      walker.currentNode = this.nodes[index];
      var replacement = [this.nodes[index]];
      var node;
      while ((node = walker.nextNode()) && node !== nextNode) replacement.push(node);
      var starts = new Array(replacement.length);
      var cursor = this.starts[index];
      for (var i = 0; i < replacement.length; i++) {
        starts[i] = cursor;
        cursor += replacement[i].data.length;
      }
      Array.prototype.splice.apply(this.nodes, [index, 1].concat(replacement));
      Array.prototype.splice.apply(this.starts, [index, 1].concat(starts));
      return replacement.length - 1;
    };

    // Adds the text nodes of an element newly inserted under content.
    TextIndex.prototype.insertTextOf = function(element) {
      if (!element || !this.content.contains(element)) return;
      var added = textNodesUnder(element);
      if (!added.length) return;
      var first = added[0];
      var low = 0;
      var high = this.nodes.length;
      while (low < high) {
        var mid = (low + high) >> 1;
        if (first.compareDocumentPosition(this.nodes[mid]) & Node.DOCUMENT_POSITION_FOLLOWING) {
          high = mid;
        } else {
          low = mid + 1;
        }
      }
      var offset = low < this.nodes.length ? this.starts[low] : this.text.length;
      var starts = new Array(added.length);
      var parts = new Array(added.length);
      var cursor = offset;
      for (var i = 0; i < added.length; i++) {
        starts[i] = cursor;
        parts[i] = added[i].data;
        cursor += parts[i].length;
      }
      var insertedLength = cursor - offset;
      for (var j = low; j < this.starts.length; j++) this.starts[j] += insertedLength;
      Array.prototype.splice.apply(this.nodes, [low, 0].concat(added));
      Array.prototype.splice.apply(this.starts, [low, 0].concat(starts));
      this.text = this.text.slice(0, offset) + parts.join("") + this.text.slice(offset);
    };

    function rangeForText(index, quote, anchorRef) {
      quote = (quote || "").trim();
      if (!quote) return null;
      var fullText = index.text;
      var start = -1;
      var anchor = anchorRef || "";
      var charMatch = /^char:(\\d+)$/.exec(anchor);
      if (charMatch) {
        var hint = Number(charMatch[1]);
        start = fullText.indexOf(quote, hint);
        if (start < 0) start = fullText.indexOf(quote, Math.max(0, hint - 80));
      }
      if (start < 0) start = fullText.indexOf(quote);
      if (start < 0) return null;
      var end = start + quote.length;

      var startIndex = index.nodeIndexAt(start);
      var endIndex = index.nodeIndexAt(end);
      if (startIndex < 0 || endIndex < 0) return null;
      var range = document.createRange();
      range.setStart(index.nodes[startIndex], start - index.starts[startIndex]);
      range.setEnd(index.nodes[endIndex], end - index.starts[endIndex]);
      return { range: range, startIndex: startIndex, endIndex: endIndex };
    }

    function wrapRangeTextSegments(index, found, configureMark) {
      var range = found.range;
      var startContainer = range.startContainer;
      var startOffset = range.startOffset;
      var endContainer = range.endContainer;
      var endOffset = range.endOffset;
      var segments = [];

      // Only text nodes from the start container to the end container can intersect the range.
      for (var i = found.startIndex; i <= found.endIndex; i++) {
        var node = index.nodes[i];
        if (!range.intersectsNode(node)) continue;
        var segmentStart = node === startContainer ? startOffset : 0;
        var segmentEnd = node === endContainer ? endOffset : node.data.length;
        if (segmentStart >= segmentEnd) continue;
        if (!node.data.slice(segmentStart, segmentEnd).trim()) continue;
        segments.push({ node: node, index: i, start: segmentStart, end: segmentEnd });
      }

      var shift = 0;
      segments.forEach(function(segment) {
        var position = segment.index + shift;
        var nextNode = index.nodes[position + 1] || null;
        var segmentRange = document.createRange();
        segmentRange.setStart(segment.node, segment.start);
        segmentRange.setEnd(segment.node, segment.end);
        var mark = document.createElement("mark");
        configureMark(mark);
        segmentRange.surroundContents(mark);
        shift += index.refreshAt(position, nextNode);
      });
    }

    // The first text node the range actually covers. rangeForText can start a range at the end
    // of the whitespace node before an item, which belongs to the list, not the item.
    function firstCoveredNode(content, range) {
      var node = range.startContainer;
      if (node.nodeType !== Node.TEXT_NODE || range.startOffset < node.data.length) return node;
      var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
      walker.currentNode = node;
      var next = walker.nextNode();
      return next && range.intersectsNode(next) ? next : node;
    }

    function targetHostForRange(content, range) {
      if (!range) return null;
      // Start from the range's start, not its common ancestor: a label that ends at an item's
      // boundary has the whole list as its common ancestor, which stacked every control after it.
      var node = firstCoveredNode(content, range);
      var element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
      if (!element || !content.contains(element)) return null;
      var listItem = element.closest("li");
      if (listItem && content.contains(listItem)) return listItem;
      var tableCell = element.closest("td, th");
      if (tableCell && content.contains(tableCell)) return tableCell;
      var block = element.closest("p, blockquote, h1, h2, h3, h4, h5, h6");
      if (block && content.contains(block)) return block;
      return element;
    }

    function reviewTargetButton(target, verdict, label, active) {
      var button = document.createElement("button");
      button.type = "button";
      var kind = verdict.indexOf("choice:") === 0 ? "choice" : verdict;
      button.className = "turf-native-target-button turf-native-target-button-" + kind + (active ? " is-active" : "");
      button.dataset.targetKey = target.key || "";
      button.dataset.verdict = verdict;
      button.textContent = label;
      return button;
    }

    function insertReviewTargetControls(content, host, target, state) {
      if (!host || host.classList.contains("turf-native-target-controls")) return null;
      var control = document.createElement("div");
      var visualState = state.indexOf("choice:") === 0 ? "selected" : (state || "unset");
      control.className = "turf-native-target-controls turf-native-target-controls-" + visualState;
      control.dataset.targetKey = target.key || "";

      var status = document.createElement("span");
      status.className = "turf-native-target-status";
      var selectedOption = Array.isArray(target.options) ? target.options.find(function(option) {
        return state === "choice:" + option.value;
      }) : null;
      status.textContent = selectedOption ? selectedOption.label : state === "approved" ? "Approved" : state === "rejected" ? "Rejected" : "Open";
      control.appendChild(status);
      if (target.decisionKind === "choice" && Array.isArray(target.options)) {
        target.options.forEach(function(option) {
          var choiceVerdict = "choice:" + option.value;
          control.appendChild(reviewTargetButton(target, choiceVerdict, option.label, state === choiceVerdict));
        });
      } else {
        control.appendChild(reviewTargetButton(target, "approved", "Approve", state === "approved"));
        control.appendChild(reviewTargetButton(target, "rejected", "Reject", state === "rejected"));
      }
      if (state !== "unset") {
        control.appendChild(reviewTargetButton(target, "unset", "Reset", false));
      }

      if (host.matches("li, td, th")) {
        host.appendChild(control);
      } else if (host.parentNode) {
        host.parentNode.insertBefore(control, host.nextSibling);
      } else {
        content.appendChild(control);
      }
      return control;
    }

    window.__turfApplyTextAnnotations = function(annotations, freshIDs) {
      var content = document.getElementById("content") || document.body;
      removeHighlights("mark.turf-native-annotation-highlight");
      var index = new TextIndex(content);
      // Only notes added since the previous apply settle; the second argument is optional.
      var fresh = {};
      (freshIDs || []).forEach(function(id) { fresh[String(id)] = true; });
      (annotations || []).forEach(function(annotation) {
        if ((annotation.anchorType || annotation.anchor_type) !== "text") return;
        var found = rangeForText(index, annotation.quote || "", annotation.anchorRef || annotation.anchor_ref || "");
        if (!found || found.range.collapsed) return;
        wrapRangeTextSegments(index, found, function(mark) {
          mark.className = "turf-native-annotation-highlight" + (fresh[String(annotation.id)] ? " is-new" : "");
          mark.dataset.annotationId = annotation.id;
          mark.title = annotation.comment || "";
        });
      });
    };

    window.__turfApplyReviewTargets = function(targets) {
      var content = document.getElementById("content") || document.body;
      removeReviewTargetControls();
      removeHighlights("mark.turf-native-target-highlight");
      var index = new TextIndex(content);
      (targets || []).forEach(function(target) {
        var found = rangeForText(index, target.label || "", "");
        if (!found || found.range.collapsed) return;
        var state = (target.verdict || "unset").trim().toLowerCase();
        var host = targetHostForRange(content, found.range);
        var visualState = state.indexOf("choice:") === 0 ? "selected" : (state || "unset");
        wrapRangeTextSegments(index, found, function(mark) {
          mark.className = "turf-native-target-highlight turf-native-target-" + visualState;
          mark.dataset.targetKey = target.key || "";
          mark.title = state === "approved" ? "Approved" : state === "rejected" ? "Rejected" : "Open";
        });
        // Later labels are searched in text that includes these controls, as before.
        index.insertTextOf(insertReviewTargetControls(content, host, target, state));
      });
    };

    document.addEventListener("click", function(event) {
      var button = event.target.closest(".turf-native-target-button");
      if (!button) return;
      event.preventDefault();
      event.stopPropagation();
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.reviewTarget) return;
      window.webkit.messageHandlers.reviewTarget.postMessage({
        key: button.dataset.targetKey || "",
        verdict: button.dataset.verdict || ""
      });
    });

    function scheduleSettledSelectionPayload(delay) {
      window.clearTimeout(window.__turfSelectionTimer);
      window.__turfSelectionTimer = window.setTimeout(selectionPayload, delay);
    }

    function noteSelectionGestureStarted() {
      window.__turfSelectionGestureActive = true;
      window.clearTimeout(window.__turfSelectionTimer);
    }

    function noteSelectionGestureEnded() {
      window.__turfSelectionGestureActive = false;
      scheduleSettledSelectionPayload(180);
    }

    ["touchstart", "pointerdown", "mousedown"].forEach(function(eventName) {
      document.addEventListener(eventName, noteSelectionGestureStarted, true);
    });

    ["touchend", "touchcancel", "pointerup", "pointercancel", "mouseup", "keyup"].forEach(function(eventName) {
      document.addEventListener(eventName, noteSelectionGestureEnded, true);
    });

    document.addEventListener("selectionchange", function() {
      window.clearTimeout(window.__turfSelectionTimer);
      if (!window.__turfSelectionGestureActive) {
        scheduleSettledSelectionPayload(260);
      }
    });
  })();
  """

  static let readingPositionScript = """
  (function() {
    var reportTimer = null;
    var restoreTimer = null;
    var restoreCancelled = false;

    function currentProgress() {
      var root = document.scrollingElement || document.documentElement;
      var maximum = Math.max(0, root.scrollHeight - window.innerHeight);
      if (maximum <= 0) return 0;
      return Math.max(0, Math.min(1, root.scrollTop / maximum));
    }

    function reportProgress() {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.readingPosition) return;
      window.webkit.messageHandlers.readingPosition.postMessage({ progress: currentProgress() });
    }

    function scheduleProgressReport() {
      window.clearTimeout(reportTimer);
      reportTimer = window.setTimeout(reportProgress, 200);
    }

    function cancelPendingRestore() {
      restoreCancelled = true;
      window.clearTimeout(restoreTimer);
    }

    window.__turfCurrentReadingProgress = currentProgress;
    window.__turfRestoreReadingPosition = function(progress) {
      var clamped = Math.max(0, Math.min(1, Number(progress) || 0));
      restoreCancelled = false;

      function apply() {
        if (restoreCancelled) return;
        var root = document.scrollingElement || document.documentElement;
        var maximum = Math.max(0, root.scrollHeight - window.innerHeight);
        root.scrollTop = maximum * clamped;
      }

      window.requestAnimationFrame(function() {
        window.requestAnimationFrame(apply);
      });
      restoreTimer = window.setTimeout(apply, 350);
    };

    window.addEventListener("scroll", scheduleProgressReport, { passive: true });
    window.addEventListener("pagehide", reportProgress);
    ["touchstart", "pointerdown", "mousedown", "wheel", "keydown"].forEach(function(eventName) {
      window.addEventListener(eventName, cancelPendingRestore, { passive: true, capture: true });
    });
  })();
  """

  /// Sets the reader body size in place (Dynamic Type) and keeps the reader at the same point
  /// of the document. It does not reload and does not animate.
  static func readerSizeScript(_ readerSize: CGFloat) -> String {
    """
    (function() {
      var progress = window.__turfCurrentReadingProgress ? window.__turfCurrentReadingProgress() : 0;
      document.documentElement.style.setProperty("--turf-reader-size", "\(cssPixels(readerSize))");
      if (progress > 0) {
        var root = document.scrollingElement || document.documentElement;
        root.scrollTop = Math.max(0, root.scrollHeight - window.innerHeight) * progress;
      }
      return true;
    })();
    """
  }

  private static func cssPixels(_ value: CGFloat) -> String {
    "\(Int(value.rounded()))px"
  }

  /// A Swift string as a JavaScript string literal (quotes, backslashes and newlines escaped).
  private static func javaScriptStringLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
          let literal = String(data: data, encoding: .utf8) else {
      return "\"\""
    }
    return literal
  }

  private static func wrap(_ body: String, readerSize: CGFloat) -> String {
    """
    <!doctype html>
    <html style="--turf-reader-size: \(cssPixels(readerSize))">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3">
        <style>
          :root {
            color-scheme: light dark;
            --turf-reader-measure: 36em;
            --turf-reader-inline: 20px;
          }
          \(TurfTheme.cssVariables)
          @media (min-width: 600px) {
            :root { --turf-reader-inline: 32px; }
          }
          html {
            font-size: var(--turf-reader-size, 18px);
            -webkit-text-size-adjust: 100%;
            text-size-adjust: 100%;
          }
          html, body {
            margin: 0;
            padding: 0;
            min-height: 100%;
            background: var(--turf-paper);
            color: var(--turf-ink);
          }
          body {
            font-family: ui-serif, "New York", Georgia, serif;
            font-size: 1rem;
            line-height: 1.6;
          }
          #content {
            box-sizing: border-box;
            width: min(100%, calc(var(--turf-reader-measure) + 2 * var(--turf-reader-inline)));
            margin: 0 auto;
            padding: 24px var(--turf-reader-inline) 48px;
            overflow-wrap: break-word;
          }
          #content > :first-child {
            margin-top: 0;
          }
          h1, h2, h3, h4, h5, h6 {
            color: var(--turf-ink);
            font-family: ui-serif, "New York", Georgia, serif;
            text-wrap: balance;
          }
          h1 {
            font-size: min(1.75rem, calc(1rem + 4vw));
            font-weight: 700;
            letter-spacing: -0.01em;
            line-height: 1.15;
            margin: 0 0 0.5em;
          }
          h2 {
            font-size: min(1.33rem, calc(1rem + 2.5vw));
            font-weight: 600;
            letter-spacing: -0.01em;
            line-height: 1.2;
            margin: 1.8em 0 0.5em;
          }
          h3 {
            font-size: 1.125rem;
            font-weight: 600;
            line-height: 1.3;
            margin: 1.5em 0 0.4em;
          }
          h4, h5, h6 {
            font-size: 1rem;
            font-weight: 600;
            line-height: 1.4;
            margin: 1.4em 0 0.3em;
          }
          p, ul, ol, blockquote, table, pre, .table-wrap {
            margin: 0 0 1em;
          }
          p {
            text-wrap: pretty;
            hanging-punctuation: first;
          }
          ul, ol {
            padding-left: 1.25em;
          }
          li {
            margin-bottom: 0.35em;
          }
          li::marker {
            color: var(--turf-muted);
          }
          a {
            color: var(--turf-accent);
            text-decoration-color: color-mix(in srgb, var(--turf-accent) 45%, transparent);
            text-decoration-thickness: 1px;
            text-underline-offset: 0.18em;
          }
          @media (hover: hover) {
            a:hover { text-decoration-color: var(--turf-accent); }
          }
          blockquote {
            background: none;
            border-left: 2px solid var(--turf-hairline);
            border-radius: 0;
            color: var(--turf-ink);
            padding: 0 0 0 1em;
          }
          table {
            border-collapse: collapse;
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 0.875rem;
            font-variant-numeric: tabular-nums;
            min-width: 100%;
          }
          #content > table {
            display: block;
            max-width: 100%;
            overflow-x: auto;
            -webkit-overflow-scrolling: touch;
          }
          th, td {
            border-bottom: 1px solid var(--turf-hairline);
            hyphens: none;
            min-width: 9rem;
            overflow-wrap: normal;
            padding: 0.6rem 0.75rem;
            vertical-align: top;
            word-break: normal;
          }
          th:first-child, td:first-child {
            min-width: 2.5rem;
          }
          th {
            color: var(--turf-muted);
            font-size: 0.75rem;
            font-weight: 600;
            letter-spacing: 0.06em;
            text-align: left;
            text-transform: uppercase;
          }
          .table-wrap {
            max-width: 100%;
            overflow-x: auto;
            -webkit-overflow-scrolling: touch;
          }
          .table-wrap table {
            margin-bottom: 0;
          }
          img {
            border-radius: var(--turf-radius-field);
            display: block;
            height: auto;
            margin: 1.5rem 0;
            max-width: 100%;
          }
          pre, code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
          }
          code {
            background: var(--turf-fill);
            border-radius: var(--turf-radius-mark);
            color: var(--turf-ink);
            font-size: 0.85em;
            padding: 0.1em 0.35em;
          }
          pre {
            background: var(--turf-fill);
            border-radius: var(--turf-radius-field);
            color: var(--turf-ink);
            font-size: 0.85rem;
            line-height: 1.55;
            overflow-x: auto;
            padding: 1em 1.25em;
            white-space: pre-wrap;
          }
          pre code {
            background: transparent;
            color: inherit;
            font-size: inherit;
            padding: 0;
          }
          mark {
            background: var(--turf-fill);
            color: inherit;
          }
          mark.turf-native-annotation-highlight {
            background: \(Self.savedAnnotationBackgroundCSS);
            border-radius: var(--turf-radius-mark);
            box-decoration-break: clone;
            -webkit-box-decoration-break: clone;
          }
          mark.turf-native-target-highlight {
            background: none;
            border-radius: var(--turf-radius-mark);
            box-decoration-break: clone;
            -webkit-box-decoration-break: clone;
            color: inherit;
            text-decoration-color: var(--turf-attention);
            text-decoration-line: underline;
            text-decoration-skip-ink: auto;
            text-decoration-thickness: 2px;
            text-underline-offset: 0.28em;
          }
          mark.turf-native-target-approved,
          mark.turf-native-target-selected {
            background: var(--turf-accent-soft);
            text-decoration-color: var(--turf-accent);
          }
          mark.turf-native-target-rejected {
            background: var(--turf-destructive-soft);
            text-decoration-color: var(--turf-destructive);
          }
          .turf-native-target-controls {
            align-items: center;
            background: none;
            border: 0;
            display: flex;
            flex-wrap: wrap;
            font: 600 0.875rem/1.2 -apple-system, system-ui, sans-serif;
            gap: 8px;
            margin: 0.5rem 0 0.9rem;
            padding: 0;
          }
          .turf-native-target-status {
            align-items: center;
            color: var(--turf-attention);
            display: inline-flex;
            font-size: 0.8125rem;
            font-weight: 600;
          }
          .turf-native-target-status::before {
            border: 1px solid currentColor;
            border-radius: 50%;
            box-sizing: border-box;
            content: "";
            height: 8px;
            margin-right: 4px;
            width: 8px;
          }
          .turf-native-target-controls-approved .turf-native-target-status,
          .turf-native-target-controls-selected .turf-native-target-status {
            color: var(--turf-accent);
          }
          .turf-native-target-controls-rejected .turf-native-target-status {
            color: var(--turf-destructive);
          }
          .turf-native-target-controls-approved .turf-native-target-status::before,
          .turf-native-target-controls-selected .turf-native-target-status::before,
          .turf-native-target-controls-rejected .turf-native-target-status::before {
            background: currentColor;
          }
          .turf-native-target-button {
            -webkit-appearance: none;
            appearance: none;
            background: var(--turf-fill);
            border: 0;
            border-radius: 999px;
            color: var(--turf-ink);
            cursor: pointer;
            font: inherit;
            min-height: 44px;
            padding: 0 16px;
          }
          .turf-native-target-controls-approved .turf-native-target-button.is-active,
          .turf-native-target-controls-selected .turf-native-target-button.is-active {
            background: var(--turf-accent-soft);
            color: var(--turf-accent);
          }
          .turf-native-target-controls-rejected .turf-native-target-button.is-active {
            background: var(--turf-destructive-soft);
            color: var(--turf-destructive);
          }
          .turf-native-target-button-unset {
            background: transparent;
            color: var(--turf-muted);
            font-weight: 500;
            min-width: 44px;
            padding-inline: 0;
          }
          .turf-native-target-button:active {
            opacity: 0.7;
          }
          @media (hover: hover) {
            .turf-native-target-button:hover { filter: brightness(0.97); }
          }
          :focus-visible {
            border-radius: 4px;
            outline: 2px solid var(--turf-accent);
            outline-offset: 2px;
          }
          ::selection {
            background: \(Self.textSelectionBackgroundCSS);
          }
        </style>
      </head>
      <body>
        <main id="content">
          \(body)
        </main>
      </body>
    </html>
    """
  }

  static func pencilSelectionScript(from start: CGPoint, to end: CGPoint, commit: Bool) -> String {
    let startX = jsNumber(start.x)
    let startY = jsNumber(start.y)
    let endX = jsNumber(end.x)
    let endY = jsNumber(end.y)
    return "window.__turfSelectRangeFromPoints && window.__turfSelectRangeFromPoints(\(startX), \(startY), \(endX), \(endY), \(commit ? "true" : "false"));"
  }

  private static func jsNumber(_ value: CGFloat) -> String {
    String(format: "%.2f", Double(value))
  }

  private static func textAnnotationPayloadJSON(for annotations: [ReviewAnnotation]) -> String {
    let payload = annotations.compactMap { annotation -> [String: Any]? in
      guard annotation.anchorType == "text",
            let quote = annotation.quote?.trimmingCharacters(in: .whitespacesAndNewlines),
            !quote.isEmpty else { return nil }
      return [
        "id": annotation.id,
        "quote": quote,
        "anchorType": annotation.anchorType,
        "anchorRef": annotation.anchorRef ?? "",
        "comment": annotation.comment,
      ]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return json
  }

  private static func reviewTargetPayloadJSON(for targets: [ReviewTarget]) -> String {
    let payload = targets.compactMap { target -> [String: Any]? in
      let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !label.isEmpty else { return nil }
      var item: [String: Any] = [
        "key": target.key,
        "label": label,
        "verdict": target.normalizedVerdict,
      ]
      item["decisionKind"] = target.decisionKind ?? "approval"
      item["options"] = (target.options ?? []).map { option in
        ["value": option.value, "label": option.label]
      }
      return item
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return json
  }
}

/// Starts WebKit's helper processes at launch so opening the first review does not pay for it.
/// The warm view is released once a reader has finished its first load. Main thread only.
enum WebViewWarmup {
  private static var webView: WKWebView?

  static func start() {
    guard webView == nil else { return }
    let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    view.loadHTMLString("", baseURL: nil)
    webView = view
  }

  static func finish() {
    webView = nil
  }
}

struct DocumentReadingPosition: Codable, Equatable {
  let progress: Double
  let contentVersion: String
}

final class DocumentReadingPositionStore {
  static let shared = DocumentReadingPositionStore()

  private let defaults: UserDefaults
  private let keyPrefix: String

  init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "turf.review.reading-position.v1."
  ) {
    self.defaults = defaults
    self.keyPrefix = keyPrefix
  }

  func save(progress: Double, documentID: String, contentVersion: String) {
    guard !documentID.isEmpty, !contentVersion.isEmpty else { return }
    let position = DocumentReadingPosition(
      progress: min(max(progress, 0), 1),
      contentVersion: contentVersion
    )
    guard let data = try? JSONEncoder().encode(position) else { return }
    defaults.set(data, forKey: key(for: documentID))
  }

  func progress(documentID: String, contentVersion: String) -> Double? {
    guard let data = defaults.data(forKey: key(for: documentID)),
          let position = try? JSONDecoder().decode(DocumentReadingPosition.self, from: data),
          position.contentVersion == contentVersion else { return nil }
    return min(max(position.progress, 0), 1)
  }

  private func key(for documentID: String) -> String {
    let encodedID = Data(documentID.utf8).base64EncodedString()
    return keyPrefix + encodedID
  }
}

enum DocumentContentVersion {
  static func make(_ content: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in content.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}

#if os(iOS)
extension HTMLDocumentView.Coordinator: UIGestureRecognizerDelegate {}
#endif

private extension CGPoint {
  func distance(to other: CGPoint) -> CGFloat {
    hypot(x - other.x, y - other.y)
  }
}
