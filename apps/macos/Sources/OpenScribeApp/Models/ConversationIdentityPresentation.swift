import Foundation

/// Readable identity is a projection; the stored title and session ID stay intact.
enum ConversationIdentityPresentation {
  static func title(
    _ storedTitle: String, locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    let prefix = "Conversation "
    guard storedTitle.hasPrefix(prefix) else { return storedTitle }
    let timestamp = String(storedTitle.dropFirst(prefix.count))
    let parser = ISO8601DateFormatter()
    guard let date = parser.date(from: timestamp), parser.string(from: date) == timestamp else {
      return storedTitle
    }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  /// Only otherwise indistinguishable rows need a reference. Grow the suffix
  /// when necessary instead of allowing two short references to collide.
  static func references(for sessions: [RuntimeSessionPresentation]) -> [String: String] {
    let unique = Dictionary(
      sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
    let groups = Dictionary(grouping: unique.values) {
      [title($0.title), $0.timerText, $0.statusText]
    }
    var result = [String: String]()
    for group in groups.values where group.count > 1 {
      let ids = group.map(\.sessionId)
      var length = 6
      while Set(ids.map { String($0.suffix(length)) }).count < ids.count {
        length += 1
      }
      for id in ids { result[id] = String(id.suffix(length)) }
    }
    return result
  }
}
