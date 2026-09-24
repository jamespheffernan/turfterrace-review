import SwiftUI

struct ReviewTargetsPanel: View {
  let store: ReviewStore
  let item: ReviewItem

  @State private var feedbackDrafts: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.sectionGap) {
      SectionHeader(
        title: "Review items",
        subtitle: store.reviewTargetSummary.total == 0 ? nil : summaryText,
        subtitleIsCount: true
      )

      if store.reviewTargets.isEmpty, let loadError = store.reviewTargetLoadError {
        ContentUnavailableView(
          "Review items did not load",
          systemImage: "exclamationmark.triangle",
          description: Text(loadError)
        )
        .frame(maxWidth: .infinity)
      } else if store.reviewTargets.isEmpty {
        ContentUnavailableView(
          "No review items",
          systemImage: "checklist",
          description: Text("This review has no item-level decisions.")
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(spacing: TurfSpacing.cardGap) {
          ForEach(store.reviewTargets) { target in
            ReviewTargetRow(
              target: target,
              feedback: feedbackBinding(for: target),
              isUpdating: store.isUpdatingReviewTarget(target),
              onApprove: {
                Task {
                  feedbackDrafts[target.key] = ""
                  await store.updateReviewTarget(target, for: item.slug, verdict: "approved", feedback: nil)
                }
              },
              onReject: {
                Task {
                  await store.updateReviewTarget(
                    target,
                    for: item.slug,
                    verdict: "rejected",
                    feedback: feedbackDrafts[target.key]
                  )
                }
              },
              onChoice: { value in
                Task {
                  feedbackDrafts[target.key] = ""
                  await store.updateReviewTarget(target, for: item.slug, verdict: "choice:\(value)", feedback: nil)
                }
              },
              onClear: {
                Task {
                  feedbackDrafts[target.key] = ""
                  await store.updateReviewTarget(target, for: item.slug, verdict: "unset", feedback: nil)
                }
              },
              onSaveFeedback: {
                Task {
                  await store.updateReviewTarget(
                    target,
                    for: item.slug,
                    verdict: "rejected",
                    feedback: feedbackDrafts[target.key]
                  )
                }
              }
            )
          }
        }
      }
    }
    .onAppear(perform: seedFeedbackDrafts)
    .onChange(of: store.reviewTargets) { _, _ in
      seedFeedbackDrafts()
    }
    .onChange(of: item.slug) { _, _ in
      feedbackDrafts = [:]
      seedFeedbackDrafts()
    }
  }

  private var summaryText: String {
    "\(store.reviewTargetSummary.decided) decided, \(store.reviewTargetSummary.undecided) open"
  }

  private func feedbackBinding(for target: ReviewTarget) -> Binding<String> {
    Binding(
      get: {
        feedbackDrafts[target.key] ?? target.feedback ?? ""
      },
      set: { value in
        feedbackDrafts[target.key] = value
      }
    )
  }

  private func seedFeedbackDrafts() {
    let activeKeys = Set(store.reviewTargets.map(\.key))
    feedbackDrafts = feedbackDrafts.filter { activeKeys.contains($0.key) }
    for target in store.reviewTargets where feedbackDrafts[target.key] == nil {
      feedbackDrafts[target.key] = target.feedback ?? ""
    }
  }
}

private struct ReviewTargetRow: View {
  let target: ReviewTarget
  @Binding var feedback: String
  let isUpdating: Bool
  let onApprove: () -> Void
  let onReject: () -> Void
  let onChoice: (String) -> Void
  let onClear: () -> Void
  let onSaveFeedback: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFeedbackFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.m) {
      HStack(alignment: .firstTextBaseline, spacing: TurfSpacing.s) {
        Image(systemName: stateIcon)
          .font(TurfType.rowTitle)
          .foregroundStyle(stateColor)
          .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
          .frame(width: TurfSpacing.xl)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
          Text(target.label)
            .font(TurfType.rowTitle)
            .foregroundStyle(TurfTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text(stateTitle)
            .font(TurfType.meta)
            .foregroundStyle(TurfTheme.muted)
            .contentTransition(.opacity)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .turfAnimation(TurfMotion.quick, value: target.verdict)

      VStack(alignment: .leading, spacing: TurfSpacing.controlGap) {
        if target.isChoice, let options = target.options {
          ForEach(options) { option in
            let isChosen = target.selectedOption?.value == option.value
            Button {
              onChoice(option.value)
            } label: {
              Text(option.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.turfTinted(isChosen ? .accent : .neutral, fullWidth: true))
            .accessibilityAddTraits(isChosen ? .isSelected : [])
          }
        } else {
          HStack(spacing: TurfSpacing.controlGap) {
            Button(action: onApprove) {
              Label("Approve", systemImage: "checkmark")
            }
            .buttonStyle(.turfTinted(target.isApproved ? .accent : .neutral, fullWidth: true))
            .accessibilityAddTraits(target.isApproved ? .isSelected : [])

            Button(action: onReject) {
              Label("Reject", systemImage: "xmark")
            }
            .buttonStyle(.turfTinted(target.isRejected ? .destructive : .neutral, fullWidth: true))
            .accessibilityAddTraits(target.isRejected ? .isSelected : [])
          }
        }

        if !target.isUnset {
          Button(action: onClear) {
            Label("Change decision", systemImage: "arrow.uturn.left")
              .font(TurfType.control)
              .foregroundStyle(TurfTheme.accent)
              .frame(minHeight: TurfSpacing.hitTarget)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Reset review item state")
          .transition(.opacity)
        }
      }
      .disabled(isUpdating)
      .turfAnimation(TurfMotion.quick, value: target.verdict)

      if showsFeedback {
        VStack(alignment: .leading, spacing: TurfSpacing.s) {
          TextField("Feedback", text: $feedback, axis: .vertical)
            .font(TurfType.body)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .focused($isFeedbackFocused)
            .padding(.horizontal, TurfSpacing.m)
            .padding(.vertical, TurfSpacing.s)
            .frame(minHeight: TurfSpacing.hitTarget)
            .turfField(isFocused: isFeedbackFocused)
            .disabled(isUpdating)
          Button {
            onSaveFeedback()
          } label: {
            if isUpdating {
              ProgressView()
                .controlSize(.small)
                .tint(TurfTheme.accent)
            } else {
              Label {
                Text("Save feedback")
              } icon: {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(TurfTheme.accent)
              }
            }
          }
          .buttonStyle(.turfTinted(.neutral))
          .disabled(isUpdating)
        }
        .transition(.turfLift(reduceMotion: reduceMotion))
      } else if isUpdating {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfCard()
    .turfAnimation(TurfMotion.content, value: showsFeedback)
  }

  private var showsFeedback: Bool {
    target.isRejected || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var stateTitle: String {
    if let selected = target.selectedOption { return selected.label }
    if target.isApproved { return "Approved" }
    if target.isRejected { return "Rejected" }
    return "Open"
  }

  private var stateIcon: String {
    if target.selectedOption != nil { return "checkmark.circle.fill" }
    if target.isApproved { return "checkmark.circle.fill" }
    if target.isRejected { return "xmark.circle.fill" }
    return "circle"
  }

  private var stateColor: Color {
    if target.selectedOption != nil { return TurfTheme.accent }
    if target.isApproved { return TurfTheme.accent }
    if target.isRejected { return TurfTheme.destructive }
    return TurfTheme.attention
  }
}
