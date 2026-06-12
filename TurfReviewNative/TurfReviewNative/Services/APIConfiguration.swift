import Foundation

struct APIConfiguration: Equatable {
  var serverURL: URL
  var username: String
  var password: String
  var useDemoOnFailure: Bool

  static let defaults = APIConfiguration(
    serverURL: defaultServerURL(),
    username: "",
    password: "",
    useDemoOnFailure: true
  )

  static var defaultsStore: UserDefaults = .standard

  static func load() -> APIConfiguration {
    let defaults = defaultsStore
    let rawURL = defaults.string(forKey: "turf.serverURL") ?? Self.defaults.serverURL.absoluteString
    let url = normalizedServerURL(from: rawURL) ?? Self.defaults.serverURL
    return APIConfiguration(
      serverURL: url,
      username: defaults.string(forKey: "turf.username") ?? "",
      password: defaults.string(forKey: "turf.password") ?? "",
      useDemoOnFailure: defaults.object(forKey: "turf.useDemoOnFailure") as? Bool ?? true
    )
  }

  func save() {
    let defaults = Self.defaultsStore
    defaults.set(serverURL.absoluteString, forKey: "turf.serverURL")
    defaults.set(username, forKey: "turf.username")
    defaults.set(password, forKey: "turf.password")
    defaults.set(useDemoOnFailure, forKey: "turf.useDemoOnFailure")
  }

  var displayURL: String {
    serverURL.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
  }

  static func normalizedServerURL(from rawValue: String) -> URL? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil,
          url.user == nil,
          url.password == nil else {
      return nil
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = scheme
    components?.query = nil
    components?.fragment = nil
    if let path = components?.percentEncodedPath,
       !path.isEmpty,
       path != "/",
       !path.hasSuffix("/") {
      components?.percentEncodedPath = "\(path)/"
    }
    return components?.url
  }

  static func defaultServerURL(bundle: Bundle = .main) -> URL {
    defaultServerURL(rawValue: bundle.object(forInfoDictionaryKey: "TurfDefaultServerURL") as? String)
  }

  static func defaultServerURL(rawValue: String?) -> URL {
    if let rawURL = rawValue,
       !rawURL.hasPrefix("$("),
       let url = normalizedServerURL(from: rawURL) {
      return url
    }
    return URL(string: "http://localhost:3457")!
  }
}
