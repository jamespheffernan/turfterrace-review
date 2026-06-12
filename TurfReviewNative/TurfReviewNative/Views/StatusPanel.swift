import SwiftUI

struct StatusPanel: View {
  @ObservedObject var store: ReviewStore
  let item: ReviewItem

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeader(title: "Proof and playback", subtitle: "Track downstream request state, retry blocked work, and play generated audio.")

      VStack(spacing: 10) {
        AudioPlayerBar(
          title: "Read aloud",
          subtitle: nil,
          url: store.absoluteAudioURL(store.ttsStatus?.url),
          status: store.ttsStatus?.status ?? item.ttsStatus
        )
        AudioPlayerBar(
          title: "Context memo",
          subtitle: store.contextStatus?.summary ?? item.contextSummary,
          url: store.absoluteAudioURL(store.contextStatus?.url),
          status: store.contextStatus?.status ?? item.contextStatus
        )
      }

      if let message = item.effectiveActionMessage {
        VStack(alignment: .leading, spacing: 6) {
          Text(ReviewDisplayText.statusLabel(item.effectiveActionStatus ?? "action"))
            .font(.caption.weight(.bold))
            .foregroundStyle(TurfTheme.statusColor(item.effectiveActionStatus ?? ""))
          Text(message)
            .font(.body)
            .foregroundStyle(TurfTheme.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .turfPanel()
      }

      if needsRetry {
        Button {
          Task { await retry() }
        } label: {
          HStack {
            if isRetrying {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise.circle.fill")
            }
            Text("Retry latest action")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRetrying)
      }

      if store.decisionRequests.isEmpty && store.legacyActions.isEmpty && store.decisionFollowups.isEmpty {
        ContentUnavailableView(
          "No downstream requests",
          systemImage: "checkmark.seal",
          description: Text("This review has no pending proof work.")
        )
      } else {
        VStack(spacing: 10) {
          ForEach(store.decisionRequests) { request in
            DecisionRequestRow(request: request) { confirmationSlug in
              Task { await store.openConfirmationReview(slug: confirmationSlug) }
            }
          }
          ForEach(store.legacyActions) { action in
            LegacyActionRow(action: action)
          }
          ForEach(store.decisionFollowups) { followup in
            FollowupReviewRow(
              followup: followup,
              url: store.absoluteFollowupURL(followup.url),
              openInNative: {
                Task { await store.openFollowupReview(followup) }
              }
            )
          }
        }
      }
    }
  }

  private var needsRetry: Bool {
    DownstreamRetryState.needsRetry(
      itemStatus: item.effectiveActionStatus,
      decisionRequests: store.decisionRequests,
      legacyActions: store.legacyActions
    )
  }

  private var isRetrying: Bool {
    store.isRetryingAction(slug: item.slug)
  }

  private func retry() async {
    guard !isRetrying else { return }
    await store.retryLatestAction(for: item.slug)
  }
}

struct DecisionRequestRow: View {
  let request: DecisionRequest
  let openConfirmation: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        BadgeText(ReviewDisplayText.statusLabel(request.status), color: TurfTheme.statusColor(request.status))
        BadgeText(ReviewDisplayText.kindLabel(request.kind), color: TurfTheme.plum)
        Spacer()
      }
      Text(request.summary)
        .font(.callout)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      if let confirmationSlug = trimmedConfirmationSlug {
        Button {
          openConfirmation(confirmationSlug)
        } label: {
          Label("Open \(confirmationSlug)", systemImage: "arrow.right.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(TurfTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open confirmation review \(confirmationSlug)")
      }
      if let proofSummary = request.proofSummary {
        Label(proofSummary, systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(TurfTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let lastError = request.lastError {
        Text(lastError)
          .font(.caption)
          .foregroundStyle(TurfTheme.coral)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfPanel()
  }

  private var trimmedConfirmationSlug: String? {
    guard let confirmationSlug = request.confirmationSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
          !confirmationSlug.isEmpty else { return nil }
    return confirmationSlug
  }
}

struct FollowupReviewRow: View {
  let followup: DecisionResponse.FollowupSummary
  let url: URL?
  let openInNative: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Button(action: openInNative) {
        rowContent
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      .accessibilityLabel("Open follow-up review \(followup.title)")

      if let url {
        Link(destination: url) {
          Image(systemName: "safari")
            .font(.caption.weight(.bold))
            .frame(width: 34, height: 34)
            .foregroundStyle(TurfTheme.accent)
            .background(TurfTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TurfTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open follow-up review in browser")
      }
    }
  }

  private var rowContent: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        BadgeText("Follow-Up Review", color: TurfTheme.accent)
        Spacer()
        Image(systemName: "arrow.right.circle.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(TurfTheme.accent)
      }
      Text(followup.title)
        .font(.callout)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Label(followup.slug, systemImage: "doc.text.magnifyingglass")
        .font(.caption)
        .foregroundStyle(TurfTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfPanel()
  }
}

struct LegacyActionRow: View {
  let action: LegacyAction

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        BadgeText(ReviewDisplayText.statusLabel(action.status), color: TurfTheme.statusColor(action.status))
        BadgeText(ReviewDisplayText.actionLabel(action.decision), color: TurfTheme.muted)
        Spacer()
      }
      if let error = action.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(TurfTheme.coral)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfPanel()
  }
}
