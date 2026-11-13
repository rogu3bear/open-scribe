import Foundation

/// Runs transcript-derived suggestions for the library and the open
/// conversation, one at a time, off the main actor's critical path.
///
/// Titles are stored through Rust, which refuses them once a person has named
/// the conversation. Name suggestions stay in memory: accepting one is a
/// person's choice and goes through the existing speaker-naming actions.
@MainActor
final class ConversationSuggestionModel: ObservableObject {
  @Published private(set) var suggestions: [String: ConversationSuggestion] = [:]
  @Published private(set) var dismissedNames: Set<String> = []

  private let library: () async throws -> NativeTranscriptLibrary
  private let suggest: @Sendable ([SuggestionTurn]) async -> ConversationSuggestion?
  private var attempted: Set<String> = []
  private var queue: [Request] = []
  private var worker: Task<Void, Never>?
  private var liveAttempts: [String: Int] = [:]
  var onTitleStored: @MainActor () -> Void = {}

  private struct Request: Equatable {
    let sessionId: String
    let key: String
    let turns: [SuggestionTurn]?
    let basis: String?
    /// The open conversation also wants names, even when its title is settled.
    var wantsNames = false
  }

  init(
    library: @escaping () async throws -> NativeTranscriptLibrary,
    suggest: @escaping @Sendable ([SuggestionTurn]) async -> ConversationSuggestion? = {
      await ConversationSuggester.suggest($0)
    }
  ) {
    self.library = library
    self.suggest = suggest
  }

  /// Queues saved conversations whose title is still a placeholder, or whose
  /// suggestion came from Draft text that is now Final.
  func considerLibrary(_ sessions: [RuntimeSessionPresentation]) {
    for session in sessions where session.lifecycle == "ready_for_review" {
      guard session.titleSource != "person" else { continue }
      let transcript = session.transcript
      let hasText = transcript.documentAvailability != .unavailable || transcript.hasDraftText
      guard hasText else { continue }
      let key = "\(session.sessionId)|\(transcript.documentVersion)|\(transcript.state.rawValue)"
      enqueue(Request(sessionId: session.sessionId, key: key, turns: nil, basis: nil))
    }
  }

  /// Suggests a provisional title while recording, from settled live
  /// captions, after about a minute of speech and then every few minutes.
  func considerLive(sessionId: String, lines: [LiveCaptionLine]) {
    let words = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
    let step = words >= 600 ? 3 : words >= 250 ? 2 : words >= 80 ? 1 : 0
    guard step > (liveAttempts[sessionId] ?? 0) else { return }
    liveAttempts[sessionId] = step
    let turns = Self.turns(from: lines)
    enqueue(
      Request(sessionId: sessionId, key: "\(sessionId)|live|\(step)", turns: turns, basis: "draft"))
  }

  /// Names for the open conversation; computed once per transcript version.
  func considerOpen(_ session: RuntimeSessionPresentation) {
    guard session.lifecycle == "ready_for_review" else { return }
    let key = "\(session.sessionId)|open|\(session.transcript.documentVersion)"
    enqueue(
      Request(sessionId: session.sessionId, key: key, turns: nil, basis: nil, wantsNames: true))
  }

  func dismissNames(sessionId: String) {
    dismissedNames.insert(sessionId)
  }

  static func turns(from lines: [LiveCaptionLine]) -> [SuggestionTurn] {
    var turns: [SuggestionTurn] = []
    for line in lines where line.isFinal {
      if let last = turns.last, last.speaker == line.speaker {
        turns[turns.count - 1] = SuggestionTurn(speaker: last.speaker, text: last.text + " " + line.text)
      } else {
        turns.append(SuggestionTurn(speaker: line.speaker, text: line.text))
      }
    }
    return turns
  }

  /// Splits the clipboard body ("Name: text" paragraphs) back into turns.
  static func turns(fromBody body: String) -> [SuggestionTurn] {
    body.components(separatedBy: "\n\n").compactMap { paragraph in
      guard let separator = paragraph.range(of: ": ") else { return nil }
      let speaker = String(paragraph[..<separator.lowerBound])
      let text = String(paragraph[separator.upperBound...])
      return speaker.isEmpty || text.isEmpty ? nil : SuggestionTurn(speaker: speaker, text: text)
    }
  }

  private func enqueue(_ request: Request) {
    guard !attempted.contains(request.key) else { return }
    attempted.insert(request.key)
    queue.append(request)
    guard worker == nil else { return }
    worker = Task { [weak self] in
      while let next = self?.dequeue() {
        await self?.run(next)
      }
      self?.worker = nil
    }
  }

  private func dequeue() -> Request? {
    queue.isEmpty ? nil : queue.removeFirst()
  }

  private func run(_ request: Request) async {
    do {
      let library = try await library()
      let sessionId = request.sessionId
      let current = try? await StructuredNativeIO.read {
        try library.conversationTitle(sessionId: sessionId)
      }
      var storesTitle = current.map(Self.acceptsSuggestion) ?? true
      guard storesTitle || request.wantsNames else { return }
      var turns = request.turns
      var basis = request.basis ?? "final"
      if turns == nil {
        let text = try await StructuredNativeIO.read {
          try library.conversationText(sessionId: sessionId, includeTimestamps: false)
        }
        turns = Self.turns(fromBody: text.body)
        basis = text.hasDraft ? "draft" : "final"
        // Saved Draft text adds little to the live suggestion; wait for Final.
        if current?.source == "suggested", basis == "draft" { storesTitle = false }
      }
      guard storesTitle || request.wantsNames else { return }
      guard let turns, let suggestion = await suggest(turns) else { return }
      suggestions[sessionId] = suggestion
      if storesTitle, let title = suggestion.title {
        let engine = suggestion.engine
        let settledBasis = basis
        let stored = try await StructuredNativeIO.mutation {
          try library.suggestTitle(
            sessionId: sessionId, title: title, engine: engine, basis: settledBasis)
        }
        if stored { onTitleStored() }
      }
    } catch {
      // A suggestion is optional; the conversation keeps its current title.
    }
  }

  /// A suggestion may replace a placeholder or a Draft-based suggestion. A
  /// person's title, or one suggested from Final text, stays put, so later
  /// corrections and launches do not rerun the model or change the title.
  static func acceptsSuggestion(_ title: NativeConversationTitle) -> Bool {
    switch title.source {
    case "placeholder": true
    case "suggested": title.suggestionBasis != "final"
    default: false
    }
  }
}
