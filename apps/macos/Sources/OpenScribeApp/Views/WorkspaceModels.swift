import Foundation
import SwiftUI

@MainActor
final class MainWorkspaceNavigation: ObservableObject {
  struct AudioReviewRequest: Equatable {
    let sessionId: String
    let id = UUID()
  }

  @Published private(set) var selectedSessionId: String?
  @Published private(set) var audioReviewRequest: AudioReviewRequest?
  private(set) var pendingImportedSessionId: String?

  func select(_ sessionId: String?) {
    guard selectedSessionId != sessionId else { return }
    selectedSessionId = sessionId
    audioReviewRequest = nil
  }

  func reviewPreservedAudio(sessionId: String) {
    select(sessionId)
    audioReviewRequest = AudioReviewRequest(sessionId: sessionId)
  }

  func synchronize(
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) {
    let resolved = MainWorkspaceSelection.resolve(
      selectedSessionId: selectedSessionId,
      currentSessionId: currentSessionId,
      savedSessionIds: savedSessionIds,
      preferCurrentSession: preferCurrentSession
    )
    select(resolved)
    reconcileImportedConversation(savedSessionIds: savedSessionIds)
  }

  func acceptImportedConversation(_ sessionId: String?, savedSessionIds: [String]) {
    pendingImportedSessionId = sessionId
    reconcileImportedConversation(savedSessionIds: savedSessionIds)
  }

  private func reconcileImportedConversation(savedSessionIds: [String]) {
    let resolution = MainWorkspaceSelection.reconcileImportedConversation(
      pendingImportedSessionId: pendingImportedSessionId,
      selectedSessionId: selectedSessionId,
      savedSessionIds: savedSessionIds
    )
    select(resolution.selectedSessionId)
    pendingImportedSessionId = resolution.pendingImportedSessionId
  }
}

enum MainWorkspaceSelection {
  struct ImportedConversationResolution: Equatable {
    let selectedSessionId: String?
    let pendingImportedSessionId: String?
  }

  static func resolve(
    selectedSessionId: String?,
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) -> String? {
    if preferCurrentSession, let currentSessionId {
      return currentSessionId
    }

    let availableSessionIds = Set(savedSessionIds + [currentSessionId].compactMap { $0 })
    if let selectedSessionId, availableSessionIds.contains(selectedSessionId) {
      return selectedSessionId
    }
    return currentSessionId ?? savedSessionIds.first
  }

  static func shouldStopDetachedPlayback(
    activePlaybackSessionId: String?,
    selectedSessionId: String?
  ) -> Bool {
    guard let activePlaybackSessionId else { return false }
    return activePlaybackSessionId != selectedSessionId
  }

  static func reconcileImportedConversation(
    pendingImportedSessionId: String?,
    selectedSessionId: String?,
    savedSessionIds: [String]
  ) -> ImportedConversationResolution {
    guard let pendingImportedSessionId else {
      return ImportedConversationResolution(
        selectedSessionId: selectedSessionId,
        pendingImportedSessionId: nil
      )
    }
    guard savedSessionIds.contains(pendingImportedSessionId) else {
      return ImportedConversationResolution(
        selectedSessionId: selectedSessionId,
        pendingImportedSessionId: pendingImportedSessionId
      )
    }
    return ImportedConversationResolution(
      selectedSessionId: pendingImportedSessionId,
      pendingImportedSessionId: nil
    )
  }
}

enum MainWorkspaceActions {
  static func canRecord(liveCanStart: Bool, importIsBusy: Bool) -> Bool {
    liveCanStart && !importIsBusy
  }
}

enum MainWorkspacePlaybackNotice {
  static func shouldPresent(errorSessionId: String?, selectedSessionId: String?) -> Bool {
    errorSessionId == nil || errorSessionId == selectedSessionId
  }
}

enum PlaybackControlAction: Equatable, Sendable {
  case play
  case cancel
  case stop

  static func resolve(isPending: Bool, isPlaying: Bool) -> Self {
    if isPlaying { return .stop }
    if isPending { return .cancel }
    return .play
  }

  var title: String {
    switch self {
    case .play: "Play"
    case .cancel: "Cancel"
    case .stop: "Stop"
    }
  }

  func isEnabled(hasActivePlayback: Bool) -> Bool {
    self != .play || !hasActivePlayback
  }
}

enum ImportedPlaybackEligibility {
  static func canPlay(_ media: RuntimePlayableMediaPresentation) -> Bool {
    media.isPlayable
  }

  static func status(_ media: RuntimePlayableMediaPresentation) -> String {
    return media.statusText
  }
}

enum LibraryConversationLists {
  static func saved(_ sessions: [RuntimeSessionPresentation]) -> [RuntimeSessionPresentation] {
    sessions.filter { $0.lifecycle == "ready_for_review" }
  }

  static func interrupted(_ sessions: [RuntimeSessionPresentation]) -> [RuntimeSessionPresentation]
  {
    sessions.filter { $0.lifecycle == "interrupted" || $0.captureRecoveryIsolated }
  }

  struct DayGroup: Equatable {
    let title: String
    let sessions: [RuntimeSessionPresentation]

    static func == (lhs: DayGroup, rhs: DayGroup) -> Bool {
      lhs.title == rhs.title && lhs.sessions.map(\.sessionId) == rhs.sessions.map(\.sessionId)
    }
  }

  /// Today, Yesterday, Previous 7 Days, then one group per earlier month,
  /// newest first. A conversation with no recorded time keeps its library
  /// order at the end.
  static func dayGroups(
    _ sessions: [RuntimeSessionPresentation], now: Date, calendar: Calendar = .current
  ) -> [DayGroup] {
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
    var order: [String] = []
    var buckets: [String: [RuntimeSessionPresentation]] = [:]
    let sorted = sessions.enumerated().sorted { lhs, rhs in
      switch (lhs.element.createdAt, rhs.element.createdAt) {
      case let (left?, right?): return left > right
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return lhs.offset < rhs.offset
      }
    }.map(\.element)
    for session in sorted {
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
    return order.map { DayGroup(title: $0, sessions: buckets[$0] ?? []) }
  }
}

