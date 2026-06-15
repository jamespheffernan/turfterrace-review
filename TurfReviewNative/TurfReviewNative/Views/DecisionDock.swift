import SwiftUI

/// Option A — the floating decision dock.
/// Always-visible, bottom-centred. Shows the recommended action plus the next
/// alternative as one-tap pills; everything else lives behind "More", which opens
/// the full `DecisionPanel`. Non-feedback actions fire immediately; actions that
/// need feedback or are gated by open review items route through More instead.
struct DecisionDock: View {
  @ObservedObject var store: ReviewStore
  let item: ReviewItem
  let onMore: () -> Void

  var body: some View {
    Group {
      if item.isPending {
        pendingDock
      } else {
        decidedDock
      }
    }
    .padding(7)
    .background(.regularMaterial, in: Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .stroke(TurfTheme.hairline, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
    .animation(.easeInOut(duration: 0.15), value: isSubmitting)
  }

  // MARK: Pending

  private var pendingDock: some View {
    HStack(spacing: 8) {
      if let primary = actions.first {
        actionPill(primary, prominent: true)
      }
      if let secondary = actions.dropFirst().first {
        actionPill(secondary, prominent: false)
      }
      moreButton
    }
  }

  private func actionPill(_ action: String, prominent: Bool) -> some View {
    let color = DecisionActionPresentation.color(for: action)
    return Button {
      tap(action)
    } label: {
      HStack(spacing: 7) {
        if isSubmitting, prominent {
          ProgressView()
            .controlSize(.small)
            .tint(prominent ? .white : color)
        } else {
          Image(systemName: DecisionActionPresentation.icon(for: action))
            .font(.system(size: 14, weight: .bold))
        }
        Text(DecisionActionPresentation.label(for: action))
          .font(.system(size: 17, weight: .semibold))
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, prominent ? 22 : 18)
      .padding(.vertical, 13)
      .foregroundStyle(prominent ? Color.white : color)
      .background(
        Capsule(style: .continuous)
          .fill(prominent ? color : Color.clear)
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(prominent ? Color.clear : TurfTheme.hairline, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
    .disabled(isSubmitting)
    .accessibilityLabel(DecisionActionPresentation.label(for: action))
  }

  private var moreButton: some View {
    Button(action: onMore) {
      Image(systemName: "ellipsis")
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(TurfTheme.muted)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("More actions and feedback")
  }

  // MARK: Decided

  private var decidedDock: some View {
    Button(action: onMore) {
      HStack(spacing: 10) {
        Circle()
          .fill(TurfTheme.statusColor(item.status))
          .frame(width: 10, height: 10)
          .padding(.leading, 10)
        Text(item.decision ?? ReviewDisplayText.statusLabel(item.status))
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(TurfTheme.ink)
          .lineLimit(1)
        Image(systemName: "chevron.up")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(TurfTheme.muted)
          .padding(.trailing, 12)
      }
      .padding(.vertical, 11)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Review decision: \(item.decision ?? item.status). Open details.")
  }

  // MARK: Behaviour

  private var actions: [String] { item.allowedActions }

  private var isSubmitting: Bool {
    store.isSubmittingDecision(slug: item.slug)
  }

  private func tap(_ action: String) {
    guard !isSubmitting else { return }
    if DecisionActionPresentation.requiresFeedback(for: action) || gateBlocks(action) {
      onMore()
      return
    }
    Task { await store.submitDecision(for: item.slug, action, feedback: "") }
  }

  private func gateBlocks(_ action: String) -> Bool {
    store.reviewTargetSummary.total > 0
      && !store.reviewTargetSummary.complete
      && Self.requiresCompletedTargets(action)
  }

  private static func requiresCompletedTargets(_ action: String) -> Bool {
    switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "execute", "approve", "send": return true
    default: return false
    }
  }
}
