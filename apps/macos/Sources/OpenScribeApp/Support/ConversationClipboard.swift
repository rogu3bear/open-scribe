import AppKit
import Foundation

/// Copies a conversation as plain text that reads well in any chat or document:
/// a heading (title, local date and length, people), then one paragraph per
/// speaker turn. Rust renders the turns; this adds the reader's locale.
enum ConversationClipboard {
  struct Options: Equatable, Sendable {
    var timestamps = true
  }

  static func text(
    _ conversation: NativeConversationText, title: String, locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    var lines = [title]
    var facts: [String] = []
    if conversation.createdAtMs > 0 {
      let date = Date(timeIntervalSince1970: Double(conversation.createdAtMs) / 1_000)
      var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
      style.locale = locale
      style.timeZone = timeZone
      facts.append(date.formatted(style))
    }
    if conversation.durationNanoseconds > 0 {
      facts.append(duration(nanoseconds: conversation.durationNanoseconds))
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

  /// "4 min", "1 hr 12 min", "45 sec".
  static func duration(nanoseconds: Int64) -> String {
    let seconds = max(1, Int((Double(nanoseconds) / 1_000_000_000).rounded()))
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) sec"
  }

  @discardableResult
  static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}

extension TranscriptLibraryModel {
  /// The clipboard text for a saved conversation, read in one pass.
  func clipboardText(
    sessionId: String, title: String, options: ConversationClipboard.Options = .init()
  ) async throws -> (text: String, turns: UInt32, hasDraft: Bool) {
    let library = try await connectedLibrary()
    let timestamps = options.timestamps
    let conversation = try await StructuredNativeIO.read {
      try library.conversationText(sessionId: sessionId, includeTimestamps: timestamps)
    }
    return (
      ConversationClipboard.text(conversation, title: title), conversation.turnCount,
      conversation.hasDraft
    )
  }
}
