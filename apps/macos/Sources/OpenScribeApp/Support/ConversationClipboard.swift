import AppKit
import Foundation

/// Copies a conversation as plain text that reads well in any chat or document:
/// a heading (title, local date and length, people), then one paragraph per
/// speaker turn. Rust renders the turns, Draft text included; this adds the
/// reader's locale and the Draft notice.
enum ConversationClipboard {
  struct Options: Equatable, Sendable {
    var timestamps = true
  }

  /// `recordingElapsed` heads a recording still in progress with its timer
  /// instead of a date and length.
  static func text(
    _ conversation: NativeConversationText, title: String, recordingElapsed: String? = nil,
    locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    var lines = [title]
    var facts: [String] = []
    if let recordingElapsed {
      facts.append("Recording in progress")
      facts.append(recordingElapsed)
    } else {
      if conversation.createdAtMs > 0 {
        let date = Date(timeIntervalSince1970: Double(conversation.createdAtMs) / 1_000)
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        facts.append(date.formatted(style))
      }
      if conversation.durationNanoseconds > 0 {
        facts.append(DurationText.length(nanoseconds: conversation.durationNanoseconds))
      }
    }
    if !conversation.participants.isEmpty {
      facts.append(ListFormatter.localizedString(byJoining: conversation.participants))
    }
    if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
    if conversation.hasDraft {
      lines.append("Draft transcript: some words may be misheard.")
    }
    return lines.joined(separator: "\n") + "\n\n" + conversation.body + "\n"
  }

  /// What a Copy says it did: "Copied 3 turns", with "· Draft" when any of
  /// the copied text is Draft.
  static func note(_ conversation: NativeConversationText) -> String {
    let turns = conversation.turnCount == 1 ? "1 turn" : "\(conversation.turnCount) turns"
    return conversation.hasDraft ? "Copied \(turns) · Draft" : "Copied \(turns)"
  }

  static let failureAnnouncement = "The conversation could not be copied."

  @discardableResult
  static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}

extension TranscriptLibraryModel {
  /// The one Copy action. The library row, the menu bar, the document and the
  /// live page all copy through it: Rust's reading copy of the conversation,
  /// headed for this reader, announced the same way everywhere. A recording
  /// in progress copies the Draft text stored so far. Returns the note a
  /// caller may show, or nil when nothing was copied.
  @discardableResult
  func copyConversation(
    _ session: RuntimeSessionPresentation, options: ConversationClipboard.Options = .init()
  ) async -> String? {
    let title = ConversationIdentityPresentation.title(for: session)
    let sessionId = session.sessionId
    let timestamps = options.timestamps
    do {
      let library = try await connectedLibrary()
      let conversation = try await StructuredNativeIO.read {
        try library.conversationText(sessionId: sessionId, includeTimestamps: timestamps)
      }
      guard conversation.turnCount > 0 else { throw CocoaError(.featureUnsupported) }
      let text = ConversationClipboard.text(
        conversation, title: title,
        recordingElapsed: session.lifecycle.isOpenCapture() ? session.timerText : nil)
      guard ConversationClipboard.copy(text) else { throw CocoaError(.featureUnsupported) }
      let note = ConversationClipboard.note(conversation)
      AccessibilityAnnouncer.post(note)
      return note
    } catch {
      AccessibilityAnnouncer.post(ConversationClipboard.failureAnnouncement)
      return nil
    }
  }
}
