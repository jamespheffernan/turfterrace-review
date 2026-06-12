import Foundation

protocol TurfReviewServicing {
  func listItems() async throws -> [ReviewItem]
  func getItem(slug: String) async throws -> ReviewItem
  func getAnnotations(slug: String) async throws -> [ReviewAnnotation]
  func createAnnotation(
    slug: String,
    quote: String?,
    anchorType: String,
    anchorRef: String?,
    comment: String,
    imageData: String?,
    imageMime: String?
  ) async throws -> ReviewAnnotation
  func deleteAnnotation(slug: String, id: Int) async throws -> DeleteAnnotationResponse
  func decide(slug: String, decision: String, feedback: String?) async throws -> DecisionResponse
  func getActions(slug: String) async throws -> ReviewActionsResponse
  func retryLatestAction(slug: String) async throws -> RetryResponse
  func getChatHistory(slug: String) async throws -> ChatHistoryResponse
  func sendChat(slug: String, message: String) async throws -> ChatSendResponse
  func ttsStatus(slug: String) async throws -> AudioStatusResponse
  func contextStatus(slug: String) async throws -> AudioStatusResponse
  func absoluteURL(for relativeOrAbsolute: String?) -> URL?
}

enum TurfReviewClientError: LocalizedError {
  case badURL(String)
  case badStatus(Int, String)
  case emptyResponse
  case loginRedirect
  case nonJSONResponse(Int, String?)
  case unreadableJSON(Int)

  var errorDescription: String? {
    switch self {
    case .badURL(let path):
      return "Could not build URL for \(path)."
    case .badStatus(let status, let message):
      return "Server returned \(status): \(message)"
    case .emptyResponse:
      return "The server returned an empty response."
    case .loginRedirect:
      return "The server redirected to login. Add Basic Auth credentials in Settings."
    case .nonJSONResponse(let status, let contentType):
      if contentType?.localizedCaseInsensitiveContains("html") == true {
        return "The server returned an HTML login page. Add Basic Auth credentials in Settings."
      }
      return "The server returned \(contentType ?? "a non-JSON response") with status \(status)."
    case .unreadableJSON(let status):
      return "The server returned JSON with status \(status), but the native app could not read it."
    }
  }
}

struct TurfReviewClient: TurfReviewServicing {
  let configuration: APIConfiguration
  var session: URLSession = .shared

  func listItems() async throws -> [ReviewItem] {
    try await send(path: "/api/items")
  }

  func getItem(slug: String) async throws -> ReviewItem {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)")
  }

  func getAnnotations(slug: String) async throws -> [ReviewAnnotation] {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/annotations")
  }

  func createAnnotation(
    slug: String,
    quote: String?,
    anchorType: String,
    anchorRef: String?,
    comment: String,
    imageData: String? = nil,
    imageMime: String? = nil
  ) async throws -> ReviewAnnotation {
    let body = AnnotationBody(
      quote: quote,
      anchorType: anchorType,
      anchorRef: anchorRef,
      comment: comment,
      imageData: imageData,
      imageMime: imageMime
    )
    return try await sendJSON(path: "/api/items/\(slug.pathComponentEncoded)/annotate", method: "POST", body: body)
  }

  func deleteAnnotation(slug: String, id: Int) async throws -> DeleteAnnotationResponse {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/annotations/\(id)", method: "DELETE")
  }

  func decide(slug: String, decision: String, feedback: String?) async throws -> DecisionResponse {
    let body = DecisionBody(decision: decision, feedback: feedback?.nilIfBlank)
    return try await sendJSON(path: "/api/items/\(slug.pathComponentEncoded)/decide", method: "POST", body: body)
  }

  func getActions(slug: String) async throws -> ReviewActionsResponse {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/actions")
  }

  func retryLatestAction(slug: String) async throws -> RetryResponse {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/action/retry", method: "POST")
  }

  func getChatHistory(slug: String) async throws -> ChatHistoryResponse {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/chat/history")
  }

  func sendChat(slug: String, message: String) async throws -> ChatSendResponse {
    let body = ChatBody(message: message)
    return try await sendJSON(path: "/api/items/\(slug.pathComponentEncoded)/chat", method: "POST", body: body)
  }

  func ttsStatus(slug: String) async throws -> AudioStatusResponse {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/tts")
  }

  func contextStatus(slug: String) async throws -> AudioStatusResponse {
    try await send(path: "/api/items/\(slug.pathComponentEncoded)/context")
  }

  func absoluteURL(for relativeOrAbsolute: String?) -> URL? {
    guard let relativeOrAbsolute = relativeOrAbsolute?.trimmingCharacters(in: .whitespacesAndNewlines),
          !relativeOrAbsolute.isEmpty else { return nil }
    if let url = URL(string: relativeOrAbsolute),
       let scheme = url.scheme?.lowercased() {
      return ["http", "https"].contains(scheme) ? url : nil
    }
    return serverURL(appending: relativeOrAbsolute)
  }

  private func send<T: Decodable>(path: String, method: String = "GET") async throws -> T {
    var request = try makeRequest(path: path, method: method)
    if method == "POST" {
      request.httpBody = Data("{}".utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return try await perform(request)
  }

  private func sendJSON<Body: Encodable, Response: Decodable>(path: String, method: String, body: Body) async throws -> Response {
    var request = try makeRequest(path: path, method: method)
    request.httpBody = try JSONEncoder().encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await perform(request)
  }

  private func makeRequest(path: String, method: String) throws -> URLRequest {
    guard let url = serverURL(appending: path) else {
      throw TurfReviewClientError.badURL(path)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !configuration.username.isEmpty || !configuration.password.isEmpty {
      let token = "\(configuration.username):\(configuration.password)"
        .data(using: .utf8)?
        .base64EncodedString() ?? ""
      request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func serverURL(appending relativePath: String) -> URL? {
    guard var baseComponents = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false),
          let relativeComponents = URLComponents(string: relativePath.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }

    let basePath = baseComponents.percentEncodedPath.trimmingSlashes
    let childPath = relativeComponents.percentEncodedPath.trimmingSlashes
    let joinedPath = [basePath, childPath]
      .filter { !$0.isEmpty }
      .joined(separator: "/")

    baseComponents.percentEncodedPath = joinedPath.isEmpty ? "/" : "/\(joinedPath)"
    baseComponents.percentEncodedQuery = relativeComponents.percentEncodedQuery
    baseComponents.percentEncodedFragment = relativeComponents.percentEncodedFragment
    return baseComponents.url
  }

  private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TurfReviewClientError.emptyResponse
    }
    let contentType = http.value(forHTTPHeaderField: "Content-Type")

    guard (200..<300).contains(http.statusCode) else {
      if (300..<400).contains(http.statusCode),
         http.value(forHTTPHeaderField: "Location")?.localizedCaseInsensitiveContains("login") == true {
        throw TurfReviewClientError.loginRedirect
      }
      if contentType?.localizedCaseInsensitiveContains("html") == true {
        throw TurfReviewClientError.nonJSONResponse(http.statusCode, contentType)
      }
      let message = (try? JSONDecoder().decode(APIMessageResponse.self, from: data).displayMessage)
        ?? String(data: data, encoding: .utf8)
        ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      throw TurfReviewClientError.badStatus(http.statusCode, message)
    }

    if data.isEmpty {
      throw TurfReviewClientError.emptyResponse
    }

    if let contentType,
       !contentType.localizedCaseInsensitiveContains("application/json"),
       !contentType.localizedCaseInsensitiveContains("+json") {
      throw TurfReviewClientError.nonJSONResponse(http.statusCode, contentType)
    }

    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw TurfReviewClientError.unreadableJSON(http.statusCode)
    }
  }
}

private struct AnnotationBody: Encodable {
  let quote: String?
  let anchorType: String
  let anchorRef: String?
  let comment: String
  let imageData: String?
  let imageMime: String?

  enum CodingKeys: String, CodingKey {
    case quote
    case anchorType = "anchor_type"
    case anchorRef = "anchor_ref"
    case comment
    case imageData = "image_data"
    case imageMime = "image_mime"
  }
}

private struct DecisionBody: Encodable {
  let decision: String
  let feedback: String?
}

private struct ChatBody: Encodable {
  let message: String
}

private extension String {
  var pathComponentEncoded: String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
  }

  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var trimmingSlashes: String {
    trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
