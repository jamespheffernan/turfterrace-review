import SwiftUI

struct ReviewTargetsPanel: View {
  @ObservedObject var store: ReviewStore
  let item: ReviewItem

  @State private var feedbackDrafts: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeader(
        title: "Review items",
        subtitle: store.reviewTargetSummary.total == 0 ? nil : summaryText
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
          description: Text("No extracted yes/no items.")
        )
        .frame(maxWidth: .infinity)
      } else {
        VStack(spacing: 10) {
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
    "\(store.reviewTargetSummary.approved) yes, \(store.reviewTargetSummary.rejected) no, \(store.reviewTargetSummary.undecided) open"
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
  let onClear: () -> Void
  let onSaveFeedback: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: stateIcon)
          .foregroundStyle(stateColor)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 5) {
          Text(target.label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TurfTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
          BadgeText(stateTitle, color: stateColor)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Button(action: onApprove) {
          Label("Yes", systemImage: "checkmark")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(target.isApproved ? TurfTheme.moss : TurfTheme.accent)

        Button(action: onReject) {
          Label("No", systemImage: "xmark")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(target.isRejected ? TurfTheme.coral : TurfTheme.muted)

        Button(action: onClear) {
          Image(systemName: "arrow.uturn.left")
            .frame(width: 22)
        }
        .buttonStyle(.bordered)
        .tint(TurfTheme.muted)
        .accessibilityLabel("Clear item decision")
      }
      .disabled(isUpdating)

      if target.isRejected || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          TextField("Feedback", text: $feedback, axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .disabled(isUpdating)
          Button {
            onSaveFeedback()
          } label: {
            if isUpdating {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Save feedback", systemImage: "tray.and.arrow.down")
            }
          }
          .buttonStyle(.bordered)
          .disabled(isUpdating)
        }
      } else if isUpdating {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfPanel()
  }

  private var stateTitle: String {
    if target.isApproved { return "Yes" }
    if target.isRejected { return "No" }
    return "Open"
  }

  private var stateIcon: String {
    if target.isApproved { return "checkmark.circle.fill" }
    if target.isRejected { return "xmark.circle.fill" }
    return "circle"
  }

  private var stateColor: Color {
    if target.isApproved { return TurfTheme.moss }
    if target.isRejected { return TurfTheme.coral }
    return TurfTheme.gold
  }
}
