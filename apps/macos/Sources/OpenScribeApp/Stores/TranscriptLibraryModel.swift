import Foundation

/// Swift consumer of Rust's transcript review, search, export, and deletion
/// authority. Rust owns every durable effect; this model holds only the
/// values the views render and routes user intent back through coarse calls.
@MainActor
final class TranscriptLibraryModel: ObservableObject {
  /// Moves a session directory to Trash and returns where it went.
  typealias TrashMover = @Sendable (URL) throws -> URL?

  @Published private(set) var sessionId: String?
  @Published private(set) var availability: NativeTranscriptAvailability = .unavailable
  @Published private(set) var segments: [NativeTranscriptSegment] = []
  @Published private(set) var speakers: [NativeSessionSpeaker] = []
  @Published private(set) var searchResults: [NativeTranscriptSearchHit] = []
  @Published private(set) var pendingDeletion: NativeSessionDeletionInventory?
  @Published private(set) var message: String?
  /// Whether `message` reports a failure rather than a completed action.
  @Published private(set) var messageIsFailure = false

  private let library: NativeTranscriptLibrary?
  private let moveToTrash: TrashMover
  #if DEBUG
    private var isFixedPreview = false
  #endif

  init(library: NativeTranscriptLibrary?, moveToTrash: @escaping TrashMover = TranscriptLibraryModel.systemTrash) {
    self.library = library
    self.moveToTrash = moveToTrash
  }

  convenience init(managedRoot: URL?) {
    self.init(library: try? managedRoot.map { try NativeTranscriptLibrary.open(managedRoot: $0.path) })
  }

  #if DEBUG
    /// Fixed values for rendered inspection and tests: no library and no
    /// durable effects; `load` keeps these values.
    convenience init(
      preview availability: NativeTranscriptAvailability,
      segments: [NativeTranscriptSegment],
      speakers: [NativeSessionSpeaker]
    ) {
      self.init(library: nil)
      self.availability = availability
      self.segments = segments
      self.speakers = speakers
      isFixedPreview = true
    }
  #endif

  nonisolated static func systemTrash(_ url: URL) throws -> URL? {
    var resulting: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    return resulting as URL?
  }

  var availabilityText: String {
    switch availability {
    case .final: "Final transcript"
    case .draft: "Draft — some tracks do not have a Final transcript yet"
    case .failed: "Transcription failed. The recorded audio is unaffected."
    case .unavailable:
      "No transcript. This build cannot transcribe locally; the recorded audio above is complete."
    }
  }

  func load(sessionId: String) {
    self.sessionId = sessionId
    #if DEBUG
      if isFixedPreview { return }
    #endif
    guard let library else {
      clear(message: "The conversation library is unavailable.")
      messageIsFailure = true
      return
    }
    do {
      availability = try library.availability(sessionId: sessionId)
      segments = try library.document(sessionId: sessionId)
      speakers = try library.speakers(sessionId: sessionId)
      report(nil)
    } catch {
      clear(message: Self.describe(error, action: "load the transcript"))
      messageIsFailure = true
    }
  }

  /// `nil` restores the machine's verbatim reading. Returns whether it saved.
  @discardableResult
  func correct(_ segment: NativeTranscriptSegment, text: String?) -> Bool {
    guard let library, let sessionId else { return false }
    return perform("save the correction") {
      try library.correctSegment(
        sessionId: sessionId, revisionId: segment.revisionId, sequence: segment.sequence,
        text: text)
    }
  }

  /// `nil` restores the name derived from the capture source. Returns whether it saved.
  @discardableResult
  func renameSpeaker(trackId: String, label: String?) -> Bool {
    guard let library, let sessionId else { return false }
    return perform("rename the speaker") {
      try library.renameSpeaker(sessionId: sessionId, trackId: trackId, label: label)
    }
  }

  func search(_ query: String) {
    guard let library, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
      searchResults = []
      return
    }
    do {
      searchResults = try library.search(query: query, sessionId: nil, limit: 50)
    } catch {
      searchResults = []
      report(Self.describe(error, action: "search transcripts"), failure: true)
    }
  }

  @discardableResult
  func export(format: NativeTranscriptExportFormat, to destination: URL) -> Bool {
    guard let library, let sessionId else { return false }
    do {
      let receipt = try library.export(
        sessionId: sessionId, format: format, destinationPath: destination.path)
      report("Exported \(receipt.segmentCount) segments.")
      return true
    } catch {
      report(Self.describe(error, action: "export the transcript"), failure: true)
      return false
    }
  }

  /// Records the intent and exposes exactly what deletion would remove.
  func requestDeletion(sessionId: String) {
    guard let library else { return }
    do {
      pendingDeletion = try library.beginDeletion(sessionId: sessionId)
      report(nil)
    } catch {
      pendingDeletion = nil
      report(Self.describe(error, action: "prepare the deletion"), failure: true)
    }
  }

  func cancelDeletion() {
    guard let library, let inventory = pendingDeletion else { return }
    pendingDeletion = nil
    try? library.abandonDeletion(sessionId: inventory.sessionId)
  }

  /// Moves the session to Trash first; Rust removes its rows only after the
  /// directory has left the library. If Trash fails nothing is deleted.
  @discardableResult
  func confirmDeletion() -> Bool {
    guard let library, let inventory = pendingDeletion else { return false }
    pendingDeletion = nil
    let trashed: URL?
    do {
      trashed = try moveToTrash(URL(fileURLWithPath: inventory.directoryPath, isDirectory: true))
    } catch {
      try? library.abandonDeletion(sessionId: inventory.sessionId)
      report("The conversation could not be moved to Trash, so nothing was deleted.", failure: true)
      return false
    }
    do {
      _ = try library.completeDeletion(
        sessionId: inventory.sessionId, trashReference: trashed?.absoluteString)
      if sessionId == inventory.sessionId { clear(message: nil) }
      report("“\(inventory.title)” was moved to Trash.")
      return true
    } catch {
      report(Self.describe(error, action: "finish the deletion"), failure: true)
      return false
    }
  }

  private func perform(_ action: String, _ body: () throws -> Void) -> Bool {
    do {
      try body()
      if let sessionId { load(sessionId: sessionId) }
      return true
    } catch {
      report(Self.describe(error, action: action), failure: true)
      return false
    }
  }

  /// Clears a finished status before a new edit starts.
  func dismissMessage() {
    report(nil)
  }

  private func report(_ text: String?, failure: Bool = false) {
    message = text
    messageIsFailure = text != nil && failure
  }

  private func clear(message: String?) {
    availability = .unavailable
    segments = []
    speakers = []
    report(message)
  }

  nonisolated static func describe(_ error: Error, action: String) -> String {
    switch error as? NativeStorageError {
    case .InvalidRequest: "Open Scribe could not \(action): the request was not valid."
    case .InvalidState: "Open Scribe could not \(action) in the conversation's current state."
    case .IntegrityMismatch: "Open Scribe could not \(action) because stored evidence did not verify."
    default: "Open Scribe could not \(action)."
    }
  }
}

extension NativeTranscriptSegment: Identifiable {
  public var id: String { "\(revisionId)#\(sequence)" }
}

extension NativeSessionSpeaker: Identifiable {
  public var id: String { trackId }
}

/// States exactly what a confirmed deletion removes (PRD 9.10).
enum SessionDeletionSummary {
  static func text(_ inventory: NativeSessionDeletionInventory) -> String {
    let size = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: inventory.mediaBytes), countStyle: .file)
    var removed = ["\(count(inventory.mediaFiles, "audio file")) (\(size))"]
    for (value, noun) in [
      (inventory.transcriptRevisions, "transcript revision"),
      (inventory.humanCorrections, "correction"),
      (inventory.speakerNames, "speaker name"),
      (inventory.markers, "marker"),
      (inventory.exportFiles, "file exported inside the conversation"),
    ] where value > 0 {
      removed.append(count(value, noun))
    }
    return "“\(inventory.title)” will be moved to Trash and removed from Open Scribe: "
      + removed.joined(separator: ", ")
      + ", and its recording history. The audio stays in Trash until you empty it. "
      + "Files you exported elsewhere are not affected."
  }

  private static func count(_ value: UInt32, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }
}
