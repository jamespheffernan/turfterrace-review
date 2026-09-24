import SwiftUI

struct StatusPanel: View {
  let store: ReviewStore
  let item: ReviewItem

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.sectionGap) {
      SectionHeader(title: "Proof and playback", subtitle: "Track downstream request state, retry blocked work, and play generated audio.")

      VStack(alignment: .leading, spacing: TurfSpacing.cardGap) {
        VStack(spacing: 0) {
          AudioPlayerBar(
            title: "Audio briefing",
            subtitle: store.contextStatus?.summary ?? item.contextSummary,
            url: store.absoluteAudioURL(store.contextStatus?.url),
            status: store.contextStatus?.status ?? item.contextStatus
          )
          .padding(.vertical, TurfSpacing.s)
          Divider()
            .padding(.leading, TurfSpacing.hitTarget + TurfSpacing.m)
          AudioPlayerBar(
            title: "Read aloud",
            subtitle: nil,
            url: store.absoluteAudioURL(store.ttsStatus?.url),
            status: store.ttsStatus?.status ?? item.ttsStatus
          )
          .padding(.vertical, TurfSpacing.s)
        }
        .padding(.horizontal, TurfSpacing.xs)
        .turfCard(padding: nil)

        if let message = item.effectiveActionMessage {
          VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
            Text(ReviewDisplayText.statusLabel(item.effectiveActionStatus ?? "action"))
              .font(TurfType.metaStrong)
              .foregroundStyle(TurfTheme.statusTone(item.effectiveActionStatus ?? "").text)
            Text(message)
              .font(TurfType.body)
              .foregroundStyle(TurfTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .turfCard()
        }
      }

      if needsRetry {
        Button {
          Task { await retry() }
        } label: {
          Label {
            Text("Retry latest action")
          } icon: {
            if isRetrying {
              ProgressView()
                .controlSize(.small)
                .tint(TurfTheme.onAccent)
            } else {
              Image(systemName: "arrow.clockwise.circle.fill")
            }
          }
          .contentTransition(.opacity)
          .turfAnimation(TurfMotion.quick, value: isRetrying)
        }
        .buttonStyle(.turfFilled(.accent, fullWidth: true))
        .disabled(isRetrying)
      }

      if store.decisionRequests.isEmpty && store.legacyActions.isEmpty && store.decisionFollowups.isEmpty {
        ContentUnavailableView(
          "No downstream requests",
          systemImage: "checkmark.seal",
          description: Text("This review has no pending proof work.")
        )
      } else {
        VStack(spacing: TurfSpacing.cardGap) {
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
    VStack(alignment: .leading, spacing: TurfSpacing.s) {
      HStack(spacing: TurfSpacing.controlGap) {
        BadgeText(ReviewDisplayText.statusLabel(request.status), tone: TurfTheme.statusTone(request.status))
        BadgeText(ReviewDisplayText.kindLabel(request.kind), tone: .neutral)
        Spacer(minLength: 0)
      }
      Text(request.summary)
        .font(TurfType.body)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      if let confirmationSlug = trimmedConfirmationSlug {
        Button {
          openConfirmation(confirmationSlug)
        } label: {
          Label("Open \(confirmationSlug)", systemImage: "arrow.right.circle.fill")
            .font(TurfType.control)
            .foregroundStyle(TurfTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: TurfSpacing.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open confirmation review \(confirmationSlug)")
      }
      if let proofSummary = request.proofSummary {
        Label(proofSummary, systemImage: "checkmark.seal")
          .font(TurfType.caption)
          .foregroundStyle(TurfTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let lastError = request.lastError {
        Text(lastError)
          .font(TurfType.caption)
          .foregroundStyle(TurfTheme.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfCard()
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
    HStack(alignment: .top, spacing: TurfSpacing.s) {
      Button(action: openInNative) {
        rowContent
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      .accessibilityLabel("Open follow-up review \(followup.title)")

      if let url {
        Link(destination: url) {
          Image(systemName: "safari")
            .font(TurfType.body)
            .foregroundStyle(TurfTheme.accent)
            .frame(width: TurfSpacing.hitTarget, height: TurfSpacing.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The 44pt target overhangs the card's top-trailing padding so the glyph sits on the card's inner edge.
        .padding(.top, -TurfSpacing.m)
        .padding(.trailing, -TurfSpacing.m)
        .accessibilityLabel("Open follow-up review in browser")
      }
    }
    .turfCard()
  }

  private var rowContent: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.s) {
      HStack(spacing: TurfSpacing.controlGap) {
        BadgeText("Follow-Up Review", tone: .neutral)
        Spacer(minLength: 0)
        Image(systemName: "arrow.right.circle.fill")
          .font(TurfType.metaStrong)
          .foregroundStyle(TurfTheme.accent)
          .accessibilityHidden(true)
      }
      Text(followup.title)
        .font(TurfType.body)
        .foregroundStyle(TurfTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Label(followup.slug, systemImage: "doc.text.magnifyingglass")
        .font(TurfType.caption)
        .foregroundStyle(TurfTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct LegacyActionRow: View {
  let action: LegacyAction

  var body: some View {
    VStack(alignment: .leading, spacing: TurfSpacing.s) {
      HStack(spacing: TurfSpacing.controlGap) {
        BadgeText(ReviewDisplayText.statusLabel(action.status), tone: TurfTheme.statusTone(action.status))
        BadgeText(ReviewDisplayText.actionLabel(action.decision), tone: .neutral)
        Spacer(minLength: 0)
      }
      if let error = action.lastError {
        Text(error)
          .font(TurfType.caption)
          .foregroundStyle(TurfTheme.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .turfCard()
  }
}
