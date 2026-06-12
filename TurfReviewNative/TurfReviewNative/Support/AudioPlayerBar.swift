import AVFoundation
import SwiftUI

struct AudioPlayerBar: View {
  let title: String
  let subtitle: String?
  let url: URL?
  let status: String?

  @State private var player: AVPlayer?
  @State private var isPlaying = false

  var body: some View {
    let playbackState = AudioPlaybackState(url: url, status: status, subtitle: subtitle)

    HStack(spacing: 12) {
      Button {
        toggle()
      } label: {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 14, weight: .bold))
          .frame(width: 34, height: 34)
          .foregroundStyle(.white)
          .background(playbackState.canPlay ? TurfTheme.accent : TurfTheme.muted)
          .clipShape(Circle())
      }
      .disabled(!playbackState.canPlay)
      .accessibilityLabel(isPlaying ? "Pause \(title)" : "Play \(title)")

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(TurfTheme.ink)
        Text(playbackState.subtitleText)
          .font(.caption)
          .foregroundStyle(TurfTheme.muted)
          .lineLimit(2)
      }

      Spacer(minLength: 0)
    }
    .padding(10)
    .background(TurfTheme.paper.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onDisappear {
      resetPlayer()
    }
    .onChange(of: url) { _, _ in
      resetPlayer()
    }
    .onChange(of: status) { _, _ in
      if !AudioPlaybackState(url: url, status: status, subtitle: subtitle).canPlay {
        resetPlayer()
      }
    }
  }

  private func toggle() {
    guard let url, AudioPlaybackState(url: url, status: status, subtitle: subtitle).canPlay else { return }
    if player == nil {
      player = AVPlayer(url: url)
    }

    if isPlaying {
      player?.pause()
      isPlaying = false
    } else {
      player?.play()
      isPlaying = true
    }
  }

  private func resetPlayer() {
    player?.pause()
    player = nil
    isPlaying = false
  }
}

struct AudioPlaybackState: Equatable {
  let url: URL?
  let status: String?
  let subtitle: String?

  var canPlay: Bool {
    url != nil && normalizedStatus == "ready"
  }

  var subtitleText: String {
    if let trimmedSubtitle = subtitle?.trimmedNonEmpty {
      return trimmedSubtitle
    }
    guard let normalizedStatus else {
      return "Unavailable"
    }
    if normalizedStatus == "ready" {
      return "Ready"
    }
    return ReviewDisplayText.statusLabel(normalizedStatus)
  }

  private var normalizedStatus: String? {
    status?.trimmedNonEmpty?.lowercased()
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
