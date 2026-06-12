import PencilKit
import SwiftUI
import UIKit

struct AnnotationPanel: View {
  @ObservedObject var store: ReviewStore
  let selection: WebSelection

  @State private var showingComposer = false
  @State private var composerQuote = ""
  @State private var composerAnchorRef: String?
  @State private var composerSlug: String?
  @State private var deletingAnnotationIDs: Set<Int> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeader(
        title: "Inline notes",
        subtitle: selection.isEmpty ? "Select text in the review to anchor a note, or add a general note." : "Selection ready. Save it as a review annotation."
      )

      if !selection.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(selection.text)
            .font(.callout)
            .foregroundStyle(TurfTheme.ink)
            .lineLimit(4)
          Button {
            composerQuote = selection.text
            composerAnchorRef = selection.anchorRef
            composerSlug = store.selectedSlug
            showingComposer = true
          } label: {
            Label("Annotate selection", systemImage: "text.badge.plus")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .turfPanel()
      }

      Button {
        composerQuote = ""
        composerAnchorRef = nil
        composerSlug = store.selectedSlug
        showingComposer = true
      } label: {
        Label("Add review note", systemImage: "square.and.pencil")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      if store.annotations.isEmpty {
        ContentUnavailableView(
          "No notes yet",
          systemImage: "text.quote",
          description: Text("Annotations stay attached to this review and travel into downstream decisions.")
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(spacing: 10) {
          ForEach(store.annotations) { annotation in
            AnnotationRow(annotation: annotation, isDeleting: deletingAnnotationIDs.contains(annotation.id)) {
              let targetSlug = annotation.slug ?? store.selectedSlug
              Task { await delete(annotation, from: targetSlug) }
            }
          }
        }
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
    VStack(alignment: .leading, spacing: 8) {
      if let quote = annotation.quote, !quote.isEmpty {
        Text("\"\(quote)\"")
          .font(.caption)
          .foregroundStyle(TurfTheme.accent)
          .lineLimit(3)
      }

      if let image = annotation.inlineImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 170)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(TurfTheme.hairline, lineWidth: 1)
          )
          .accessibilityLabel("Pencil annotation sketch")
      }

      Text(annotation.comment)
        .font(.body)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Text(annotation.createdAt?.prefix(16) ?? "Just now")
          .font(.caption2)
          .foregroundStyle(TurfTheme.muted)
        Spacer()
        Button(role: .destructive, action: onDelete) {
          if isDeleting {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "trash")
          }
        }
        .buttonStyle(.borderless)
        .disabled(isDeleting)
        .accessibilityLabel("Delete annotation")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfPanel()
  }
}

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
  @State private var drawing = PKDrawing()
  @State private var note = ""
  @State private var allowsFingerDrawing = false
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        PencilCanvasView(drawing: $drawing, allowsFingerDrawing: allowsFingerDrawing)
          .frame(minHeight: 360)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(TurfTheme.hairline, lineWidth: 1)
          )
          .accessibilityLabel("Pencil sketch canvas")

        HStack(spacing: 12) {
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

        TextEditor(text: $note)
          .frame(minHeight: 96)
          .padding(8)
          .scrollContentBackground(.hidden)
          .background(TurfTheme.panel)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(TurfTheme.hairline, lineWidth: 1)
          )
          .disabled(isSaving)
          .accessibilityLabel("Pencil note")

        Spacer(minLength: 0)
      }
      .padding(16)
      .background(TurfTheme.paper)
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

private extension ReviewAnnotation {
  var inlineImage: UIImage? {
    guard let imageData,
          let data = Data(base64Encoded: imageData),
          let image = UIImage(data: data) else { return nil }
    return image
  }
}

struct AnnotationComposer: View {
  let quote: String
  let onSave: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var comment = ""
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        if !quote.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Quote")
              .font(.caption.weight(.bold))
              .foregroundStyle(TurfTheme.muted)
            Text(quote)
              .font(.callout)
              .foregroundStyle(TurfTheme.ink)
              .lineLimit(6)
          }
          .padding(12)
          .turfPanel()
        }

        TextEditor(text: $comment)
          .frame(minHeight: 180)
          .padding(8)
          .scrollContentBackground(.hidden)
          .background(TurfTheme.panel)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(TurfTheme.hairline, lineWidth: 1)
          )
          .disabled(isSaving)
          .accessibilityLabel("Annotation comment")

        Spacer()
      }
      .padding(16)
      .background(TurfTheme.paper)
      .navigationTitle("Annotation")
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
          .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        }
      }
    }
  }

  private func save() async {
    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isSaving else { return }
    isSaving = true
    let didSave = await onSave(trimmed)
    isSaving = false
    if didSave {
      dismiss()
    }
  }
}
