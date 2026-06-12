import Foundation
import SwiftUI
import UIKit
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

  func needsReload(html: String, baseURL: URL?) -> Bool {
    self != HTMLDocumentLoadState(html: html, baseURL: baseURL)
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

struct HTMLDocumentView: UIViewRepresentable {
  let html: String
  let baseURL: URL?
  let annotations: [ReviewAnnotation]
  let onPencilSelection: (WebSelection) -> Void
  @Binding var selection: WebSelection

  init(
    html: String,
    baseURL: URL?,
    annotations: [ReviewAnnotation] = [],
    selection: Binding<WebSelection>,
    onPencilSelection: @escaping (WebSelection) -> Void = { _ in }
  ) {
    self.html = html
    self.baseURL = baseURL
    self.annotations = annotations
    _selection = selection
    self.onPencilSelection = onPencilSelection
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection, onPencilSelection: onPencilSelection)
  }

  func makeUIView(context: Context) -> WKWebView {
    let userContent = WKUserContentController()
    userContent.add(context.coordinator, name: "selection")

    let script = WKUserScript(
      source: Self.selectionScript,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    userContent.addUserScript(script)

    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContent

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
    context.coordinator.installPencilSelectionGesture(on: webView)
    webView.loadHTMLString(Self.wrap(html), baseURL: baseURL)
    context.coordinator.currentLoadState = HTMLDocumentLoadState(html: html, baseURL: baseURL)
    context.coordinator.updateAnnotations(annotations, in: webView)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    context.coordinator.onPencilSelection = onPencilSelection
    if context.coordinator.currentLoadState?.needsReload(html: html, baseURL: baseURL) != false {
      context.coordinator.currentLoadState = HTMLDocumentLoadState(html: html, baseURL: baseURL)
      context.coordinator.noteDocumentWillReload()
      webView.loadHTMLString(Self.wrap(html), baseURL: baseURL)
    }
    context.coordinator.updateAnnotations(annotations, in: webView)
  }

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    uiView.configuration.userContentController.removeScriptMessageHandler(forName: "selection")
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {
    @Binding var selection: WebSelection
    var onPencilSelection: (WebSelection) -> Void
    var currentLoadState: HTMLDocumentLoadState?
    private weak var pencilSelectionRecognizer: UIPanGestureRecognizer?
    private var pencilStartPoint: CGPoint?
    private var latestAnnotations: [ReviewAnnotation] = []
    private var renderedAnnotationPayload: String?
    private var lastPreviewSelectionTime: CFTimeInterval = 0

    init(selection: Binding<WebSelection>, onPencilSelection: @escaping (WebSelection) -> Void) {
      _selection = selection
      self.onPencilSelection = onPencilSelection
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name == "selection",
            let payload = message.body as? [String: Any] else { return }
      let text = payload["text"] as? String ?? ""
      let offset = payload["offset"] as? Int
      selection = WebSelection(text: text, anchorRef: offset.map { "char:\($0)" })
    }

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

    func noteDocumentWillReload() {
      renderedAnnotationPayload = nil
    }

    func updateAnnotations(_ annotations: [ReviewAnnotation], in webView: WKWebView) {
      latestAnnotations = annotations
      applyAnnotationsIfNeeded(in: webView)
    }

    private func applyAnnotationsIfNeeded(in webView: WKWebView) {
      let payload = HTMLDocumentView.textAnnotationPayloadJSON(for: latestAnnotations)
      guard payload != renderedAnnotationPayload else { return }
      renderedAnnotationPayload = payload
      webView.evaluateJavaScript("window.__turfApplyTextAnnotations && window.__turfApplyTextAnnotations(\(payload));")
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
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      renderedAnnotationPayload = nil
      applyAnnotationsIfNeeded(in: webView)
    }
  }

  private static let selectionScript = """
  (function() {
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

    function removeNativeHighlights() {
      document.querySelectorAll("mark.turf-native-annotation-highlight").forEach(function(mark) {
        var parent = mark.parentNode;
        if (!parent) return;
        while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
        parent.removeChild(mark);
        parent.normalize();
      });
    }

    function textNodesUnder(root) {
      var nodes = [];
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      var node;
      while ((node = walker.nextNode())) nodes.push(node);
      return nodes;
    }

    function rangeForTextAnnotation(content, annotation) {
      var quote = (annotation.quote || "").trim();
      if (!quote) return null;
      var fullText = content.textContent || "";
      var start = -1;
      var anchor = annotation.anchorRef || annotation.anchor_ref || "";
      var charMatch = /^char:(\\d+)$/.exec(anchor);
      if (charMatch) {
        var hint = Number(charMatch[1]);
        start = fullText.indexOf(quote, hint);
        if (start < 0) start = fullText.indexOf(quote, Math.max(0, hint - 80));
      }
      if (start < 0) start = fullText.indexOf(quote);
      if (start < 0) return null;
      var end = start + quote.length;

      var nodes = textNodesUnder(content);
      var cursor = 0;
      var startNode = null;
      var startOffset = 0;
      var endNode = null;
      var endOffset = 0;
      nodes.forEach(function(node) {
        var next = cursor + node.textContent.length;
        if (!startNode && start >= cursor && start <= next) {
          startNode = node;
          startOffset = start - cursor;
        }
        if (!endNode && end >= cursor && end <= next) {
          endNode = node;
          endOffset = end - cursor;
        }
        cursor = next;
      });
      if (!startNode || !endNode) return null;
      var range = document.createRange();
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
      return range;
    }

    window.__turfApplyTextAnnotations = function(annotations) {
      var content = document.getElementById("content") || document.body;
      removeNativeHighlights();
      (annotations || []).forEach(function(annotation) {
        if ((annotation.anchorType || annotation.anchor_type) !== "text") return;
        var range = rangeForTextAnnotation(content, annotation);
        if (!range || range.collapsed) return;
        var mark = document.createElement("mark");
        mark.className = "turf-native-annotation-highlight";
        mark.dataset.annotationId = annotation.id;
        mark.title = annotation.comment || "";
        try {
          range.surroundContents(mark);
        } catch (e) {
          mark.appendChild(range.extractContents());
          range.insertNode(mark);
        }
      });
    };

    document.addEventListener("selectionchange", function() {
      window.clearTimeout(window.__turfSelectionTimer);
      window.__turfSelectionTimer = window.setTimeout(selectionPayload, 90);
    });
  })();
  """

  private static func wrap(_ body: String) -> String {
    """
    <!doctype html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=3">
        <style>
          :root {
            color-scheme: light;
            --paper: #f7f2e8;
            --paper-soft: #fffdf7;
            --ink: #211f1b;
            --muted: #6f6a61;
            --accent: #007c89;
            --terracotta: #c06030;
            --terracotta-soft: rgba(192, 96, 48, 0.08);
            --hairline: #ddd1bf;
            --inset: #ece4d8;
          }
          html, body {
            margin: 0;
            padding: 0;
            min-height: 100%;
            background: var(--paper);
            color: var(--ink);
            font-family: ui-serif, Georgia, "Times New Roman", serif;
            font-size: 18px;
            line-height: 1.78;
          }
          body {
            -webkit-text-size-adjust: 100%;
          }
          #content {
            box-sizing: border-box;
            width: min(100%, 900px);
            margin: 0 auto;
            padding: 34px clamp(28px, 6vw, 76px) 80px;
            overflow-wrap: anywhere;
          }
          #content > :first-child {
            margin-top: 0;
          }
          h1, h2, h3, h4, h5, h6 {
            font-family: ui-serif, Georgia, "Times New Roman", serif;
            letter-spacing: 0;
            line-height: 1.2;
            color: var(--ink);
          }
          h1 {
            font-size: clamp(2.25rem, 4.6vw, 3.65rem);
            font-weight: 700;
            margin: 0 0 0.7em;
          }
          h2 {
            color: var(--terracotta);
            font-size: clamp(1.45rem, 2.4vw, 2rem);
            font-weight: 700;
            margin: 2em 0 0.5em;
          }
          h3 {
            font-size: 1.18rem;
            font-weight: 700;
            margin: 1.75em 0 0.45em;
          }
          p, ul, ol, blockquote, table, pre {
            margin-top: 0;
            margin-bottom: 1.28em;
          }
          p, li, blockquote {
            font-size: 1.06rem;
          }
          li {
            margin-bottom: 0.42em;
          }
          ul, ol {
            padding-left: 1.35em;
          }
          a {
            color: var(--terracotta);
            text-decoration-color: rgba(192, 96, 48, 0.34);
            text-underline-offset: 3px;
          }
          blockquote {
            border-left: 3px solid var(--terracotta);
            padding: 18px 22px;
            color: #4f463c;
            background: var(--terracotta-soft);
            border-radius: 0 8px 8px 0;
          }
          table {
            border-collapse: collapse;
            width: 100%;
            font-size: 0.95rem;
            font-family: -apple-system, BlinkMacSystemFont, "Avenir Next", sans-serif;
          }
          th, td {
            border-bottom: 1px solid var(--hairline);
            padding: 0.7rem 0.8rem;
            vertical-align: top;
          }
          th {
            text-align: left;
            color: var(--muted);
            font-size: 0.74rem;
            text-transform: uppercase;
            font-weight: 700;
          }
          img {
            display: block;
            max-width: 100%;
            height: auto;
            border-radius: 8px;
            margin: 1.6rem 0;
          }
          pre, code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          code {
            background: var(--inset);
            border-radius: 4px;
            color: var(--muted);
            font-size: 0.84em;
            padding: 2px 7px;
          }
          pre {
            background: var(--ink);
            border-radius: 8px;
            color: var(--inset);
            font-size: 0.88rem;
            line-height: 1.6;
            overflow-x: auto;
            padding: 20px 24px;
            white-space: pre-wrap;
          }
          pre code {
            background: transparent;
            color: inherit;
            padding: 0;
          }
          mark {
            background: rgba(0, 124, 137, 0.16);
            color: inherit;
          }
          mark.turf-native-annotation-highlight {
            background: rgba(0, 124, 137, 0.22);
            border-radius: 3px;
            box-decoration-break: clone;
            -webkit-box-decoration-break: clone;
          }
          ::selection {
            background: rgba(0, 124, 137, 0.24);
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
}

private extension CGPoint {
  func distance(to other: CGPoint) -> CGFloat {
    hypot(x - other.x, y - other.y)
  }
}
