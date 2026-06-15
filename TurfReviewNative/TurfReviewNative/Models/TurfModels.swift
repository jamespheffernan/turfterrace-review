import Foundation

enum ReviewTab: String, CaseIterable, Identifiable {
  case pending
  case parked
  case decided

  var id: String { rawValue }

  var title: String {
    switch self {
    case .pending: return "Pending"
    case .parked: return "Parked"
    case .decided: return "Decided"
    }
  }
}

struct ReviewItem: Codable, Hashable, Identifiable {
  let databaseID: Int?
  let slug: String
  let title: String
  let category: String
  var status: String
  var decision: String?
  var actions: ReviewActionList?
  var feedback: String?
  var renderedHTML: String?
  var markdown: String?
  var contentLength: Int?
  var actionStatus: String?
  var actionMessage: String?
  var approvalStatus: String?
  var approvalMessage: String?
  var ttsStatus: String?
  var contextStatus: String?
  var contextSummary: String?
  var decisionSchemaVersion: Int?
  var sessionKey: String? = nil
  var workspaceDir: String? = nil
  var sourcePath: String? = nil
  var createdAt: String?
  var updatedAt: String?

  var id: String { slug }

  enum CodingKeys: String, CodingKey {
    case databaseID = "id"
    case slug
    case title
    case category
    case status
    case decision
    case actions
    case feedback
    case renderedHTML = "rendered_html"
    case markdown
    case contentLength = "content_length"
    case actionStatus = "action_status"
    case actionMessage = "action_message"
    case approvalStatus = "approval_status"
    case approvalMessage = "approval_message"
    case ttsStatus = "tts_status"
    case contextStatus = "context_status"
    case contextSummary = "context_summary"
    case decisionSchemaVersion = "decision_schema_version"
    case sessionKey = "session_key"
    case workspaceDir = "workspace_dir"
    case sourcePath = "source_path"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  var effectiveActionStatus: String? {
    actionStatus ?? approvalStatus
  }

  var effectiveActionMessage: String? {
    actionMessage ?? approvalMessage
  }

  var normalizedStatus: String {
    Self.normalizedToken(status)
  }

  var isPending: Bool {
    normalizedStatus == "pending"
  }

  var isParked: Bool {
    normalizedStatus == "parked"
      || (normalizedStatus == "archived" && decision.map(Self.normalizedToken) == "park")
  }

  var isDecided: Bool {
    !isPending && !isParked
  }

  var allowedActions: [String] {
    if usesCanonicalRouting {
      return Self.canonicalActions(for: category)
    }

    if let values = actions?.values,
       !values.isEmpty {
      return values
    }

    return Self.canonicalActions(for: category)
  }

  var archiveAction: String? {
    let noActionDecisions = ["Noted", "No further action", "Park"]
    return noActionDecisions.first { decision in
      allowedActions.contains { Self.normalizedToken($0) == Self.normalizedToken(decision) }
    }
  }

  var usesCanonicalRouting: Bool {
    (decisionSchemaVersion ?? 1) >= 3
      || sessionKey?.nilIfBlank != nil
      || workspaceDir?.nilIfBlank != nil
      || sourcePath?.nilIfBlank != nil
  }

  var contentLengthLabel: String {
    let length = contentLength ?? max(markdown?.count ?? 0, renderedHTML?.count ?? 0)
    guard length > 0 else { return "No body" }
    if length == 1 { return "1 char" }
    if length < 1000 { return "\(length) chars" }

    let tenths = Int((Double(length) / 100.0).rounded())
    let whole = tenths / 10
    let decimal = tenths % 10
    if decimal == 0 {
      return "\(whole)k chars"
    }
    return "\(whole).\(decimal)k chars"
  }

  var displayHTML: String {
    if let renderedHTML, !renderedHTML.isEmpty { return renderedHTML }
    if let markdown, !markdown.isEmpty { return "<pre>\(Self.escapeHTML(markdown))</pre>" }
    return "<p>No review body was returned by the server.</p>"
  }

  static func canonicalActions(for category: String) -> [String] {
    switch normalizedToken(category) {
    case "outreach": return ["Send", "Edit", "Kill"]
    case "kitchenlux": return ["Execute", "Inbox", "Rework", "Park", "Kill"]
    case "confirmation": return ["Approve", "Rework", "Kill", "No further action"]
    case "clarification": return ["Execute", "Rework", "Kill", "No further action"]
    default: return ["Noted", "Execute", "Inbox", "Rework", "Kill"]
    }
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func normalizedToken(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

struct ReviewActionList: Codable, Hashable {
  let values: [String]

  init(_ values: [String]) {
    self.values = values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if let values = try? container.decode([String].self) {
      self.init(values)
      return
    }

    if let raw = try? container.decode(String.self),
       let data = raw.data(using: .utf8),
       let values = try? JSONDecoder().decode([String].self, from: data) {
      self.init(values)
      return
    }

    self.init([])
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(values)
  }
}

struct DownstreamStatus: Equatable {
  let rawValue: String

  init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  var normalizedValue: String {
    rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  var needsRetry: Bool {
    switch normalizedValue {
    case "failed", "blocked", "blocked_system", "blocked_decision":
      return true
    default:
      return false
    }
  }
}

enum ReviewDisplayText {
  static func statusLabel(_ value: String?) -> String {
    label(
      value,
      knownLabels: [
        "blocked decision": "Blocked Decision",
        "blocked system": "Blocked System",
        "waiting external": "Waiting External",
        "needs confirmation": "Needs Confirmation",
      ]
    )
  }

  static func kindLabel(_ value: String?) -> String {
    label(
      value,
      knownLabels: [
        "agent build": "Agent Build",
        "agent followup": "Agent Follow-Up",
        "agent rework": "Agent Rework",
        "create calendar event": "Calendar Event",
        "create omnifocus task": "OmniFocus Task",
        "decision clarification": "Decision Clarification",
        "outreach approval": "Outreach Approval",
        "sensitive confirmation": "Sensitive Confirmation",
      ]
    )
  }

  static func actionLabel(_ value: String?) -> String {
    label(value, knownLabels: ["no further action": "No Further Action"])
  }

  private static func label(_ value: String?, knownLabels: [String: String]) -> String {
    guard let normalized = value?.normalizedDisplayToken else { return "Unknown" }
    if let known = knownLabels[normalized] { return known }

    return normalized
      .split(separator: " ")
      .map { word in
        word.prefix(1).uppercased() + word.dropFirst()
      }
      .joined(separator: " ")
  }
}

struct DownstreamRetryState {
  static func needsRetry(
    itemStatus: String?,
    decisionRequests: [DecisionRequest],
    legacyActions: [LegacyAction]
  ) -> Bool {
    if let latestRequest = decisionRequests.first {
      return DownstreamStatus(latestRequest.status).needsRetry
    }

    if let latestAction = legacyActions.first {
      return DownstreamStatus(latestAction.status).needsRetry
    }

    guard let itemStatus else {
      return false
    }
    return DownstreamStatus(itemStatus).needsRetry
  }
}

struct ReviewAnnotation: Codable, Hashable, Identifiable {
  let id: Int
  let slug: String?
  let quote: String?
  let anchorType: String
  let anchorRef: String?
  let comment: String
  let imageData: String?
  let imageMime: String?
  let createdAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case slug
    case quote
    case anchorType = "anchor_type"
    case anchorRef = "anchor_ref"
    case comment
    case imageData = "image_data"
    case imageMime = "image_mime"
    case createdAt = "created_at"
  }

  init(
    id: Int,
    slug: String?,
    quote: String?,
    anchorType: String,
    anchorRef: String?,
    comment: String,
    imageData: String? = nil,
    imageMime: String? = nil,
    createdAt: String?
  ) {
    self.id = id
    self.slug = slug
    self.quote = quote
    self.anchorType = anchorType
    self.anchorRef = anchorRef
    self.comment = comment
    self.imageData = imageData
    self.imageMime = imageMime
    self.createdAt = createdAt
  }
}

struct ReviewTarget: Codable, Hashable, Identifiable {
  let databaseID: Int?
  let key: String
  let label: String
  let sourceType: String?
  let anchorRef: String?
  let ordinal: Int
  let verdict: String
  let feedback: String?
  let decided: Bool
  let decidedAt: String?
  let updatedAt: String?

  var id: String { key }

  enum CodingKeys: String, CodingKey {
    case databaseID = "id"
    case key
    case label
    case sourceType
    case anchorRef
    case ordinal
    case verdict
    case feedback
    case decided
    case decidedAt
    case updatedAt
  }

  init(
    databaseID: Int? = nil,
    key: String,
    label: String,
    sourceType: String? = nil,
    anchorRef: String? = nil,
    ordinal: Int,
    verdict: String = "unset",
    feedback: String? = nil,
    decided: Bool? = nil,
    decidedAt: String? = nil,
    updatedAt: String? = nil
  ) {
    self.databaseID = databaseID
    self.key = key
    self.label = label
    self.sourceType = sourceType
    self.anchorRef = anchorRef
    self.ordinal = ordinal
    self.verdict = verdict
    self.feedback = feedback
    self.decided = decided ?? (verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unset")
    self.decidedAt = decidedAt
    self.updatedAt = updatedAt
  }

  var normalizedVerdict: String {
    verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  var isApproved: Bool { normalizedVerdict == "approved" }
  var isRejected: Bool { normalizedVerdict == "rejected" }
  var isUnset: Bool { normalizedVerdict == "unset" || normalizedVerdict.isEmpty }
}

struct ReviewTargetSummary: Codable, Hashable {
  let total: Int
  let approved: Int
  let rejected: Int
  let undecided: Int
  let decided: Int
  let complete: Bool

  static let empty = ReviewTargetSummary(
    total: 0,
    approved: 0,
    rejected: 0,
    undecided: 0,
    decided: 0,
    complete: true
  )
}

struct ReviewTargetsResponse: Codable, Hashable {
  let slug: String
  let targets: [ReviewTarget]
  let summary: ReviewTargetSummary
}

struct ReviewTargetJudgmentResponse: Codable, Hashable {
  let slug: String
  let target: ReviewTarget?
  let summary: ReviewTargetSummary
}

struct DecisionRequest: Codable, Hashable, Identifiable {
  let id: Int
  let slug: String?
  let kind: String
  let summary: String
  let sensitivity: String?
  let status: String
  let proofJSON: String?
  let confirmationSlug: String?
  let lastError: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case slug
    case kind
    case summary
    case sensitivity
    case status
    case proofJSON = "proof_json"
    case confirmationSlug = "confirmation_slug"
    case lastError = "last_error"
    case updatedAt = "updated_at"
  }

  var proofSummary: String? {
    guard let proofJSON = proofJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
          !proofJSON.isEmpty,
          let data = proofJSON.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
      return nil
    }

    if let dictionary = object as? [String: Any] {
      return Self.preferredProofSummary(from: dictionary)
        ?? Self.compactProofSummary(from: dictionary)
    }

    if let values = object as? [Any] {
      return values
        .compactMap(Self.proofValueLabel)
        .prefix(3)
        .joined(separator: " | ")
        .nilIfBlank
    }

    return Self.proofValueLabel(object)
  }

  private static func preferredProofSummary(from dictionary: [String: Any]) -> String? {
    for key in ["summary", "message", "detail", "result", "proof"] {
      if let label = proofValueLabel(dictionary[key]) {
        return label
      }
    }
    return nil
  }

  private static func compactProofSummary(from dictionary: [String: Any]) -> String? {
    dictionary.keys
      .sorted()
      .compactMap { key in
        proofValueLabel(dictionary[key]).map { "\(ReviewDisplayText.actionLabel(key)): \($0)" }
      }
      .prefix(3)
      .joined(separator: " | ")
      .nilIfBlank
  }

  private static func proofValueLabel(_ value: Any?) -> String? {
    switch value {
    case let value as String:
      return value.nilIfBlank
    case let value as Bool:
      return value ? "true" : "false"
    case let value as NSNumber:
      return value.stringValue.nilIfBlank
    default:
      return nil
    }
  }
}

struct ReviewActionsResponse: Codable {
  let slug: String
  let requests: [DecisionRequest]
  let legacyActions: [LegacyAction]
}

extension ReviewActionsResponse {
  enum CodingKeys: String, CodingKey {
    case slug
    case requests
    case legacyActions
    case legacyActionsSnake = "legacy_actions"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    slug = try container.decode(String.self, forKey: .slug)
    requests = try container.decodeIfPresent([DecisionRequest].self, forKey: .requests) ?? []
    legacyActions = try container.decodeIfPresent([LegacyAction].self, forKey: .legacyActions)
      ?? container.decodeIfPresent([LegacyAction].self, forKey: .legacyActionsSnake)
      ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(slug, forKey: .slug)
    try container.encode(requests, forKey: .requests)
    try container.encode(legacyActions, forKey: .legacyActions)
  }
}

struct LegacyAction: Codable, Hashable, Identifiable {
  let id: Int
  let slug: String
  let decision: String
  let status: String
  let lastError: String?

  enum CodingKeys: String, CodingKey {
    case id
    case slug
    case decision
    case status
    case lastError = "last_error"
  }
}

struct DecisionResponse: Codable {
  struct ActionSummary: Codable {
    let status: String
    let message: String
  }

  struct RequestSummary: Codable, Hashable, Identifiable {
    let id: Int
    let kind: String
    let status: String
    let summary: String
  }

  struct FollowupSummary: Codable, Hashable, Identifiable {
    var id: String { slug }
    let slug: String
    let title: String
    let url: String
  }

  let status: String
  let decision: String
  let slug: String
  let queued: Bool
  let processed: Bool
  let sessionKey: String?
  let action: ActionSummary
  let requests: [RequestSummary]
  let followups: [FollowupSummary]

  enum CodingKeys: String, CodingKey {
    case status
    case decision
    case slug
    case queued
    case processed
    case sessionKey
    case action
    case requests
    case followups
  }
}

extension DecisionResponse {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let alternateContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)

    status = try container.decode(String.self, forKey: .status)
    decision = try container.decode(String.self, forKey: .decision)
    slug = try container.decode(String.self, forKey: .slug)
    queued = try container.decodeIfPresent(Bool.self, forKey: .queued) ?? false
    processed = try container.decodeIfPresent(Bool.self, forKey: .processed) ?? false
    sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
      ?? alternateContainer.decodeIfPresent(String.self, forKey: .sessionKey)
    action = try container.decodeIfPresent(ActionSummary.self, forKey: .action)
      ?? ActionSummary(status: queued ? "queued" : "succeeded", message: "\(decision) saved.")
    requests = try container.decodeIfPresent([RequestSummary].self, forKey: .requests) ?? []
    followups = try container.decodeIfPresent([FollowupSummary].self, forKey: .followups) ?? []
  }

  private enum AlternateCodingKeys: String, CodingKey {
    case sessionKey = "session_key"
  }
}

struct ChatMessage: Codable, Hashable, Identifiable {
  var id = UUID()
  let role: String
  let content: String
  let createdAt: String?

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case createdAt = "created_at"
  }
}

struct ChatHistoryResponse: Codable {
  let sessionKey: String
  let messages: [ChatMessage]
}

extension ChatHistoryResponse {
  enum CodingKeys: String, CodingKey {
    case sessionKey
    case messages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let alternateContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
    sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
      ?? alternateContainer.decode(String.self, forKey: .sessionKey)
    messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
  }

  private enum AlternateCodingKeys: String, CodingKey {
    case sessionKey = "session_key"
  }
}

struct ChatSendResponse: Codable {
  let sessionKey: String
  let message: ChatMessage
}

extension ChatSendResponse {
  enum CodingKeys: String, CodingKey {
    case sessionKey
    case message
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let alternateContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
    sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
      ?? alternateContainer.decode(String.self, forKey: .sessionKey)
    message = try container.decode(ChatMessage.self, forKey: .message)
  }

  private enum AlternateCodingKeys: String, CodingKey {
    case sessionKey = "session_key"
  }
}

struct AudioStatusResponse: Codable, Hashable {
  let status: String?
  let url: String?
  let summary: String?

  init(status: String?, url: String?, summary: String?) {
    self.status = status
    self.url = url
    self.summary = summary
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case url
    case summary
    case contextSummary = "context_summary"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(String.self, forKey: .status)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
      ?? container.decodeIfPresent(String.self, forKey: .contextSummary)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(status, forKey: .status)
    try container.encodeIfPresent(url, forKey: .url)
    try container.encodeIfPresent(summary, forKey: .summary)
  }
}

struct RetryResponse: Codable {
  struct ActionSummary: Codable {
    let id: Int
    let status: String
    let decision: String?
  }

  struct RequestSummary: Codable {
    let id: Int
    let status: String
    let kind: String?
  }

  let ok: Bool
  let slug: String?
  let action: ActionSummary?
  let request: RequestSummary?
  let error: String?
  let detail: String?
  let message: String?

  init(
    ok: Bool,
    slug: String?,
    action: ActionSummary? = nil,
    request: RequestSummary? = nil,
    error: String? = nil,
    detail: String? = nil,
    message: String? = nil
  ) {
    self.ok = ok
    self.slug = slug
    self.action = action
    self.request = request
    self.error = error
    self.detail = detail
    self.message = message
  }

  var rejectionMessage: String {
    APIMessageResponse(error: error, detail: detail, message: message).displayMessage
      ?? "Retry was not accepted by the server."
  }
}

struct DeleteAnnotationResponse: Codable {
  let deleted: Bool
  let error: String?
  let detail: String?
  let message: String?

  init(deleted: Bool, error: String? = nil, detail: String? = nil, message: String? = nil) {
    self.deleted = deleted
    self.error = error
    self.detail = detail
    self.message = message
  }

  var rejectionMessage: String {
    APIMessageResponse(error: error, detail: detail, message: message).displayMessage
      ?? "Annotation was not deleted by the server."
  }
}

struct APIMessageResponse: Codable {
  let error: String?
  let detail: String?
  let message: String?

  var displayMessage: String? {
    error?.apiMessageText
      ?? detail?.apiMessageText
      ?? message?.apiMessageText
  }
}

private extension String {
  var normalizedDisplayToken: String? {
    let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    return normalized.isEmpty ? nil : normalized
  }

  var apiMessageText: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
