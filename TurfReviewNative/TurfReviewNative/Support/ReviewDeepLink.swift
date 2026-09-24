import Foundation

struct ReviewDeepLink: Equatable {
  static let universalLinkHost = "review.turfterrace.com"

  let slug: String

  init?(url: URL, configuredServerURL: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased() else { return nil }

    let encodedSegments = components.percentEncodedPath
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)

    let encodedSlug: String
    switch scheme {
    case "http", "https":
      let allowedHosts = [Self.universalLinkHost, configuredServerURL.host?.lowercased()]
        .compactMap { $0 }
      guard let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            encodedSegments.count == 2,
            encodedSegments[0] == "review" else { return nil }
      encodedSlug = encodedSegments[1]

    case "turf-review":
      if components.host?.lowercased() == "review" {
        guard encodedSegments.count == 1 else { return nil }
        encodedSlug = encodedSegments[0]
      } else {
        guard components.host == nil,
              encodedSegments.count == 2,
              encodedSegments[0] == "review" else { return nil }
        encodedSlug = encodedSegments[1]
      }

    default:
      return nil
    }

    guard let decodedSlug = encodedSlug.removingPercentEncoding?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !decodedSlug.isEmpty,
      !decodedSlug.contains("/") else { return nil }

    slug = decodedSlug
  }
}
