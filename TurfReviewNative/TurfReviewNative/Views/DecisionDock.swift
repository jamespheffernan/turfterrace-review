import SwiftUI

/// Option A — the floating decision dock.
/// Always-visible, bottom-centred. Shows the recommended action plus the next
/// alternative as one-tap pills; everything else lives behind "More", which opens
/// the full `DecisionPanel`. Non-feedback actions fire immediately; actions that
/// need feedback or are gated by open review items route through More instead.
struct DecisionDock: View {
  let store: ReviewStore
  let item: ReviewItem
  let onMore: () -> Void
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Whether this dock has shown the review as pending. The dock is recreated per review, so a
  /// decided capsule that follows a pending dock is a decision landing, not a review being opened.
  @State private var sawPending: Bool
  /// Whether this user started a decision from this dock or its panel. Only then does a pending →
  /// decided change land with the haptic and the settle; a decision made elsewhere and picked up
  /// by a refresh just appears.
  @State private var decisionRequested = false

  init(store: ReviewStore, item: ReviewItem, onMore: @escaping () -> Void) {
    self.store = store
    self.item = item
    self.onMore = onMore
    _sawPending = State(initialValue: item.isPending)
  }

  var body: some View {
    // A ZStack so the pills and the decided capsule overlap while they crossfade.
    ZStack {
      if item.isPending {
        pendingDock
          .transition(pendingTransition)
      } else {
        decidedDock
          .transition(decidedTransition)
      }
    }
    .frame(maxWidth: .infinity)
    .turfAnimation(TurfMotion.content, value: item.isPending)
    .turfAnimation(TurfMotion.quick, value: isSubmitting)
    #if os(iOS)
    .sensoryFeedback(.success, trigger: item.isPending) { wasPending, isPending in
      wasPending && !isPending && decisionRequested
    }
    #endif
    .onChange(of: isSubmitting) { _, submitting in
      if submitting {
        decisionRequested = true
      } else if item.isPending {
        // The submission failed or was refused; a later remote decision is not this user's.
        decisionRequested = false
      }
    }
  }

  // MARK: Pending

  private var pendingDock: some View {
    HStack(spacing: TurfSpacing.controlGap) {
      if let primary = actions.first {
        primaryPill(primary)
      }
      if showsSecondary, let secondary = actions.dropFirst().first {
        secondaryPill(secondary)
      }
      if !isCompact {
        Spacer(minLength: 0)
      }
      reviewButton
    }
  }

  private func primaryPill(_ action: String) -> some View {
    let tone = DecisionActionPresentation.tone(for: action)
    return Button {
      tap(action)
    } label: {
      Label {
        Text(DecisionActionPresentation.label(for: action))
          .lineLimit(1)
      } icon: {
        ZStack {
          if isSubmitting {
            ProgressView()
              .tint(TurfTheme.onAccent)
              .transition(.opacity)
          } else {
            Image(systemName: DecisionActionPresentation.icon(for: action))
              .transition(.opacity)
          }
        }
      }
      .font(TurfType.dockLabel)
    }
    .buttonStyle(.turfFilled(tone == .destructive ? .destructive : .accent, fullWidth: isCompact))
    // Busy, not disabled: the spinner stays at full strength and tap() ignores repeats.
    .allowsHitTesting(!isSubmitting)
    .accessibilityLabel(DecisionActionPresentation.label(for: action))
    .accessibilityValue(isSubmitting ? "Submitting" : "")
    .accessibilityAddTraits(isSubmitting ? .updatesFrequently : [])
  }

  private func secondaryPill(_ action: String) -> some View {
    Button {
      tap(action)
    } label: {
      Label {
        Text(DecisionActionPresentation.label(for: action))
          .lineLimit(1)
      } icon: {
        Image(systemName: DecisionActionPresentation.icon(for: action))
          .foregroundStyle(DecisionActionPresentation.tone(for: action).icon)
      }
      .font(TurfType.dockLabel)
    }
    .buttonStyle(.turfTinted(.neutral))
    .disabled(isSubmitting)
    .accessibilityLabel(DecisionActionPresentation.label(for: action))
  }

  private var reviewButton: some View {
    Button {
      // The panel can submit too; a demo decision completes in one update, so the
      // isSubmitting change is never observed.
      decisionRequested = true
      onMore()
    } label: {
      Label("Review", systemImage: "slider.horizontal.3")
        .font(TurfType.dockLabel)
        .lineLimit(1)
        .labelStyle(ReviewLabelStyle(iconOnly: dynamicTypeSize.isAccessibilitySize))
    }
    .buttonStyle(.turfTinted(.neutral))
    .accessibilityLabel("More actions and feedback")
  }

  // MARK: Decided

  private var decidedDock: some View {
    Button(action: onMore) {
      HStack(spacing: TurfSpacing.s) {
        DecidedStatusDot(
          tone: TurfTheme.statusTone(item.status),
          lands: sawPending && decisionRequested && !reduceMotion,
          reduceMotion: reduceMotion
        )
        Text(item.decision ?? ReviewDisplayText.statusLabel(item.status))
          .font(TurfType.dockLabel)
          .foregroundStyle(TurfTheme.ink)
          .lineLimit(1)
        Image(systemName: "chevron.up")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(TurfTheme.muted)
      }
    }
    .buttonStyle(.turfTinted(.neutral, fullWidth: isCompact))
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("Review decision: \(item.decision ?? item.status). Open details.")
  }

  /// Pills fade and shrink slightly on the way out (exit); the decided capsule fades in.
  /// Under Reduce Motion both are a plain crossfade.
  private var pendingTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity,
      removal: .opacity.combined(with: .scale(scale: 0.96)).animation(TurfMotion.exit)
    )
  }

  private var decidedTransition: AnyTransition {
    .opacity
  }

  private var showsSecondary: Bool {
    !isCompact && !dynamicTypeSize.isAccessibilitySize
  }

  // MARK: Behaviour

  private var actions: [String] { item.allowedActions }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  private var isSubmitting: Bool {
    store.isSubmittingDecision(slug: item.slug)
  }

  private func tap(_ action: String) {
    guard !isSubmitting else { return }
    decisionRequested = true
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

/// The status dot of the decided capsule. When a decision lands it settles from half size with
/// `TurfMotion.confirm`; when a decided review is simply opened it appears at rest.
private struct DecidedStatusDot: View {
  let tone: TurfTone
  let reduceMotion: Bool
  @State private var scale: CGFloat

  init(tone: TurfTone, lands: Bool, reduceMotion: Bool) {
    self.tone = tone
    self.reduceMotion = reduceMotion
    _scale = State(initialValue: lands ? 0.5 : 1)
  }

  var body: some View {
    TurfStatusDot(tone: tone)
      .scaleEffect(scale)
      .onAppear {
        guard scale != 1 else { return }
        withTurfAnimation(TurfMotion.confirm, reduceMotion: reduceMotion) {
          scale = 1
        }
      }
  }
}

/// Title and icon normally; icon only at accessibility text sizes, so the dock stays on one row.
private struct ReviewLabelStyle: LabelStyle {
  let iconOnly: Bool

  func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      configuration.icon
    } else {
      HStack(spacing: TurfSpacing.s) {
        configuration.icon
        configuration.title
      }
    }
  }
}

#if os(macOS)
struct MacReviewToolbar: View {
  let store: ReviewStore
  let item: ReviewItem
  let onDecisionDetails: () -> Void
  let onItems: () -> Void
  let onNotes: () -> Void
  let onAsk: () -> Void
  let onProof: () -> Void

  var body: some View {
    HStack(spacing: TurfSpacing.controlGap) {
      if let primaryAction {
        primaryButton(primaryAction)
          .transition(.opacity)
      }

      Menu {
        if item.isPending, !secondaryActions.isEmpty {
          Section("Other decisions") {
            ForEach(secondaryActions, id: \.self) { action in
              Button {
                tap(action)
              } label: {
                Label(
                  DecisionActionPresentation.label(for: action),
                  systemImage: DecisionActionPresentation.icon(for: action)
                )
              }
              .disabled(isSubmitting)
            }
          }
        }

        Button(action: onDecisionDetails) {
          Label("Decision details…", systemImage: "slider.horizontal.3")
        }

        Divider()

        Section("Review") {
          Button(action: onItems) {
            Label(menuLabel("Items", count: store.reviewTargetSummary.undecided), systemImage: "checklist")
          }
          Button(action: onNotes) {
            Label(menuLabel("Notes", count: store.annotations.count), systemImage: "note.text")
          }
          Button(action: onAsk) {
            Label(menuLabel("Ask", count: store.chatMessages.count), systemImage: "bubble.left.and.bubble.right")
          }
          Button(action: onProof) {
            Label("Proof", systemImage: "waveform.path.ecg")
          }
        }
      } label: {
        HStack(spacing: TurfSpacing.xs) {
          Label("Review", systemImage: "sidebar.right")
            .labelStyle(.titleAndIcon)
            .font(TurfType.control)
          // Only the review items still waiting for a decision.
          TurfCountBadge(count: store.reviewTargetSummary.undecided)
        }
      }
      .fixedSize()
      .help("Review tools and other decisions")
    }
    // When the review is decided the primary crossfades out and the menu settles into its place.
    .turfAnimation(TurfMotion.content, value: primaryAction == nil)
  }

  @ViewBuilder
  private func primaryButton(_ action: String) -> some View {
    let tone = DecisionActionPresentation.tone(for: action)
    Button {
      tap(action)
    } label: {
      Label {
        Text(DecisionActionPresentation.label(for: action))
      } icon: {
        if isSubmitting {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: DecisionActionPresentation.icon(for: action))
        }
      }
      .labelStyle(.titleAndIcon)
      .font(TurfType.control)
    }
    .buttonStyle(.borderedProminent)
    .tint(tone == .destructive ? TurfTheme.destructiveFill : TurfTheme.accentFill)
    .disabled(isSubmitting)
    .fixedSize()
    .help("Choose \(DecisionActionPresentation.label(for: action))")
  }

  private var primaryAction: String? {
    if item.isPending {
      return item.allowedActions.first
    }
    return nil
  }

  private var secondaryActions: [String] {
    Array(item.allowedActions.dropFirst())
  }

  private var isSubmitting: Bool {
    store.isSubmittingDecision(slug: item.slug)
  }

  private func tap(_ action: String) {
    guard !isSubmitting else { return }
    if DecisionActionPresentation.requiresFeedback(for: action) || gateBlocks(action) {
      onDecisionDetails()
      return
    }
    Task { await store.submitDecision(for: item.slug, action, feedback: "") }
  }

  private func gateBlocks(_ action: String) -> Bool {
    store.reviewTargetSummary.total > 0
      && !store.reviewTargetSummary.complete
      && requiresCompletedTargets(action)
  }

  private func requiresCompletedTargets(_ action: String) -> Bool {
    switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "execute", "approve", "send": return true
    default: return false
    }
  }

  private func menuLabel(_ title: String, count: Int) -> String {
    count > 0 ? "\(title) · \(min(count, 99))" : title
  }
}
#endif
