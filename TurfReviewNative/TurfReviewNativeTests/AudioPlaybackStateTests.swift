import XCTest
#if os(iOS)
import AVFoundation
#endif
#if os(macOS)
@testable import TurfReviewMac
#else
@testable import TurfReviewNative
#endif

final class AudioPlaybackStateTests: XCTestCase {
  #if os(iOS)
  func testPlaybackSessionIgnoresSilentMode() async throws {
    let session = AVAudioSession.sharedInstance()

    try await PlaybackAudioSession.activate()

    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .spokenAudio)
  }
  #endif

  func testReadyStatusIsCaseAndWhitespaceInsensitive() {
    let state = AudioPlaybackState(
      url: URL(string: "http://localhost:3457/audio/read.mp3"),
      status: " READY ",
      subtitle: nil
    )

    XCTAssertTrue(state.canPlay)
    XCTAssertEqual(state.presentation.label, "Ready")
    XCTAssertEqual(state.subtitleText, "Ready to play.")
  }

  func testReadyStatusWithoutURLIsAnActionableError() {
    let state = AudioPlaybackState(url: nil, status: "ready", subtitle: nil)

    XCTAssertFalse(state.canPlay)
    XCTAssertEqual(state.presentation.label, "Error")
    XCTAssertEqual(state.subtitleText, "The server marked audio ready, but no media file is available.")
  }
  func testMissingHostedAudioFallsBackToOnDeviceSpeech() {
    let state = AudioPlaybackState(
      url: nil,
      status: "missing",
      subtitle: nil,
      localSpeechAvailable: true
    )

    XCTAssertTrue(state.canPlay)
    XCTAssertTrue(state.usesLocalSpeech)
    XCTAssertEqual(state.presentation.label, "Ready")
    XCTAssertEqual(state.subtitleText, "Read aloud with an on-device voice.")
  }

  func testHostedAudioStillTakesPriorityOverOnDeviceSpeech() {
    let state = AudioPlaybackState(
      url: URL(string: "https://review.turfterrace.com/api/reviews/review-1/tts"),
      status: "ready",
      subtitle: nil,
      localSpeechAvailable: true
    )

    XCTAssertTrue(state.canPlay)
    XCTAssertFalse(state.usesLocalSpeech)
    XCTAssertEqual(state.subtitleText, "Ready to play.")
  }

  func testLocalSpeechExtractsReadableTextFromHTML() {
    let content = LocalSpeechContent(
      source: "<h1>Decision</h1><p>Ship &amp; verify.</p>",
      isHTML: true
    )
    let normalized = content.spokenText?.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    XCTAssertEqual(normalized, "Decision Ship & verify.")
  }

  func testHTMLReadAloudSplitsIntoSkippableParagraphs() throws {
    let content = LocalSpeechContent(
      source: "<h1>Decision</h1><p>Ship &amp; verify.</p><ul><li>First step</li><li>Second step</li></ul>",
      isHTML: true
    )
    let paragraphs = LocalSpeechPlayer.paragraphs(from: try XCTUnwrap(content.spokenText))

    XCTAssertEqual(paragraphs.first, "Decision")
    XCTAssertEqual(paragraphs.dropFirst().first, "Ship & verify.")
    XCTAssertEqual(paragraphs.count, 4)
    XCTAssertTrue(paragraphs[2].hasSuffix("First step"))
  }

  func testMarkdownReadAloudKeepsParagraphBreaksAndDropsMarkup() throws {
    let content = LocalSpeechContent(
      source: "# Decision\n\nShip **carefully**.\n\n- First step\n- Second step",
      isHTML: false
    )
    let paragraphs = LocalSpeechPlayer.paragraphs(from: try XCTUnwrap(content.spokenText))

    XCTAssertEqual(paragraphs, ["Decision", "Ship carefully.", "First step", "Second step"])
  }


  func testFailureStatusUsesClearErrorState() {
    let state = AudioPlaybackState(
      url: URL(string: "http://localhost:3457/audio/read.mp3"),
      status: "blocked_system",
      subtitle: nil
    )

    XCTAssertFalse(state.canPlay)
    XCTAssertEqual(state.presentation.label, "Error")
    XCTAssertEqual(state.subtitleText, "Audio could not be prepared.")
  }

  func testSubtitlePrefersTrimmedServerSummary() {
    let state = AudioPlaybackState(
      url: URL(string: "http://localhost:3457/audio/context.mp3"),
      status: "ready",
      subtitle: "  Context summary  "
    )

    XCTAssertEqual(state.subtitleText, "Context summary")
  }

  func testQueuedAudioUsesPreparingState() {
    let state = AudioPlaybackState(
      url: nil,
      status: "queued",
      subtitle: nil
    )

    XCTAssertFalse(state.canPlay)
    XCTAssertEqual(state.presentation.label, "Preparing")
    XCTAssertEqual(state.subtitleText, "Audio is being prepared.")
  }
}
