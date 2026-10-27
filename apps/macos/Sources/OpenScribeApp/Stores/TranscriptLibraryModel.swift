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
  @Published private(set) var namedSpeakers: [NativeNamedTranscriptSpeaker] = []
  @Published private(set) var reviewMetadata: NativeConversationReviewMetadata?
  @Published private(set) var searchResults: [NativeTranscriptSearchHit] = []
  @Published private(set) var pendingDeletion: NativeSessionDeletionInventory?
  @Published private var documentMessage: String?
  @Published private var documentMessageIsFailure = false
  /// A library-operation warning cannot be acknowledged by loading a different
  /// document. It remains visible until this app instance is restarted.
  @Published private var deletionWarning: String?

  var message: String? {
    let parts = [deletionWarning, documentMessage].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  var messageIsFailure: Bool { deletionWarning != nil || documentMessageIsFailure }
  var editingFailureMessage: String? { documentMessageIsFailure ? documentMessage : nil }
  /// Which audio exports the loaded session can offer.
  @Published private(set) var audioOptions: NativeAudioExportOptions?
  @Published private(set) var isExporting = false
  /// Scope history, declared metadata, and accepted screen context, read-only.
  @Published private(set) var contextDetail: NativeContextDetail?
  @Published private(set) var contextEvents: [NativeContextEvent] = []

  @Published private(set) var isLoading = false
  @Published private(set) var isSearching = false
  @Published private(set) var isEditing = false
  @Published private(set) var isDeleting = false
  private var loadGeneration: UInt64 = 0
  private var searchGeneration: UInt64 = 0
  private var library: NativeTranscriptLibrary?
  private var managedRoot: URL?
  private var connectionTask: Task<TranscriptLibraryConnection, Error>?
  private var connectionId: UUID?
  private let moveToTrash: TrashMover
  private var activeSearchQuery = ""
  /// The Rust-validated capture timeline, for the WAV mix.
  private var timeline: (@Sendable (String) throws -> [NativeTimelineSegment])?
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
    self.managedRoot = nil
  }

  convenience init(managedRoot: URL?) {
    self.init(library: nil)
    self.managedRoot = managedRoot
  }

  /// Opening the store can recover journals and wait for a database lock.
  /// One shared connection task owns that work outside the UI actor.
  private func readyLibrary() async throws -> NativeTranscriptLibrary {
    if let library { return library }
    guard let managedRoot else { throw NativeStorageError.InvalidState }
    if connectionTask == nil {
      connectionId = UUID()
      connectionTask = Task {
        try await StructuredNativeIO.read {
          let library = try NativeTranscriptLibrary.open(managedRoot: managedRoot.path)
          let preparation = try? NativeRecordingPreparation.open(managedRoot: managedRoot.path)
          return TranscriptLibraryConnection(
            library: library,
            timeline: preparation.map { source in
              { @Sendable sessionId in try source.playbackTimeline(sessionId: sessionId) }
            })
        }
      }
    }
    let requestId = connectionId
    do {
      let connection = try await connectionTask!.value
      if connectionId == requestId {
        library = connection.library
        timeline = connection.timeline
        connectionTask = nil
        connectionId = nil
      }
      return connection.library
    } catch {
      if connectionId == requestId {
        connectionTask = nil
        connectionId = nil
      }
      throw error
    }
  }

  deinit { connectionTask?.cancel() }

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

  func load(sessionId: String) async {
    await load(
      sessionId: sessionId,
      transcriptionUnavailableReason:
        self.sessionId == sessionId ? transcriptionUnavailableReason : nil)
  }

  func load(session: RuntimeSessionPresentation) async {
    await load(
      sessionId: session.sessionId,
      transcriptionUnavailableReason: session.transcriptionUnavailableReason)
  }

  /// A late metadata save can only refresh its own currently selected document.
  func reloadAfterDetailsSave(session: RuntimeSessionPresentation) async {
    guard sessionId == session.sessionId else { return }
    await load(session: session)
  }

  private func load(sessionId: String, transcriptionUnavailableReason: String?) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    #if DEBUG
      if isFixedPreview {
        self.sessionId = sessionId
        self.transcriptionUnavailableReason = transcriptionUnavailableReason
        return
      }
    #endif
    if self.sessionId != sessionId { clear(message: nil) }
    self.sessionId = sessionId
    self.transcriptionUnavailableReason = transcriptionUnavailableReason
    if transcriptionUnavailableReason != nil { searchResults = [] }
    isLoading = true
    defer { if loadGeneration == generation { isLoading = false } }
    do {
      let library = try await readyLibrary()
      let snapshot = try await StructuredNativeIO.read {
        try TranscriptDocumentSnapshot(
          library: library, sessionId: sessionId,
          isUntimed: transcriptionUnavailableReason != nil)
      }
      guard !Task.isCancelled, loadGeneration == generation, self.sessionId == sessionId else {
        return
      }
      availability = snapshot.availability
      segments = snapshot.segments
      speakers = snapshot.speakers
      namedSpeakers = snapshot.namedSpeakers
      reviewMetadata = snapshot.metadata
      audioOptions = snapshot.audioOptions
      contextDetail = snapshot.context
      contextEvents = snapshot.events
      report(nil)
    } catch is CancellationError {
      return
    } catch {
      guard loadGeneration == generation, self.sessionId == sessionId else { return }
      clear(message: Self.describe(error, action: "load the transcript"))
      self.transcriptionUnavailableReason = transcriptionUnavailableReason
      documentMessageIsFailure = true
    }
  }

  /// The caller may bind the edit to a sheet's original conversation.
  @discardableResult
  func correct(
    _ segment: NativeTranscriptSegment, text: String?, in expectedSession: String? = nil
  ) async -> Bool {
    guard let sessionId, expectedSession == nil || expectedSession == sessionId else {
      return false
    }
    return await performSpeakerReview(sessionId: sessionId, action: "save the correction") {
      library in
      try library.correctSegment(
        sessionId: sessionId, revisionId: segment.revisionId, sequence: segment.sequence, text: text
      )
    }
  }

  @discardableResult
  func renameSpeaker(
    trackId: String, label: String?, in expectedSession: String? = nil
  ) async -> Bool {
    guard let sessionId, expectedSession == nil || expectedSession == sessionId else {
      return false
    }
    return await performSpeakerReview(sessionId: sessionId, action: "rename the speaker") {
      library in
      try library.renameSpeaker(sessionId: sessionId, trackId: trackId, label: label)
    }
  }

  func assignSpeaker(
    sessionId: String, segment: NativeTranscriptSegment,
    assignment: NativeTranscriptSpeakerAssignment
  ) async -> Bool {
    await performSpeakerReview(sessionId: sessionId, action: "save the speaker assignment") {
      library in
      _ = try library.assignSpeaker(
        sessionId: sessionId, revisionId: segment.revisionId,
        sequence: segment.sequence, assignment: assignment)
    }
  }

  func renameNamedSpeaker(sessionId: String, speakerId: String, label: String) async -> Bool {
    await performSpeakerReview(sessionId: sessionId, action: "rename this person") { library in
      try library.renameNamedSpeaker(sessionId: sessionId, speakerId: speakerId, label: label)
    }
  }

  private func performSpeakerReview(
    sessionId expectedSession: String, action: String,
    _ operation: @escaping @Sendable (NativeTranscriptLibrary) throws -> Void
  ) async -> Bool {
    guard sessionId == expectedSession, !isEditing else { return false }
    isEditing = true
    defer { isEditing = false }
    do {
      let library = try await readyLibrary()
      try await StructuredNativeIO.mutation { try operation(library) }
      if sessionId == expectedSession { await load(sessionId: expectedSession) }
      // A committed edit also refreshes the latest cross-conversation query.
      await search(activeSearchQuery, debounce: false)
      return true
    } catch {
      if sessionId == expectedSession {
        report(Self.describe(error, action: action), failure: true)
      }
      return false
    }
  }

  func search(_ query: String) async {
    await search(query, debounce: true)
  }

  private func search(_ query: String, debounce: Bool) async {
    searchGeneration &+= 1
    let generation = searchGeneration
    activeSearchQuery = query
    searchResults = []
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      isSearching = false
      return
    }
    isSearching = true
    defer { if searchGeneration == generation { isSearching = false } }
    do {
      if debounce { try await Task.sleep(nanoseconds: 150_000_000) }
      let library = try await readyLibrary()
      let matches = try await StructuredNativeIO.read {
        try library.search(query: query, sessionId: nil, limit: 50)
      }
      guard !Task.isCancelled, searchGeneration == generation else { return }
      searchResults = matches
    } catch is CancellationError {
      return
    } catch {
      guard searchGeneration == generation else { return }
      report(Self.describe(error, action: "search transcripts"), failure: true)
    }
  }

  @discardableResult
  func export(
    format: NativeTranscriptExportFormat, to destination: URL, from requestedSession: String? = nil
  ) async -> Bool {
    guard let expectedSession = sessionId, !isExporting,
      requestedSession == nil || requestedSession == expectedSession
    else { return false }
    isExporting = true
    defer { isExporting = false }
    do {
      let library = try await readyLibrary()
      let receipt = try await StructuredNativeIO.mutation {
        try library.export(
          sessionId: expectedSession, format: format, destinationPath: destination.path)
      }
      if sessionId == expectedSession {
        let count = receipt.segmentCount == 1 ? "1 segment" : "\(receipt.segmentCount) segments"
        report("Exported \(count).")
      }
      return true
    } catch {
      if sessionId == expectedSession {
        report(Self.describe(error, action: "export the transcript"), failure: true)
      }
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
  func export(
    _ kind: ConversationExport, to destination: URL, from requestedSession: String? = nil
  ) async -> Bool {
    guard let sessionId, !isExporting,
      requestedSession == nil || requestedSession == sessionId
    else { return false }
    isExporting = true
    report(nil)
    defer { isExporting = false }
    do {
      let library = try await readyLibrary()
      let timeline = timeline
      let summary = try await StructuredNativeIO.mutation {
        try Self.run(
          kind, library: library, timeline: timeline, sessionId: sessionId,
          destination: destination)
      }
      if self.sessionId == sessionId { report(summary) }
      return true
    } catch {
      if self.sessionId == sessionId {
        report(Self.describe(error, action: "export the conversation"), failure: true)
      }
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
  func contextEvidenceStart(
    _ event: NativeContextEvent, in requestedSession: String? = nil
  ) async -> Int64? {
    guard let expectedSession = sessionId,
      requestedSession == nil || requestedSession == expectedSession
    else { return nil }
    do {
      let library = try await readyLibrary()
      let resolved = try await StructuredNativeIO.read {
        let reference = try library.citeContextEvent(
          sessionId: expectedSession, eventId: event.eventId, block: nil)
        return try library.resolveEvidence(referenceJson: reference)
      }
      guard !Task.isCancelled, sessionId == expectedSession else { return nil }
      guard resolved.state == .available else {
        report(Self.evidenceProblem(resolved.state), failure: true)
        return nil
      }
      return resolved.startNs
    } catch is CancellationError {
      return nil
    } catch {
      if sessionId == expectedSession {
        report(Self.describe(error, action: "open this context event"), failure: true)
      }
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

  /// Deletion remains a separately confirmed, globally visible operation.
  func requestDeletion(sessionId: String) async {
    guard !isDeleting else { return }
    if let pendingDeletion {
      if pendingDeletion.sessionId != sessionId {
        report(
          "Finish or cancel the current deletion before choosing another conversation.",
          failure: true)
      }
      return
    }
    isDeleting = true
    defer { isDeleting = false }
    do {
      let library = try await readyLibrary()
      pendingDeletion = try await StructuredNativeIO.mutation {
        try library.beginDeletion(sessionId: sessionId)
      }
      report(nil)
    } catch {
      if (error as? NativeStorageError) == .InvalidState {
        report(
          "Wait for capture or audio processing to finish before moving this conversation to Trash.",
          failure: true)
      } else {
        report(Self.describe(error, action: "prepare the deletion"), failure: true)
      }
    }
  }

  func cancelDeletion() async {
    guard !isDeleting, let inventory = pendingDeletion else { return }
    isDeleting = true
    defer { isDeleting = false }
    do {
      let library = try await readyLibrary()
      try await StructuredNativeIO.mutation {
        try library.abandonDeletion(sessionId: inventory.sessionId)
      }
      pendingDeletion = nil
    } catch {
      report(Self.describe(error, action: "cancel the deletion"), failure: true)
    }
  }

  @discardableResult
  func confirmDeletion() async -> Bool {
    guard !isDeleting, let inventory = pendingDeletion else { return false }
    isDeleting = true
    defer { isDeleting = false }
    do {
      let library = try await readyLibrary()
      let moveToTrash = moveToTrash
      let outcome = try await StructuredNativeIO.mutation {
        Self.delete(inventory, library: library, moveToTrash: moveToTrash)
      }
      pendingDeletion = outcome.pending
      if outcome.success {
        if sessionId == inventory.sessionId {
          loadGeneration &+= 1
          isLoading = false
          clear(message: nil)
        }
        await search(activeSearchQuery, debounce: false)
      }
      if outcome.warning {
        reportDeletionWarning(outcome.message)
      } else {
        report(outcome.message, failure: !outcome.success)
      }
      return outcome.success
    } catch {
      report(Self.describe(error, action: "delete the conversation"), failure: true)
      return false
    }
  }

  nonisolated private static func delete(
    _ inventory: NativeSessionDeletionInventory, library: NativeTranscriptLibrary,
    moveToTrash: TrashMover
  ) -> TranscriptDeletionOutcome {
    let trashed: URL?
    do {
      trashed = try moveToTrash(URL(fileURLWithPath: inventory.directoryPath, isDirectory: true))
    } catch {
      guard FileManager.default.fileExists(atPath: inventory.directoryPath) else {
        return .init(
          success: false, warning: true, pending: nil,
          message:
            "The move to Trash could not be confirmed. The library location is unavailable. When capture and other work have finished, restart Open Scribe to reconcile the deletion; verify Trash before assuming the audio is recoverable."
        )
      }
      do {
        try library.abandonDeletion(sessionId: inventory.sessionId)
        return .init(
          success: false, warning: false, pending: nil,
          message:
            "The move to Trash did not finish. The conversation is still listed in Open Scribe; check its audio before trying again."
        )
      } catch {
        return .init(
          success: false, warning: false, pending: inventory,
          message: Self.describe(error, action: "cancel the incomplete deletion"))
      }
    }
    do {
      let receipt = try library.completeDeletion(
        sessionId: inventory.sessionId, trashReference: trashed?.absoluteString)
      return .init(
        success: true, warning: !receipt.walCheckpointed, pending: nil,
        message: Self.deletionResult(
          title: inventory.title, walCheckpointed: receipt.walCheckpointed))
    } catch {
      return .init(
        success: false, warning: true, pending: nil,
        message:
          "The conversation files were moved to Trash, but database removal or cleanup could not be confirmed. When capture and other work have finished, restart Open Scribe to reconcile the deletion before copying or sharing the library."
      )
    }
  }

  nonisolated static func deletionResult(title: String, walCheckpointed: Bool) -> String {
    let moved = "“\(title)” was moved to Trash."
    guard !walCheckpointed else { return moved }
    return moved + " Database cleanup is incomplete because the database is busy. "
      + "Earlier data may remain in the database journal. When capture and other work have finished, restart Open Scribe before copying or sharing the library."
  }

  /// Clears a finished status before a new edit starts.
  func dismissMessage() {
    report(nil)
  }

  private func report(_ text: String?, failure: Bool = false) {
    documentMessage = text
    documentMessageIsFailure = text != nil && failure
  }

  private func reportDeletionWarning(_ text: String) {
    deletionWarning = text
    report(nil)
  }

  private func clear(message: String?) {
    availability = .unavailable
    transcriptionUnavailableReason = nil
    segments = []
    speakers = []
    namedSpeakers = []
    reviewMetadata = nil
    audioOptions = nil
    contextDetail = nil
    contextEvents = []
    report(message)
  }

  nonisolated static func describe(_ error: Error, action: String) -> String {
    switch error as? NativeStorageError {
    case .InvalidRequest: "Open Scribe could not \(action): the request was not valid."
    case .InvalidState: "Open Scribe could not \(action) in the conversation's current state."
    case .IntegrityMismatch:
      "Open Scribe could not \(action) because stored evidence did not verify."
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
      + "Moving files back from Trash does not restore the deleted review database. "
      + "Files you exported elsewhere and copies in Time Machine or other backups are not affected."
  }

  private static func count(_ value: UInt32, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }
}

private struct TranscriptLibraryConnection: Sendable {
  let library: NativeTranscriptLibrary
  let timeline: (@Sendable (String) throws -> [NativeTimelineSegment])?
}

private struct TranscriptDocumentSnapshot: Sendable {
  let availability: NativeTranscriptAvailability
  let segments: [NativeTranscriptSegment]
  let speakers: [NativeSessionSpeaker]
  let namedSpeakers: [NativeNamedTranscriptSpeaker]
  let metadata: NativeConversationReviewMetadata?
  let audioOptions: NativeAudioExportOptions?
  let context: NativeContextDetail?
  let events: [NativeContextEvent]

  init(library: NativeTranscriptLibrary, sessionId: String, isUntimed: Bool) throws {
    availability = isUntimed ? .unavailable : try library.availability(sessionId: sessionId)
    segments = isUntimed ? [] : try library.document(sessionId: sessionId)
    speakers =
      isUntimed
      ? (try? library.speakers(sessionId: sessionId)) ?? []
      : try library.speakers(sessionId: sessionId)
    namedSpeakers =
      isUntimed
      ? (try? library.namedSpeakers(sessionId: sessionId)) ?? []
      : try library.namedSpeakers(sessionId: sessionId)
    metadata =
      isUntimed
      ? try? library.reviewMetadata(sessionId: sessionId)
      : try library.reviewMetadata(sessionId: sessionId)
    audioOptions = try? library.audioExportOptions(sessionId: sessionId)
    context = try? library.contextDetail(sessionId: sessionId)
    events = (try? library.contextEvents(sessionId: sessionId)) ?? []
  }
}

private struct TranscriptDeletionOutcome: Sendable {
  let success: Bool
  let warning: Bool
  let pending: NativeSessionDeletionInventory?
  let message: String
}
