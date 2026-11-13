import Foundation

/// Readable identity is a projection; the stored title and session ID stay intact.
enum ConversationIdentityPresentation {
  /// The title a reader sees for a conversation: a person's title or a
  /// suggestion as written, and a capture placeholder as a time of day.
  static func title(
    for session: RuntimeSessionPresentation, locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    title(session.displayTitle, locale: locale, timeZone: timeZone)
  }

  /// A capture placeholder (`Conversation <ISO 8601>`) reads as the time the
  /// conversation began; the library's date sections carry the day.
  static func title(
    _ storedTitle: String, locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    guard let date = placeholderDate(storedTitle) else { return storedTitle }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return "Conversation at \(formatter.string(from: date))"
  }

  static func isPlaceholder(_ storedTitle: String) -> Bool {
    placeholderDate(storedTitle) != nil
  }

  private static func placeholderDate(_ storedTitle: String) -> Date? {
    let prefix = "Conversation "
    guard storedTitle.hasPrefix(prefix) else { return nil }
    let timestamp = String(storedTitle.dropFirst(prefix.count))
    let parser = ISO8601DateFormatter()
    guard let date = parser.date(from: timestamp), parser.string(from: date) == timestamp else {
      return nil
    }
    return date
  }

  /// Only otherwise indistinguishable rows need a reference. Grow the suffix
  /// when necessary instead of allowing two short references to collide.
  static func references(for sessions: [RuntimeSessionPresentation]) -> [String: String] {
    let unique = Dictionary(
      sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
    let groups = Dictionary(grouping: unique.values) {
      [title(for: $0), $0.timerText, $0.statusText]
    }
    var result = [String: String]()
    for group in groups.values where group.count > 1 {
      result.merge(ShortIdentityReference.references(for: group.map(\.sessionId))) { first, _ in
        first
      }
    }
    return result
  }
}

/// Stable references for evidence identities, independent of display order.
enum ShortIdentityReference {
  static func references(for identifiers: [String]) -> [String: String] {
    let ids = Set(identifiers)
    var length = 6
    while Set(ids.map { String($0.suffix(length)) }).count < ids.count {
      length += 1
    }
    return Dictionary(uniqueKeysWithValues: ids.map { ($0, String($0.suffix(length))) })
  }
}
