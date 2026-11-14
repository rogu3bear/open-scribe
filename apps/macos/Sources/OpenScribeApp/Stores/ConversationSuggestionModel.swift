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
    /// The open conversation also wants names, even when its title is settled.
    var wantsNames = false
  }

  /// A suspended model never suggests and never opens the library: proof and
  /// hosted launches keep titles and names as stored.
  init(
    library: @escaping () async throws -> NativeTranscriptLibrary,
    suspended: Bool = false,
    suggest: @escaping @Sendable ([SuggestionTurn]) async -> ConversationSuggestion? = {
      await ConversationSuggester.suggest($0)
    }
  ) {
    if suspended {
      self.library = { throw NativeStorageError.InvalidState }
      self.suggest = { @Sendable _ in nil }
    } else {
      self.library = library
      self.suggest = suggest
    }
  }

  /// Queues saved conversations whose title is still a placeholder, or whose
  /// suggestion came from Draft text that is now Final.
  func considerLibrary(_ sessions: [RuntimeSessionPresentation]) {
    for session in sessions where session.lifecycle == .readyForReview {
      guard session.titleSource != .person else { continue }
      let transcript = session.transcript
      let hasText = transcript.documentAvailability != .unavailable || transcript.hasDraftText
      guard hasText else { continue }
      let key = "\(session.sessionId)|\(transcript.documentVersion)|\(transcript.state.rawValue)"
      enqueue(Request(sessionId: session.sessionId, key: key))
    }
  }

  /// Suggests a provisional title while recording, after about a minute of
  /// settled speech and then every few minutes. It reads the Draft windows
  /// Rust has stored so far, the text Copy So Far copies.
  func considerLive(sessionId: String, lines: [LiveCaptionLine]) {
    let words = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
    let step = words >= 600 ? 3 : words >= 250 ? 2 : words >= 80 ? 1 : 0
    guard step > (liveAttempts[sessionId] ?? 0) else { return }
    liveAttempts[sessionId] = step
    enqueue(Request(sessionId: sessionId, key: "\(sessionId)|live|\(step)"))
  }

  /// Names for the open conversation; computed once per transcript version.
  func considerOpen(_ session: RuntimeSessionPresentation) {
    guard session.lifecycle == .readyForReview else { return }
    let key = "\(session.sessionId)|open|\(session.transcript.documentVersion)"
    enqueue(Request(sessionId: session.sessionId, key: key, wantsNames: true))
  }

  func dismissNames(sessionId: String) {
    dismissedNames.insert(sessionId)
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
      // Rust decides which suggestions it would store; ask before reading text.
      let accepts = { (basis: NativeSuggestionBasis) in
        current.map { basis == .draft ? $0.acceptsDraftSuggestion : $0.acceptsFinalSuggestion }
          ?? true
      }
      guard accepts(.draft) || accepts(.final) || request.wantsNames else { return }
      let text = try await StructuredNativeIO.read {
        try library.conversationText(sessionId: sessionId, includeTimestamps: false)
      }
      let basis: NativeSuggestionBasis = text.hasDraft ? .draft : .final
      let storesTitle = accepts(basis)
      guard storesTitle || request.wantsNames else { return }
      let turns = text.turns.map { SuggestionTurn(speaker: $0.speaker, text: $0.text) }
      guard let suggestion = await suggest(turns) else { return }
      suggestions[sessionId] = suggestion
      if storesTitle, let title = suggestion.title {
        let engine = suggestion.engine
        let stored = try await StructuredNativeIO.mutation {
          try library.suggestTitle(sessionId: sessionId, title: title, engine: engine, basis: basis)
        }
        if stored { onTitleStored() }
      }
    } catch {
      // A suggestion is optional; the conversation keeps its current title.
    }
  }
}
