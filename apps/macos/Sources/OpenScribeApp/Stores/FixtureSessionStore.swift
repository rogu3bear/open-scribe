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

  @Published private(set) var currentSession: RuntimeSessionPresentation?
  @Published private(set) var savedSessions: [RuntimeSessionPresentation] = []
  @Published private(set) var isSnapshotStale = false
  @Published private(set) var errorMessage: String?

  private let snapshotProvider: SnapshotProvider
  private let importProvider: ImportProvider?
  private var pollingTask: Task<Void, Never>?

  init(
    snapshotProvider: @escaping SnapshotProvider,
    importProvider: ImportProvider? = nil,
    startsPolling: Bool = true
  ) {
    self.snapshotProvider = snapshotProvider
    self.importProvider = importProvider
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
      }
    )
  }

  deinit {
    pollingTask?.cancel()
  }

  func refresh() {
    do {
      let native = try snapshotProvider()
      currentSession = native.currentSession.map(RuntimeSessionPresentation.init(native:))
      savedSessions = native.savedSessions.map(RuntimeSessionPresentation.init(native:))
      isSnapshotStale = false
      errorMessage = nil
    } catch {
      currentSession = nil
      isSnapshotStale = true
      errorMessage =
        "Live recording state is unavailable. The saved list is last known; recorded media was not changed."
    }
  }

  @discardableResult
  func importManagedCaf(title: String, sourceURL: URL) throws -> NativeImportedMediaEvidence {
    guard let importProvider else {
      throw RuntimeLibraryStoreError.importUnavailable
    }
    let evidence = try importProvider(title, sourceURL.path)
    guard evidence.originalUntouched, evidence.readyForReview else {
      throw RuntimeLibraryStoreError.importEvidenceRejected
    }
    refresh()
    return evidence
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
