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

  /// Kill is destructive; sending, executing, approving and "no further action" are accent;
  /// edit, rework, inbox and park are neutral.
  static func tone(for action: String) -> TurfTone {
    switch normalized(action) {
    case "kill": return .destructive
    case "edit", "rework", "inbox", "park": return .neutral
    default: return .accent
    }
  }

  static func color(for action: String) -> Color {
    tone(for: action).icon
  }

  static func label(for action: String) -> String {
    ReviewDisplayText.actionLabel(action)
  }

  private static func normalized(_ action: String?) -> String {
    action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }
}

struct DecisionPanel: View {
  let store: ReviewStore
  let item: ReviewItem

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// About five lines of body text; grows with Dynamic Type.
  @ScaledMetric(relativeTo: .body) private var feedbackMinHeight: CGFloat = 122
  @State private var feedback = ""
  @State private var feedbackValidationDecision: String?
  @State private var submittingAction: String?
  @FocusState private var isFeedbackFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.sectionGap) {
      SectionHeader(title: item.isPending ? "Choose the next action" : "Decision", subtitle: item.isPending ? "Feedback travels with the decision and existing annotations." : "This review has left the pending queue.")

      if item.isPending {
        pendingContent
          .transition(.opacity)
      } else {
        decidedCard
          .transition(.opacity)
      }
    }
    .turfAnimation(TurfMotion.content, value: item.isPending)
    .onChange(of: item.slug) { _, _ in
      resetDraft()
    }
  }

  private var pendingContent: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.sectionGap) {
      VStack(alignment: .leading, spacing: TurfSpacing.cardGap) {
        VStack(spacing: TurfSpacing.controlGap) {
          ForEach(Array(item.allowedActions.enumerated()), id: \.element) { index, action in
            actionButton(action, isPrimary: index == 0)
          }
        }
        .turfCard()

        if store.reviewTargetSummary.total > 0 {
          ReviewTargetDecisionGate(summary: store.reviewTargetSummary, isBlocking: targetGateBlocksAnySubmission)
        }
      }

      VStack(alignment: .leading, spacing: TurfSpacing.s) {
        Text("Feedback")
          .font(TurfType.metaStrong)
          .foregroundStyle(TurfTheme.muted)
        TextEditor(text: $feedback)
          .font(TurfType.body)
          .scrollContentBackground(.hidden)
          .focused($isFeedbackFocused)
          .frame(minHeight: feedbackMinHeight)
          .padding(TurfSpacing.s)
          .turfField(isFocused: isFeedbackFocused, isInvalid: needsFeedback)
          .disabled(isSubmitting)
          .accessibilityLabel("Decision feedback")
        if needsFeedback {
          Text("Feedback is required for this action.")
            .font(TurfType.meta)
            .foregroundStyle(TurfTheme.destructive)
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .turfCard()
      .turfAnimation(TurfMotion.quick, value: needsFeedback)
    }
  }

  private func actionButton(_ action: String, isPrimary: Bool) -> some View {
    let tone = DecisionActionPresentation.tone(for: action)
    let isSubmittingThis = isSubmitting && submittingAction == action
    let button = Button {
      Task { await submit(action) }
    } label: {
      Label {
        Text(DecisionActionPresentation.label(for: action))
          .multilineTextAlignment(.center)
      } icon: {
        if isSubmittingThis {
          ProgressView()
            .controlSize(.small)
            .tint(isPrimary ? TurfTheme.onAccent : tone.text)
        } else {
          Image(systemName: DecisionActionPresentation.icon(for: action))
        }
      }
      .contentTransition(.opacity)
      .turfAnimation(TurfMotion.quick, value: isSubmittingThis)
    }
    .disabled(targetGateBlocksSubmission(for: action) || isSubmitting)
    .accessibilityLabel(DecisionActionPresentation.label(for: action))

    return Group {
      if isPrimary {
        button.buttonStyle(.turfFilled(tone == .destructive ? .destructive : .accent, fullWidth: true))
      } else {
        button.buttonStyle(.turfTinted(tone, fullWidth: true))
      }
    }
  }

  private var decidedCard: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.s) {
      HStack(alignment: .center, spacing: TurfSpacing.s) {
        TurfStatusDot(tone: TurfTheme.statusTone(item.status))
        Text(item.decision ?? item.status)
          .font(.title3.weight(.semibold))
          .foregroundStyle(TurfTheme.ink)
      }
      if let feedback = item.feedback, !feedback.isEmpty {
        Text(feedback)
          .font(TurfType.body)
          .foregroundStyle(TurfTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfCard()
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

  private func submit(_ action: String) async {
    guard !isSubmitting, !targetGateBlocksSubmission(for: action) else { return }
    guard !DecisionActionPresentation.requiresFeedback(for: action)
            || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      feedbackValidationDecision = action
      return
    }
    feedbackValidationDecision = nil
    submittingAction = action
    await store.submitDecision(for: item.slug, action, feedback: feedback)
    submittingAction = nil
  }

  private func resetDraft() {
    feedback = ""
    feedbackValidationDecision = nil
    submittingAction = nil
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

/// The review-item gate: one card row, one encoding (the icon). No tinted fill, no stroke.
private struct ReviewTargetDecisionGate: View {
  let summary: ReviewTargetSummary
  let isBlocking: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: TurfSpacing.s) {
      Image(systemName: isBlocking ? "exclamationmark.triangle.fill" : "checklist")
        .font(TurfType.metaStrong)
        .foregroundStyle(isBlocking ? TurfTheme.attention : TurfTheme.accent)
        .frame(width: TurfSpacing.xl)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
        Text("\(summary.decided) decided, \(summary.undecided) open")
          .font(TurfType.metaStrong)
          .monospacedDigit()
          .foregroundStyle(TurfTheme.ink)
          .contentTransition(reduceMotion ? .opacity : .numericText())
        if isBlocking {
          Text("Items remain open for this final action.")
            .font(TurfType.meta)
            .foregroundStyle(TurfTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .turfCard()
    .turfAnimation(TurfMotion.quick, value: summary)
    .accessibilityElement(children: .combine)
  }
}

struct SectionHeader: View {
  let title: String
  let subtitle: String?
  /// Set when the subtitle is a count that changes on screen ("2 decided, 2 open").
  var subtitleIsCount = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
      Text(title)
        .font(TurfType.panelTitle)
        .foregroundStyle(TurfTheme.ink)
      if let subtitle {
        Text(subtitle)
          .font(TurfType.meta)
          .monospacedDigit()
          .foregroundStyle(TurfTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(subtitleIsCount && !reduceMotion ? .numericText() : .opacity)
          .turfAnimation(TurfMotion.quick, value: subtitleIsCount ? subtitle : "")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}
