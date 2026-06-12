import SwiftUI

struct ChatPanel: View {
  @ObservedObject var store: ReviewStore
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeader(title: "Ask about this review", subtitle: "Chat uses the same review session as the web app when OpenClaw is configured.")

      VStack(spacing: 10) {
        if store.chatMessages.isEmpty {
          ContentUnavailableView("No chat yet", systemImage: "bubble.left", description: Text("Ask what matters, what is risky, or what to change first."))
            .frame(maxWidth: .infinity)
        } else {
          ForEach(store.chatMessages) { message in
            ChatBubble(message: message)
          }
        }
      }

      HStack(alignment: .bottom, spacing: 8) {
        TextField("Ask about this review", text: $draft, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(1...4)
          .disabled(isSending)
        Button {
          let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          let startedSlug = store.selectedSlug
          guard !message.isEmpty, !isSending else { return }
          draft = ""
          Task { await send(message, for: startedSlug) }
        } label: {
          if isSending {
            ProgressView()
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
          }
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        .accessibilityLabel("Send chat message")
      }
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

  private var isSending: Bool {
    store.isSendingChat(slug: store.selectedSlug)
  }
}

struct ChatBubble: View {
  let message: ChatMessage

  var body: some View {
    HStack {
      if message.role == "user" { Spacer(minLength: 28) }
      VStack(alignment: .leading, spacing: 5) {
        Text(label)
          .font(.caption2.weight(.bold))
          .foregroundStyle(TurfTheme.muted)
        Text(message.content)
          .font(.callout)
          .foregroundStyle(message.role == "user" ? .white : TurfTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(11)
      .background(background)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      if message.role != "user" { Spacer(minLength: 28) }
    }
  }

  private var label: String {
    switch message.role {
    case "user": return "You"
    case "assistant": return "Benji"
    case "system": return "System"
    default: return message.role.capitalized
    }
  }

  private var background: Color {
    if message.role == "user" { return TurfTheme.accent }
    if message.role == "system" { return TurfTheme.coral.opacity(0.12) }
    return TurfTheme.paper
  }
}
