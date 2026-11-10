import Foundation

/// Disabled local intelligence writes nothing. The review surface says so.
struct LocalIntelligenceRefusal: Equatable {
  let mode: String
  /// Meeting-memory claims this refusal created. Disabled always writes zero.
  let claimsWritten: Int
  /// No engine is named while local intelligence is disabled.
  let engine: String?
  let readout: String
}

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
  /// Source-derived name plus every stored rename, oldest first.
  @Published private(set) var speakerLabelHistory: [NativeSpeakerLabelHistory] = []
  @Published private(set) var namedSpeakers: [NativeNamedTranscriptSpeaker] = []
  /// Source name plus every stored assignment for each selected passage.
  @Published private(set) var namedSpeakerTurnHistory: [NativeNamedSpeakerTurnHistory] = []
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
  /// Effective claims Rust projected. Swift does not invent or renumber them.
  @Published private(set) var derivedClaims: [DerivedClaimSummary] = []

  /// The only shipped local-intelligence mode. It does not ingest a
  /// meeting-memory delta, name an engine, or add a claim.
  func refuseLocalIntelligence() -> LocalIntelligenceRefusal {
    LocalIntelligenceRefusal(
      mode: "disabled",
      claimsWritten: 0,
      engine: nil,
      readout: "Intelligence off"
    )
  }
  /// Plain review sentence when voice clustering is unavailable. Nil when the
  /// session has no such decision.
  @Published private(set) var speakerDiarizationText: String?
  /// Stored engine, model revision, input scope, run state, and evidence
  /// ranges for the readable transcript.
  @Published private(set) var provenance: [NativeTranscriptProvenance] = []
  /// Nil when no model revision is readable.
  @Published private(set) var provenanceText: String?
  /// The claim whose evidence is open, and the passage that citation highlights.
  @Published private(set) var focusedClaim: ClaimReviewFocus?
  @Published private(set) var claimHighlightSegmentId: String?
  @Published private(set) var claimEvidenceOpen = false
  /// Advances when Return restores focus to `focusedClaim`.
  @Published private(set) var claimFocusGeneration: UInt64 = 0

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
    return Self.text(for: availability)
  }

  /// The words a reader shows for this transcript posture. Draft stays distinct
  /// from a Final transcript and from a failed run.
  nonisolated static func text(for availability: NativeTranscriptAvailability) -> String {
    switch availability {
    case .final: "Final transcript"
    case .draft: "Draft — a Final transcript does not cover every range yet"
    case .failed: "Transcription failed. The recorded audio is unaffected."
    case .unavailable: "No transcript yet."
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
      speakerLabelHistory = snapshot.speakerLabelHistory
      namedSpeakers = snapshot.namedSpeakers
      namedSpeakerTurnHistory = snapshot.namedSpeakerTurnHistory
      speakerDiarizationText = snapshot.speakerDiarizationText
      provenance = snapshot.provenance
      provenanceText = Self.provenanceText(for: snapshot.provenance)
      reviewMetadata = snapshot.metadata
      audioOptions = snapshot.audioOptions
      contextDetail = snapshot.context
      contextEvents = snapshot.events
      derivedClaims = try Self.decodeClaims(snapshot.claimsJSON)
      if let focusedClaim, !derivedClaims.contains(where: { $0.claimId == focusedClaim.claimId }) {
        self.focusedClaim = nil
        claimHighlightSegmentId = nil
        claimEvidenceOpen = false
      }
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

  /// Moves the absorbed person's selected passages onto the kept person.
  /// Both people remain, and earlier assignments stay in the history.
  func mergeNamedSpeakers(sessionId: String, keepId: String, absorbId: String) async -> Bool {
    await performSpeakerReview(sessionId: sessionId, action: "merge these people") { library in
      _ = try library.mergeNamedSpeakers(
        sessionId: sessionId, keepId: keepId, absorbId: absorbId)
    }
  }

  /// Gives this one passage to a new person. The caller leaves the other
  /// selected passages with the original person.
  func splitNamedSpeaker(
    sessionId: String, speakerId: String, segment: NativeTranscriptSegment, label: String
  ) async -> Bool {
    await performSpeakerReview(sessionId: sessionId, action: "split this passage") { library in
      _ = try library.splitNamedSpeaker(
        sessionId: sessionId, speakerId: speakerId,
        turns: [
          NativeNamedSpeakerTurn(revisionId: segment.revisionId, sequence: segment.sequence)
        ], label: label)
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

  /// Opens one side of a claim. The returned audio position is what the view
  /// seeks. The highlighted passage is the loaded segment with that revision
  /// and range. A missing side explains itself and does not seek.
  func openClaimEvidence(claimId: String, side: String) async -> Int64? {
    guard let expectedSession = sessionId, side == "supporting" || side == "contradicting" else {
      return nil
    }
    do {
      let library = try await readyLibrary()
      let navigation = try await StructuredNativeIO.read {
        try library.navigateDerivedClaim(sessionId: expectedSession, claimId: claimId)
      }
      guard !Task.isCancelled, sessionId == expectedSession else { return nil }
      focusedClaim = ClaimReviewFocus(
        claimId: navigation.claimId, revisionId: navigation.revisionId, text: navigation.text,
        adjudication: navigation.adjudication)
      guard let target = navigation.targets.first(where: { $0.side == side }) else {
        closeClaimEvidence()
        report("This claim has no \(side) evidence.", failure: true)
        return nil
      }
      guard target.state == .available else {
        closeClaimEvidence()
        report(Self.evidenceProblem(target.state), failure: true)
        return nil
      }
      claimHighlightSegmentId = Self.citedSegmentId(in: segments, target: target)
      claimEvidenceOpen = true
      report(nil)
      return target.startNs
    } catch is CancellationError {
      return nil
    } catch {
      if sessionId == expectedSession {
        closeClaimEvidence()
        report(Self.describe(error, action: "open this claim"), failure: true)
      }
      return nil
    }
  }

  /// Confirms, corrects, or rejects the effective claim. Rust chooses the new
  /// revision. Leaving a claim unresolved is not an action.
  @discardableResult
  func adjudicateClaim(claimId: String, action: String, text: String?) async -> Bool {
    guard let expectedSession = sessionId,
      action == "accepted" || action == "corrected" || action == "rejected"
    else { return false }
    do {
      let library = try await readyLibrary()
      let revision = try await StructuredNativeIO.mutation {
        try library.adjudicateDerivedClaim(
          sessionId: expectedSession, claimId: claimId, action: action, text: text)
      }
      guard !revision.isEmpty, !Task.isCancelled, sessionId == expectedSession else { return false }
      let json = try await StructuredNativeIO.read {
        try library.effectiveDerivedClaims(sessionId: expectedSession)
      }
      guard !Task.isCancelled, sessionId == expectedSession else { return false }
      derivedClaims = try Self.decodeClaims(json)
      if focusedClaim?.claimId == claimId,
        let updated = derivedClaims.first(where: { $0.claimId == claimId })
      {
        focusedClaim = ClaimReviewFocus(
          claimId: updated.claimId, revisionId: updated.revisionId, text: updated.text,
          adjudication: updated.adjudication)
      }
      report(nil)
      return true
    } catch is CancellationError {
      return false
    } catch {
      if sessionId == expectedSession {
        report(Self.describe(error, action: "record this claim review"), failure: true)
      }
      return false
    }
  }

  /// Leaves the cited passage and asks the review to focus the claim again.
  func returnToClaim() {
    guard claimEvidenceOpen, focusedClaim != nil else { return }
    closeClaimEvidence()
    claimFocusGeneration &+= 1
  }

  private func closeClaimEvidence() {
    claimEvidenceOpen = false
    claimHighlightSegmentId = nil
  }

  static func citedSegmentId(
    in segments: [NativeTranscriptSegment], target: NativeClaimTarget
  ) -> String? {
    segments.first {
      $0.revisionId == target.recordId && $0.startNanoseconds == target.startNs
        && $0.endNanoseconds == target.endNs
    }?.id
  }

  static func decodeClaims(_ json: String) throws -> [DerivedClaimSummary] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([DerivedClaimSummary].self, from: Data(json.utf8))
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
    speakerLabelHistory = []
    namedSpeakers = []
    namedSpeakerTurnHistory = []
    speakerDiarizationText = nil
    provenance = []
    provenanceText = nil
    reviewMetadata = nil
    audioOptions = nil
    contextDetail = nil
    contextEvents = []
    derivedClaims = []
    focusedClaim = nil
    claimHighlightSegmentId = nil
    claimEvidenceOpen = false
    report(message)
  }

  /// Names the stored run. The last sentence refuses a determinism claim.
  nonisolated static func provenanceText(for records: [NativeTranscriptProvenance]) -> String? {
    guard !records.isEmpty else { return nil }
    let lines = records.map { record in
      let ranges = record.ranges.map { range in
        "\(range.startNanoseconds)-\(range.endNanoseconds) ns"
      }.joined(separator: ", ")
      return
        "Engine \(record.engine) \(record.engineVersion). Model \(record.modelId), revision \(record.modelSha256). Input \(record.inputDigest). Run \(record.runState). Finality \(record.finality). Evidence \(ranges)."
    }
    return lines.joined(separator: "\n")
      + "\nOpen Scribe does not claim that running this model again produces the same words."
  }

  /// Speaker names come from the audio source until a person renames them.
  /// The diarization sentence stays when no calibrated model ran.
  nonisolated static func speakerAssignmentText(
    diarization: String?, history: [NativeSpeakerLabelHistory]
  ) -> String? {
    var lines: [String] = []
    if let diarization, !diarization.isEmpty { lines.append(diarization) }
    for item in history {
      lines.append(speakerLabelHistoryText(for: item))
    }
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n")
  }

  /// One line per stored claim. Ranges only: the claim sentence stays out.
  nonisolated static func derivedItemProvenanceText(for claims: [DerivedClaimSummary]) -> String? {
    var lines: [String] = []
    var sawModel = false
    for claim in claims {
      let producer = claim.producer ?? ""
      guard producer == "model_run" || producer == "human" else { continue }
      var line = producer == "model_run" ? "Model run" : "Named by you"
      if producer == "model_run" {
        sawModel = true
        if let run = claim.modelRunId, !run.isEmpty { line += " \(run)" }
        line += "."
        if let digest = claim.inputDigest, !digest.isEmpty {
          line += " Input \(digest)."
        }
      } else {
        line += "."
      }
      line += " Revision \(claim.revisionId)."
      if let adjudication = claim.adjudication, !adjudication.isEmpty {
        line += " Adjudication \(adjudication)."
      }
      if let evidence = claim.evidence, !evidence.isEmpty {
        line += " Evidence \(evidence)."
      }
      lines.append(line)
    }
    guard !lines.isEmpty else { return nil }
    if sawModel {
      lines.append(
        "Open Scribe does not claim that running this model again produces the same words.")
    }
    return lines.joined(separator: "\n")
  }

  /// Words for the rename sheet. The source default stays on its own line.
  /// Each stored rename follows, oldest first, and says whether a person
  /// chose it or the source name was restored.
  nonisolated static func speakerLabelHistoryText(for history: NativeSpeakerLabelHistory) -> String
  {
    var lines = ["Source default: \(history.sourceDefaultLabel)"]
    for revision in history.revisions {
      let origin =
        switch revision.origin {
        case .sourceDefault: "source name"
        case .human: "named by you"
        }
      lines.append("\(revision.label), \(origin)")
    }
    return lines.joined(separator: "\n")
  }

  /// Words for one passage. The source default stays on its own line.
  /// Each stored assignment follows, oldest first.
  nonisolated static func namedSpeakerTurnHistoryText(for history: NativeNamedSpeakerTurnHistory)
    -> String
  {
    var lines = ["Source default: \(history.sourceDefaultLabel)"]
    for revision in history.revisions {
      let origin =
        switch revision.origin {
        case .sourceDefault: "source name"
        case .human: "named by you"
        }
      lines.append("\(revision.label), \(origin)")
    }
    return lines.joined(separator: "\n")
  }

  /// The sentence shown when clustering stayed unavailable. Any other state
  /// is not described as a finished diarization.
  nonisolated static func speakerDiarizationText(for record: NativeSpeakerDiarization) -> String? {
    guard record.clusteringState == "unavailable",
      record.reason == "no calibrated diarization model"
    else { return nil }
    return
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
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
      (inventory.derivedItems, "derived item"),
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
  let speakerLabelHistory: [NativeSpeakerLabelHistory]
  let namedSpeakers: [NativeNamedTranscriptSpeaker]
  let namedSpeakerTurnHistory: [NativeNamedSpeakerTurnHistory]
  let metadata: NativeConversationReviewMetadata?
  let audioOptions: NativeAudioExportOptions?
  let context: NativeContextDetail?
  let events: [NativeContextEvent]
  let claimsJSON: String
  let speakerDiarizationText: String?
  let provenance: [NativeTranscriptProvenance]

  init(library: NativeTranscriptLibrary, sessionId: String, isUntimed: Bool) throws {
    availability = isUntimed ? .unavailable : try library.availability(sessionId: sessionId)
    segments = isUntimed ? [] : try library.document(sessionId: sessionId)
    speakers =
      isUntimed
      ? (try? library.speakers(sessionId: sessionId)) ?? []
      : try library.speakers(sessionId: sessionId)
    speakerLabelHistory =
      isUntimed
      ? (try? library.speakerLabelHistory(sessionId: sessionId)) ?? []
      : try library.speakerLabelHistory(sessionId: sessionId)
    namedSpeakers =
      isUntimed
      ? (try? library.namedSpeakers(sessionId: sessionId)) ?? []
      : try library.namedSpeakers(sessionId: sessionId)
    namedSpeakerTurnHistory =
      isUntimed
      ? (try? library.namedSpeakerTurnHistory(sessionId: sessionId)) ?? []
      : try library.namedSpeakerTurnHistory(sessionId: sessionId)
    metadata =
      isUntimed
      ? try? library.reviewMetadata(sessionId: sessionId)
      : try library.reviewMetadata(sessionId: sessionId)
    audioOptions = try? library.audioExportOptions(sessionId: sessionId)
    context = try? library.contextDetail(sessionId: sessionId)
    events = (try? library.contextEvents(sessionId: sessionId)) ?? []
    claimsJSON = try library.effectiveDerivedClaims(sessionId: sessionId)
    provenance = isUntimed ? [] : try library.inspectProvenance(sessionId: sessionId)
    let diarization: NativeSpeakerDiarization?
    if isUntimed {
      diarization = try? library.prepareSpeakerDiarization(sessionId: sessionId)
    } else {
      diarization = try library.prepareSpeakerDiarization(sessionId: sessionId)
    }
    speakerDiarizationText = diarization.flatMap(
      TranscriptLibraryModel.speakerDiarizationText(for:))
  }
}

/// Stored claims grouped into meeting-memory sections. Empty sections are
/// omitted. This does not create a claim.
enum StructuredMemory {
  nonisolated static func text(for claims: [DerivedClaimSummary]) -> String? {
    let lines = claims.compactMap(line(for:))
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n")
  }

  nonisolated static func line(for claim: DerivedClaimSummary) -> String? {
    guard let heading = heading(forKind: claim.kind) else { return nil }
    let producerName = claim.producer ?? ""
    let producer =
      switch producerName {
      case "model_run": "Producer model run"
      case "human": "Producer human"
      default: "Producer unknown"
      }
    var line = "\(heading). \(claim.text). Status \(claim.status). \(producer)."
    if let run = claim.modelRunId, !run.isEmpty {
      line += " Model run \(run)."
    }
    line +=
      " Evidence supporting \(claim.supportingCount), contradicting \(claim.contradictingCount)."
    if let adjudication = claim.adjudication, !adjudication.isEmpty {
      line += " Adjudication \(adjudication)."
    }
    line += " Id \(claim.claimId)."
    return line
  }

  /// People and documents have no stored claim kind, so they are not invented.
  nonisolated static func heading(forKind kind: String) -> String? {
    switch kind {
    case "fact": "Facts"
    case "decision": "Decisions"
    case "commitment": "Commitments"
    case "question": "Questions"
    case "open_loop", "loose_end": "Open loops"
    case "topic": "Topics"
    case "number_or_term": "Numbers"
    default: nil
    }
  }
}

struct ClaimReviewFocus: Equatable {
  let claimId: String
  let revisionId: String
  let text: String
  let adjudication: String?
}

struct DerivedClaimSummary: Decodable, Equatable, Identifiable, Sendable {
  let claimId: String
  let revisionId: String
  let kind: String
  let status: String
  let text: String
  let adjudication: String?
  let supportingCount: Int
  let contradictingCount: Int
  let producer: String?
  let evidence: String?
  let modelRunId: String?
  let inputDigest: String?

  var id: String { claimId }
}

private struct TranscriptDeletionOutcome: Sendable {
  let success: Bool
  let warning: Bool
  let pending: NativeSessionDeletionInventory?
  let message: String
}
