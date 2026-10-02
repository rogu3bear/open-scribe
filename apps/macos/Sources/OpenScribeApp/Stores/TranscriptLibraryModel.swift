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
  @Published private(set) var transcriptionUnavailableReason: String?
  @Published private(set) var segments: [NativeTranscriptSegment] = []
  @Published private(set) var speakers: [NativeSessionSpeaker] = []
  @Published private(set) var searchResults: [NativeTranscriptSearchHit] = []
  @Published private(set) var pendingDeletion: NativeSessionDeletionInventory?
  @Published private(set) var message: String?
  /// Whether `message` reports a failure rather than a completed action.
  @Published private(set) var messageIsFailure = false
  /// Which audio exports the loaded session can offer.
  @Published private(set) var audioOptions: NativeAudioExportOptions?
  @Published private(set) var isExporting = false
  /// Scope history, declared metadata, and accepted screen context, read-only.
  @Published private(set) var contextDetail: NativeContextDetail?
  @Published private(set) var contextEvents: [NativeContextEvent] = []

  private let library: NativeTranscriptLibrary?
  private let moveToTrash: TrashMover
  /// The Rust-validated capture timeline, for the WAV mix.
  private let timeline: (@Sendable (String) throws -> [NativeTimelineSegment])?
  #if DEBUG
    private var isFixedPreview = false
  #endif

  init(
    library: NativeTranscriptLibrary?,
    moveToTrash: @escaping TrashMover = TranscriptLibraryModel.systemTrash,
    timeline: (@Sendable (String) throws -> [NativeTimelineSegment])? = nil
  ) {
    self.library = library
    self.moveToTrash = moveToTrash
    self.timeline = timeline
  }

  convenience init(managedRoot: URL?) {
    let library = try? managedRoot.map { try NativeTranscriptLibrary.open(managedRoot: $0.path) }
    var timeline: (@Sendable (String) throws -> [NativeTimelineSegment])?
    if let root = managedRoot,
      let preparation = try? NativeRecordingPreparation.open(managedRoot: root.path)
    {
      timeline = { sessionId in try preparation.playbackTimeline(sessionId: sessionId) }
    }
    self.init(library: library, timeline: timeline)
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
    if let transcriptionUnavailableReason { return transcriptionUnavailableReason }
    return switch availability {
    case .final: "Final transcript"
    case .draft: "Draft — some tracks do not have a Final transcript yet"
    case .failed: "Transcription failed. The recorded audio is unaffected."
    case .unavailable:
      "No transcript yet."
    }
  }

  func load(sessionId: String) {
    load(
      sessionId: sessionId,
      transcriptionUnavailableReason:
        self.sessionId == sessionId ? transcriptionUnavailableReason : nil)
  }

  func load(session: RuntimeSessionPresentation) {
    load(
      sessionId: session.sessionId,
      transcriptionUnavailableReason: session.transcriptionUnavailableReason)
  }

  private func load(sessionId: String, transcriptionUnavailableReason: String?) {
    self.sessionId = sessionId
    self.transcriptionUnavailableReason = transcriptionUnavailableReason
    #if DEBUG
      if isFixedPreview { return }
    #endif
    guard let library else {
      clear(message: "The conversation library is unavailable.")
      messageIsFailure = true
      return
    }
    if let transcriptionUnavailableReason {
      clear(message: nil)
      self.transcriptionUnavailableReason = transcriptionUnavailableReason
      searchResults = []
      // Load metadata independently of transcript collection, keeping only
      // export options Rust can provide. Untimed captures may have none.
      speakers = (try? library.speakers(sessionId: sessionId)) ?? []
      audioOptions = try? library.audioExportOptions(sessionId: sessionId)
      contextDetail = try? library.contextDetail(sessionId: sessionId)
      contextEvents = (try? library.contextEvents(sessionId: sessionId)) ?? []
      return
    }
    do {
      availability = try library.availability(sessionId: sessionId)
      segments = try library.document(sessionId: sessionId)
      speakers = try library.speakers(sessionId: sessionId)
      audioOptions = try? library.audioExportOptions(sessionId: sessionId)
      contextDetail = try? library.contextDetail(sessionId: sessionId)
      contextEvents = (try? library.contextEvents(sessionId: sessionId)) ?? []
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

  /// Conversation exports beyond transcript text (ADR 0010).
  enum ConversationExport: Sendable {
    case validatedMix
    case mixWAV
    case original
    case track(String)
    case sessionManifest
    case portablePackage
  }

  /// Media and package exports copy whole files, so they run off the main
  /// actor. Rust verifies every byte it writes; export never changes state.
  @discardableResult
  func export(_ kind: ConversationExport, to destination: URL) async -> Bool {
    guard let library, let sessionId, !isExporting else { return false }
    isExporting = true
    report(nil)
    defer { isExporting = false }
    let timeline = timeline
    do {
      let summary = try await Task.detached(priority: .utility) {
        try Self.run(
          kind, library: library, timeline: timeline, sessionId: sessionId,
          destination: destination)
      }.value
      report(summary)
      return true
    } catch {
      report(Self.describe(error, action: "export the conversation"), failure: true)
      return false
    }
  }

  nonisolated private static func run(
    _ kind: ConversationExport, library: NativeTranscriptLibrary,
    timeline: (@Sendable (String) throws -> [NativeTimelineSegment])?, sessionId: String,
    destination: URL
  ) throws -> String {
    let path = destination.path
    let size = { (bytes: UInt64) in
      ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    switch kind {
    case .validatedMix:
      let receipt = try library.exportValidatedMix(sessionId: sessionId, destinationPath: path)
      return "Exported the verified mix (\(size(receipt.byteLength)))."
    case .mixWAV:
      guard let timeline else { throw NativeStorageError.InvalidState }
      try TimelineMixExporter.exportWAV(plan: try timeline(sessionId), to: destination)
      return "Exported the lossless mix."
    case .original:
      let receipt = try library.exportOriginalMedia(sessionId: sessionId, destinationPath: path)
      return "Exported the original audio (\(size(receipt.byteLength)))."
    case .track(let trackId):
      let receipt = try library.exportTrackWav(
        sessionId: sessionId, trackId: trackId, destinationPath: path)
      return "Exported the track (\(size(receipt.byteLength)))."
    case .sessionManifest:
      _ = try library.exportSessionManifest(sessionId: sessionId, destinationPath: path)
      return "Exported the session manifest."
    case .portablePackage:
      let summary = try library.exportPortablePackage(sessionId: sessionId, destinationPath: path)
      return "Exported a portable package: \(summary.files) files, \(size(summary.byteLength))."
    }
  }

  /// Where a saved context event begins, once Rust has resolved its citation
  /// as available evidence; otherwise says why it cannot be opened.
  func contextEvidenceStart(_ event: NativeContextEvent) -> Int64? {
    guard let library, let sessionId else { return nil }
    do {
      let reference = try library.citeContextEvent(
        sessionId: sessionId, eventId: event.eventId, block: nil)
      let resolved = try library.resolveEvidence(referenceJson: reference)
      guard resolved.state == .available else {
        report(Self.evidenceProblem(resolved.state), failure: true)
        return nil
      }
      return resolved.startNs
    } catch {
      report(Self.describe(error, action: "open this context event"), failure: true)
      return nil
    }
  }

  nonisolated static func evidenceProblem(_ state: NativeEvidenceState) -> String {
    switch state {
    case .available: "The evidence is available."
    case .superseded: "A newer reading replaces this evidence."
    case .missing: "This evidence is no longer in the library."
    case .deleted: "This evidence was deleted."
    case .integrityMismatch: "This evidence no longer matches what was recorded."
    case .unsupportedVersion: "This evidence uses a newer format than this version of Open Scribe."
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
    transcriptionUnavailableReason = nil
    segments = []
    speakers = []
    audioOptions = nil
    contextDetail = nil
    contextEvents = []
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
      (inventory.contextEvents, "screen context event"),
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
