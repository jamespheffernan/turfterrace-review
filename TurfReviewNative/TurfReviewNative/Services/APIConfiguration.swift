import Foundation
import Security

struct APIConfiguration: Equatable {
  var serverURL: URL
  var username: String
  var password: String
  var useDemoOnFailure: Bool

  static let defaults = APIConfiguration(
    serverURL: defaultServerURL(),
    username: "",
    password: "",
    useDemoOnFailure: false
  )

  static var defaultsStore: UserDefaults = .standard
  static var credentialStore: CredentialStoring = KeychainCredentialStore()
  static var sessionStore: SessionStoring = KeychainSessionStore()

  static func load(
    compiledDefaultServerURL: URL = APIConfiguration.defaultServerURL()
  ) -> APIConfiguration {
    let defaults = defaultsStore
    let rawURL = defaults.string(forKey: "turf.serverURL") ?? compiledDefaultServerURL.absoluteString
    let storedURL = normalizedServerURL(from: rawURL) ?? compiledDefaultServerURL
    let migratesLoopbackDefault = isLegacyLoopbackDefault(storedURL)
      && !isLoopbackHost(compiledDefaultServerURL.host)
    let url = migratesLoopbackDefault ? compiledDefaultServerURL : storedURL
    let loadedCredentials = loadCredentials(
      for: url,
      defaults: defaults,
      migrateFromLoopback: migratesLoopbackDefault
    )
    if migratesLoopbackDefault, loadedCredentials.canCommitServerMigration {
      defaults.set(url.absoluteString, forKey: "turf.serverURL")
    }
    return APIConfiguration(
      serverURL: url,
      username: loadedCredentials.credentials?.username ?? "",
      password: loadedCredentials.credentials?.password ?? "",
      useDemoOnFailure: defaults.object(forKey: "turf.useDemoOnFailure") as? Bool ?? false
    )
  }

  @discardableResult
  func save() -> Bool {
    let defaults = Self.defaultsStore
    let credentials = hasCredentials
      ? StoredBasicAuthCredentials(serverURL: serverURL, username: username, password: password)
      : nil
    do {
      try Self.sessionStore.save(nil)
      try Self.credentialStore.save(credentials)
      defaults.set(serverURL.absoluteString, forKey: "turf.serverURL")
      defaults.set(useDemoOnFailure, forKey: "turf.useDemoOnFailure")
      Self.removeLegacyCredentials(from: defaults)
      return true
    } catch {
      return false
    }
  }

  var displayURL: String {
    serverURL.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
  }
  var hasCredentials: Bool {
    !username.isEmpty || !password.isEmpty
  }

  func authenticatedRequest(for url: URL, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    for (header, value) in authenticationHeaders(for: url, method: method) {
      request.setValue(value, forHTTPHeaderField: header)
    }
    return request
  }

  func authenticatedRequest(path: String, method: String = "GET") -> URLRequest? {
    guard let url = url(appending: path) else { return nil }
    return authenticatedRequest(for: url, method: method)
  }

  func url(appending relativePath: String) -> URL? {
    guard var baseComponents = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
          let relativeComponents = URLComponents(
            string: relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
          ) else {
      return nil
    }

    let slashes = CharacterSet(charactersIn: "/")
    let basePath = baseComponents.percentEncodedPath.trimmingCharacters(in: slashes)
    let childPath = relativeComponents.percentEncodedPath.trimmingCharacters(in: slashes)
    let joinedPath = [basePath, childPath]
      .filter { !$0.isEmpty }
      .joined(separator: "/")

    baseComponents.percentEncodedPath = joinedPath.isEmpty ? "/" : "/\(joinedPath)"
    baseComponents.percentEncodedQuery = relativeComponents.percentEncodedQuery
    baseComponents.percentEncodedFragment = relativeComponents.percentEncodedFragment
    return baseComponents.url
  }

  func authenticationHeaders(for url: URL, method: String = "GET") -> [String: String] {
    guard Self.hasSameOrigin(url, serverURL),
          let origin,
          let session = hostedSession else {
      return [:]
    }
    var headers = [
      "Cookie": "\(session.cookieName)=\(session.cookieValue)",
      "Origin": origin,
    ]
    if Self.requiresCSRF(method) {
      headers["X-CSRF-Token"] = session.csrfToken
    }
    return headers
  }

  var hostedSession: HostedSessionState? {
    guard let session = try? Self.sessionStore.load(),
          session.cookieName == HostedSessionState.cookieName,
          !session.cookieValue.isEmpty,
          !session.csrfToken.isEmpty,
          Self.hasSameOrigin(session.serverURL, serverURL),
          session.expiresAt > Date() else {
      return nil
    }
    return session
  }

  var origin: String? {
    guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  func storeHostedSession(_ session: HostedSessionState) throws {
    guard Self.hasSameOrigin(session.serverURL, serverURL) else {
      throw HostedSessionStoreError.originMismatch
    }
    try Self.sessionStore.save(session)
  }

  func clearHostedSession() throws {
    try Self.sessionStore.save(nil)
  }

  private static func requiresCSRF(_ method: String) -> Bool {
    !["GET", "HEAD", "OPTIONS"].contains(method.uppercased())
  }

  private static func loadCredentials(
    for serverURL: URL,
    defaults: UserDefaults,
    migrateFromLoopback: Bool
  ) -> (credentials: StoredBasicAuthCredentials?, canCommitServerMigration: Bool) {
    var keychainReadFailed = false
    do {
      if let stored = try credentialStore.load() {
        if hasSameOrigin(stored.serverURL, serverURL) {
          return (stored, true)
        }
        if migrateFromLoopback, isLegacyLoopbackDefault(stored.serverURL) {
          let migrated = StoredBasicAuthCredentials(
            serverURL: serverURL,
            username: stored.username,
            password: stored.password
          )
          do {
            try credentialStore.save(migrated)
            removeLegacyCredentials(from: defaults)
            return (migrated, true)
          } catch {
            // Keep the old server preference so the secure migration retries next launch.
            return (migrated, false)
          }
        }
        // Credentials from a different non-loopback origin are never migrated.
        return (nil, true)
      }
    } catch {
      keychainReadFailed = true
    }

    let legacyUsername = defaults.string(forKey: "turf.username") ?? ""
    let legacyPassword = defaults.string(forKey: "turf.password") ?? ""
    guard !legacyUsername.isEmpty || !legacyPassword.isEmpty else {
      return (nil, !keychainReadFailed)
    }

    let legacy = StoredBasicAuthCredentials(
      serverURL: serverURL,
      username: legacyUsername,
      password: legacyPassword
    )
    do {
      try credentialStore.save(legacy)
      removeLegacyCredentials(from: defaults)
      return (legacy, true)
    } catch {
      // Preserve both legacy values and a loopback preference so a production
      // migration retries instead of committing a server without secure credentials.
      return (legacy, !migrateFromLoopback)
    }
  }

  private static func removeLegacyCredentials(from defaults: UserDefaults) {
    defaults.removeObject(forKey: "turf.username")
    defaults.removeObject(forKey: "turf.password")
  }

  private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let lhsScheme = lhs.scheme?.lowercased(),
          let rhsScheme = rhs.scheme?.lowercased(),
          let lhsHost = lhs.host?.lowercased(),
          let rhsHost = rhs.host?.lowercased() else {
      return false
    }
    return lhsScheme == rhsScheme
      && lhsHost == rhsHost
      && effectivePort(of: lhs, scheme: lhsScheme) == effectivePort(of: rhs, scheme: rhsScheme)
  }

  private static func effectivePort(of url: URL, scheme: String) -> Int? {
    url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
  }

  private static func isLegacyLoopbackDefault(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http",
          url.port == 3457,
          isLoopbackHost(url.host) else {
      return false
    }
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    return path.isEmpty || path == "/"
  }

  private static func isLoopbackHost(_ rawHost: String?) -> Bool {
    guard let host = rawHost?.lowercased() else { return false }
    if host == "localhost" || host.hasSuffix(".localhost")
      || host == "::1" || host == "0:0:0:0:0:0:0:1" {
      return true
    }
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4
      && octets.first == "127"
      && octets.allSatisfy { octet in
        guard let value = Int(octet) else { return false }
        return (0...255).contains(value)
      }
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

struct StoredBasicAuthCredentials: Codable, Equatable {
  let serverURL: URL
  let username: String
  let password: String
}

protocol CredentialStoring {
  func load() throws -> StoredBasicAuthCredentials?
  func save(_ credentials: StoredBasicAuthCredentials?) throws
}

struct KeychainCredentialStore: CredentialStoring {
  private let service = "com.jamesheffernan.turfreviewnative.credentials"
  private let account = "basic-auth"

  func load() throws -> StoredBasicAuthCredentials? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainCredentialStoreError(status: status)
    }
    return try JSONDecoder().decode(StoredBasicAuthCredentials.self, from: data)
  }

  func save(_ credentials: StoredBasicAuthCredentials?) throws {
    guard let credentials else {
      let status = SecItemDelete(baseQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainCredentialStoreError(status: status)
      }
      return
    }

    let data = try JSONEncoder().encode(credentials)
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainCredentialStoreError(status: updateStatus)
    }

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainCredentialStoreError(status: addStatus)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

private struct KeychainCredentialStoreError: Error {
  let status: OSStatus
}

struct HostedSessionState: Codable, Equatable {
  static let cookieName = "__Host-turf_review_session"

  let serverURL: URL
  let cookieName: String
  let cookieValue: String
  let csrfToken: String
  let expiresAt: Date
}

protocol SessionStoring {
  func load() throws -> HostedSessionState?
  func save(_ session: HostedSessionState?) throws
}

struct KeychainSessionStore: SessionStoring {
  private let service = "com.jamesheffernan.turfreviewnative.credentials"
  private let account = "hosted-session"

  func load() throws -> HostedSessionState? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw HostedSessionStoreError.keychain(status)
    }
    return try JSONDecoder().decode(HostedSessionState.self, from: data)
  }

  func save(_ session: HostedSessionState?) throws {
    guard let session else {
      let status = SecItemDelete(baseQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw HostedSessionStoreError.keychain(status)
      }
      return
    }

    let data = try JSONEncoder().encode(session)
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw HostedSessionStoreError.keychain(updateStatus)
    }

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw HostedSessionStoreError.keychain(addStatus)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

enum HostedSessionStoreError: Error {
  case keychain(OSStatus)
  case originMismatch
}
