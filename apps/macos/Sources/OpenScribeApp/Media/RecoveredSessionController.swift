@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Darwin
import Foundation

enum RecoveredSessionPhase: Equatable, Sendable {
  case scanning
  case none
  case available
  case failed

  var diagnosticName: String {
    switch self {
    case .scanning: "scanning"
    case .none: "none"
    case .available: "available"
    case .failed: "failed"
    }
  }
}

enum RecoveredPlaybackStartupState: Equatable, Sendable {
  case pending
  case playing
  case failed
  case superseded
}

struct RecoveredPlaybackMediaIdentity: Equatable, Sendable {
  let sessionId: String
  let sourceId: String
  let trackId: String
  let segmentId: String

  init(_ session: NativeRecoveredPlayableSession) {
    sessionId = session.sessionId
    sourceId = session.sourceId
    trackId = session.trackId
    segmentId = session.segmentId
  }
}

private struct RecoveredPlaybackStartupRecord {
  let identity: RecoveredPlaybackMediaIdentity
  var state: RecoveredPlaybackStartupState
}

private enum RecoveredSessionError: Error {
  case managedRootUnavailable
  case invalidEvidence
}

@MainActor
final class RecoveredSessionController: ObservableObject {
  private static let maximumRecoveredPlaybackStartupRecords = 8

  typealias RecoveryFactory = @Sendable () throws -> PlayableSessionRecovering
  typealias ImportedPlaybackLeaseProvider =
    @Sendable (String) throws -> ImportedPlaybackLeaseHolding
  typealias RecoveredPlaybackLeaseProvider =
    @Sendable (RecoveredPlaybackMediaIdentity) throws -> ImportedPlaybackLeaseHolding
  typealias PlaybackTerminationDecisionObserver = @Sendable (UUID, Bool) -> Void

  @Published private(set) var phase: RecoveredSessionPhase = .scanning
  @Published private(set) var sessions: [NativeRecoveredPlayableSession] = []
  @Published private(set) var activePlaybackSessionId: String?
  @Published private(set) var playingSessionId: String?
  @Published private(set) var activeMixdownSessionId: String?
  @Published private(set) var timelineClockAdjustmentNanoseconds: Int64 = 0
  @Published private(set) var pendingRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?
  @Published private(set) var playingRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?
  @Published private(set) var errorMessage: String?
  @Published private(set) var errorSessionId: String?
  @Published private(set) var errorRecoveredMediaIdentity: RecoveredPlaybackMediaIdentity?

  private let recoveryFactory: RecoveryFactory
  private let importedPlaybackLeaseProvider: ImportedPlaybackLeaseProvider
  private let mixdownLeaseProvider: ImportedPlaybackLeaseProvider?
  private let recoveredPlaybackLeaseProvider: RecoveredPlaybackLeaseProvider
  private let player: RecoveredAudioPlaying
  private let timelineProvider: (@Sendable (String) throws -> [NativeTimelineSegment])?
  private let timelinePlayer = TimelineAudioPlayer()
  private let playbackTerminationDecisionObserver: PlaybackTerminationDecisionObserver
  private var playbackTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryGeneration: UUID?
  private var activePlaybackGeneration: UUID?
  private var recoveredPlaybackStartupRecords: [UUID: RecoveredPlaybackStartupRecord] = [:]
  private var recoveredPlaybackStartupOrder: [UUID] = []

  init(
    recoveryFactory: @escaping RecoveryFactory,
    importedPlaybackLeaseProvider: @escaping ImportedPlaybackLeaseProvider = { _ in
      throw RecoveredSessionError.managedRootUnavailable
    },
    mixdownLeaseProvider: ImportedPlaybackLeaseProvider? = nil,
    recoveredPlaybackLeaseProvider: @escaping RecoveredPlaybackLeaseProvider = { _ in
      throw RecoveredSessionError.managedRootUnavailable
    },
    player: RecoveredAudioPlaying,
    timelineProvider: (@Sendable (String) throws -> [NativeTimelineSegment])? = nil,
    playbackTerminationDecisionObserver: @escaping PlaybackTerminationDecisionObserver = { _, _ in }
  ) {
    self.recoveryFactory = recoveryFactory
    self.importedPlaybackLeaseProvider = importedPlaybackLeaseProvider
    self.mixdownLeaseProvider = mixdownLeaseProvider
    self.recoveredPlaybackLeaseProvider = recoveredPlaybackLeaseProvider
    self.player = player
    self.timelineProvider = timelineProvider
    self.playbackTerminationDecisionObserver = playbackTerminationDecisionObserver
    player.setPlaybackTerminationHandler { [weak self] termination in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let isActive = self.activePlaybackGeneration == termination.generation
        self.playbackTerminationDecisionObserver(termination.generation, isActive)
        guard isActive else { return }
        let failedSessionId = self.activePlaybackSessionId
        let failedRecoveredIdentity =
          self.playingRecoveredMediaIdentity ?? self.pendingRecoveredMediaIdentity
        let startupState: RecoveredPlaybackStartupState =
          switch termination.outcome {
          case .finished: .playing
          case .failed, .outputRouteChanged: .failed
          }
        self.settleRecoveredPlaybackStartup(
          generation: termination.generation,
          state: startupState
        )
        self.activePlaybackGeneration = nil
        self.playbackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.activeMixdownSessionId = nil
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = nil
        if termination.outcome != .finished {
          let playbackErrorMessage =
            switch termination.outcome {
            case .finished:
              ""
            case .failed:
              failedRecoveredIdentity == nil
                ? "Saved audio playback stopped because decoding failed."
                : "Recovered audio playback stopped because decoding failed."
            case .outputRouteChanged:
              "Playback stopped because the audio output changed. Press Play to restart."
            }
          self.setPlaybackError(
            playbackErrorMessage,
            sessionId: failedSessionId,
            recoveredMediaIdentity: failedRecoveredIdentity
          )
        }
      }
    }
  }

  convenience init(managedRoot: URL?) {
    self.init(
      recoveryFactory: {
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        return try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
      },
      importedPlaybackLeaseProvider: { sessionId in
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        let preparation = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
        return try preparation.leaseImportedPlayback(sessionId: sessionId)
      },
      mixdownLeaseProvider: { sessionId in
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        let preparation = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
        _ = try ValidatedMixdownBuilder.buildIfNeeded(
          preparation: preparation, sessionId: sessionId, storagePath: managedRoot.path)
        guard let lease = try preparation.leaseValidatedMixdown(sessionId: sessionId) else {
          throw TimelinePlaybackError.invalidPlan
        }
        return lease
      },
      recoveredPlaybackLeaseProvider: { identity in
        guard let managedRoot else {
          throw RecoveredSessionError.managedRootUnavailable
        }
        let preparation = try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
        return try preparation.leaseRecoveredPlayback(
          sessionId: identity.sessionId,
          sourceId: identity.sourceId,
          trackId: identity.trackId,
          segmentId: identity.segmentId
        )
      },
      player: RecoveredAudioPlayer(),
      timelineProvider: { sessionId in
        guard let managedRoot else { throw RecoveredSessionError.managedRootUnavailable }
        return try NativeRecordingPreparation.open(managedRoot: managedRoot.path)
          .playbackTimeline(sessionId: sessionId)
      }
    )
  }

  /// Scans the library off the main actor. `phase` stays `.scanning` until the
  /// scan publishes; a newer scan supersedes an older one still in flight.
  func recoverOnLaunch() {
    if playingSessionId != nil || activePlaybackGeneration != nil {
      stopPlayback()
    }
    phase = .scanning
    clearPlaybackError()
    recoveryTask?.cancel()
    let generation = UUID()
    recoveryGeneration = generation
    let recoveryFactory = recoveryFactory
    AppTelemetry.recoveryProof(stage: "scan-started", detail: "launch")
    let started = ContinuousClock.now
    let signpost = AppTelemetry.signposter.beginInterval("launch_recovery")
    recoveryTask = Task { [weak self] in
      let outcome: Result<[NativeRecoveredPlayableSession], Error>
      do {
        outcome = .success(
          try await StructuredNativeIO.read {
            if Thread.isMainThread {
              AppTelemetry.performanceStall(operation: "launch_recovery_main", milliseconds: 0)
            }
            return try recoveryFactory().recoverPlayableSessions()
          })
      } catch {
        outcome = .failure(error)
      }
      let milliseconds = DiagnosticTiming.milliseconds(since: started)
      AppTelemetry.signposter.endInterval("launch_recovery", signpost)
      DiagnosticTiming.note("launch_recovery", milliseconds: milliseconds)
      guard let self, self.recoveryGeneration == generation else { return }
      self.recoveryTask = nil
      self.publishLaunchRecovery(outcome, milliseconds: milliseconds)
    }
  }

  /// Waits for the scan started by `recoverOnLaunch`, including one that has
  /// already published.
  func waitForLaunchRecovery() async {
    await recoveryTask?.value
  }

  private func publishLaunchRecovery(
    _ outcome: Result<[NativeRecoveredPlayableSession], Error>,
    milliseconds: Int
  ) {
    do {
      let recovered = try outcome.get()
      guard
        recovered.allSatisfy({
          $0.mediaPreserved && $0.readyForReview && !$0.recordingStarted
            && $0.sampleCount > 0 && $0.byteLength > 0
        })
      else {
        throw RecoveredSessionError.invalidEvidence
      }
      sessions = recovered
      phase = recovered.isEmpty ? .none : .available
      AppTelemetry.recoveryProof(
        stage: "scan-finished",
        detail: "phase=\(phase.diagnosticName) count=\(recovered.count) milliseconds=\(milliseconds)"
      )
    } catch is CancellationError {
      sessions = []
      clearPlaybackError()
      phase = .none
      AppTelemetry.recoveryProof(
        stage: "scan-cancelled", detail: "milliseconds=\(milliseconds)")
    } catch RecoveredSessionError.invalidEvidence {
      publishRecoveryFailure(code: "invalid_evidence", milliseconds: milliseconds)
    } catch {
      publishRecoveryFailure(code: "unavailable", milliseconds: milliseconds)
    }
  }

  private func publishRecoveryFailure(code: String, milliseconds: Int) {
    sessions = []
    errorMessage =
      "Recovery could not confirm playable local media. Original files were not changed."
    errorSessionId = nil
    errorRecoveredMediaIdentity = nil
    phase = .failed
    AppTelemetry.recoveryProof(
      stage: code == "invalid_evidence" ? "scan-rejected" : "scan-failed",
      detail: "code=\(code) milliseconds=\(milliseconds)")
  }

  @discardableResult
  func play(_ session: NativeRecoveredPlayableSession) -> UUID? {
    guard session.readyForReview, session.mediaPreserved, !session.recordingStarted else {
      return nil
    }
    stopPlayback()
    let identity = RecoveredPlaybackMediaIdentity(session)
    let generation = UUID()
    beginRecoveredPlaybackStartup(generation: generation, identity: identity)
    activePlaybackGeneration = generation
    activePlaybackSessionId = session.sessionId
    pendingRecoveredMediaIdentity = identity
    clearPlaybackError()
    notePlayback("playback-requested", sessionId: session.sessionId)
    let leaseProvider = recoveredPlaybackLeaseProvider
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        let lease = try await StructuredImportedPlaybackCopy.run { isCancelled in
          if isCancelled() { throw CancellationError() }
          let lease = try leaseProvider(identity)
          if isCancelled() { throw CancellationError() }
          return lease
        }
        try Task.checkCancellation()
        guard self.activePlaybackGeneration == generation else { return }
        try await self.player.playRecovered(
          receipt: lease.playbackPath(),
          retaining: lease,
          generation: generation
        )
        guard self.activePlaybackGeneration == generation else { return }
        self.settleRecoveredPlaybackStartup(generation: generation, state: .playing)
        self.playbackTask = nil
        self.playingSessionId = session.sessionId
        self.notePlayback("playback-opened", sessionId: session.sessionId)
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = identity
        self.clearPlaybackError()
      } catch is CancellationError {
        self.finishCancelledPlayback(generation: generation)
      } catch {
        guard self.activePlaybackGeneration == generation else { return }
        self.settleRecoveredPlaybackStartup(generation: generation, state: .failed)
        self.player.stop()
        self.activePlaybackGeneration = nil
        self.playbackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = nil
        self.setPlaybackError(
          "Recovered audio could not be opened for playback.",
          sessionId: session.sessionId,
          recoveredMediaIdentity: identity
        )
      }
    }
    return generation
  }

  func playbackStartupState(
    generation: UUID,
    identity: RecoveredPlaybackMediaIdentity
  ) -> RecoveredPlaybackStartupState? {
    guard let record = recoveredPlaybackStartupRecords[generation], record.identity == identity
    else {
      return nil
    }
    return record.state
  }

  /// Plays saved imported audio, optionally from a position in the media.
  func play(_ session: RuntimeSessionPresentation, startNanoseconds: Int64 = 0) {
    stopPlayback()
    clearPlaybackError()
    guard let media = session.playableMedia else {
      setPlaybackError(
        "This saved conversation has no confirmed playable local audio.",
        sessionId: session.sessionId
      )
      return
    }
    guard media.isPlayable else {
      setPlaybackError(
        media.availability == "corrupt"
          ? "Saved audio appears corrupt and was not opened."
          : "Saved audio is unavailable and was not opened.",
        sessionId: session.sessionId
      )
      return
    }
    let leaseProvider = importedPlaybackLeaseProvider
    let sessionId = session.sessionId
    notePlayback("playback-requested", sessionId: sessionId)
    let generation = UUID()
    activePlaybackGeneration = generation
    activePlaybackSessionId = session.sessionId
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        let lease = try await StructuredNativeIO.read {
          try leaseProvider(sessionId)
        }
        guard self.activePlaybackGeneration == generation else { return }
        try await self.player.playImported(
          receipt: lease.playbackPath(),
          retaining: lease,
          generation: generation,
          startNanoseconds: startNanoseconds
        )
        guard self.activePlaybackGeneration == generation else { return }
        self.playbackTask = nil
        self.playingSessionId = session.sessionId
        self.notePlayback("playback-opened", sessionId: session.sessionId)
        self.clearPlaybackError()
      } catch is CancellationError {
        guard self.activePlaybackGeneration == generation else { return }
        self.finishCancelledPlayback(generation: generation)
      } catch ImportedPlaybackError.unsupportedByteLength {
        guard self.activePlaybackGeneration == generation else { return }
        self.player.stop()
        self.activePlaybackGeneration = nil
        self.playbackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = nil
        self.setPlaybackError(
          "Saved audio is too large for safe playback on this version of Open Scribe.",
          sessionId: session.sessionId
        )
      } catch {
        guard self.activePlaybackGeneration == generation else { return }
        self.player.stop()
        self.activePlaybackGeneration = nil
        self.playbackTask = nil
        self.activePlaybackSessionId = nil
        self.playingSessionId = nil
        self.pendingRecoveredMediaIdentity = nil
        self.playingRecoveredMediaIdentity = nil
        self.setPlaybackError(
          "Saved audio could not be opened for playback.",
          sessionId: session.sessionId
        )
      }
    }
  }

  func playSynchronized(sessionId: String, startNanoseconds: Int64 = 0) {
    stopPlayback()
    clearPlaybackError()
    guard let timelineProvider else {
      setPlaybackError("Synchronized playback is unavailable.", sessionId: sessionId)
      return
    }
    let generation = UUID()
    activePlaybackGeneration = generation
    activePlaybackSessionId = sessionId
    notePlayback("playback-requested", sessionId: sessionId)
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        let segments = try await StructuredImportedPlaybackCopy.run { isCancelled in
          if isCancelled() { throw CancellationError() }
          let result = try timelineProvider(sessionId)
          if isCancelled() { throw CancellationError() }
          return result
        }
        try Task.checkCancellation()
        guard self.activePlaybackGeneration == generation else { return }
        try self.timelinePlayer.play(
          segments: segments, startNanoseconds: startNanoseconds, generation: generation
        ) {
          [weak self] termination in
          Task { @MainActor [weak self] in
            guard let self, self.activePlaybackGeneration == termination.generation else { return }
            self.stopPlayback(generation: termination.generation)
            if termination.outcome != .finished {
              self.setPlaybackError(
                "Synchronized playback stopped. Check the audio output and try again.",
                sessionId: sessionId)
            }
          }
        }
        self.timelineClockAdjustmentNanoseconds =
          segments.map(\.clockAdjustmentNanoseconds).max() ?? 0
        self.playingSessionId = sessionId
        self.notePlayback("playback-opened", sessionId: sessionId)
        self.playbackTask = nil
      } catch {
        guard self.activePlaybackGeneration == generation else { return }
        self.stopPlayback(generation: generation)
        if !(error is CancellationError) {
          self.setPlaybackError(
            "A synchronized timeline could not be verified. Older recordings may have no shared clock.",
            sessionId: sessionId)
        }
      }
    }
  }

  func playMixdown(sessionId: String) {
    stopPlayback()
    clearPlaybackError()
    guard let mixdownLeaseProvider else {
      setPlaybackError("Stereo mix playback is unavailable.", sessionId: sessionId)
      return
    }
    let generation = UUID()
    activePlaybackGeneration = generation
    activePlaybackSessionId = sessionId
    activeMixdownSessionId = sessionId
    notePlayback("playback-requested", sessionId: sessionId)
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        let lease = try await StructuredNativeIO.mutation {
          try mixdownLeaseProvider(sessionId)
        }
        try Task.checkCancellation()
        guard self.activePlaybackGeneration == generation else { return }
        try await self.player.playImported(
          receipt: lease.playbackPath(), retaining: lease, generation: generation)
        guard self.activePlaybackGeneration == generation else { return }
        self.playingSessionId = sessionId
        self.notePlayback("playback-opened", sessionId: sessionId)
        self.playbackTask = nil
      } catch {
        guard self.activePlaybackGeneration == generation else { return }
        self.stopPlayback(generation: generation)
        if !(error is CancellationError) {
          self.setPlaybackError(
            "The stereo mix could not be verified. Source tracks remain available below.",
            sessionId: sessionId)
        }
      }
    }
  }

  func stopPlayback(generation: UUID? = nil) {
    if let generation, activePlaybackGeneration != generation { return }
    if let activePlaybackGeneration {
      settleRecoveredPlaybackStartup(
        generation: activePlaybackGeneration,
        state: .superseded
      )
    }
    playbackTask?.cancel()
    playbackTask = nil
    activePlaybackGeneration = nil
    activePlaybackSessionId = nil
    pendingRecoveredMediaIdentity = nil
    playingRecoveredMediaIdentity = nil
    player.stop()
    timelinePlayer.stop()
    timelineClockAdjustmentNanoseconds = 0
    playingSessionId = nil
    activeMixdownSessionId = nil
  }

  private func finishCancelledPlayback(generation: UUID) {
    guard activePlaybackGeneration == generation else { return }
    settleRecoveredPlaybackStartup(generation: generation, state: .superseded)
    player.stop()
    activePlaybackGeneration = nil
    playbackTask = nil
    activePlaybackSessionId = nil
    playingSessionId = nil
    activeMixdownSessionId = nil
    pendingRecoveredMediaIdentity = nil
    playingRecoveredMediaIdentity = nil
  }

  private func setPlaybackError(
    _ message: String,
    sessionId: String?,
    recoveredMediaIdentity: RecoveredPlaybackMediaIdentity? = nil
  ) {
    errorMessage = message
    errorSessionId = sessionId
    errorRecoveredMediaIdentity = recoveredMediaIdentity
    AppTelemetry.recoveryProof(
      stage: "playback-failed",
      detail: "session=\(DiagnosticPrivacy.token(sessionId ?? "none"))"
    )
  }

  private func notePlayback(_ stage: String, sessionId: String) {
    AppTelemetry.recoveryProof(
      stage: stage,
      detail: "session=\(DiagnosticPrivacy.token(sessionId))"
    )
  }

  private func clearPlaybackError() {
    errorMessage = nil
    errorSessionId = nil
    errorRecoveredMediaIdentity = nil
  }

  private func beginRecoveredPlaybackStartup(
    generation: UUID,
    identity: RecoveredPlaybackMediaIdentity
  ) {
    recoveredPlaybackStartupRecords[generation] = RecoveredPlaybackStartupRecord(
      identity: identity,
      state: .pending
    )
    recoveredPlaybackStartupOrder.append(generation)
    while recoveredPlaybackStartupOrder.count > Self.maximumRecoveredPlaybackStartupRecords {
      let evicted = recoveredPlaybackStartupOrder.removeFirst()
      recoveredPlaybackStartupRecords.removeValue(forKey: evicted)
    }
  }

  private func settleRecoveredPlaybackStartup(
    generation: UUID,
    state: RecoveredPlaybackStartupState
  ) {
    guard var record = recoveredPlaybackStartupRecords[generation], record.state == .pending else {
      return
    }
    record.state = state
    recoveredPlaybackStartupRecords[generation] = record
  }
}
