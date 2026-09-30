import Foundation

private enum RuntimeLibraryStoreError: Error {
  case managedRootUnavailable
  case importUnavailable
  case importEvidenceRejected
}

enum StructuredNativeIO {
  static func read<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await run(operation, checksCancellationAfterOperation: true)
  }

  static func mutation<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await run(operation, checksCancellationAfterOperation: false)
  }

  private static func run<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result,
    checksCancellationAfterOperation: Bool
  ) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
      group.addTask(priority: .userInitiated) {
        try Task.checkCancellation()
        let result = try operation()
        if checksCancellationAfterOperation {
          try Task.checkCancellation()
        }
        return result
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      return result
    }
  }
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

  @Published private(set) var currentSession: RuntimeSessionPresentation?
  @Published private(set) var savedSessions: [RuntimeSessionPresentation] = []
  @Published private(set) var isSnapshotStale = false
  @Published private(set) var errorMessage: String?
  /// The app sets this while launch recovery scans the library. Capture waits
  /// for that scan, so a current session read meanwhile is a terminated one
  /// awaiting recovery and is never presented as live.
  var isLaunchRecoveryPending: @MainActor () -> Bool = { false }

  private let snapshotProvider: SnapshotProvider
  nonisolated private let importProvider: ImportProvider?
  nonisolated private let normalizedImportProvider: NormalizedImportProvider?
  nonisolated private let compressedImportProvider: CompressedImportProvider?
  nonisolated private let packageImportProvider: PackageImportProvider?
  private var pollingTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration: UInt64 = 0
  private var refreshQueued = false

  init(
    snapshotProvider: @escaping SnapshotProvider,
    importProvider: ImportProvider? = nil,
    normalizedImportProvider: NormalizedImportProvider? = nil,
    compressedImportProvider: CompressedImportProvider? = nil,
    packageImportProvider: PackageImportProvider? = nil,
    startsPolling: Bool = true
  ) {
    self.snapshotProvider = snapshotProvider
    self.importProvider = importProvider
    self.normalizedImportProvider = normalizedImportProvider
    self.compressedImportProvider = compressedImportProvider
    self.packageImportProvider = packageImportProvider
    refresh()
    if startsPolling {
      pollingTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled else { return }
          self?.refresh()
        }
      }
    }
  }

  convenience init(managedRoot: URL?) {
    let controller = try? managedRoot.map {
      try NativeRecordingPreparation.open(managedRoot: $0.path)
    }
    let library = try? managedRoot.map { try NativeTranscriptLibrary.open(managedRoot: $0.path) }
    self.init(
      snapshotProvider: {
        guard let controller else {
          throw RuntimeLibraryStoreError.managedRootUnavailable
        }
        return try controller.runtimeLibrarySnapshot()
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
      }
    )
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

  private func startRefresh(generation: UInt64) {
    let snapshotProvider = snapshotProvider
    // A snapshot read during the scan may predate its recovery even if the
    // scan has finished by the time the read returns.
    let readDuringRecovery = isLaunchRecoveryPending()
    refreshTask = Task { [weak self] in
      let result: Result<NativeRuntimeLibrarySnapshot, Error>
      do {
        result = .success(try await StructuredNativeIO.read(snapshotProvider))
      } catch {
        result = .failure(error)
      }
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
        currentSession =
          readDuringRecovery || isLaunchRecoveryPending()
          ? nil : native.currentSession.map(RuntimeSessionPresentation.init(native:))
        savedSessions = native.savedSessions.map(RuntimeSessionPresentation.init(native:))
        isSnapshotStale = false
        errorMessage = nil
      case .failure(let error) where error is CancellationError:
        break
      case .failure:
        currentSession = nil
        isSnapshotStale = true
        errorMessage =
          "Live recording state is unavailable. The saved list is last known; recorded media was not changed."
      }
    }
    if refreshQueued || generation != refreshGeneration {
      refreshQueued = false
      startRefresh(generation: refreshGeneration)
    }
  }
}

@MainActor
final class FixtureSessionStore: ObservableObject {
  @Published private(set) var snapshot: SessionPresentation
  @Published private(set) var commandError: String?
  @Published private(set) var displayedElapsedSeconds: UInt64

  private var timerTask: Task<Void, Never>?

  init(fixture: NativeFixture) {
    let initial = SessionPresentation(native: nativeFixture(fixture: fixture))
    snapshot = initial
    displayedElapsedSeconds = initial.elapsedSeconds
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self?.tick()
      }
    }
  }

  deinit {
    timerTask?.cancel()
  }

  var displayedTimerText: String? {
    guard snapshot.timerBehavior != .hidden else { return nil }
    let hours = displayedElapsedSeconds / 3_600
    let minutes = (displayedElapsedSeconds % 3_600) / 60
    let seconds = displayedElapsedSeconds % 60
    return String(format: "%02llu:%02llu:%02llu", hours, minutes, seconds)
  }

  var displayedLabel: String {
    guard let timer = displayedTimerText else { return snapshot.label }
    switch snapshot.presentation {
    case "recording": return "Recording · \(timer)"
    case "paused": return "Paused · \(timer)"
    default: return snapshot.label
    }
  }

  var displayedAccessibilityValue: String {
    guard let originalTimer = snapshot.timerText, let displayedTimer = displayedTimerText else {
      return snapshot.accessibilityValue
    }
    return snapshot.accessibilityValue.replacingOccurrences(
      of: originalTimer,
      with: displayedTimer
    )
  }

  func send(
    _ kind: NativeCommandKind,
    journalDurable: Bool = false,
    mediaFilesOpen: Bool = false,
    mediaSafe: Bool = false,
    elapsedSeconds: UInt64 = 0
  ) {
    do {
      let native = try nativeApplyFixtureCommand(
        fixture: snapshot.nativeFixture,
        command: NativeCommand(
          kind: kind,
          journalDurable: journalDurable,
          mediaFilesOpen: mediaFilesOpen,
          mediaSafe: mediaSafe,
          elapsedSeconds: elapsedSeconds
        )
      )
      snapshot = SessionPresentation(native: native)
      displayedElapsedSeconds = snapshot.elapsedSeconds
      commandError = nil
      if let announcement = snapshot.announcement {
        AccessibilityAnnouncer.post(announcement)
      }
    } catch {
      commandError = error.localizedDescription
    }
  }

  func inspect() {
    AccessibilityAnnouncer.post(displayedAccessibilityValue)
  }

  func tick() {
    guard snapshot.timerBehavior == .advancing else { return }
    displayedElapsedSeconds = displayedElapsedSeconds.saturatingAdd(1)
  }
}

extension UInt64 {
  fileprivate func saturatingAdd(_ value: UInt64) -> UInt64 {
    let (sum, overflow) = addingReportingOverflow(value)
    return overflow ? .max : sum
  }
}

enum FixtureLaunchSelection {
  static func selected(from arguments: [String]) -> NativeFixture {
    guard let marker = arguments.firstIndex(of: "--fixture"), arguments.indices.contains(marker + 1)
    else {
      return .idle
    }

    switch arguments[marker + 1] {
    case "ready": return .ready
    case "starting": return .starting
    case "recording": return .recording
    case "paused": return .paused
    case "finalizing": return .finalizing
    case "recording-degraded": return .recordingDegraded
    case "permission-revoked": return .permissionRevoked
    case "recovery-required": return .recoveryRequired
    case "complete": return .complete
    default: return .idle
    }
  }
}
