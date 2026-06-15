import SwiftUI

enum DecisionActionPresentation {
  static func requiresFeedback(for action: String?) -> Bool {
    switch normalized(action) {
    case "rework", "edit": return true
    default: return false
    }
  }

  static func icon(for action: String) -> String {
    switch normalized(action) {
    case "send": return "paperplane.fill"
    case "edit", "rework": return "pencil.and.outline"
    case "kill": return "xmark.octagon.fill"
    case "execute", "approve": return "bolt.fill"
    case "inbox": return "tray.and.arrow.down.fill"
    case "park": return "pause.circle.fill"
    default: return "checkmark.circle.fill"
    }
  }

  static func color(for action: String) -> Color {
    switch normalized(action) {
    case "kill": return TurfTheme.coral
    case "edit", "rework": return TurfTheme.gold
    case "inbox": return TurfTheme.plum
    case "park": return TurfTheme.muted
    case "execute", "approve", "send": return TurfTheme.accent
    default: return TurfTheme.moss
    }
  }

  static func label(for action: String) -> String {
    ReviewDisplayText.actionLabel(action)
  }

  private static func normalized(_ action: String?) -> String {
    action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }
}

struct DecisionPanel: View {
  @ObservedObject var store: ReviewStore
  let item: ReviewItem

  @State private var feedback = ""
  @State private var feedbackValidationDecision: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeader(title: item.isPending ? "Choose the next action" : "Decision", subtitle: item.isPending ? "Feedback travels with the decision and existing annotations." : "This review has left the pending queue.")

      if item.isPending {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 146), spacing: 10, alignment: .top)], spacing: 10) {
          ForEach(item.allowedActions, id: \.self) { action in
            Button {
              Task { await submit(action) }
            } label: {
              HStack(alignment: .center, spacing: 8) {
                Image(systemName: DecisionActionPresentation.icon(for: action))
                  .frame(width: 18)
                Text(DecisionActionPresentation.label(for: action))
                  .font(.subheadline.weight(.semibold))
                  .lineLimit(2)
                  .minimumScaleFactor(0.9)
                  .fixedSize(horizontal: false, vertical: true)
                  .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
              }
              .padding(12)
              .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
              .foregroundStyle(.white)
              .background(DecisionActionPresentation.color(for: action))
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .stroke(actionNeedsFeedback(action) ? TurfTheme.coral.opacity(0.8) : DecisionActionPresentation.color(for: action).opacity(0.35), lineWidth: actionNeedsFeedback(action) ? 2 : 1)
              )
            }
            .buttonStyle(.plain)
            .disabled(targetGateBlocksSubmission(for: action) || isSubmitting)
            .accessibilityLabel(DecisionActionPresentation.label(for: action))
          }
        }

        if store.reviewTargetSummary.total > 0 {
          ReviewTargetDecisionGate(summary: store.reviewTargetSummary, isBlocking: targetGateBlocksAnySubmission)
        }

        VStack(alignment: .leading, spacing: 7) {
          Text("Feedback")
            .font(.caption.weight(.bold))
            .foregroundStyle(TurfTheme.muted)
          TextEditor(text: $feedback)
            .frame(minHeight: 122)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(TurfTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(needsFeedback ? TurfTheme.coral.opacity(0.55) : TurfTheme.hairline, lineWidth: 1)
            )
            .disabled(isSubmitting)
            .accessibilityLabel("Decision feedback")
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text(item.decision ?? item.status)
            .font(.title3.weight(.bold))
            .foregroundStyle(TurfTheme.statusColor(item.status))
          if let feedback = item.feedback, !feedback.isEmpty {
            Text(feedback)
              .font(.body)
              .foregroundStyle(TurfTheme.ink)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .turfPanel()
      }
    }
    .onChange(of: item.slug) { _, _ in
      resetDraft()
    }
  }

  private var needsFeedback: Bool {
    guard let feedbackValidationDecision else { return false }
    return DecisionActionPresentation.requiresFeedback(for: feedbackValidationDecision)
      && feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var targetGateBlocksAnySubmission: Bool {
    item.allowedActions.contains { targetGateBlocksSubmission(for: $0) }
  }

  private func targetGateBlocksSubmission(for action: String) -> Bool {
    store.reviewTargetSummary.total > 0
      && !store.reviewTargetSummary.complete
      && Self.requiresCompletedTargets(for: action)
  }

  private var isSubmitting: Bool {
    store.isSubmittingDecision(slug: item.slug)
  }

  private func actionNeedsFeedback(_ action: String) -> Bool {
    feedbackValidationDecision == action && needsFeedback
  }

  private func submit(_ action: String) async {
    guard !isSubmitting, !targetGateBlocksSubmission(for: action) else { return }
    guard !DecisionActionPresentation.requiresFeedback(for: action)
            || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      feedbackValidationDecision = action
      return
    }
    feedbackValidationDecision = nil
    await store.submitDecision(for: item.slug, action, feedback: feedback)
  }

  private func resetDraft() {
    feedback = ""
    feedbackValidationDecision = nil
  }

  private static func requiresCompletedTargets(for action: String) -> Bool {
    switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "execute", "approve", "send":
      return true
    default:
      return false
    }
  }
}

private struct ReviewTargetDecisionGate: View {
  let summary: ReviewTargetSummary
  let isBlocking: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: isBlocking ? "exclamationmark.triangle.fill" : "checklist")
        .foregroundStyle(isBlocking ? TurfTheme.gold : TurfTheme.accent)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text("\(summary.approved) yes, \(summary.rejected) no, \(summary.undecided) open")
          .font(.caption.weight(.bold))
          .foregroundStyle(TurfTheme.ink)
        if isBlocking {
          Text("Items remain open for this final action.")
            .font(.caption)
            .foregroundStyle(TurfTheme.muted)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(isBlocking ? TurfTheme.gold.opacity(0.12) : TurfTheme.accent.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke((isBlocking ? TurfTheme.gold : TurfTheme.accent).opacity(0.28), lineWidth: 1)
    )
  }
}

struct SectionHeader: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.headline)
        .foregroundStyle(TurfTheme.ink)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(TurfTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
