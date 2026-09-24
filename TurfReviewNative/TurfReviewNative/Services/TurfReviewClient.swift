import Foundation

protocol TurfReviewServicing {
  func downloadResource(_ url: URL) async throws -> (Data, String)
  func listItems() async throws -> [ReviewItem]
  func getItem(slug: String) async throws -> ReviewItem
  func getAnnotations(slug: String) async throws -> [ReviewAnnotation]
  func getReviewTargets(slug: String) async throws -> ReviewTargetsResponse
  func updateReviewTarget(slug: String, targetKey: String, verdict: String, feedback: String?) async throws -> ReviewTargetJudgmentResponse
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
  func decide(slug: String, decision: String, actionId: String?, feedback: String?) async throws -> DecisionResponse
  func getActions(slug: String) async throws -> ReviewActionsResponse
  func retryLatestAction(slug: String) async throws -> RetryResponse
  func getChatHistory(slug: String) async throws -> ChatHistoryResponse
  func sendChat(slug: String, message: String) async throws -> ChatSendResponse
  func ttsStatus(slug: String) async throws -> AudioStatusResponse
  func contextStatus(slug: String) async throws -> AudioStatusResponse
  func absoluteURL(for relativeOrAbsolute: String?) -> URL?
}

extension TurfReviewServicing {
  func downloadResource(_ url: URL) async throws -> (Data, String) {
    throw TurfReviewClientError.unsupportedOperation("downloading resources")
  }
}

enum TurfReviewClientError: LocalizedError {
  case badURL(String)
  case badStatus(Int, String)
  case emptyResponse
  case authenticationRequired
  case invalidSessionResponse
  case sessionPersistenceFailed
  case nonJSONResponse(Int, String?)
  case unreadableJSON(Int)
  case unsupportedOperation(String)

  var errorDescription: String? {
    switch self {
    case .badURL(let path):
      return "Could not build URL for \(path)."
    case .badStatus(let status, let message):
      return "Server returned \(status): \(message)"
    case .emptyResponse:
      return "The server returned an empty response."
    case .authenticationRequired:
      return "Your Turf Review session expired. Sign in again in Settings."
    case .invalidSessionResponse:
      return "Turf Review returned an invalid sign-in session."
    case .sessionPersistenceFailed:
      return "Turf Review could not store the signed-in session securely."
    case .nonJSONResponse(let status, let contentType):
      return "The server returned \(contentType ?? "a non-JSON response") with status \(status)."
    case .unreadableJSON(let status):
      return "The server returned JSON with status \(status), but the native app could not read it."
    case .unsupportedOperation(let operation):
      return "The hosted Turf Review service does not support \(operation)."
    }
  }
}

struct HostedSessionStatus: Decodable, Equatable {
  let authenticated: Bool
  let csrfToken: String?
  let expiresAt: String?
}

struct HostedMutationReceipt: Decodable, Equatable {
  struct Job: Decodable, Equatable {
    let id: String
    let status: String
    let actionPayloadHash: String?
    let actionType: String?
  }

  let accepted: Bool
  let replayed: Bool
  let changeLogOperationId: String
  let annotationId: String?
  let externalAnnotationId: Int?
  let annotation: HostedAnnotation?
  let decisionId: String?
  let judgmentId: String?
  let job: Job?
}

struct TurfReviewClient: TurfReviewServicing {
  let configuration: APIConfiguration
  var session: URLSession = .shared

  func downloadResource(_ url: URL) async throws -> (Data, String) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      throw TurfReviewClientError.badURL(url.absoluteString)
    }
    let own = configuration.serverURL
    let sameOrigin = url.scheme == own.scheme && url.host == own.host && url.port == own.port
    let data: Data
    let response: HTTPURLResponse
    if sameOrigin {
      let path = url.path + (url.query.map { "?" + $0 } ?? "")
      (data, response) = try await performHosted(path: path, method: "GET", body: nil)
    } else {
      // Public embedded resources never receive the review service's credentials.
      var request = URLRequest(url: url)
      request.httpShouldHandleCookies = false
      let result = try await session.data(for: request)
      data = result.0
      response = try Self.httpResponse(result.1)
      try Self.validateStatus(response, data: data)
    }
    return (data, response.mimeType ?? "application/octet-stream")
  }

  func listItems() async throws -> [ReviewItem] {
    var items: [ReviewItem] = []
    var cursor: String?

    repeat {
      let path = cursor.map { "/api/reviews?cursor=\($0.queryValueEncoded)" } ?? "/api/reviews"
      let page: HostedReviewList = try await sendHosted(path: path)
      items.append(contentsOf: page.items.map(Self.reviewItem(from:)))
      cursor = page.nextCursor
    } while cursor != nil

    return items
  }

  /// The item, first target page and audio status all come from one detail response.
  /// Concurrent readers of the same review share a single request instead of issuing one each.
  private func sharedDetail(slug: String) async throws -> HostedReviewDetail {
    let path = "/api/reviews/\(slug.pathComponentEncoded)"
    return try await HostedDetailRequests.shared.detail(key: detailRequestKey(slug: slug)) {
      try await sendHosted(path: path)
    }
  }

  private func detailRequestKey(slug: String) -> String {
    "\(configuration.serverURL.absoluteString)\n\(configuration.username)\n\(slug)"
  }

  /// Keeps reads that start before a write completes from answering reads made after it.
  private func mutatingReview<Response>(
    slug: String,
    _ mutation: () async throws -> Response
  ) async throws -> Response {
    let key = detailRequestKey(slug: slug)
    await HostedDetailRequests.shared.invalidate(key: key)
    do {
      let response = try await mutation()
      await HostedDetailRequests.shared.invalidate(key: key)
      return response
    } catch {
      await HostedDetailRequests.shared.invalidate(key: key)
      throw error
    }
  }

  func getItem(slug: String) async throws -> ReviewItem {
    let reviewID = slug.pathComponentEncoded
    let detail = try await sharedDetail(slug: slug)
    var renderedHTML: String?
    var markdown: String?

    if detail.content != nil {
      let document = try await sendHostedDocument(path: "/api/reviews/\(reviewID)/document")
      if document.isHTML {
        renderedHTML = document.text
      } else {
        markdown = document.text
      }
    }

    return Self.reviewItem(from: detail, renderedHTML: renderedHTML, markdown: markdown)
  }

  func getAnnotations(slug: String) async throws -> [ReviewAnnotation] {
    var annotations: [ReviewAnnotation] = []
    var cursor: Int?

    repeat {
      let suffix = cursor.map { "?cursor=\($0)" } ?? ""
      let page: HostedAnnotationPage = try await sendHosted(
        path: "/api/reviews/\(slug.pathComponentEncoded)/annotations\(suffix)"
      )
      annotations.append(contentsOf: page.annotations.map { $0.reviewAnnotation(slug: slug) })
      cursor = page.nextCursor
    } while cursor != nil

    return annotations
  }

  func getReviewTargets(slug: String) async throws -> ReviewTargetsResponse {
    let reviewID = slug.pathComponentEncoded
    var targets: [ReviewTarget] = []
    var cursor: String?

    repeat {
      let detail: HostedReviewDetail
      if let cursor {
        detail = try await sendHosted(path: "/api/reviews/\(reviewID)?targetCursor=\(cursor.queryValueEncoded)")
      } else {
        detail = try await sharedDetail(slug: slug)
      }
      targets.append(contentsOf: detail.targets.map(Self.reviewTarget(from:)))
      cursor = detail.nextTargetCursor
    } while cursor != nil

    return ReviewTargetsResponse(slug: slug, targets: targets, summary: Self.summary(for: targets))
  }

  func updateReviewTarget(slug: String, targetKey: String, verdict: String, feedback: String?) async throws -> ReviewTargetJudgmentResponse {
    let body = HostedTargetBody(
      mutationId: UUID().uuidString.lowercased(),
      verdict: verdict,
      feedback: feedback?.nilIfBlank
    )
    let _: HostedMutationReceipt = try await mutatingReview(slug: slug) {
      try await sendHostedMutation(
        path: "/api/reviews/\(slug.pathComponentEncoded)/targets/\(targetKey.pathComponentEncoded)",
        method: "PUT",
        body: body
      )
    }
    let response = try await getReviewTargets(slug: slug)
    return ReviewTargetJudgmentResponse(
      slug: slug,
      target: response.targets.first { $0.key == targetKey },
      summary: response.summary
    )
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
    if imageData?.nilIfBlank != nil || imageMime?.nilIfBlank != nil {
      throw TurfReviewClientError.unsupportedOperation("image annotation uploads")
    }
    let body = HostedAnnotationBody(
      mutationId: UUID().uuidString.lowercased(),
      comment: comment,
      quote: quote?.nilIfBlank,
      anchorType: anchorType,
      anchorRef: anchorRef?.nilIfBlank
    )
    let receipt: HostedMutationReceipt = try await mutatingReview(slug: slug) {
      try await sendHostedMutation(
        path: "/api/reviews/\(slug.pathComponentEncoded)/annotations",
        method: "POST",
        body: body
      )
    }
    guard let annotation = receipt.annotation else {
      throw TurfReviewClientError.unreadableJSON(200)
    }
    return annotation.reviewAnnotation(slug: slug)
  }

  func deleteAnnotation(slug: String, id: Int) async throws -> DeleteAnnotationResponse {
    let receipt: HostedDeleteAnnotationReceipt = try await mutatingReview(slug: slug) {
      try await sendHostedMutation(
        path: "/api/reviews/\(slug.pathComponentEncoded)/annotations/\(id)",
        method: "DELETE",
        body: HostedEmptyBody()
      )
    }
    return DeleteAnnotationResponse(deleted: receipt.deleted)
  }

  func decide(slug: String, decision: String, actionId: String?, feedback: String?) async throws -> DecisionResponse {
    if actionId?.nilIfBlank != nil {
      throw TurfReviewClientError.unsupportedOperation("legacy action identifiers in hosted decisions")
    }
    let body = HostedDecisionBody(
      mutationId: UUID().uuidString.lowercased(),
      decision: decision,
      noteText: feedback?.nilIfBlank
    )
    let receipt: HostedMutationReceipt = try await mutatingReview(slug: slug) {
      try await sendHostedMutation(
        path: "/api/reviews/\(slug.pathComponentEncoded)/decisions",
        method: "POST",
        body: body
      )
    }
    let actionStatus = receipt.job?.status ?? "succeeded"
    return DecisionResponse(
      // The hosted service lists every decided review as `processed`.
      status: receipt.accepted ? "processed" : "rejected",
      decision: decision,
      slug: slug,
      queued: receipt.job?.status == "queued",
      processed: receipt.job == nil,
      sessionKey: nil,
      action: DecisionResponse.ActionSummary(status: actionStatus, message: "\(decision) saved."),
      requests: [],
      followups: []
    )
  }

  func getActions(slug: String) async throws -> ReviewActionsResponse {
    throw TurfReviewClientError.unsupportedOperation("reading action status")
  }

  func retryLatestAction(slug: String) async throws -> RetryResponse {
    throw TurfReviewClientError.unsupportedOperation("retrying actions")
  }

  func getChatHistory(slug: String) async throws -> ChatHistoryResponse {
    throw TurfReviewClientError.unsupportedOperation("review chat")
  }

  func sendChat(slug: String, message: String) async throws -> ChatSendResponse {
    throw TurfReviewClientError.unsupportedOperation("review chat")
  }

  func ttsStatus(slug: String) async throws -> AudioStatusResponse {
    if let media = try await sharedDetail(slug: slug).media?.tts { return media }
    return try await sendHosted(path: "/api/reviews/\(slug.pathComponentEncoded)/tts")
  }

  func contextStatus(slug: String) async throws -> AudioStatusResponse {
    if let media = try await sharedDetail(slug: slug).media?.context { return media }
    return try await sendHosted(path: "/api/reviews/\(slug.pathComponentEncoded)/context")
  }

  func absoluteURL(for relativeOrAbsolute: String?) -> URL? {
    guard let relativeOrAbsolute = relativeOrAbsolute?.trimmingCharacters(in: .whitespacesAndNewlines),
          !relativeOrAbsolute.isEmpty else { return nil }
    if let url = URL(string: relativeOrAbsolute),
       let scheme = url.scheme?.lowercased() {
      return ["http", "https"].contains(scheme) ? url : nil
    }
    return configuration.url(appending: relativeOrAbsolute)
  }

  func establishHostedSession() async throws {
    guard configuration.hasCredentials else {
      throw TurfReviewClientError.authenticationRequired
    }
    guard let url = configuration.url(appending: "/api/session"),
          let origin = configuration.origin else {
      throw TurfReviewClientError.badURL("/api/session")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue(origin, forHTTPHeaderField: "Origin")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      HostedLoginBody(username: configuration.username, password: configuration.password)
    )

    let (data, response) = try await session.data(for: request)
    let http = try Self.httpResponse(response)
    try Self.validateStatus(http, data: data)
    let status: HostedSessionStatus = try Self.decodeEnvelope(data, status: http.statusCode)
    guard status.authenticated,
          let csrfToken = status.csrfToken?.nilIfBlank,
          let expiresAtString = status.expiresAt,
          let expiresAt = Self.fractionalISO8601.date(from: expiresAtString)
            ?? Self.iso8601.date(from: expiresAtString),
          let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
          let cookie = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookie],
            for: url
          ).first(where: { $0.name == HostedSessionState.cookieName }),
          !cookie.value.isEmpty else {
      throw TurfReviewClientError.invalidSessionResponse
    }

    do {
      try configuration.storeHostedSession(HostedSessionState(
        serverURL: configuration.serverURL,
        cookieName: cookie.name,
        cookieValue: cookie.value,
        csrfToken: csrfToken,
        expiresAt: expiresAt
      ))
    } catch {
      throw TurfReviewClientError.sessionPersistenceFailed
    }
  }

  func sessionStatus() async throws -> HostedSessionStatus {
    let status: HostedSessionStatus = try await sendHosted(path: "/api/session")
    guard status.authenticated else {
      throw TurfReviewClientError.authenticationRequired
    }
    return status
  }

  func logout() async throws {
    guard configuration.hostedSession != nil else {
      try configuration.clearHostedSession()
      return
    }
    defer { try? configuration.clearHostedSession() }
    let _: HostedSessionStatus = try await sendHostedMutation(
      path: "/api/session",
      method: "DELETE",
      body: HostedEmptyBody()
    )
  }

  func sendHostedMutation<Body: Encodable, Response: Decodable>(
    path: String,
    method: String,
    body: Body
  ) async throws -> Response {
    let normalizedMethod = method.uppercased()
    guard ["POST", "PUT", "PATCH", "DELETE"].contains(normalizedMethod) else {
      throw TurfReviewClientError.unsupportedOperation("a \(normalizedMethod) hosted mutation")
    }
    return try await sendHosted(path: path, method: normalizedMethod, body: JSONEncoder().encode(body))
  }

  private func sendHosted<Response: Decodable>(
    path: String,
    method: String = "GET",
    body: Data? = nil
  ) async throws -> Response {
    let (data, http) = try await performHosted(path: path, method: method, body: body)
    return try Self.decodeEnvelope(data, status: http.statusCode)
  }

  private func sendHostedDocument(path: String) async throws -> (text: String, isHTML: Bool) {
    let (data, http) = try await performHosted(path: path, method: "GET", body: nil)
    guard let text = String(data: data, encoding: .utf8) else {
      throw TurfReviewClientError.emptyResponse
    }
    let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    return (text, contentType.localizedCaseInsensitiveContains("text/html"))
  }

  private func performHosted(
    path: String,
    method: String,
    body: Data?
  ) async throws -> (Data, HTTPURLResponse) {
    if configuration.hostedSession == nil {
      try await establishHostedSession()
    }

    var result = try await performOnce(path: path, method: method, body: body)
    if result.1.statusCode == 401 {
      try? configuration.clearHostedSession()
      try await establishHostedSession()
      result = try await performOnce(path: path, method: method, body: body)
    }
    try Self.validateStatus(result.1, data: result.0)
    return result
  }

  private func performOnce(
    path: String,
    method: String,
    body: Data?
  ) async throws -> (Data, HTTPURLResponse) {
    guard var request = configuration.authenticatedRequest(path: path, method: method),
          request.value(forHTTPHeaderField: "Cookie") != nil,
          request.value(forHTTPHeaderField: "Origin") != nil else {
      throw TurfReviewClientError.authenticationRequired
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    return (data, try Self.httpResponse(response))
  }

  private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      throw TurfReviewClientError.emptyResponse
    }
    return http
  }

  private static func validateStatus(_ http: HTTPURLResponse, data: Data) throws {
    guard (200..<300).contains(http.statusCode) else {
      let hostedError = try? JSONDecoder().decode(HostedErrorEnvelope.self, from: data)
      let message = hostedError?.error.message
        ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      throw TurfReviewClientError.badStatus(http.statusCode, message)
    }
  }

  private static func decodeEnvelope<Response: Decodable>(_ data: Data, status: Int) throws -> Response {
    guard !data.isEmpty else {
      throw TurfReviewClientError.emptyResponse
    }
    do {
      return try JSONDecoder().decode(HostedEnvelope<Response>.self, from: data).data
    } catch {
      throw TurfReviewClientError.unreadableJSON(status)
    }
  }

  private static func reviewItem(from item: HostedReviewListItem) -> ReviewItem {
    ReviewItem(
      databaseID: nil,
      slug: item.slug,
      title: item.title ?? "Untitled review",
      category: item.category,
      status: item.status,
      decision: item.decision,
      actions: nil,
      feedback: nil,
      renderedHTML: nil,
      markdown: nil,
      contentLength: item.contentLength,
      actionStatus: nil,
      actionMessage: nil,
      approvalStatus: nil,
      approvalMessage: nil,
      ttsStatus: nil,
      contextStatus: nil,
      contextSummary: nil,
      decisionSchemaVersion: nil,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt
    )
  }

  private static func reviewItem(
    from detail: HostedReviewDetail,
    renderedHTML: String?,
    markdown: String?
  ) -> ReviewItem {
    ReviewItem(
      databaseID: nil,
      slug: detail.slug,
      title: detail.title ?? "Untitled review",
      category: detail.category,
      status: detail.status,
      decision: nil,
      actions: nil,
      feedback: nil,
      renderedHTML: renderedHTML,
      markdown: markdown,
      artifactType: detail.customContentManifest == nil ? nil : "hosted_custom_content",
      contentLength: max(renderedHTML?.utf8.count ?? 0, markdown?.utf8.count ?? 0),
      actionStatus: nil,
      actionMessage: nil,
      approvalStatus: nil,
      approvalMessage: nil,
      ttsStatus: nil,
      contextStatus: nil,
      contextSummary: nil,
      decisionSchemaVersion: nil,
      createdAt: detail.createdAt,
      updatedAt: detail.updatedAt
    )
  }

  private static func reviewTarget(from target: HostedReviewTarget) -> ReviewTarget {
    ReviewTarget(
      key: target.id,
      label: target.label ?? target.id,
      ordinal: target.ordinal,
      verdict: target.judgment ?? "unset",
      feedback: target.feedback
    )
  }

  private static func summary(for targets: [ReviewTarget]) -> ReviewTargetSummary {
    let approved = targets.filter(\.isApproved).count
    let rejected = targets.filter(\.isRejected).count
    let undecided = targets.count - approved - rejected
    return ReviewTargetSummary(
      total: targets.count,
      approved: approved,
      rejected: rejected,
      undecided: undecided,
      decided: approved + rejected,
      complete: undecided == 0
    )
  }

  private static let iso8601 = ISO8601DateFormatter()
  private static let fractionalISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

private struct HostedEnvelope<Value: Decodable>: Decodable {
  let data: Value
}

private struct HostedErrorEnvelope: Decodable {
  struct HostedError: Decodable {
    let code: String
    let message: String
  }

  let error: HostedError
}

private struct HostedLoginBody: Encodable {
  let username: String
  let password: String
}

private struct HostedEmptyBody: Encodable {}

private struct HostedReviewList: Decodable {
  let items: [HostedReviewListItem]
  let nextCursor: String?
}

private struct HostedReviewListItem: Decodable {
  let reviewId: String
  let slug: String
  let title: String?
  let category: String
  let status: String
  let decision: String?
  let contentLength: Int?
  let createdAt: String?
  let updatedAt: String?
}

private struct HostedReferenceMarker: Decodable {}

private struct HostedContentAvailability: Decodable {
  let renderedHtml: HostedReferenceMarker?
  let markdown: HostedReferenceMarker?
}

private struct HostedReviewDetail: Decodable {
  let reviewId: String
  let slug: String
  let title: String?
  let category: String
  let status: String
  let createdAt: String?
  let updatedAt: String?
  let content: HostedContentAvailability?
  let customContentManifest: HostedReferenceMarker?
  let targets: [HostedReviewTarget]
  let nextTargetCursor: String?
  let media: HostedReviewMedia?
}

private struct HostedReviewMedia: Decodable {
  let tts: AudioStatusResponse?
  let context: AudioStatusResponse?
}

/// Shares one in-flight hosted detail request between concurrent readers of a review.
/// Completed responses are not cached; a mutation starts a new epoch so later reads refetch.
private actor HostedDetailRequests {
  static let shared = HostedDetailRequests()

  private struct Entry {
    let epoch: Int
    let id: UUID
    let task: Task<HostedReviewDetail, Error>
  }

  private var epochs: [String: Int] = [:]
  private var inFlight: [String: Entry] = [:]

  func detail(
    key: String,
    load: @escaping @Sendable () async throws -> HostedReviewDetail
  ) async throws -> HostedReviewDetail {
    let epoch = epochs[key, default: 0]
    if let entry = inFlight[key], entry.epoch == epoch {
      return try await entry.task.value
    }
    let entry = Entry(epoch: epoch, id: UUID(), task: Task { try await load() })
    inFlight[key] = entry
    defer {
      if inFlight[key]?.id == entry.id { inFlight[key] = nil }
    }
    return try await entry.task.value
  }

  func invalidate(key: String) {
    epochs[key, default: 0] += 1
    inFlight[key] = nil
  }
}

private struct HostedReviewTarget: Decodable {
  let id: String
  let ordinal: Int
  let label: String?
  let state: String?
  let judgment: String?
  let feedback: String?
}

struct HostedAnnotation: Decodable, Equatable {
  let id: Int
  let reviewId: String
  let quote: String?
  let anchorType: String
  let anchorRef: String?
  let comment: String
  let imageData: String?
  let imageMime: String?
  let createdAt: String?

  /// `reviewId` is the service's internal item ID, not the slug the app keys reviews by.
  /// Annotations are fetched per review, so they take the slug they were requested for.
  func reviewAnnotation(slug: String) -> ReviewAnnotation {
    ReviewAnnotation(
      id: id,
      slug: slug,
      quote: quote,
      anchorType: anchorType,
      anchorRef: anchorRef,
      comment: comment,
      imageData: imageData,
      imageMime: imageMime,
      createdAt: createdAt
    )
  }
}

private struct HostedAnnotationPage: Decodable {
  let annotations: [HostedAnnotation]
  let nextCursor: Int?
}

private struct HostedDeleteAnnotationReceipt: Decodable {
  let deleted: Bool
  let annotationId: Int
}

private struct HostedTargetBody: Encodable {
  let mutationId: String
  let verdict: String
  let feedback: String?
}

private struct HostedAnnotationBody: Encodable {
  let mutationId: String
  let comment: String
  let quote: String?
  let anchorType: String
  let anchorRef: String?
}

private struct HostedDecisionBody: Encodable {
  let mutationId: String
  let decision: String
  let noteText: String?
}

private extension String {
  var pathComponentEncoded: String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
  }

  var queryValueEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
  }

  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
