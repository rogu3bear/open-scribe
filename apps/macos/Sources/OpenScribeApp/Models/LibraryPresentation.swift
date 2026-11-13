import Foundation

/// The library as every surface shows it, built once per Rust snapshot: the
/// sidebar, the menu bar, search matches, the bottom bar, and Settings.
/// Rust keeps the newest interrupted session as its current session; here it
/// joins the others, so there is one Needs Attention list.
struct LibraryPresentation: Equatable, Sendable {
  struct Section: Equatable, Identifiable, Sendable {
    let title: String
    let sessions: [RuntimeSessionPresentation]
    var id: String { title }
  }

  /// The capture in progress.
  let now: RuntimeSessionPresentation?
  /// Stopped recordings that kept audio, newest first.
  let needsAttention: [RuntimeSessionPresentation]
  /// Saved conversations: Today, Yesterday, Previous 7 Days, then by month.
  let days: [Section]
  /// Attempts that stopped before any audio was saved, newest first. The
  /// sidebar folds them into one quiet row.
  let didNotRecord: [RuntimeSessionPresentation]
  /// Saved conversations in library order.
  let saved: [RuntimeSessionPresentation]
  /// The newest saved conversation Copy can copy.
  let latestCopyable: RuntimeSessionPresentation?
  /// The reader's title for every listed conversation.
  let titles: [String: String]
  /// Short references, only for rows that would otherwise read the same.
  let references: [String: String]
  private let sessions: [String: RuntimeSessionPresentation]

  static let empty = LibraryPresentation(current: nil, saved: [], now: Date())

  init(
    current: RuntimeSessionPresentation?, saved library: [RuntimeSessionPresentation],
    now date: Date, calendar: Calendar = .current
  ) {
    let all = (current.map { [$0] } ?? []) + library
    var unique: [RuntimeSessionPresentation] = []
    var seen = Set<String>()
    for session in all where seen.insert(session.sessionId).inserted { unique.append(session) }
    let stopped = unique.filter { $0.lifecycle == .interrupted || $0.captureRecoveryIsolated }
    now = current.flatMap { $0.lifecycle.isOpenCapture() && !$0.captureRecoveryIsolated ? $0 : nil }
    needsAttention = Self.newestFirst(stopped.filter { !$0.didNotRecord })
    didNotRecord = Self.newestFirst(stopped.filter(\.didNotRecord))
    saved = unique.filter { $0.lifecycle == .readyForReview }
    days = Self.dayGroups(saved, now: date, calendar: calendar)
    latestCopyable = saved.filter(Self.canCopy).max {
      ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
    }
    titles = Dictionary(
      unique.map { ($0.sessionId, ConversationIdentityPresentation.title(for: $0)) },
      uniquingKeysWith: { first, _ in first })
    let shown = (now.map { [$0] } ?? []) + needsAttention + saved
    references = ConversationIdentityPresentation.references(for: shown)
    sessions = Dictionary(
      unique.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
  }

  func session(_ sessionId: String?) -> RuntimeSessionPresentation? {
    sessionId.flatMap { sessions[$0] }
  }

  /// Saved conversations and stopped recordings that kept audio.
  var conversationCount: Int { saved.count + needsAttention.count + (now == nil ? 0 : 1) }

  var isEmpty: Bool { now == nil && needsAttention.isEmpty && saved.isEmpty }

  /// The conversation whose kept audio the menu offers to review.
  func preservedConversation(
    media: [NativeRecoveredPlayableSession]
  ) -> RuntimeSessionPresentation? {
    Self.preservedConversation(in: needsAttention + saved, media: media)
  }

  static func preservedConversation(
    in sessions: [RuntimeSessionPresentation], media: [NativeRecoveredPlayableSession]
  ) -> RuntimeSessionPresentation? {
    sessions.first {
      ($0.lifecycle == .interrupted || $0.lifecycle == .readyForReview)
        && ($0.needsAttention || $0.recovered) && $0.hasVerifiedPreservedAudio(from: media)
    }
  }

  // MARK: What a person may do with a conversation

  /// Copy needs transcript text: Final, partly Final, or the live Draft.
  static func canCopy(_ session: RuntimeSessionPresentation) -> Bool {
    session.lifecycle == .readyForReview
      && (session.transcript.documentAvailability == .final
        || session.transcript.documentAvailability == .partial
        || session.transcript.hasDraftText)
  }

  /// Any conversation except the capture in progress can be renamed.
  static func canRename(_ session: RuntimeSessionPresentation) -> Bool {
    session.lifecycle == .readyForReview || session.lifecycle == .interrupted
      || session.captureRecoveryIsolated
  }

  /// Why Move to Trash is unavailable, or nil when it is offered. Rust decides
  /// which sessions may go; a recording in progress holds every deletion.
  static func trashUnavailableReason(
    _ session: RuntimeSessionPresentation, recorderIdle: Bool
  ) -> String? {
    if !session.canMoveToTrash {
      return session.captureRecoveryIsolated
        ? "This recording's audio couldn't be opened, so it stays in the library."
        : "Finish the current recording before moving this conversation to Trash."
    }
    return recorderIdle
      ? nil : "Finish the current recording before moving a conversation to Trash."
  }

  // MARK: Grouping

  private static func newestFirst(
    _ sessions: [RuntimeSessionPresentation]
  ) -> [RuntimeSessionPresentation] {
    sessions.enumerated().sorted { lhs, rhs in
      switch (lhs.element.createdAt, rhs.element.createdAt) {
      case let (left?, right?) where left != right: return left > right
      case (.some, nil): return true
      case (nil, .some): return false
      default: return lhs.offset < rhs.offset
      }
    }.map(\.element)
  }

  /// Today, Yesterday, Previous 7 Days, then one group per earlier month,
  /// newest first. A conversation with no recorded time keeps its library
  /// order at the end.
  static func dayGroups(
    _ sessions: [RuntimeSessionPresentation], now: Date, calendar: Calendar = .current
  ) -> [Section] {
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
    var order: [String] = []
    var buckets: [String: [RuntimeSessionPresentation]] = [:]
    for session in newestFirst(sessions) {
      let title: String
      if let created = session.createdAt {
        if created >= today {
          title = "Today"
        } else if created >= yesterday {
          title = "Yesterday"
        } else if created >= week {
          title = "Previous 7 Days"
        } else {
          let sameYear =
            calendar.component(.year, from: created) == calendar.component(.year, from: now)
          title =
            sameYear
            ? created.formatted(.dateTime.month(.wide))
            : created.formatted(.dateTime.month(.wide).year())
        }
      } else {
        title = "Earlier"
      }
      if buckets[title] == nil { order.append(title) }
      buckets[title, default: []].append(session)
    }
    return order.map { Section(title: $0, sessions: buckets[$0] ?? []) }
  }
}
