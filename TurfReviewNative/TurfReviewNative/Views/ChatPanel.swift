import SwiftUI

struct ChatPanel: View {
  let store: ReviewStore

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var draft = ""
  @FocusState private var isDraftFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.sectionGap) {
      SectionHeader(title: "Ask about this review", subtitle: "Chat uses the same review session as the web app when OpenClaw is configured.")

      VStack(spacing: TurfSpacing.cardGap) {
        if store.chatMessages.isEmpty {
          ContentUnavailableView("No chat yet", systemImage: "bubble.left", description: Text("Ask what matters, what is risky, or what to change first."))
            .frame(maxWidth: .infinity)
        } else {
          ForEach(store.chatMessages) { message in
            ChatBubble(message: message)
              .transition(.turfLift(reduceMotion: reduceMotion))
          }
        }
      }
      .turfAnimation(TurfMotion.panel, value: store.chatMessages.count)

      HStack(alignment: .bottom, spacing: TurfSpacing.s) {
        TextField("Ask about this review", text: $draft, axis: .vertical)
          .font(TurfType.body)
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .focused($isDraftFocused)
          .padding(.horizontal, TurfSpacing.m)
          .padding(.vertical, TurfSpacing.s)
          .frame(minHeight: TurfSpacing.hitTarget)
          .turfField(isFocused: isDraftFocused)
          .disabled(isSending)
        Button {
          let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          let startedSlug = store.selectedSlug
          guard !message.isEmpty, !isSending else { return }
          draft = ""
          Task { await send(message, for: startedSlug) }
        } label: {
          Group {
            if isSending {
              ProgressView()
            } else {
              Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(canSend ? TurfTheme.accent : TurfTheme.faint)
            }
          }
          .frame(width: TurfSpacing.hitTarget, height: TurfSpacing.hitTarget)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send chat message")
      }
      .turfCard()
    }
    .onChange(of: store.selectedSlug) { _, _ in
      draft = ""
    }
  }

  private func send(_ message: String, for startedSlug: String?) async {
    let didSend = await store.sendChat(message, for: startedSlug)
    if !didSend, store.selectedSlug == startedSlug {
      draft = message
    }
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
  }

  private var isSending: Bool {
    store.isSendingChat(slug: store.selectedSlug)
  }
}

struct ChatBubble: View {
  let message: ChatMessage

  var body: some View {
    HStack(spacing: 0) {
      if isUser { Spacer(minLength: TurfSpacing.xxxl) }
      HStack(alignment: .firstTextBaseline, spacing: TurfSpacing.s) {
        if isSystem {
          Image(systemName: "exclamationmark.circle")
            .font(TurfType.metaStrong)
            .foregroundStyle(TurfTheme.destructive)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
          Text(label)
            .font(TurfType.metaStrong)
            .foregroundStyle(authorColor)
          Text(message.content)
            .font(TurfType.body)
            .foregroundStyle(isUser ? TurfTheme.onAccent : TurfTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(TurfSpacing.cardInset)
      .background { bubbleBackground }
      .accessibilityElement(children: .combine)
      if !isUser { Spacer(minLength: TurfSpacing.xxxl) }
    }
  }

  private var isUser: Bool { message.role == "user" }
  private var isSystem: Bool { message.role == "system" }

  private var label: String {
    switch message.role {
    case "user": return "You"
    case "assistant": return "Benji"
    case "system": return "System"
    default: return message.role.capitalized
    }
  }

  /// Muted text never sits on a soft fill, so the system author stays ink.
  private var authorColor: Color {
    if isUser { return TurfTheme.onAccent }
    if isSystem { return TurfTheme.ink }
    return TurfTheme.muted
  }

  @ViewBuilder
  private var bubbleBackground: some View {
    let shape = RoundedRectangle(cornerRadius: TurfRadius.card, style: .continuous)
    if isUser {
      shape.fill(TurfTheme.accentFill)
    } else if isSystem {
      shape.fill(TurfTheme.card).overlay(shape.fill(TurfTheme.destructiveSoft))
    } else {
      shape.fill(TurfTheme.card)
    }
  }
}
