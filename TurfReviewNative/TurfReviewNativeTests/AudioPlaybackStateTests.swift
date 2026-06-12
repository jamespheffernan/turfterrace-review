import XCTest
@testable import TurfReviewNative

final class AudioPlaybackStateTests: XCTestCase {
  func testReadyStatusIsCaseAndWhitespaceInsensitive() {
    let state = AudioPlaybackState(
      url: URL(string: "http://localhost:3457/audio/read.mp3"),
      status: " READY ",
      subtitle: nil
    )

    XCTAssertTrue(state.canPlay)
    XCTAssertEqual(state.subtitleText, "Ready")
  }

  func testReadyStatusStillRequiresURL() {
    let state = AudioPlaybackState(url: nil, status: "ready", subtitle: nil)

    XCTAssertFalse(state.canPlay)
    XCTAssertEqual(state.subtitleText, "Ready")
  }

  func testSubtitleFallsBackToReadableStatus() {
    let state = AudioPlaybackState(
      url: URL(string: "http://localhost:3457/audio/read.mp3"),
      status: "blocked_system",
      subtitle: nil
    )

    XCTAssertFalse(state.canPlay)
    XCTAssertEqual(state.subtitleText, "Blocked System")
  }

  func testSubtitlePrefersTrimmedServerSummary() {
    let state = AudioPlaybackState(
      url: URL(string: "http://localhost:3457/audio/context.mp3"),
      status: "ready",
      subtitle: "  Context summary  "
    )

    XCTAssertEqual(state.subtitleText, "Context summary")
  }
}
