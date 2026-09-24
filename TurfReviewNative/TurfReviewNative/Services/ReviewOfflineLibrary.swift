import CryptoKit
import Foundation

/// Downloaded review content is separate from credentials and scoped to one account.
/// Only confirmed server mutations may change review decisions.
actor ReviewOfflineLibrary {
  struct Snapshot: Codable {
    var item: ReviewItem
    var annotations: [ReviewAnnotation]
    var targets: ReviewTargetsResponse
    var tts: AudioStatusResponse?
    var context: AudioStatusResponse?
    var version: String
    var savedAt: Date
    var complete: Bool = false
    var sectionsComplete: Bool = false
  }

  nonisolated let root: URL
  private var active = true
  private var generations: [String: Int] = [:]

  init(root: URL) { self.root = root }

  static func application(configuration: APIConfiguration) -> ReviewOfflineLibrary {
    let identity = configuration.serverURL.absoluteString + "\n" + configuration.username
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TurfReview/Offline/" + key(identity), isDirectory: true)
    return ReviewOfflineLibrary(root: root)
  }

  static func version(_ item: ReviewItem) -> String {
    [item.updatedAt ?? item.createdAt ?? "", String(item.contentLength ?? 0)].joined(separator: "|")
  }

  static func key(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func queue() -> [ReviewItem] {
    guard active else { return [] }
    return (try? JSONDecoder().decode([ReviewItem].self, from: Data(contentsOf: root.appendingPathComponent("queue.json")))) ?? []
  }

  func saveQueue(_ items: [ReviewItem]) throws {
    // Keep the launch index small; document bodies live in separate files.
    let index = items.map { value -> ReviewItem in
      var value = value
      value.renderedHTML = nil
      value.markdown = nil
      return value
    }
    try write(JSONEncoder().encode(index), to: root.appendingPathComponent("queue.json"))
  }

  func snapshot(slug: String) -> Snapshot? {
    guard active else { return nil }
    return try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL(slug)))
  }

  func generation(slug: String) -> Int { generations[slug, default: 0] }

  func save(_ snapshot: Snapshot, generation: Int) throws {
    guard generations[snapshot.item.slug, default: 0] == generation else { throw CancellationError() }
    try write(JSONEncoder().encode(snapshot), to: snapshotURL(snapshot.item.slug))
  }

  func remove(slug: String) {
    generations[slug, default: 0] += 1
    try? FileManager.default.removeItem(at: snapshotURL(slug))
  }
  func pruneDownloads(keeping slugs: Set<String>) {
    guard active else { return }
    let removedSlugs = generations.keys.filter { !slugs.contains($0) }
    for slug in removedSlugs {
      generations[slug, default: 0] += 1
    }
    let fileManager = FileManager.default
    let reviewsDirectory = root.appendingPathComponent("reviews", isDirectory: true)
    let keptSnapshotNames = Set(slugs.map { Self.key($0) + ".json" })
    let snapshotURLs = (try? fileManager.contentsOfDirectory(
      at: reviewsDirectory,
      includingPropertiesForKeys: nil
    )) ?? []

    for snapshotURL in snapshotURLs where !keptSnapshotNames.contains(snapshotURL.lastPathComponent) {
      try? fileManager.removeItem(at: snapshotURL)
    }

    var keptMediaNames: Set<String> = []
    for snapshotURL in snapshotURLs where keptSnapshotNames.contains(snapshotURL.lastPathComponent) {
      guard let data = try? Data(contentsOf: snapshotURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
      for status in [snapshot.tts, snapshot.context] {
        guard let rawURL = status?.url,
              let url = URL(string: rawURL),
              url.isFileURL else { continue }
        keptMediaNames.insert(url.lastPathComponent)
      }
    }

    let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
    let mediaURLs = (try? fileManager.contentsOfDirectory(
      at: mediaDirectory,
      includingPropertiesForKeys: nil
    )) ?? []
    for mediaURL in mediaURLs where !keptMediaNames.contains(mediaURL.lastPathComponent) {
      try? fileManager.removeItem(at: mediaURL)
    }
  }


  func clear() {
    active = false
    try? FileManager.default.removeItem(at: root)
  }

  func mediaURL(remote: URL, version: String) -> URL? {
    let path = mediaDestination(remote: remote, version: version)
    return FileManager.default.fileExists(atPath: path.path) ? path : nil
  }

  func saveMedia(_ data: Data, remote: URL, version: String) throws -> URL {
    let path = mediaDestination(remote: remote, version: version)
    try write(data, to: path)
    return path
  }

  private func mediaDestination(remote: URL, version: String) -> URL {
    root.appendingPathComponent("media", isDirectory: true)
      .appendingPathComponent(Self.key(remote.absoluteString + "|" + version)).appendingPathExtension("mp3")
  }

  private func snapshotURL(_ slug: String) -> URL {
    root.appendingPathComponent("reviews", isDirectory: true)
      .appendingPathComponent(Self.key(slug)).appendingPathExtension("json")
  }

  private func write(_ data: Data, to url: URL) throws {
    guard active else { throw CancellationError() }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var excluded = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    #if os(iOS)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: url, options: .atomic)
    #endif
  }
}

/// Inline ordinary document assets so a saved document has no image/style round trips.
enum OfflineDocumentAssets {
  static func download(html: String, baseURL: URL, client: TurfReviewServicing) async throws -> String {
    var output = html
    let tags = try NSRegularExpression(pattern: #"<(?:img|script|link|source|video|audio)\b[^>]*>"#, options: [.caseInsensitive])
    let attributes = try NSRegularExpression(pattern: #"\b(src|href|poster|srcset)\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
    var matches: [NSTextCheckingResult] = []
    for tag in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      if let range = Range(tag.range, in: html) {
        let text = html[range].lowercased()
        if text.hasPrefix("<link"), !text.contains("stylesheet"), !text.contains("icon") { continue }
      }
      matches += attributes.matches(in: html, range: tag.range)
    }
    var replacements: [String: String] = [:]
    for match in matches {
      try Task.checkCancellation()
      guard let range = Range(match.range(at: 2), in: html),
            let nameRange = Range(match.range(at: 1), in: html) else { continue }
      let raw = String(html[range])
      if html[nameRange].lowercased() == "srcset" {
        // Data URI sources already work offline; avoid splitting their embedded commas.
        if raw.contains("data:") { continue }
        var candidates: [String] = []
        for candidate in raw.split(separator: ",") {
          let parts = candidate.split(whereSeparator: { $0.isWhitespace })
          guard let source = parts.first,
                let url = URL(string: String(source), relativeTo: baseURL)?.absoluteURL,
                ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
          let dataURL = try await resource(url, client: client, visited: [])
          candidates.append(([dataURL] + parts.dropFirst().map(String.init)).joined(separator: " "))
        }
        if !candidates.isEmpty { replacements[raw] = candidates.joined(separator: ", ") }
      } else {
        guard replacements[raw] == nil,
              let url = URL(string: raw.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
        replacements[raw] = try await resource(url, client: client, visited: [])
      }
    }
    for match in matches.reversed() {
      guard let range = Range(match.range(at: 2), in: output),
            let original = Range(match.range(at: 2), in: html),
            let replacement = replacements[String(html[original])] else { continue }
      output.replaceSubrange(range, with: replacement)
    }
    return output
  }

  private static func resource(_ url: URL, client: TurfReviewServicing, visited: Set<URL>) async throws -> String {
    guard !visited.contains(url), visited.count < 12 else { throw URLError(.cannotDecodeContentData) }
    var visited = visited
    visited.insert(url)
    var (data, mime) = try await client.downloadResource(url)
    if mime == "text/css", let css = String(data: data, encoding: .utf8) {
      let pattern = #"url\(\s*["']?([^"')]+)["']?\s*\)|@import\s+["']([^"']+)["']"#
      let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      var result = css
      for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
        let capture = match.range(at: 1).location == NSNotFound ? 2 : 1
        guard let originalRange = Range(match.range(at: capture), in: css),
              let resultRange = Range(match.range(at: capture), in: result) else { continue }
        let raw = String(css[originalRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let child = URL(string: raw, relativeTo: url)?.absoluteURL,
              ["https", "http"].contains(child.scheme?.lowercased() ?? "") else { continue }
        let replacement = try await resource(child, client: client, visited: visited)
        result.replaceSubrange(resultRange, with: replacement)
      }
      data = Data(result.utf8)
    }
    return "data:\(mime);base64,\(data.base64EncodedString())"
  }

}
