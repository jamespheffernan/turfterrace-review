import AVFoundation
import Foundation
import SwiftUI

struct AudioPlayerBar: View {
  let title: String
  let subtitle: String?
  let url: URL?
  let status: String?
  let requestHeaders: [String: String]
  let localSpeechContent: LocalSpeechContent?

  @StateObject private var localSpeechPlayer = LocalSpeechPlayer()
  @State private var player: AVPlayer?
  @State private var isPlaying = false
  @State private var isPreparingPlayback = false
  @State private var playbackError: String?
  @State private var preparationTask: Task<Void, Never>?
  @State private var preparedMediaURL: URL?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    title: String,
    subtitle: String?,
    url: URL?,
    status: String?,
    requestHeaders: [String: String] = [:],
    localSpeechContent: LocalSpeechContent? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.url = url
    self.status = status
    self.requestHeaders = requestHeaders
    self.localSpeechContent = localSpeechContent
  }

  var body: some View {
    let playbackState = AudioPlaybackState(
      url: url,
      status: status,
      subtitle: subtitle,
      localSpeechAvailable: localSpeechContent?.isAvailable == true
    )
    let presentation = presentation(for: playbackState)

    HStack(spacing: TurfSpacing.m) {
      Button { toggle() } label: {
        Group {
          if isPreparingPlayback {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: isAnythingPlaying ? "pause.fill" : "play.fill")
              .font(.body.weight(.semibold))
              .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
          }
        }
        .frame(width: TurfSpacing.hitTarget, height: TurfSpacing.hitTarget)
        .foregroundStyle(TurfTheme.accent)
        .contentShape(Rectangle())
        .turfAnimation(TurfMotion.quick, value: isAnythingPlaying)
      }
      .buttonStyle(.plain)
      .disabled(!playbackState.canPlay || isPreparingPlayback)
      .accessibilityLabel(isAnythingPlaying ? "Pause \(title)" : "Play \(title)")
      VStack(alignment: .leading, spacing: TurfSpacing.stackTight) {
        Text(title).font(TurfType.control).foregroundStyle(TurfTheme.ink)
        if playbackError != nil || !playbackState.canPlay {
          Text(presentation.detail).font(TurfType.meta).foregroundStyle(TurfTheme.muted).lineLimit(2)
        } else {
          Text(playbackDescription(for: playbackState))
            .font(TurfType.meta).foregroundStyle(TurfTheme.muted)
        }
      }
      Spacer(minLength: 0)
      if playbackState.canPlay {
        if playbackState.usesLocalSpeech {
          skipButton("gobackward", label: "Previous paragraph", enabled: localSpeechPlayer.canSkipBack) {
            localSpeechPlayer.skipBack()
          }
          skipButton("goforward", label: "Next paragraph", enabled: localSpeechPlayer.canSkipAhead) {
            localSpeechPlayer.skipAhead()
          }
        } else {
          skipButton("gobackward.15", label: "Back 15 seconds", enabled: player != nil) { seek(by: -15) }
          skipButton("goforward.15", label: "Forward 15 seconds", enabled: player != nil) { seek(by: 15) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onDisappear {
      resetPlayer()
    }
    .onChange(of: url) { _, _ in
      resetPlayer()
    }
    .onChange(of: localSpeechContent) { _, _ in
      resetPlayer()
    }
    .onChange(of: status) { _, _ in
      resetPlayer()
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
      guard let endedItem = notification.object as? AVPlayerItem,
            endedItem === player?.currentItem else { return }
      player?.seek(to: .zero)
      isPlaying = false
    }
  }

  private func skipButton(
    _ symbol: String,
    label: String,
    enabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.body)
        .frame(width: TurfSpacing.hitTarget, height: TurfSpacing.hitTarget)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(enabled ? TurfTheme.ink : TurfTheme.faint)
    .disabled(!enabled)
    .accessibilityLabel(label)
  }

  private func seek(by seconds: Double) {
    guard let player else { return }
    var target = player.currentTime().seconds + seconds
    if let duration = player.currentItem?.duration.seconds, duration.isFinite {
      target = min(target, duration)
    }
    player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
  }

  private func presentation(for state: AudioPlaybackState) -> AudioPlaybackPresentation {
    if let playbackError {
      return AudioPlaybackPresentation(label: "Error", detail: playbackError, color: TurfTheme.destructive)
    }
    if isPreparingPlayback {
      return AudioPlaybackPresentation(label: "Preparing", detail: "Checking the audio stream…", color: TurfTheme.muted)
    }
    return state.presentation
  }
  private var isAnythingPlaying: Bool {
    isPlaying || localSpeechPlayer.isPlaying
  }

  private func playbackDescription(for state: AudioPlaybackState) -> String {
    if state.usesLocalSpeech {
      return localSpeechPlayer.isPlaying ? "Speaking" : "On-device voice"
    }
    if isPlaying { return "Playing" }
    return url?.isFileURL == true ? "Downloaded" : "Listen"
  }

  private func toggle() {
    let playbackState = AudioPlaybackState(
      url: url,
      status: status,
      subtitle: subtitle,
      localSpeechAvailable: localSpeechContent?.isAvailable == true
    )
    guard playbackState.canPlay else { return }
    if playbackState.usesLocalSpeech {
      toggleLocalSpeech()
      return
    }
    guard let url else { return }
    if isPlaying {
      player?.pause()
      isPlaying = false
      return
    }

    if let player {
      player.play()
      isPlaying = true
      return
    }
    preparationTask?.cancel()
    isPreparingPlayback = true
    playbackError = nil
    preparationTask = Task { @MainActor in
      var downloadedMediaURL: URL?
      defer {
        if let downloadedMediaURL {
          try? FileManager.default.removeItem(at: downloadedMediaURL)
        }
        isPreparingPlayback = false
        preparationTask = nil
      }
      do {
        #if os(iOS)
        try await PlaybackAudioSession.activate()
        #endif
        try Task.checkCancellation()
        let playbackURL: URL
        if url.isFileURL || requestHeaders.isEmpty {
          playbackURL = url
        } else {
          let downloadedURL = try await downloadAuthenticatedMedia(from: url)
          downloadedMediaURL = downloadedURL
          playbackURL = downloadedURL
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: playbackURL)
        guard try await asset.load(.isPlayable) else {
          throw AudioPlaybackError.notPlayable
        }
        try Task.checkCancellation()
        if let preparedMediaURL {
          try? FileManager.default.removeItem(at: preparedMediaURL)
        }
        preparedMediaURL = downloadedMediaURL
        downloadedMediaURL = nil
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        player.play()
        isPlaying = true
      } catch is CancellationError {
        return
      } catch {
        player = nil
        isPlaying = false
        playbackError = "Audio could not load. Check the connection and try again."
      }
    }
  }
  private func toggleLocalSpeech() {
    if localSpeechPlayer.hasActiveUtterance {
      localSpeechPlayer.toggle()
      return
    }
    guard let localSpeechContent else { return }

    preparationTask?.cancel()
    isPreparingPlayback = true
    playbackError = nil
    preparationTask = Task { @MainActor in
      defer {
        isPreparingPlayback = false
        preparationTask = nil
      }
      do {
        #if os(iOS)
        try await PlaybackAudioSession.activate()
        #endif
        try Task.checkCancellation()
        guard let text = localSpeechContent.spokenText else {
          throw AudioPlaybackError.noReadableText
        }
        try Task.checkCancellation()
        player?.pause()
        player = nil
        isPlaying = false
        localSpeechPlayer.speak(text)
      } catch is CancellationError {
        return
      } catch {
        playbackError = "This review does not contain readable text."
      }
    }
  }


  private func downloadAuthenticatedMedia(from url: URL) async throws -> URL {
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    for (header, value) in requestHeaders {
      request.setValue(value, forHTTPHeaderField: header)
    }

    let (downloadURL, response) = try await URLSession.shared.download(for: request)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
      throw AudioPlaybackError.notPlayable
    }

    let suggestedExtension = response.suggestedFilename.flatMap { filename -> String? in
      let pathExtension = URL(fileURLWithPath: filename).pathExtension
      return pathExtension.isEmpty ? nil : pathExtension
    }
    let fallbackExtension = url.pathExtension.isEmpty ? "audio" : url.pathExtension
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("turf-review-audio-\(UUID().uuidString)")
      .appendingPathExtension(suggestedExtension ?? fallbackExtension)
    try FileManager.default.moveItem(at: downloadURL, to: destination)
    return destination
  }

  private func resetPlayer() {
    preparationTask?.cancel()
    preparationTask = nil
    player?.pause()
    player = nil
    localSpeechPlayer.stop()
    isPlaying = false
    isPreparingPlayback = false
    if let preparedMediaURL {
      try? FileManager.default.removeItem(at: preparedMediaURL)
      self.preparedMediaURL = nil
    }
    playbackError = nil
  }
}

enum PlaybackAudioSession {
  #if os(iOS)
  static func activate() async throws {
    try await Task.detached(priority: .userInitiated) {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio)
      try session.setActive(true)
    }.value
  }
  #endif
}

struct AudioPlaybackPresentation: Equatable {
  let label: String
  let detail: String
  let color: Color
}

struct AudioPlaybackState: Equatable {
  let url: URL?
  let status: String?
  let subtitle: String?
  let localSpeechAvailable: Bool
  init(
    url: URL?,
    status: String?,
    subtitle: String?,
    localSpeechAvailable: Bool = false
  ) {
    self.url = url
    self.status = status
    self.subtitle = subtitle
    self.localSpeechAvailable = localSpeechAvailable
  }


  var remoteAudioAvailable: Bool {
    url != nil && normalizedStatus == "ready"
  }

  var usesLocalSpeech: Bool {
    !remoteAudioAvailable && localSpeechAvailable
  }

  var canPlay: Bool {
    remoteAudioAvailable || localSpeechAvailable
  }

  var subtitleText: String {
    presentation.detail
  }

  var presentation: AudioPlaybackPresentation {
    if usesLocalSpeech {
      return AudioPlaybackPresentation(
        label: "Ready",
        detail: "Read aloud with an on-device voice.",
        color: TurfTheme.accent
      )
    }
    if normalizedStatus == "ready", url == nil {
      return AudioPlaybackPresentation(
        label: "Error",
        detail: "The server marked audio ready, but no media file is available.",
        color: TurfTheme.destructive
      )
    }
    if normalizedStatus == "ready" {
      return AudioPlaybackPresentation(
        label: "Ready",
        detail: trimmedSubtitle ?? "Ready to play.",
        color: TurfTheme.accent
      )
    }
    if ["pending", "queued", "generating", "processing", "preparing"].contains(normalizedStatus ?? "") {
      return AudioPlaybackPresentation(
        label: "Preparing",
        detail: trimmedSubtitle ?? "Audio is being prepared.",
        color: TurfTheme.muted
      )
    }
    if ["error", "failed", "blocked", "blocked_system"].contains(normalizedStatus ?? "") {
      return AudioPlaybackPresentation(
        label: "Error",
        detail: trimmedSubtitle ?? "Audio could not be prepared.",
        color: TurfTheme.destructive
      )
    }
    return AudioPlaybackPresentation(
      label: "Unavailable",
      detail: trimmedSubtitle ?? "No audio is available for this review.",
      color: TurfTheme.muted
    )
  }

  private var trimmedSubtitle: String? {
    subtitle?.trimmedNonEmpty
  }

  private var normalizedStatus: String? {
    status?.trimmedNonEmpty?.lowercased()
  }
}

struct LocalSpeechContent: Equatable {
  let source: String
  let isHTML: Bool

  var isAvailable: Bool {
    source.trimmedNonEmpty != nil
  }

  var spokenText: String? {
    guard let source = source.trimmedNonEmpty else { return nil }
    if !isHTML {
      // Parse line by line so paragraph breaks survive; read-aloud skips by paragraph.
      let lines = source.components(separatedBy: .newlines).compactMap { line -> String? in
        let spoken = (try? AttributedString(markdown: line)).map { String($0.characters) } ?? line
        return spoken.trimmedNonEmpty
      }
      return lines.joined(separator: "\n").trimmedNonEmpty
    }
    guard let data = source.data(using: .utf8),
          let attributed = try? NSAttributedString(
            data: data,
            options: [
              .documentType: NSAttributedString.DocumentType.html,
              .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
          ) else {
      return nil
    }
    return attributed.string.trimmedNonEmpty
  }
}

/// Reads a document one paragraph per utterance, so the listener can skip back and ahead.
@MainActor
final class LocalSpeechPlayer: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
  @Published private(set) var isPlaying = false
  /// True from the first `speak` until the document finishes or is stopped, including while paused.
  @Published private(set) var isActive = false

  private let synthesizer = AVSpeechSynthesizer()
  private var paragraphs: [String] = []
  private var currentIndex = 0
  /// Each skip queues a new generation; callbacks from cancelled generations are ignored.
  private var generation = 0
  private var queued: [ObjectIdentifier: (generation: Int, index: Int)] = [:]
  private var voice: AVSpeechSynthesisVoice?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  var hasActiveUtterance: Bool {
    synthesizer.isSpeaking || synthesizer.isPaused
  }

  var canSkipBack: Bool { isActive }
  var canSkipAhead: Bool { isActive && currentIndex + 1 < paragraphs.count }

  func speak(_ text: String) {
    paragraphs = Self.paragraphs(from: text)
    guard !paragraphs.isEmpty else { return }
    voice = SpeechVoiceChoice.bestVoice(for: Locale.autoupdatingCurrent)
    play(from: 0)
  }

  func toggle() {
    if synthesizer.isPaused {
      synthesizer.continueSpeaking()
      isPlaying = true
    } else if synthesizer.isSpeaking {
      synthesizer.pauseSpeaking(at: .word)
      isPlaying = false
    }
  }

  /// Restarts the previous paragraph, or the first one when already at the start.
  func skipBack() {
    guard isActive else { return }
    play(from: max(0, currentIndex - 1))
  }

  func skipAhead() {
    guard canSkipAhead else { return }
    play(from: currentIndex + 1)
  }

  func stop() {
    generation += 1
    queued.removeAll()
    if hasActiveUtterance {
      synthesizer.stopSpeaking(at: .immediate)
    }
    isPlaying = false
    isActive = false
  }

  private func play(from index: Int) {
    generation += 1
    queued.removeAll()
    if hasActiveUtterance {
      synthesizer.stopSpeaking(at: .immediate)
    }
    currentIndex = index
    for paragraphIndex in index..<paragraphs.count {
      let utterance = AVSpeechUtterance(string: paragraphs[paragraphIndex])
      utterance.voice = voice
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate
      queued[ObjectIdentifier(utterance)] = (generation, paragraphIndex)
      synthesizer.speak(utterance)
    }
    isActive = true
    isPlaying = true
  }

  /// Splits spoken text on line breaks; each non-empty line is one skippable paragraph.
  nonisolated static func paragraphs(from text: String) -> [String] {
    text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func isCurrent(_ utterance: AVSpeechUtterance) -> (generation: Int, index: Int)? {
    guard let entry = queued[ObjectIdentifier(utterance)], entry.generation == generation else { return nil }
    return entry
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    guard let entry = isCurrent(utterance) else { return }
    currentIndex = entry.index
    isPlaying = true
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
    guard isCurrent(utterance) != nil else { return }
    isPlaying = false
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
    guard isCurrent(utterance) != nil else { return }
    isPlaying = true
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard let entry = isCurrent(utterance) else { return }
    queued[ObjectIdentifier(utterance)] = nil
    if entry.index == paragraphs.count - 1 {
      isPlaying = false
      isActive = false
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    guard isCurrent(utterance) != nil else { return }
    isPlaying = false
    isActive = false
  }
}

private enum AudioPlaybackError: Error {
  case notPlayable
  case noReadableText
}

private extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Chooses the most natural installed voice for read-aloud. Asking for a voice by language alone
/// returns the compact voice; Enhanced and Premium voices sound far better once downloaded in
/// Settings > Accessibility > Read & Speak > Voices (named Spoken Content before iOS 26).
enum SpeechVoiceChoice {
  struct Candidate: Equatable {
    let identifier: String
    let language: String
    let qualityRank: Int
    let isNovelty: Bool
  }

  static func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let candidates = voices.map { voice in
      Candidate(
        identifier: voice.identifier,
        language: voice.language,
        qualityRank: qualityRank(voice.quality),
        isNovelty: voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice)
      )
    }
    guard let chosen = best(
      among: candidates,
      languageCode: locale.language.languageCode?.identifier ?? "en",
      regionCode: locale.region?.identifier
    ) else {
      return AVSpeechSynthesisVoice(language: "en-GB")
    }
    return AVSpeechSynthesisVoice(identifier: chosen.identifier)
  }

  /// Highest quality first, then the user's region, then British English for English readers.
  static func best(among candidates: [Candidate], languageCode: String, regionCode: String?) -> Candidate? {
    let language = languageCode.lowercased()
    let preferredTag = regionCode.map { "\(language)-\($0.uppercased())" }
    let fallbackTag = language == "en" ? "en-GB" : nil
    func score(_ candidate: Candidate) -> Int {
      var value = candidate.qualityRank * 10
      if candidate.language == preferredTag { value += 2 } else if candidate.language == fallbackTag { value += 1 }
      return value
    }
    return candidates
      .filter { !$0.isNovelty && $0.language.lowercased().hasPrefix(language + "-") }
      .max { left, right in
        let leftScore = score(left), rightScore = score(right)
        return leftScore == rightScore ? left.identifier > right.identifier : leftScore < rightScore
      }
  }

  private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
    switch quality {
    case .premium: return 3
    case .enhanced: return 2
    default: return 1
    }
  }
}
