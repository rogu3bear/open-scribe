import AppKit

@MainActor
enum AccessibilityAnnouncer {
  static func post(_ message: String) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }
}

/// Tracks capture truth at the shared store, independently of view focus and
/// elapsed time. Only successful Rust snapshots advance the announcement state.
struct RuntimeCaptureAnnouncements {
  private struct State: Equatable {
    let sessionId: String
    let announcement: String?
  }

  private var currentState: State?
  private var savedRecoveryStates: [String: State]?

  mutating func update(
    current: RuntimeSessionPresentation?, saved: [RuntimeSessionPresentation]
  ) -> [String] {
    var messages: [String] = []
    let previousCurrent = currentState
    let nextCurrent = current.map { State(sessionId: $0.sessionId, announcement: message(for: $0)) }
    if nextCurrent != currentState, let message = nextCurrent?.announcement {
      messages.append(message)
    }
    currentState = nextCurrent

    let nextSaved = Dictionary(
      uniqueKeysWithValues: saved.filter { $0.recovered && $0.needsAttention }.map {
        ($0.sessionId, State(sessionId: $0.sessionId, announcement: message(for: $0)))
      }
    )
    // Seed existing history silently. Newly recovered partial recordings are
    // material changes, but moving unchanged interrupted truth into the library
    // must not announce it a second time.
    if let savedRecoveryStates {
      for session in saved where session.recovered && session.needsAttention {
        let state = State(sessionId: session.sessionId, announcement: message(for: session))
        if savedRecoveryStates[session.sessionId] != state, previousCurrent != state,
          nextCurrent != state, let message = state.announcement
        {
          messages.append(message)
        }
      }
    }
    savedRecoveryStates = nextSaved
    return messages
  }

  private func message(for session: RuntimeSessionPresentation) -> String? {
    let failed = session.sources.filter { $0.lifecycle == "failed" }.map(\.name).sorted()
    let failure =
      failed.isEmpty ? "" : " \(ListFormatter.localizedString(byJoining: failed)) failed."
    let durableCapture =
      session.lifecycle == "recording"
      && session.journalDurable && session.mediaFilesOpen
    let continuation: String
    if durableCapture, session.sources.contains(where: { $0.lifecycle == "capturing" }) {
      continuation = " Capture continues on \(capturingSources(in: session))."
    } else if session.lifecycle == "paused" {
      continuation = " Capture is paused."
    } else {
      continuation = " No source is confirmed capturing."
    }
    if session.interruptionReason == "permission_revoked" {
      return "Capture permission was withdrawn.\(failure)\(continuation)"
        + (session.needsAttention ? " Recovery required." : "")
    }
    if session.lifecycle == "interrupted" || (session.recovered && session.needsAttention) {
      return "Recovery required for \(session.title).\(failure)\(continuation)"
    }
    if session.lifecycle == "paused" {
      return "Paused.\(failure) Capture is suspended."
    }
    guard durableCapture else { return nil }
    if session.isDegradedRecording {
      return "Recording — degraded.\(failure)\(continuation)"
    }
    guard session.isRecording else { return nil }
    return "Recording \(capturingSources(in: session)).\(failure)"
      + (failed.isEmpty ? "" : continuation)
  }

  private func capturingSources(in session: RuntimeSessionPresentation) -> String {
    let names = session.sources.filter { $0.lifecycle == "capturing" }.map(\.name).sorted()
    return names.isEmpty ? "audio" : ListFormatter.localizedString(byJoining: names)
  }
}
