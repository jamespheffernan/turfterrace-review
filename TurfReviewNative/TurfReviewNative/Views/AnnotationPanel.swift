import SwiftUI
#if os(iOS)
import PencilKit
import UIKit
#endif

struct AnnotationPanel: View {
  let store: ReviewStore
  let selection: WebSelection

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showingComposer = false
  @State private var composerQuote = ""
  @State private var composerAnchorRef: String?
  @State private var composerSlug: String?
  @State private var deletingAnnotationIDs: Set<Int> = []

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.sectionGap) {
      SectionHeader(
        title: "Notes & annotations",
        subtitle: selection.isEmpty ? "Add a general note, or select text in the review to attach a note to that passage." : "The selected passage is ready for an attached note."
      )

      VStack(alignment: .leading, spacing: TurfSpacing.controlGap) {
        if !selection.isEmpty {
          Text(selection.text)
            .font(TurfType.quote)
            .foregroundStyle(TurfTheme.ink)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, TurfSpacing.xs)
          Button {
            composerQuote = selection.text
            composerAnchorRef = selection.anchorRef
            composerSlug = store.selectedSlug
            showingComposer = true
          } label: {
            Label("Annotate selection", systemImage: "text.badge.plus")
          }
          .buttonStyle(.turfFilled(.accent, fullWidth: true))
        }

        Button {
          composerQuote = ""
          composerAnchorRef = nil
          composerSlug = store.selectedSlug
          showingComposer = true
        } label: {
          Label {
            Text("Add review note")
          } icon: {
            Image(systemName: "square.and.pencil").foregroundStyle(TurfTheme.accent)
          }
        }
        .buttonStyle(.turfTinted(.neutral, fullWidth: true))
      }
      .turfCard()

      if store.annotations.isEmpty {
        ContentUnavailableView(
          "No notes for this review",
          systemImage: "note.text",
          description: Text("Select text to attach a note, or add a general review note. Notes are included with your decision.")
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(spacing: TurfSpacing.cardGap) {
          ForEach(store.annotations) { annotation in
            AnnotationRow(annotation: annotation, isDeleting: deletingAnnotationIDs.contains(annotation.id)) {
              let targetSlug = annotation.slug ?? store.selectedSlug
              Task { await delete(annotation, from: targetSlug) }
            }
            .transition(.turfLift(reduceMotion: reduceMotion))
          }
        }
        .turfAnimation(TurfMotion.panel, value: store.annotations.map(\.id))
      }
    }
    .sheet(isPresented: $showingComposer) {
      AnnotationComposer(quote: composerQuote) { comment in
        await store.createAnnotation(
          for: composerSlug,
          quote: composerQuote.isEmpty ? nil : composerQuote,
          anchorRef: composerAnchorRef,
          comment: comment
        )
      }
    }
    .onChange(of: store.selectedSlug) { _, _ in
      showingComposer = false
      composerQuote = ""
      composerAnchorRef = nil
      composerSlug = nil
      deletingAnnotationIDs = []
    }
  }

  private func delete(_ annotation: ReviewAnnotation, from targetSlug: String?) async {
    guard !deletingAnnotationIDs.contains(annotation.id) else { return }
    deletingAnnotationIDs.insert(annotation.id)
    defer { deletingAnnotationIDs.remove(annotation.id) }
    await store.deleteAnnotation(annotation, for: targetSlug)
  }
}

struct AnnotationRow: View {
  let annotation: ReviewAnnotation
  let isDeleting: Bool
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.s) {
      if let quote = annotation.quote, !quote.isEmpty {
        Text(Self.highlighted(quote))
          .font(TurfType.quote)
          .foregroundStyle(TurfTheme.ink)
          .lineLimit(3)
          .accessibilityLabel("Quoted passage: \(quote)")
      }

      if let image = annotation.inlineImage {
        Image(turfPlatformImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 170)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(TurfSpacing.s)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: TurfRadius.field, style: .continuous))
          .accessibilityLabel("Pencil annotation sketch")
      }

      Text(annotation.comment)
        .font(TurfType.body)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .center, spacing: TurfSpacing.s) {
        Text(timestamp)
          .font(TurfType.caption)
          .foregroundStyle(TurfTheme.muted)
        Spacer(minLength: 0)
        Button(role: .destructive, action: onDelete) {
          Group {
            if isDeleting {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "trash")
                .font(TurfType.body)
                .foregroundStyle(TurfTheme.destructive)
            }
          }
          .frame(width: TurfSpacing.hitTarget, height: TurfSpacing.hitTarget)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .accessibilityLabel("Delete annotation")
      }
      // The 44pt delete target overhangs the card's bottom-trailing padding instead of growing the row.
      // Upward it reaches only into the stack spacing, so it never covers the comment text.
      .padding(.trailing, -TurfSpacing.m)
      .padding(.top, -TurfSpacing.s)
      .padding(.bottom, -TurfSpacing.m)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfCard()
  }

  private var timestamp: String {
    guard let createdAt = annotation.createdAt else { return "Just now" }
    if let date = ServerDate.parse(createdAt) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return String(createdAt.prefix(16))
  }

  /// The quote painted with the reader's saved-note highlighter, line by line.
  private static func highlighted(_ quote: String) -> AttributedString {
    var text = AttributedString(quote)
    text.backgroundColor = TurfTheme.highlight
    return text
  }
}

#if os(iOS)
struct PencilAnnotationPayload: Equatable {
  let anchorRef: String
  let comment: String
  let imageData: String
  let imageMime: String

  static let anchorRef = "apple-pencil-sketch"
  static let imageMime = "image/png"

  init?(drawing: PKDrawing, note: String, scale: CGFloat = UIScreen.main.scale) {
    guard let imageData = Self.pngData(from: drawing, scale: scale) else { return nil }
    self.anchorRef = Self.anchorRef
    self.comment = Self.comment(from: note)
    self.imageData = imageData
    self.imageMime = Self.imageMime
  }

  static func comment(from note: String) -> String {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "Apple Pencil sketch."
    }
    return "Apple Pencil sketch: \(trimmed)"
  }

  static func pngData(from drawing: PKDrawing, scale: CGFloat = UIScreen.main.scale) -> String? {
    let drawingBounds = drawing.bounds
    guard !drawingBounds.isNull, !drawingBounds.isEmpty else { return nil }

    let renderBounds = drawingBounds.insetBy(dx: -24, dy: -24)
    let transparentImage = drawing.image(from: renderBounds, scale: scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: transparentImage.size, format: format)
    let image = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: transparentImage.size))
      transparentImage.draw(in: CGRect(origin: .zero, size: transparentImage.size))
    }
    return image.pngData()?.base64EncodedString()
  }
}

struct PencilAnnotationComposer: View {
  let onSave: (PencilAnnotationPayload) async -> Bool

  @Environment(\.dismiss) private var dismiss
  /// About four lines of body text; grows with Dynamic Type.
  @ScaledMetric(relativeTo: .body) private var noteMinHeight: CGFloat = 96
  @State private var drawing = PKDrawing()
  @State private var note = ""
  @State private var allowsFingerDrawing = false
  @State private var isSaving = false
  @FocusState private var isNoteFocused: Bool
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: TurfSpacing.l) {
        // The canvas stays white on purpose: the saved sketch is rendered on white.
        PencilCanvasView(drawing: $drawing, allowsFingerDrawing: allowsFingerDrawing)
          .frame(minHeight: 360)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: TurfRadius.field, style: .continuous))
          .accessibilityLabel("Pencil sketch canvas")

        HStack(spacing: TurfSpacing.m) {
          Toggle("Finger drawing", isOn: $allowsFingerDrawing)
            .disabled(isSaving)
          Spacer()
          Button(role: .destructive) {
            drawing = PKDrawing()
          } label: {
            Label("Clear", systemImage: "eraser")
          }
          .disabled(drawing.bounds.isNull || drawing.bounds.isEmpty || isSaving)
        }
        .frame(minHeight: TurfSpacing.hitTarget)
        .padding(.horizontal, TurfSpacing.cardInset)
        .padding(.vertical, TurfSpacing.xs)
        .turfCard(padding: nil)

        TextEditor(text: $note)
          .font(TurfType.body)
          .frame(minHeight: noteMinHeight)
          .scrollContentBackground(.hidden)
          .focused($isNoteFocused)
          .padding(TurfSpacing.s)
          .turfField(isFocused: isNoteFocused)
          .background(TurfTheme.card, in: RoundedRectangle(cornerRadius: TurfRadius.field, style: .continuous))
          .disabled(isSaving)
          .accessibilityLabel("Pencil note")

        Spacer(minLength: 0)
      }
      .padding(TurfSpacing.panelInset(compact: horizontalSizeClass == .compact))
      .background(TurfTheme.panel)
      .navigationTitle("Pencil note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            if isSaving {
              ProgressView()
            } else {
              Text("Save")
            }
          }
          .disabled(!hasDrawing || isSaving)
        }
      }
    }
  }

  private var hasDrawing: Bool {
    !drawing.bounds.isNull && !drawing.bounds.isEmpty
  }

  private func save() async {
    guard hasDrawing,
          !isSaving,
          let payload = PencilAnnotationPayload(drawing: drawing, note: note) else { return }
    isSaving = true
    let didSave = await onSave(payload)
    isSaving = false
    if didSave {
      dismiss()
    }
  }
}

struct PencilCanvasView: UIViewRepresentable {
  @Binding var drawing: PKDrawing
  let allowsFingerDrawing: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(drawing: $drawing)
  }

  func makeUIView(context: Context) -> PKCanvasView {
    let canvasView = PKCanvasView()
    canvasView.delegate = context.coordinator
    canvasView.backgroundColor = .white
    canvasView.isOpaque = true
    canvasView.drawing = drawing
    canvasView.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
    canvasView.tool = PKInkingTool(.pen, color: .label, width: 5)
    canvasView.alwaysBounceVertical = false
    canvasView.alwaysBounceHorizontal = false
    canvasView.isScrollEnabled = false
    context.coordinator.installToolPicker(for: canvasView)
    return canvasView
  }

  func updateUIView(_ canvasView: PKCanvasView, context: Context) {
    if canvasView.drawing.dataRepresentation() != drawing.dataRepresentation() {
      canvasView.drawing = drawing
    }
    canvasView.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
    context.coordinator.installToolPicker(for: canvasView)
  }

  final class Coordinator: NSObject, PKCanvasViewDelegate {
    private let drawing: Binding<PKDrawing>
    private var toolPicker: PKToolPicker?

    init(drawing: Binding<PKDrawing>) {
      self.drawing = drawing
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      drawing.wrappedValue = canvasView.drawing
    }

    func installToolPicker(for canvasView: PKCanvasView) {
      if toolPicker == nil {
        toolPicker = PKToolPicker()
      }
      guard let toolPicker else { return }
      toolPicker.addObserver(canvasView)
      toolPicker.setVisible(true, forFirstResponder: canvasView)
      DispatchQueue.main.async {
        canvasView.becomeFirstResponder()
      }
    }
  }
}
#endif

private extension ReviewAnnotation {
  var inlineImage: TurfPlatformImage? {
    guard let imageData,
          let data = Data(base64Encoded: imageData),
          let image = TurfPlatformImage(data: data) else { return nil }
    return image
  }
}

struct AnnotationComposer: View {
  let quote: String
  var autofocus: Bool = false
  let onSave: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  @State private var comment = ""
  @State private var isSaving = false
  @State private var presentationStage = 0
  @FocusState private var isCommentFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: TurfSpacing.l) {
        AnnotationComposerHeader(isSaving: isSaving, hasQuote: !quote.isEmpty)
          .opacity(presentationStage >= 1 ? 1 : 0)
          .offset(y: reduceMotion || presentationStage >= 1 ? 0 : TurfMotion.lift)

        if !quote.isEmpty {
          AnnotationQuotePreview(quote: quote)
            .opacity(presentationStage >= 1 ? 1 : 0)
            .offset(y: reduceMotion || presentationStage >= 1 ? 0 : TurfMotion.lift)
        }

        AnnotationEditorField(comment: $comment, isSaving: isSaving, isFocused: $isCommentFocused)
          .opacity(presentationStage >= 2 ? 1 : 0)
          .offset(y: reduceMotion || presentationStage >= 2 ? 0 : TurfMotion.lift)

        Spacer()
      }
      .padding(TurfSpacing.panelInset(compact: isCompact))
      .background(TurfTheme.panel)
      .navigationTitle("New note")
      .turfInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            Group {
              if isSaving {
                Label("Saving", systemImage: "checkmark.circle.fill")
              } else {
                Label("Save", systemImage: "checkmark")
              }
            }
            .labelStyle(.titleAndIcon)
            .contentTransition(.opacity)
          }
          .buttonStyle(.turfFilled(.accent))
          .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
          .keyboardShortcut(.return, modifiers: .command)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(TurfTheme.panel)
    .onAppear {
      runEntrance()
    }
  }

  private var isCompact: Bool {
    #if os(iOS)
    horizontalSizeClass == .compact
    #else
    false
    #endif
  }

  private func save() async {
    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isSaving else { return }
    TurfPlatformFeedback.saveStarted()
    withTurfAnimation(TurfMotion.quick, reduceMotion: reduceMotion) {
      isSaving = true
    }
    let didSave = await onSave(trimmed)
    withTurfAnimation(TurfMotion.quick, reduceMotion: reduceMotion) {
      isSaving = false
    }
    if didSave {
      TurfPlatformFeedback.saveSucceeded()
      dismiss()
    }
  }

  private func runEntrance() {
    if reduceMotion {
      presentationStage = 2
      focusEditorIfNeeded()
      return
    }

    presentationStage = 0
    withTurfAnimation(TurfMotion.panel, reduceMotion: reduceMotion) {
      presentationStage = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + AnnotationComposerMotion.editorDelay) {
      withTurfAnimation(TurfMotion.panel, reduceMotion: reduceMotion) {
        presentationStage = 2
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + AnnotationComposerMotion.focusDelay) {
      focusEditorIfNeeded()
    }
  }

  private func focusEditorIfNeeded() {
    guard autofocus else { return }
    isCommentFocused = true
  }
}

/*
 ANIMATION STORYBOARD  (all stages use TurfMotion.panel, 8pt lift; Reduce Motion shows everything at once)

   0ms   sheet content mounts; header and quote lift into place
  70ms   editor lifts into place and becomes the main target
 120ms   keyboard focus follows the visual motion
 Save   label swaps to "Saving" (TurfMotion.quick); the button itself carries the press feedback
 */
private enum AnnotationComposerMotion {
  static let editorDelay: TimeInterval = 0.07
  static let focusDelay: TimeInterval = 0.12
}

private struct AnnotationComposerHeader: View {
  let isSaving: Bool
  let hasQuote: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
      Text(isSaving ? "Saving note" : "Ready to annotate")
        .font(TurfType.panelTitle)
        .foregroundStyle(TurfTheme.ink)
        .contentTransition(.opacity)
      // A general note has no anchored passage, so the anchor line only appears with a quote.
      if isSaving || hasQuote {
        Text(isSaving ? "Adding it to the review" : "The selected text is anchored")
          .font(TurfType.meta)
          .foregroundStyle(TurfTheme.muted)
          .contentTransition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct AnnotationQuotePreview: View {
  let quote: String

  var body: some View {
    Text(Self.highlighted(quote))
      .font(TurfType.quote)
      .foregroundStyle(TurfTheme.ink)
      .lineLimit(5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .turfCard()
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Selected quote")
      .accessibilityValue(quote)
  }

  /// A draft note: the quote carries the active highlighter until the note is saved.
  private static func highlighted(_ quote: String) -> AttributedString {
    var text = AttributedString(quote)
    text.backgroundColor = TurfTheme.highlightActive
    return text
  }
}

private struct AnnotationEditorField: View {
  @Binding var comment: String
  let isSaving: Bool
  var isFocused: FocusState<Bool>.Binding

  /// TextEditor draws its text inset from its own frame (5pt leading, 8pt top on iOS).
  /// The placeholder adds the same inset so it sits exactly where typed text starts.
  private static let systemTextInset = EdgeInsets(top: 8, leading: 5, bottom: 0, trailing: 0)

  var body: some View {
    ZStack(alignment: .topLeading) {
      if comment.isEmpty {
        Text("Add your note")
          .font(TurfType.body)
          .foregroundStyle(TurfTheme.muted)
          .padding(Self.systemTextInset)
          .padding(TurfSpacing.s)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }

      TextEditor(text: $comment)
        .font(TurfType.body)
        .frame(minHeight: 190)
        .padding(TurfSpacing.s)
        .scrollContentBackground(.hidden)
        .disabled(isSaving)
        .focused(isFocused)
        .accessibilityLabel("Annotation comment")
    }
    .turfField(isFocused: isFocused.wrappedValue)
    .background(TurfTheme.card, in: RoundedRectangle(cornerRadius: TurfRadius.field, style: .continuous))
  }
}
