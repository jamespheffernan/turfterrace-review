import XCTest
#if os(macOS)
@testable import TurfReviewMac
#else
@testable import TurfReviewNative
#endif

final class ReviewDeepLinkTests: XCTestCase {
  private let serverURL = URL(string: "https://review.turfterrace.com")!

  func testParsesPublicReviewLink() {
    let url = URL(string: "https://review.turfterrace.com/review/launch-plan-123?return=pending#notes")!

    XCTAssertEqual(ReviewDeepLink(url: url, configuredServerURL: serverURL)?.slug, "launch-plan-123")
  }

  func testParsesReviewLinkForConfiguredLocalServer() {
    let localServerURL = URL(string: "http://127.0.0.1:3457")!
    let url = URL(string: "http://127.0.0.1:3457/review/local-item")!

    XCTAssertEqual(ReviewDeepLink(url: url, configuredServerURL: localServerURL)?.slug, "local-item")
  }

  func testParsesCustomReviewLink() {
    let url = URL(string: "turf-review://review/launch-plan-123")!

    XCTAssertEqual(ReviewDeepLink(url: url, configuredServerURL: serverURL)?.slug, "launch-plan-123")
  }

  func testRejectsUntrustedAndNestedLinks() {
    XCTAssertNil(ReviewDeepLink(
      url: URL(string: "https://example.com/review/launch-plan-123")!,
      configuredServerURL: serverURL
    ))
    XCTAssertNil(ReviewDeepLink(
      url: URL(string: "https://review.turfterrace.com/review/launch-plan-123/artifact/")!,
      configuredServerURL: serverURL
    ))
    XCTAssertNil(ReviewDeepLink(
      url: URL(string: "https://review.turfterrace.com/pending")!,
      configuredServerURL: serverURL
    ))
  }

  @MainActor
  func testPushTapRouterPublishesAndConsumesExactReviewURL() {
    _ = PushNotificationTapRouter.takePendingURL()
    let url = URL(string: "https://review.turfterrace.com/review/pushed-review")!
    var observedURL: URL?
    let observer = NotificationCenter.default.addObserver(
      forName: .turfReviewNotificationTapped,
      object: nil,
      queue: nil
    ) { notification in
      observedURL = notification.object as? URL
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    PushNotificationTapRouter.publish(url)

    XCTAssertEqual(observedURL, url)
    PushNotificationTapRouter.consume(url)
    XCTAssertNil(PushNotificationTapRouter.takePendingURL())
  }
}
