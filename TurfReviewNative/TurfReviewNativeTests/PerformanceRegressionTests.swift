import XCTest
#if os(macOS)
@testable import TurfReviewMac
#else
@testable import TurfReviewNative
#endif

final class ServerDateTests: XCTestCase {
  private static func formatterChain(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    func sqlite(_ format: String) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      return formatter
    }
    return fractional.date(from: trimmed)
      ?? plain.date(from: trimmed)
      ?? sqlite("yyyy-MM-dd HH:mm:ss").date(from: trimmed)
      ?? sqlite("yyyy-MM-dd HH:mm:ss.SSS").date(from: trimmed)
      ?? sqlite("yyyy-MM-dd").date(from: trimmed)
  }

  func testFastPathMatchesFormatterChain() {
    var generator = SystemRandomNumberGenerator()
    var samples = [
      "2024-02-29 12:00:00", "2023-02-29 12:00:00", "2026-09-22 23:59:59", "2026-09-22T23:59:59Z",
      "1970-01-01", "2000-12-31T00:00:00Z", "2026-09-22 24:00:00", "2026-13-01", "2026-09-22 12:00:00.123",
      "2026-09-22T12:00:00.123Z", " 2026-09-22 12:00:00 ", "garbage", "",
    ]
    for _ in 0..<2_000 {
      let year = Int.random(in: 1990...2099, using: &generator)
      let month = Int.random(in: 0...13, using: &generator)
      let day = Int.random(in: 0...32, using: &generator)
      let hour = Int.random(in: 0...24, using: &generator)
      let minute = Int.random(in: 0...60, using: &generator)
      let second = Int.random(in: 0...60, using: &generator)
      samples.append(String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second))
      samples.append(String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second))
      samples.append(String(format: "%04d-%02d-%02d", year, month, day))
      let millisecond = Int.random(in: 0...999, using: &generator)
      samples.append(String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, month, day, hour, minute, second, millisecond))
    }

    for sample in samples {
      XCTAssertEqual(ServerDate.parse(sample), Self.formatterChain(sample), sample)
    }
  }

  func testFastPathAcceptsOnlyStrictForms() {
    XCTAssertNotNil(ServerDate.fastParse("2026-09-22 13:35:17"))
    XCTAssertNotNil(ServerDate.fastParse("2026-09-22T13:35:17Z"))
    XCTAssertNotNil(ServerDate.fastParse("2026-09-22"))
    XCTAssertNotNil(ServerDate.fastParse("2026-09-17T16:54:47.183Z"))
    XCTAssertNil(ServerDate.fastParse("2026-09-22T13:35:17.12Z"))
    XCTAssertNil(ServerDate.fastParse("2026-09-22T13:35:17.1234Z"))
    XCTAssertNil(ServerDate.fastParse("2026-09-22 13:35:17.123"))
    XCTAssertNil(ServerDate.fastParse("2026-09-22T13:35:17+01:00"))
    XCTAssertNil(ServerDate.fastParse("2026-9-22"))
  }
}

final class SpeechVoiceChoiceTests: XCTestCase {
  private func voice(_ id: String, _ language: String, _ rank: Int, novelty: Bool = false) -> SpeechVoiceChoice.Candidate {
    .init(identifier: id, language: language, qualityRank: rank, isNovelty: novelty)
  }

  func testPrefersHighestQualityOverRegion() {
    let chosen = SpeechVoiceChoice.best(
      among: [voice("compact-gb", "en-GB", 1), voice("premium-us", "en-US", 3), voice("enhanced-gb", "en-GB", 2)],
      languageCode: "en", regionCode: "GB"
    )
    XCTAssertEqual(chosen?.identifier, "premium-us")
  }

  func testPrefersUsersRegionAtEqualQualityAndSkipsNoveltyAndOtherLanguages() {
    let chosen = SpeechVoiceChoice.best(
      among: [
        voice("premium-us", "en-US", 3), voice("premium-gb", "en-GB", 3),
        voice("novelty", "en-GB", 3, novelty: true), voice("premium-fr", "fr-FR", 3),
      ],
      languageCode: "en", regionCode: "GB"
    )
    XCTAssertEqual(chosen?.identifier, "premium-gb")
  }

  func testReturnsNilWithoutVoicesForLanguage() {
    XCTAssertNil(SpeechVoiceChoice.best(among: [voice("fr", "fr-FR", 3)], languageCode: "en", regionCode: "GB"))
  }
}
