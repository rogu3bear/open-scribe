import Combine
import Foundation

private enum RuntimeLibraryStoreError: Error {
  case managedRootUnavailable
  case importUnavailable
  case importEvidenceRejected
}

@MainActor
final class RuntimeLibraryStore: ObservableObject {
  typealias SnapshotProvider = @Sendable () throws -> NativeRuntimeLibrarySnapshot
  typealias ImportProvider = @Sendable (String, String) throws -> NativeImportedMediaEvidence
  typealias NormalizedImportProvider =
    @Sendable (String, String, NativeOriginalImportMetadata) throws
    -> NativeImportedMediaEvidence
  typealias CompressedImportProvider =
    @Sendable (String, String, NativeCompressedImportMetadata) throws
    -> NativeImportedMediaEvidence
  typealias PackageImportProvider = @Sendable (String) throws -> NativePackageImportReceipt
  typealias RenameProvider = @Sendable (String, String) throws -> String
  typealias DeclareProvider = @Sendable (String, [String], String?) throws -> Void

  @Published private(set) var currentSession: RuntimeSessionPresentation?
  @Published private(set) var savedSessions: [RuntimeSessionPresentation] = []
  @Published private(set) var isSnapshotStale = false
  @Published private(set) var errorMessage: String?
  /// The result of the last title or details edit, for the workspace notice.
  @Published private(set) var editMessage: String?
  @Published private(set) var editMessageIsFailure = false
  /// The app sets this while launch recovery scans the library. Capture waits
  /// for that scan, so a current session read meanwhile is a terminated one
  /// awaiting recovery and is never presented as live.
  var isLaunchRecoveryPending: @MainActor () -> Bool = { false }

  private let snapshotProvider: SnapshotProvider
  private let announce: @MainActor (String) -> Void
  private var captureAnnouncements = RuntimeCaptureAnnouncements()
  nonisolated private let importProvider: ImportProvider?
  nonisolated private let normalizedImportProvider: NormalizedImportProvider?
  nonisolated private let compressedImportProvider: CompressedImportProvider?
  nonisolated private let packageImportProvider: PackageImportProvider?
  nonisolated private let renameProvider: RenameProvider?
  nonisolated private let declareProvider: DeclareProvider?
  private var pollingTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration: UInt64 = 0
  private var refreshQueued = false
  private var loggedSnapshotSignature = ""

  init(
    snapshotProvider: @escaping SnapshotProvider,
    importProvider: ImportProvider? = nil,
    normalizedImportProvider: NormalizedImportProvider? = nil,
    compressedImportProvider: CompressedImportProvider? = nil,
    packageImportProvider: PackageImportProvider? = nil,
    renameProvider: RenameProvider? = nil,
    declareProvider: DeclareProvider? = nil,
    announce: @escaping @MainActor (String) -> Void = AccessibilityAnnouncer.post,
    startsPolling: Bool = true,
    refreshesImmediately: Bool = true
  ) {
    self.snapshotProvider = snapshotProvider
    self.announce = announce
    self.importProvider = importProvider
    self.normalizedImportProvider = normalizedImportProvider
    self.compressedImportProvider = compressedImportProvider
    self.packageImportProvider = packageImportProvider
    self.renameProvider = renameProvider
    self.declareProvider = declareProvider
    if refreshesImmediately {
      refresh()
      if startsPolling {
        startPolling()
      }
    }
  }

  private func startPolling() {
    pollingTask = Task { [weak self] in
      var idleTicks = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        // Recording, pause, and finalization move the clock every second.
        // An idle library keeps its last sealed snapshot and checks again
        // only every five seconds.
        let live = self?.tracksLiveClock ?? false
        if live {
          idleTicks = 0
          self?.refresh()
        } else {
          idleTicks += 1
          if idleTicks >= 5 {
            idleTicks = 0
            self?.refresh()
          }
        }
      }
    }
  }

  private var tracksLiveClock: Bool {
    guard let lifecycle = currentSession?.lifecycle else { return false }
    return ["preparing", "recording", "paused", "finalizing"].contains(lifecycle)
  }

  convenience init(managedRoot: URL?, refreshesImmediately: Bool = true) {
    let controller = try? managedRoot.map {
      try NativeRecordingPreparation.open(managedRoot: $0.path)
    }
    let library = try? managedRoot.map { try NativeTranscriptLibrary.open(managedRoot: $0.path) }
    self.init(
      snapshotProvider: {
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try controller.runtimeLibrarySnapshotAtHost(hostTime: mach_absolute_time())
      },
      importProvider: { title, sourcePath in
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try controller.importRecoverableCaf(title: title, sourcePath: sourcePath)
      },
      normalizedImportProvider: { title, normalizedPath, original in
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try controller.importNormalizedCaf(
          title: title, normalizedPath: normalizedPath, original: original
        )
      },
      compressedImportProvider: { title, sourcePath, metadata in
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try controller.importCompressedM4a(
          title: title, sourcePath: sourcePath, metadata: metadata
        )
      },
      packageImportProvider: { packagePath in
        guard let library else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try library.importPortablePackage(packagePath: packagePath)
      },
      renameProvider: { sessionId, title in
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try controller.renameSession(sessionId: sessionId, title: title)
      },
      declareProvider: { sessionId, participants, topic in
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        _ = try controller.declareSession(
          sessionId: sessionId,
          declaration: NativeSessionDeclaration(participants: participants, topic: topic))
      },
      refreshesImmediately: refreshesImmediately
    )
  }

  /// Replaces a conversation's title through Rust, then rereads the library.
  /// Returns the stored title; a refusal leaves the title as it was and says why.
  @discardableResult
  func rename(sessionId: String, title: String) async -> String? {
    guard let renameProvider else {
      report(
        edit: "The conversation library is unavailable, so the title was not changed.",
        failure: true)
      return nil
    }
    let sessionToken = DiagnosticPrivacy.token(sessionId)
    do {
      let stored = try await StructuredNativeIO.mutation { try renameProvider(sessionId, title) }
      AppTelemetry.libraryNote(stage: "rename", detail: "session=\(sessionToken) result=renamed")
      report(edit: nil)
      refresh()
      return stored
    } catch {
      AppTelemetry.libraryNote(stage: "rename", detail: "session=\(sessionToken) result=refused")
      report(edit: Self.editFailure(error, what: "rename the conversation"), failure: true)
      return nil
    }
  }

  /// Records participants and a topic for a saved conversation through the
  /// same journaled declaration a live capture uses.
  @discardableResult
  func declare(sessionId: String, participants: [String], topic: String?) async -> Bool {
    guard let declareProvider else {
      report(
        edit: "The conversation library is unavailable, so the details were not saved.",
        failure: true)
      return false
    }
    let sessionToken = DiagnosticPrivacy.token(sessionId)
    do {
      try await StructuredNativeIO.mutation { try declareProvider(sessionId, participants, topic) }
      AppTelemetry.libraryNote(stage: "declare", detail: "session=\(sessionToken) result=saved")
      report(edit: nil)
      return true
    } catch {
      AppTelemetry.libraryNote(stage: "declare", detail: "session=\(sessionToken) result=refused")
      report(edit: Self.editFailure(error, what: "save the conversation details"), failure: true)
      return false
    }
  }

  func dismissEditMessage() {
    report(edit: nil)
  }

  private func report(edit message: String?, failure: Bool = false) {
    editMessage = message
    editMessageIsFailure = message != nil && failure
  }

  nonisolated static func editFailure(_ error: Error, what action: String) -> String {
    switch error as? NativeStorageError {
    case .InvalidRequest:
      "Open Scribe could not \(action): the text is empty, too long, or contains characters that cannot be stored."
    case .InvalidState:
      "Open Scribe could not \(action) in the conversation's current state."
    default:
      "Open Scribe could not \(action)."
    }
  }

  deinit {
    pollingTask?.cancel()
    refreshTask?.cancel()
  }

  func refresh() {
    if refreshTask != nil {
      refreshQueued = true
      return
    }
    refreshGeneration &+= 1
    startRefresh(generation: refreshGeneration)
  }

  @discardableResult
  nonisolated func importManagedAudio(
    title: String,
    sourceURL: URL
  ) throws -> NativeImportedMediaEvidence {
    let prepared = try BoundedAudioImport.prepare(
      sourceURL: sourceURL, policy: nativeImportPolicy()
    )
    defer { prepared.removeTemporaryCopy() }
    if let compressed = prepared.compressed {
      guard let compressedImportProvider else {
        throw RuntimeLibraryStoreError.importUnavailable
      }
      let evidence = try compressedImportProvider(title, prepared.cafURL.path, compressed)
      guard evidence.originalUntouched, evidence.readyForReview else {
        throw RuntimeLibraryStoreError.importEvidenceRejected
      }
      Task { @MainActor [weak self] in self?.refresh() }
      return evidence
    }
    guard let original = prepared.original else {
      return try importManagedCaf(title: title, sourceURL: prepared.cafURL)
    }
    guard let normalizedImportProvider else {
      throw RuntimeLibraryStoreError.importUnavailable
    }
    let evidence = try normalizedImportProvider(title, prepared.cafURL.path, original)
    guard evidence.originalUntouched, evidence.readyForReview else {
      throw RuntimeLibraryStoreError.importEvidenceRejected
    }
    Task { @MainActor [weak self] in self?.refresh() }
    return evidence
  }

  /// Opens a portable package from another Mac as a new saved conversation.
  nonisolated func openPortablePackage(packageURL: URL) throws -> NativePackageImportReceipt {
    guard let packageImportProvider else {
      throw RuntimeLibraryStoreError.importUnavailable
    }
    let receipt = try packageImportProvider(packageURL.path)
    Task { @MainActor [weak self] in
      self?.refresh()
    }
    return receipt
  }

  @discardableResult
  nonisolated func importManagedCaf(
    title: String,
    sourceURL: URL
  ) throws -> NativeImportedMediaEvidence {
    guard let importProvider else {
      throw RuntimeLibraryStoreError.importUnavailable
    }
    let evidence = try importProvider(title, sourceURL.path)
    guard evidence.originalUntouched, evidence.readyForReview else {
      throw RuntimeLibraryStoreError.importEvidenceRejected
    }
    Task { @MainActor [weak self] in
      self?.refresh()
    }
    return evidence
  }

  private func noteSnapshotIfChanged(
    current: RuntimeSessionPresentation?, saved: [RuntimeSessionPresentation]
  ) {
    let currentSignature =
      current.map { "\($0.sessionId):\($0.lifecycle):\($0.health)" } ?? "none"
    let savedSignature = saved.map {
      "\($0.sessionId):\($0.lifecycle):\($0.health):\($0.transcript.state.rawValue)"
    }.joined(separator: ",")
    let signature = "\(currentSignature)|\(savedSignature)"
    guard signature != loggedSnapshotSignature else { return }
    loggedSnapshotSignature = signature
    AppTelemetry.libraryNote(
      stage: "snapshot",
      detail:
        "current=\(DiagnosticPrivacy.token(current?.sessionId ?? "none")) saved=\(saved.count) lifecycle=\(DiagnosticPrivacy.token(current?.lifecycle ?? "idle"))"
    )
  }

  private func startRefresh(generation: UInt64) {
    let snapshotProvider = snapshotProvider
    // A snapshot read during the scan may predate its recovery even if the
    // scan has finished by the time the read returns.
    let readDuringRecovery = isLaunchRecoveryPending()
    let signpost = AppTelemetry.signposter.beginInterval("library_snapshot")
    let started = ContinuousClock.now
    refreshTask = Task { [weak self] in
      let result: Result<NativeRuntimeLibrarySnapshot, Error>
      do {
        result = .success(try await StructuredNativeIO.read(snapshotProvider))
      } catch {
        result = .failure(error)
      }
      let milliseconds = DiagnosticTiming.milliseconds(since: started)
      AppTelemetry.signposter.endInterval("library_snapshot", signpost)
      DiagnosticTiming.note("library_snapshot", milliseconds: milliseconds)
      guard let self else { return }
      self.finishRefresh(
        result, generation: generation, readDuringRecovery: readDuringRecovery)
    }
  }

  private func finishRefresh(
    _ result: Result<NativeRuntimeLibrarySnapshot, Error>,
    generation: UInt64,
    readDuringRecovery: Bool
  ) {
    refreshTask = nil
    if generation == refreshGeneration {
      switch result {
      case .success(let native):
        let nextCurrent =
          readDuringRecovery || isLaunchRecoveryPending()
          ? nil : native.currentSession.map(RuntimeSessionPresentation.init(native:))
        let nextSaved = native.savedSessions.map(RuntimeSessionPresentation.init(native:))
        let announcements = captureAnnouncements.update(current: nextCurrent, saved: nextSaved)
        // Identical snapshots must not invalidate SwiftUI. The one-second poll
        // otherwise redraws the whole library while the app is idle.
        guard
          currentSession != nextCurrent || savedSessions != nextSaved || isSnapshotStale
            || errorMessage != nil
        else { break }
        currentSession = nextCurrent
        savedSessions = nextSaved
        isSnapshotStale = false
        errorMessage = nil
        noteSnapshotIfChanged(current: nextCurrent, saved: nextSaved)
        for message in announcements {
          announce(message)
        }
      case .failure(let error) where error is CancellationError:
        break
      case .failure:
        let alreadyFailed = isSnapshotStale && errorMessage != nil
        currentSession = nil
        isSnapshotStale = true
        errorMessage =
          "Live recording state is unavailable. The saved list is last known; recorded media was not changed."
        if !alreadyFailed {
          loggedSnapshotSignature = ""
          AppTelemetry.libraryNote(stage: "snapshot-failed", detail: "code=unavailable")
        }
      }
    }
    if refreshQueued || generation != refreshGeneration {
      refreshQueued = false
      startRefresh(generation: refreshGeneration)
    }
  }
}
