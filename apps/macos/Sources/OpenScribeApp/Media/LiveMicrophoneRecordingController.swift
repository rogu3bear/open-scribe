@preconcurrency import AVFoundation
import AppKit
import Darwin
import Foundation

typealias MicrophoneFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias MicrophoneHealthHandler = @Sendable (MicrophoneSourceHealthObservation) -> Void
typealias MicrophoneFailureHandler = @Sendable (MicrophoneCaptureAdapterError) -> Void
typealias SystemAudioFirstSampleHandler = @Sendable (NativeFirstSampleReceipt) -> Void
typealias SystemAudioFailureHandler = @Sendable (SystemAudioCaptureAdapterError) -> Void

protocol ManagedSegmentWriting: CapturedAudioWriting {
  var authorization: NativeMediaOpenAuthorization { get }
  func receipt() throws -> NativeMediaOpenReceipt
  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt
  /// Rust's durable acceptance of `segmentId`'s first sample when this writer
  /// already submitted it on its own queue; nil when the caller must submit.
  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence?
}

extension ManagedSegmentWriting {
  func acceptedFirstSampleEvidence(segmentId: String) -> NativeFirstSampleEvidence? { nil }
}

extension ManagedCAFWriter: ManagedSegmentWriting {}

protocol MicrophoneCapturing: AnyObject, Sendable {
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler,
    onFailure: @escaping MicrophoneFailureHandler
  ) throws
  func stop() -> UInt64?
}

extension MicrophoneCaptureAdapter: MicrophoneCapturing {}

protocol SystemAudioCapturing: AnyObject, Sendable {
  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws
  func stop() async throws -> UInt64?
}

extension SystemAudioCaptureAdapter: SystemAudioCapturing {}

enum LiveMicrophoneRecordingPhase: String, Equatable, Sendable {
  case idle
  case requestingPermission
  case preparing
  case starting
  case capturing
  case pausing
  case paused
  case stopping
  case saved
  case failed
}

@MainActor
final class LiveMicrophoneRecordingController: NSObject, ObservableObject {
  typealias PreparationFactory = @Sendable () throws -> NativeRecordingPreparationProtocol
  typealias WriterFactory =
    @Sendable (NativeMediaOpenAuthorization) throws
    -> ManagedSegmentWriting
  typealias CaptureFactory = @Sendable (ManagedSegmentWriting) -> MicrophoneCapturing
  typealias SystemCaptureFactory =
    @Sendable (ManagedSegmentWriting) async throws -> SystemAudioCapturing
  typealias CaptureHealthTelemetry =
    @Sendable (CaptureSourceHealthTelemetryRecord) -> Void

  @Published private(set) var phase: LiveMicrophoneRecordingPhase = .idle {
    didSet { notePhaseChange(from: oldValue) }
  }
  @Published private(set) var errorMessage: String?
  @Published private(set) var failureCode: String?
  @Published private(set) var savedPath: String?
  @Published private(set) var savedPaths: [String] = []
  @Published private(set) var microphoneSourceHealth: MicrophoneSourceHealthObservation?
  @Published private(set) var captureSelection: RecorderCaptureSelection = .system
  @Published private(set) var recorderDetail: NativeRecorderDetail?
  @Published private(set) var mixdownStatus: String?
  @Published private(set) var lastSavedSessionId: String?
  /// The app sets this while launch recovery scans the library off the main
  /// actor; no recording or import may begin until that scan publishes.
  var isLaunchRecoveryPending: @MainActor () -> Bool = { false }

  private let permission: MicrophonePermissionProviding
  private let preparationFactory: PreparationFactory
  private let writerFactory: WriterFactory
  private let captureFactory: CaptureFactory
  private let systemCaptureFactory: SystemCaptureFactory?
  private var requiredSources: [NativeMediaSourceKind]
  private let captureHealthTelemetry: CaptureHealthTelemetry
  private let segmentedCapture: Bool
  private let availableBytes: @Sendable (String) throws -> UInt64
  private let segmentedSuccessorWriterFactory:
    @Sendable (NativeMediaOpenAuthorization) throws -> ManagedCAFWriter
  private let hostTime: @Sendable () -> UInt64
  private let proofCheckpoint: @Sendable (RecorderProofPhase, String) -> Void
  private var selectedSystemCaptureFactory:
    (
      @Sendable (ManagedSegmentWriting, RecorderCaptureSelection) async throws ->
        SystemAudioCapturing
    )?
  private var storageWatchTask: Task<Void, Never>?
  private var permissionWatchTask: Task<Void, Never>?
  private var applicationExitObserver: NSObjectProtocol?
  private var systemPowerObservers: [NSObjectProtocol] = []

  private var preparation: NativeRecordingPreparationProtocol?
  private var writers: [NativeMediaSourceKind: ManagedSegmentWriting] = [:]
  private var microphoneCapture: MicrophoneCapturing?
  private var systemCapture: SystemAudioCapturing?
  private var sourcesWithFirstSample: Set<NativeMediaSourceKind> = []
  private var failedSources: Set<NativeMediaSourceKind> = []
  private var sourceFailureTask: Task<Void, Never>?
  private var activeSessionId: String?
  /// Kept after the active id is cleared so a Saved or Failed line still
  /// names the session. Titles and paths are never stored here.
  private var diagnosticSessionId: String?
  private var activeAttempt: UUID?
  /// Identity the microphone adapter binds when capture starts. Segment
  /// generations advance on every rotation, so observations are matched
  /// against this snapshot, never against the current segment.
  private var microphoneCaptureIdentity: MicrophoneCaptureIdentity?
  private var acceptedMicrophoneObservationSequence: UInt64 = 0
  /// Matches `RESERVE_BYTES` in the store. A restore below this returns the
  /// space sentence and does not observe storage or stop the recording.
  private static let microphoneRestoreReserveBytes: UInt64 = 512 * 1024 * 1024
  private let microphoneDeviceProbe: @MainActor () -> MicrophoneDeviceIdentity?
  private var selectedMicrophoneDevice: MicrophoneDeviceIdentity?
  private var pendingDifferentDevice: MicrophoneDeviceIdentity?
  private var sealedMicrophoneWriter: ManagedSegmentWriting?
  private var microphoneRestoreCapture: MicrophoneCapturing?
  private var restoreTask: Task<Void, Never>?
  private var restoreSampleGate: RestoreSampleGate?
  private var restorePermissionTask: Task<Void, Never>?
  private var restoreGeneration = UUID()
  private var restoreCancelled = false
  /// Approved device for one paused restore. The next resume consumes it.
  /// Later probes must not read the mutable selection in its place.
  private var approvedPausedMicrophoneRestore: MicrophoneDeviceIdentity?
  /// Continuing-source notice held until Rust confirms `.capturing`.
  /// A Starting span must not claim the other source is recording.
  private var pendingPausedRestoreNotice: String?
  /// Set while an explicit restore has an opening segment and no new sample.
  private var microphoneRestoreSegmentOpen = false
  private var restorePermissionWithdrawn = false

  init(
    permission: MicrophonePermissionProviding,
    preparationFactory: @escaping PreparationFactory,
    writerFactory: @escaping WriterFactory,
    captureFactory: @escaping CaptureFactory,
    requiredSources: [NativeMediaSourceKind] = [.microphone],
    systemCaptureFactory: SystemCaptureFactory? = nil,
    segmentedCapture: Bool = false,
    hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
    availableBytes: @escaping @Sendable (String) throws -> UInt64 = {
      try RecorderStorage.availableBytes(at: $0)
    },
    segmentedSuccessorWriterFactory:
      @escaping @Sendable (NativeMediaOpenAuthorization) throws -> ManagedCAFWriter = {
        try ManagedCAFWriter(authorization: $0)
      },
    proofCheckpoint: @escaping @Sendable (RecorderProofPhase, String) -> Void = { _, _ in },
    captureHealthTelemetry: @escaping CaptureHealthTelemetry = {
      AppTelemetry.captureSourceHealth($0)
    },
    microphoneDeviceProbe: @escaping @MainActor () -> MicrophoneDeviceIdentity? = { nil }
  ) {
    self.permission = permission
    self.preparationFactory = preparationFactory
    self.writerFactory = writerFactory
    self.captureFactory = captureFactory
    self.requiredSources = requiredSources
    self.systemCaptureFactory = systemCaptureFactory
    self.captureHealthTelemetry = captureHealthTelemetry
    self.segmentedCapture = segmentedCapture
    self.hostTime = hostTime
    self.availableBytes = availableBytes
    self.proofCheckpoint = proofCheckpoint
    self.segmentedSuccessorWriterFactory = segmentedSuccessorWriterFactory
    self.microphoneDeviceProbe = microphoneDeviceProbe
    super.init()
    observeSystemPower()
  }

  override convenience init() {
    let root = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("Open Scribe", isDirectory: true)
    self.init(managedRoot: root)
  }

  convenience init(managedRoot: URL?) {
    self.init(
      permission: AVFoundationMicrophonePermissionAuthority(),
      preparationFactory: {
        guard let root = managedRoot else {
          throw LiveMicrophoneRecordingError.managedRootUnavailable
        }
        return try NativeRecordingPreparation.open(managedRoot: root.path)
      },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { writer in
        MicrophoneCaptureAdapter(
          backend: AVAudioEngineMicrophoneBackend(),
          writer: writer,
          identity: MicrophoneCaptureIdentity(authorization: writer.authorization)
        )
      },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { writer in
        try await SystemAudioCaptureAdapter.allAuthorizedSystemAudio(writer: writer)
      },
      segmentedCapture: true,
      microphoneDeviceProbe: { MicrophoneDeviceProbe.currentInput() }
    )
    selectedSystemCaptureFactory = { writer, selection in
      if let filter = selection.filter {
        return SystemAudioCaptureAdapter(writer: writer, filter: filter)
      }
      guard selection.kind == .systemAudio else {
        throw LiveMicrophoneRecordingError.invalidSourcePlan
      }
      return try await SystemAudioCaptureAdapter.allAuthorizedSystemAudio(writer: writer)
    }
  }

  var isCapturing: Bool {
    phase == .capturing
  }

  var canStart: Bool {
    (phase == .idle || phase == .saved || phase == .failed) && activeSessionId == nil
      && !isLaunchRecoveryPending()
  }

  /// True once the microphone failed in this session. It stays retired for
  /// every later span, so a microphone-only scope would capture nothing.
  var isMicrophoneRetired: Bool { failedSources.contains(.microphone) }

  /// Resume does not show this. The microphone is retired, this session is
  /// open, and another required source is still available.
  var showsReconnect: Bool {
    guard phase == .capturing || phase == .paused else { return false }
    guard activeSessionId != nil, failedSources.contains(.microphone) else { return false }
    return requiredSources.contains { $0 != .microphone && !failedSources.contains($0) }
  }

  var showsUseThisMicrophone: Bool {
    showsReconnect && pendingDifferentDevice != nil
  }

  private var continuingSourceName: String {
    captureSelection.kind == .applicationAudio ? captureSelection.name : "System audio"
  }

  /// Live wording for a source that is recording. Stored for publication
  /// after Rust confirms `.capturing`; never replaced by the paused clause.
  private var continuingSourceContinuation: String {
    "\(continuingSourceName) is still recording."
  }

  /// Paused restore preflight has not resumed the other source. Capturing
  /// and the future notice keep the caller's live continuation.
  private func restoreContinuation(_ liveContinuation: String) -> String {
    phase == .paused ? "The recording is paused." : liveContinuation
  }

  private var capturingMicrophoneSentence: String {
    "The microphone stopped. \(continuingSourceContinuation)"
  }

  private var pausedMicrophoneSentence: String {
    "The microphone stopped. The recording is paused."
  }

  private var microphoneCouldNotBeRestoredSentence: String {
    "The microphone could not be restored. \(restoreContinuation(continuingSourceContinuation))"
  }

  private var microphoneCouldNotBeRestoredContinuingSentence: String {
    "The microphone could not be restored. \(continuingSourceContinuation)"
  }

  private var microphoneCouldNotBeRestoredResumingSentence: String {
    "The microphone could not be restored. The recording is resuming."
  }

  private var microphonePermissionWithdrawnSentence: String {
    "Microphone access was withdrawn. \(restoreContinuation(continuingSourceContinuation))"
  }

  private var microphonePermissionWithdrawnContinuingSentence: String {
    "Microphone access was withdrawn. \(continuingSourceContinuation)"
  }

  private var microphonePermissionWithdrawnResumingSentence: String {
    "Microphone access was withdrawn. The recording is resuming."
  }

  private var microphoneAccessOffSentence: String {
    "Microphone access is off. Enable it in System Settings. "
      + restoreContinuation(continuingSourceContinuation)
  }

  private var microphoneRestoreReserveSentence: String {
    "Not enough free space to restore the microphone. "
      + restoreContinuation("Existing audio is still recording.")
  }

  private var differentMicrophoneContinuingSentence: String {
    "This is a different microphone. \(continuingSourceContinuation)"
  }

  private var unavailableMicrophoneContinuingSentence: String {
    "The selected microphone is not available. \(continuingSourceContinuation)"
  }

  private var differentMicrophoneSentence: String {
    "This is a different microphone. \(restoreContinuation(continuingSourceContinuation))"
  }

  private var unavailableMicrophoneSentence: String {
    "The selected microphone is not available. \(restoreContinuation(continuingSourceContinuation))"
  }

  private var differentMicrophoneResumingSentence: String {
    "This is a different microphone. The recording is resuming."
  }

  private var unavailableMicrophoneResumingSentence: String {
    "The selected microphone is not available. The recording is resuming."
  }

  var sourceSelectionPresentation: RecorderSourceSelectionPresentation {
    // A new session clears retirement; a resumed span preserves it.
    RecorderSourceSelectionPresentation(
      selection: captureSelection,
      microphoneRetired: !canStart && isMicrophoneRetired,
      selectedAudioRetired: !canStart
        && captureSelection.kind.map { failedSources.contains($0) } == true
    )
  }

  var canStop: Bool {
    phase == .starting || phase == .capturing || phase == .paused
  }

  var canPause: Bool { segmentedCapture && phase == .capturing }
  var canResume: Bool { segmentedCapture && phase == .paused }
  var canMark: Bool { segmentedCapture && (phase == .capturing || phase == .paused) }

  /// The session journal's one writer and its open session, for context
  /// scope changes and proposals (ADR 0011). `nil` when no capture is open.
  var contextBinding: ContextBinding? {
    guard let preparation, let activeSessionId,
      [.starting, .capturing, .pausing, .paused].contains(phase)
    else { return nil }
    return ContextBinding(preparation: preparation, sessionId: activeSessionId)
  }

  /// Idle wording. It never claims readiness while launch recovery holds capture.
  var readinessText: String {
    isLaunchRecoveryPending()
      ? "Checking recordings from the last session…"
      : "Ready to record \(captureSelection.recordedAudio)"
  }

  var statusText: String {
    switch phase {
    case .idle: readinessText
    case .requestingPermission: "Requesting microphone access…"
    case .preparing: "Preparing durable recording…"
    case .starting:
      failedSources.isEmpty
        ? "Starting \(captureSelection.recordedAudio)…" : "Starting the remaining audio…"
    case .capturing:
      if !failedSources.isEmpty {
        "Recording continues with remaining audio"
      } else if microphoneSourceHealth?.event == .routeInterrupted {
        "Recording continues; checking microphone after an audio-route change"
      } else {
        "Recording \(captureSelection.recordedAudio)"
      }
    case .pausing: "Securing the pause boundary…"
    case .paused: "Paused — captured time is stopped"
    case .stopping: "Securing recording…"
    case .saved: mixdownStatus ?? "Recording saved"
    case .failed: "Conversation capture failed"
    }
  }

  func start(resuming: Bool = false) async {
    guard resuming ? canResume : canStart else { return }
    let approvedPausedRestore = resuming ? approvedPausedMicrophoneRestore : nil
    approvedPausedMicrophoneRestore = nil
    var restoringMicrophone = approvedPausedRestore != nil
    let previousWriters = resuming ? writers : [:]
    let previousSession = resuming ? activeSessionId : nil
    let previousSavedPaths = savedPaths
    let attempt = UUID()
    activeAttempt = attempt
    lastSavedSessionId = nil
    mixdownStatus = nil
    if !resuming { recorderDetail = nil }
    errorMessage = nil
    pendingPausedRestoreNotice = nil
    failureCode = nil
    savedPath = nil
    savedPaths = []
    activeSessionId = nil
    if !resuming {
      diagnosticSessionId = nil
      selectedMicrophoneDevice = nil
      pendingDifferentDevice = nil
      sealedMicrophoneWriter = nil
      microphoneRestoreSegmentOpen = false
    }
    writers = [:]
    sourcesWithFirstSample = []
    // A source that failed during degraded continuation stays retired for
    // every later span of the same session; a fresh session starts clean.
    failedSources = resuming ? failedSources : []
    microphoneSourceHealth = nil
    microphoneCaptureIdentity = nil
    acceptedMicrophoneObservationSequence = 0
    if !failedSources.contains(.microphone) {
      phase = .requestingPermission
      let permissionState = await permission.request()
      guard permissionState == .authorized else {
        if resuming {
          writers = previousWriters
          rememberSession(previousSession)
          savedPaths = previousSavedPaths
          savedPath = previousSavedPaths.first
          activeAttempt = nil
          phase = .paused
          errorMessage = "Microphone access is unavailable. The recording remains paused."
          return
        }
        await fail(
          "Microphone access is \(permissionState.rawValue). Enable it in System Settings.",
          code: "permission-\(permissionState.rawValue)"
        )
        return
      }
      selectedMicrophoneDevice = microphoneDeviceProbe()
    }

    phase = .preparing
    do {
      let preparation = try self.preparation ?? preparationFactory()
      let sessionId: String
      if let previousSession {
        sessionId = previousSession
        do {
          if let path = previousWriters.values.first?.authorization.absolutePath {
            recorderDetail = try preparation.recorderAction(
              sessionId: sessionId,
              action: .observeStorage(availableBytes: self.availableBytes(path)))
          }
          _ = try preparation.recorderAction(sessionId: sessionId, action: .prepareResume)
        } catch {
          // Resume preparation failed before any source started. Rust never
          // journaled the resume, so it is still paused; restore the paused
          // session exactly as a denied permission does and explain why. Resume
          // and Stop stay available.
          self.preparation = preparation
          writers = previousWriters
          rememberSession(previousSession)
          savedPaths = previousSavedPaths
          savedPath = previousSavedPaths.first
          microphoneCapture = nil
          systemCapture = nil
          activeAttempt = nil
          if restoringMicrophone {
            cancelJournaledMicrophoneRestore(sessionId: previousSession, preparation: preparation)
            restoringMicrophone = false
          }
          errorMessage =
            recorderDetail?.storageLevel == "critical"
            ? "Not enough free space to resume. The recording is still paused; free space and try again."
            : "The recording could not resume and remains paused. \(error.localizedDescription)"
          phase = .paused
          return
        }
      } else {
        let prepared = try preparation.prepareSessionWithRequiredSources(
          title: Self.sessionTitle(), requiredSources: requiredSources)
        guard prepared.journalDurable, !prepared.recordingStarted else {
          throw LiveMicrophoneRecordingError.invalidPreparation
        }
        sessionId = prepared.sessionId
        if segmentedCapture {
          _ = try preparation.recorderAction(
            sessionId: sessionId,
            action: .selectAudio(
              kind: captureSelection.kind, identity: captureSelection.identity,
              displayName: captureSelection.name))
        }
      }
      self.preparation = preparation
      rememberSession(sessionId)
      proofCheckpoint(.preparation, sessionId)
      // Retired sources keep their sealed writer for the saved-path list but
      // get no successor authorization and no capture in this span.
      for source in requiredSources where failedSources.contains(source) {
        if let previous = previousWriters[source] { writers[source] = previous }
      }
      if restoringMicrophone {
        openRestoredMicrophone(
          preparation: preparation, sessionId: sessionId, previousWriters: previousWriters)
      }
      let spanSources = requiredSources.filter { !failedSources.contains($0) }
      for (index, source) in spanSources.enumerated() {
        let authorization: NativeMediaOpenAuthorization
        if let previous = previousWriters[source] {
          authorization = try preparation.authorizeNextSegment(
            sessionId: sessionId, previousSegmentId: previous.authorization.segmentId)
        } else {
          authorization = try preparation.authorizeInitialMedia(
            sessionId: sessionId, sourceKind: source,
            sourceDisplayName: source == .microphone
              ? Self.displayName(for: source) : captureSelection.name)
        }
        if segmentedCapture {
          let storage = try preparation.recorderAction(
            sessionId: sessionId,
            action: .observeStorage(
              availableBytes: self.availableBytes(
                URL(fileURLWithPath: authorization.absolutePath).deletingLastPathComponent().path)))
          guard storage.storageLevel != "critical" else {
            throw ManagedCAFWriterError.storagePressure
          }
          recorderDetail = storage
        }
        let writer = try writerFactory(authorization)
        let mediaOpen = try preparation.acceptMediaOpen(receipt: writer.receipt())
        let allMediaShouldBeOpen = index == spanSources.count - 1
        guard mediaOpen.journalDurable,
          mediaOpen.mediaFilesOpen == allMediaShouldBeOpen,
          !mediaOpen.recordingStarted
        else {
          throw LiveMicrophoneRecordingError.invalidMediaOpen
        }
        if segmentedCapture {
          guard let nativeWriter = writer as? ManagedCAFWriter else {
            throw LiveMicrophoneRecordingError.invalidMediaOpen
          }
          writers[source] = SegmentedCAFWriter(
            current: nativeWriter, preparation: preparation,
            makeSuccessor: segmentedSuccessorWriterFactory)
        } else {
          writers[source] = writer
        }
      }

      if microphoneRestoreSegmentOpen {
        failedSources.remove(.microphone)
      }

      let microphoneCapture: MicrophoneCapturing?
      if failedSources.contains(.microphone) {
        microphoneCapture = nil
      } else {
        guard let microphoneWriter = writers[.microphone] else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        microphoneCapture = captureFactory(microphoneWriter)
        microphoneCaptureIdentity = MicrophoneCaptureIdentity(
          authorization: microphoneWriter.authorization)
      }
      self.microphoneCapture = microphoneCapture

      let audioSource = spanSources.first { $0 != .microphone }
      if let audioSource {
        guard let systemWriter = writers[audioSource] else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        do {
          if let selectedSystemCaptureFactory {
            systemCapture = try await selectedSystemCaptureFactory(systemWriter, captureSelection)
          } else if let systemCaptureFactory {
            systemCapture = try await systemCaptureFactory(systemWriter)
          } else {
            throw LiveMicrophoneRecordingError.invalidSourcePlan
          }
        } catch {
          if microphoneRestoreSegmentOpen { cancelOpenMicrophoneRestore() }
          await fail(
            "System audio access or the selected source is unavailable. \(error.localizedDescription)",
            code: "system-audio-unavailable",
            interruptionReason: .captureStartFailed
          )
          return
        }
      }

      if segmentedCapture {
        if resuming {
          _ = try preparation.recorderAction(
            sessionId: sessionId, action: .anchorResume(hostTime: hostTime()))
        } else {
          try SegmentedCAFWriter.anchor(
            preparation: preparation, sessionId: sessionId, hostAnchor: hostTime())
        }
      }
      phase = .starting
      guard await checkMicrophonePermission() else { return }
      beginPermissionWatch()
      if let systemCapture, let audioSource {
        try await systemCapture.start(
          onFirstSample: { [weak self] receipt in
            Task { @MainActor [weak self] in
              guard self?.activeSessionId == sessionId else { return }
              guard self?.activeAttempt == attempt else { return }
              await self?.acceptFirstSample(receipt, from: audioSource, attempt: attempt)
            }
          },
          onFailure: { [weak self] error in
            Task { @MainActor [weak self] in
              guard self?.activeSessionId == sessionId else { return }
              guard self?.activeAttempt == attempt else { return }
              if error == .userStopped {
                await self?.stop()
                return
              }
              await self?.handleCaptureFailure(
                String(describing: error),
                code: "system-audio-\(String(describing: error))",
                source: audioSource,
                interruptionReason: error == .permissionDenied ? .permissionRevoked : .captureFailed
              )
            }
          }
        )
        // Rust can confirm the surviving span before this await returns.
        // Keep that span. A stale or cancelled attempt still stops its source.
        guard activeAttempt == attempt, activeSessionId == sessionId, !restoreCancelled,
          phase == .starting || phase == .capturing
        else {
          _ = try? await systemCapture.stop()
          if restoreCancelled { cancelOpenMicrophoneRestore() }
          return
        }
        guard await checkMicrophonePermission() else { return }
      }
      if let approvedPausedRestore {
        guard activeAttempt == attempt, activeSessionId == sessionId, !restoreCancelled,
          phase == .starting || phase == .capturing
        else {
          if restoreCancelled { cancelOpenMicrophoneRestore() }
          return
        }
        // The approved identity is fixed for this resume. Probe with no further
        // suspension; a change is a different choice and must not start capture.
        let observedDevice = microphoneDeviceProbe()
        if observedDevice?.uniqueID != approvedPausedRestore.uniqueID {
          cancelOpenMicrophoneRestore()
          // Starting has not confirmed the span, so describe resume. Recording
          // already confirmed by Rust keeps the continuing-source sentence.
          let alreadyConfirmed = phase == .capturing
          if let observedDevice {
            pendingDifferentDevice = observedDevice
            if alreadyConfirmed {
              pendingPausedRestoreNotice = nil
              errorMessage = differentMicrophoneContinuingSentence
            } else {
              pendingPausedRestoreNotice = differentMicrophoneContinuingSentence
              errorMessage = differentMicrophoneResumingSentence
            }
          } else {
            pendingDifferentDevice = nil
            if alreadyConfirmed {
              pendingPausedRestoreNotice = nil
              errorMessage = unavailableMicrophoneContinuingSentence
            } else {
              pendingPausedRestoreNotice = unavailableMicrophoneContinuingSentence
              errorMessage = unavailableMicrophoneResumingSentence
            }
          }
          await confirmRecordingIfReady(sessionId: sessionId, attempt: attempt)
          return
        }
      }
      try microphoneCapture?.start(
        onFirstSample: { [weak self] receipt in
          Task { @MainActor [weak self] in
            guard self?.activeSessionId == sessionId else { return }
            guard self?.activeAttempt == attempt else { return }
            await self?.acceptFirstSample(receipt, from: .microphone, attempt: attempt)
          }
        },
        onObservation: { [weak self] observation in
          Task { @MainActor [weak self] in
            guard self?.activeSessionId == sessionId else { return }
            guard self?.activeAttempt == attempt else { return }
            await self?.acceptMicrophoneObservation(observation)
          }
        },
        onFailure: { [weak self] error in
          Task { @MainActor [weak self] in
            guard self?.activeSessionId == sessionId else { return }
            guard self?.activeAttempt == attempt else { return }
            guard let self, await self.checkMicrophonePermission() else { return }
            await self.handleCaptureFailure(
              String(describing: error),
              code: "capture-\(String(describing: error))",
              source: .microphone,
              interruptionReason: .captureFailed
            )
          }
        }
      )
    } catch {
      guard activeAttempt == attempt, !restoreCancelled else {
        if restoreCancelled { cancelOpenMicrophoneRestore() }
        return
      }
      if microphoneRestoreSegmentOpen { cancelOpenMicrophoneRestore() }
      await fail(
        error.localizedDescription,
        code: Self.failureCode(for: error),
        interruptionReason: .captureStartFailed
      )
    }
  }

  func stop(pausing: Bool = false) async {
    let sessionToStop = activeSessionId
    if restoreTask != nil {
      restoreCancelled = true
      restoreSampleGate?.resume(false)
      _ = microphoneRestoreCapture?.stop()
    }
    while let sourceFailureTask {
      await sourceFailureTask.value
    }
    if let restoreTask {
      await restoreTask.value
      if self.restoreTask == restoreTask { self.restoreTask = nil }
    }
    restoreCancelled = false
    cancelOpenMicrophoneRestore()
    guard activeSessionId == sessionToStop else { return }
    guard canStop, let preparation else { return }
    storageWatchTask?.cancel()
    if phase == .paused, let activeSessionId {
      do {
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId, action: .finishPaused)
        resetActiveSession()
        phase = .saved
        startMixdown(preparation: preparation, sessionId: activeSessionId)
      } catch {
        errorMessage = "The paused recording could not be finalized. Its source audio is preserved."
      }
      return
    }
    if pausing {
      guard canPause, let activeSessionId else { return }
      do {
        _ = try preparation.recorderAction(sessionId: activeSessionId, action: .beginPause)
      } catch {
        errorMessage = "The pause could not be made durable."
        return
      }
    }
    phase = pausing ? .pausing : .stopping
    if let activeSessionId { proofCheckpoint(.stop, activeSessionId) }
    let continuingSources = Set(requiredSources).subtracting(failedSources)
    var finalSampleTimes: [NativeMediaSourceKind: UInt64] = [:]
    if continuingSources.contains(.microphone), let microphoneTime = microphoneCapture?.stop() {
      finalSampleTimes[.microphone] = microphoneTime
    }
    do {
      if let audioSource = requiredSources.first(where: { $0 != .microphone }),
        continuingSources.contains(audioSource),
        let systemTime = try await systemCapture?.stop()
      {
        finalSampleTimes[audioSource] = systemTime
      }
    } catch {
      await fail(
        "System audio could not be stopped safely. Recovery state was preserved.",
        code: "system-audio-stop",
        stopCapture: false,
        interruptionReason: .captureFailed
      )
      return
    }
    guard Set(finalSampleTimes.keys) == continuingSources else {
      let missingSources = continuingSources.subtracting(finalSampleTimes.keys)
      let message =
        missingSources == [.microphone]
        ? "No microphone sample was durably written. Recovery state was preserved."
        : "A required source produced no durable sample. Recovery state was preserved."
      await fail(
        message,
        code: "no-durable-sample",
        stopCapture: false,
        interruptionReason: .stopWithoutDurableSample
      )
      return
    }
    do {
      for source in requiredSources where continuingSources.contains(source) {
        guard let writer = writers[source], let finalSampleHostTime = finalSampleTimes[source]
        else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        let receipt = try writer.sealSegmentReceipt(finalSampleHostTime: finalSampleHostTime)
        proofCheckpoint(.seal, receipt.sessionId)
        let evidence = try preparation.sealSegment(receipt: receipt)
        guard evidence.segmentSealed, !evidence.recordingStarted else {
          throw LiveMicrophoneRecordingError.invalidSegmentSeal
        }
      }
      savedPaths = requiredSources.compactMap { writers[$0]?.authorization.absolutePath }
      savedPath = savedPaths.first
      if pausing, let activeSessionId {
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId, action: .completePause(hostTime: hostTime()))
        microphoneCapture = nil
        systemCapture = nil
        activeAttempt = nil
        phase = .paused
        return
      }
      if segmentedCapture, let activeSessionId,
        try preparation.recorderDetail(sessionId: activeSessionId).lifecycle != "ready_for_review"
      {
        // Rust has not finalized (for example a reserved successor is still
        // open). Do not claim Saved; interrupt so recovery owns the outcome.
        throw LiveMicrophoneRecordingError.invalidSegmentSeal
      }
      let sessionId = activeSessionId
      resetActiveSession()
      phase = .saved
      if let sessionId { startMixdown(preparation: preparation, sessionId: sessionId) }
    } catch {
      await fail(
        error.localizedDescription,
        code: "segment-seal",
        interruptionReason: .segmentSealFailed
      )
    }
  }

  private func acceptFirstSample(
    _ receipt: NativeFirstSampleReceipt,
    from source: NativeMediaSourceKind,
    attempt: UUID
  ) async {
    guard phase == .starting else { return }
    guard await checkMicrophonePermission() else { return }
    guard requiredSources.contains(source), let preparation else { return }
    let evidence: NativeFirstSampleEvidence
    if let accepted = writers[source]?.acceptedFirstSampleEvidence(segmentId: receipt.segmentId) {
      // A segmented writer accepted this receipt on its queue before reporting
      // it. The segment may have rotated since; the durable evidence stands.
      evidence = accepted
    } else {
      do {
        evidence = try preparation.acceptFirstSample(receipt: receipt)
      } catch {
        await handleCaptureFailure(
          error.localizedDescription,
          code: "first-sample-evidence",
          interruptionReason: .firstSampleRejected
        )
        return
      }
    }
    guard
      evidence.journalDurable, evidence.mediaFilesOpen, evidence.firstSampleDurable,
      !evidence.recordingStarted
    else {
      await handleCaptureFailure(
        LiveMicrophoneRecordingError.invalidFirstSample.localizedDescription,
        code: "first-sample-evidence",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    sourcesWithFirstSample.insert(source)
    if source == .microphone { microphoneRestoreSegmentOpen = false }
    await confirmRecordingIfReady(sessionId: receipt.sessionId, attempt: attempt)
  }

  /// Enters Recording only when this attempt's active sources all have durable
  /// first samples. A device comparison never assigns `.capturing` by itself.
  private func confirmRecordingIfReady(sessionId: String, attempt: UUID) async {
    guard phase == .starting else { return }
    guard activeSessionId == sessionId, activeAttempt == attempt, let preparation else { return }
    let spanSources = Set(requiredSources).subtracting(failedSources)
    guard !spanSources.isEmpty, sourcesWithFirstSample == spanSources else { return }
    let recording: NativeRecordingStartedEvidence
    do {
      recording = try preparation.confirmRecording(sessionId: sessionId)
    } catch {
      pendingPausedRestoreNotice = nil
      await handleCaptureFailure(
        error.localizedDescription,
        code: "recording-authority",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    guard recording.journalDurable, recording.mediaFilesOpen, recording.recordingStarted,
      Set(recording.requiredSources) == spanSources,
      Set(recording.activeSources) == spanSources
    else {
      pendingPausedRestoreNotice = nil
      await handleCaptureFailure(
        LiveMicrophoneRecordingError.invalidRecordingAuthority.localizedDescription,
        code: "recording-authority",
        interruptionReason: .firstSampleRejected
      )
      return
    }
    phase = .capturing
    if let pendingPausedRestoreNotice {
      errorMessage = pendingPausedRestoreNotice
      self.pendingPausedRestoreNotice = nil
    }
    proofCheckpoint(.recording, sessionId)
    if segmentedCapture { beginStorageWatch() }
  }

  private func acceptMicrophoneObservation(
    _ observation: MicrophoneSourceHealthObservation
  ) async {
    guard phase == .starting || phase == .capturing,
      let activeSessionId,
      writers[.microphone] != nil,
      let boundIdentity = microphoneCaptureIdentity
    else { return }
    guard observation.identity.sessionId == activeSessionId,
      observation.identity == boundIdentity,
      observation.sequence > acceptedMicrophoneObservationSequence
    else { return }
    guard !failedSources.contains(.microphone) || microphoneRestoreSegmentOpen else { return }
    acceptedMicrophoneObservationSequence = observation.sequence
    microphoneSourceHealth = observation
    let rustSourceState: String
    if failedSources.contains(.microphone) {
      rustSourceState = "failed"
    } else if phase == .capturing {
      rustSourceState = "active"
    } else {
      rustSourceState = "preparing"
    }
    captureHealthTelemetry(
      CaptureSourceHealthTelemetryRecord(
        observation: observation,
        rustSourceState: rustSourceState,
        visibleState: phase.rawValue
      )
    )
    guard await checkMicrophonePermission() else { return }
    if observation.event == .routeInterrupted {
      await handleCaptureFailure(
        "The microphone audio route stopped.",
        code: "capture-route-interrupted",
        source: .microphone,
        interruptionReason: .captureFailed
      )
    }
  }

  private func handleCaptureFailure(
    _ message: String,
    code: String,
    source: NativeMediaSourceKind? = nil,
    interruptionReason: NativeSessionInterruptionReason
  ) async {
    let failedSessionId = activeSessionId
    let failedAttempt = activeAttempt
    while let sourceFailureTask {
      await sourceFailureTask.value
    }
    guard activeSessionId == failedSessionId, activeAttempt == failedAttempt,
      phase == .starting || phase == .capturing
    else {
      return
    }
    if source == .microphone, microphoneRestoreSegmentOpen {
      let withdrawn = interruptionReason == .permissionRevoked
      restorePermissionWithdrawn = withdrawn
      cancelOpenMicrophoneRestore()
      restoreSampleGate?.resume(false)
      // Starting has not confirmed the surviving source. Describe resume until
      // Rust does, including when its sample is still pending. Capturing keeps
      // the live sentence; confirm then no-ops on this phase.
      if phase == .starting {
        pendingPausedRestoreNotice =
          withdrawn
          ? microphonePermissionWithdrawnContinuingSentence
          : microphoneCouldNotBeRestoredContinuingSentence
        errorMessage =
          withdrawn
          ? microphonePermissionWithdrawnResumingSentence
          : microphoneCouldNotBeRestoredResumingSentence
      } else {
        errorMessage =
          withdrawn ? microphonePermissionWithdrawnSentence : microphoneCouldNotBeRestoredSentence
      }
      if let failedSessionId, let failedAttempt {
        await confirmRecordingIfReady(sessionId: failedSessionId, attempt: failedAttempt)
      }
      return
    }
    if segmentedCapture, source == .microphone,
      !sourcesWithFirstSample.contains(.microphone),
      requiredSources.contains(where: { $0 != .microphone && sourcesWithFirstSample.contains($0) })
    {
      if await retireUnstartedMicrophone() { return }
    }
    if segmentedCapture, let preparation, let activeSessionId,
      let path = writers.values.first?.authorization.absolutePath
    {
      do {
        // A writer can encounter ENOSPC before the timer runs. This fresh
        // observation lets Rust release its emergency journal space first.
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId, action: .observeStorage(availableBytes: availableBytes(path)))
        if recorderDetail?.storageLevel == "critical" {
          await stop()
          errorMessage =
            "Recording stopped because storage reached its reserve. Existing audio was preserved."
          return
        }
      } catch {
        await fail(
          "Storage availability could not be checked. Recording was stopped to preserve audio.",
          code: "storage-observation-failed", interruptionReason: interruptionReason)
        return
      }
    }
    if let source {
      guard writers[source] != nil else { return }
      guard !failedSources.contains(source) else {
        return
      }
      if phase == .capturing, Set(requiredSources).subtracting(failedSources).count > 1 {
        let task = Task { @MainActor in
          await self.degradeCaptureAfterSourceFailure(
            source: source, message: message, code: code,
            reason: interruptionReason == .permissionRevoked ? .permissionRevoked : .captureFailed)
          self.sourceFailureTask = nil
        }
        sourceFailureTask = task
        await task.value
        return
      }
    }
    let preserveMicrophoneOnly =
      source == .microphone
      && sourcesWithFirstSample.contains(.microphone)
      && !requiredSources.contains { $0 != .microphone && !failedSources.contains($0) }
    await fail(message, code: code, interruptionReason: interruptionReason)
    if preserveMicrophoneOnly {
      errorMessage = "The microphone stopped and the recording was preserved."
    }
  }

  private func degradeCaptureAfterSourceFailure(
    source: NativeMediaSourceKind,
    message: String,
    code: String,
    reason: NativeSourceFailureReason
  ) async {
    let interruptionReason: NativeSessionInterruptionReason =
      reason == .permissionRevoked ? .permissionRevoked : .captureFailed
    guard let preparation, let activeSessionId, let writer = writers[source] else {
      await fail(message, code: code, interruptionReason: interruptionReason)
      return
    }
    var sourceWasSealed = false
    do {
      let finalSampleHostTime: UInt64?
      switch source {
      case .microphone:
        finalSampleHostTime = microphoneCapture?.stop()
        microphoneCapture = nil
      case .systemAudio, .applicationAudio:
        finalSampleHostTime = try await systemCapture?.stop()
        systemCapture = nil
      }
      let segmentId = writer.authorization.segmentId
      if segmentedCapture, writer.acceptedFirstSampleEvidence(segmentId: segmentId) == nil {
        // A rotation sealed the predecessor, then the successor failed before
        // its first sample and never became a real segment. Rust abandons it,
        // leaving the source on its sealed media as a seal would.
        try preparation.abandonReservedSegment(sessionId: activeSessionId, segmentId: segmentId)
      } else {
        guard let finalSampleHostTime else {
          throw LiveMicrophoneRecordingError.missingFailedSourceSample
        }
        let sealReceipt = try writer.sealSegmentReceipt(finalSampleHostTime: finalSampleHostTime)
        let sealed = try preparation.sealSegment(receipt: sealReceipt)
        guard sealed.segmentSealed, !sealed.recordingStarted else {
          throw LiveMicrophoneRecordingError.invalidSegmentSeal
        }
      }
      sourceWasSealed = true
      let failure = try preparation.recordSourceFailure(
        sessionId: activeSessionId,
        sourceKind: source,
        reason: reason
      )
      guard failure.journalDurable, failure.sourceFailed, failure.sessionDegraded,
        !failure.sessionInterrupted, failure.recordingContinues
      else {
        throw LiveMicrophoneRecordingError.invalidSourceFailure
      }
      failedSources.insert(source)
      if source == .microphone {
        // Drop progress that would still claim the mic is fine after retirement.
        // Keep degrade events (routeInterrupted / writerFailed) as durable health.
        if microphoneSourceHealth?.event == .progress {
          microphoneSourceHealth = nil
        }
        microphoneCaptureIdentity = nil
      }
      if segmentedCapture {
        recorderDetail = try preparation.recorderDetail(sessionId: activeSessionId)
      }
      if source == .microphone {
        errorMessage =
          reason == .permissionRevoked
          ? microphonePermissionWithdrawnSentence
          : capturingMicrophoneSentence
      } else {
        errorMessage =
          reason == .permissionRevoked
          ? "\(Self.displayName(for: source)) permission was withdrawn. Remaining audio is still recording."
          : "\(Self.displayName(for: source)) stopped. Remaining audio is still recording. \(message)"
      }
      failureCode = code
      phase = .capturing
    } catch {
      let failureContext =
        sourceWasSealed
        ? "The failed source was sealed, but continued recording could not be confirmed."
        : "The failed source could not be sealed safely."
      await fail(
        "\(failureContext) \(error.localizedDescription)",
        code: code,
        interruptionReason: interruptionReason
      )
      if source == .microphone, !sourceWasSealed {
        errorMessage = "The microphone could not be sealed safely. Existing audio was preserved."
      }
    }
  }

  private func fail(
    _ message: String,
    code: String,
    stopCapture: Bool = true,
    interruptionReason: NativeSessionInterruptionReason? = nil
  ) async {
    phase = .stopping
    if stopCapture {
      _ = microphoneCapture?.stop()
      _ = try? await systemCapture?.stop()
    }
    var operatorMessage = message
    var interruptionConfirmed = interruptionReason == nil || activeSessionId == nil
    if let interruptionReason, let preparation, let activeSessionId {
      do {
        let evidence = try preparation.interruptSession(
          sessionId: activeSessionId,
          reason: interruptionReason
        )
        interruptionConfirmed =
          evidence.journalDurable && evidence.sessionInterrupted && !evidence.recordingStarted
        if !interruptionConfirmed {
          operatorMessage += " Recovery state could not be confirmed."
        }
      } catch {
        operatorMessage += " Recovery state could not be confirmed."
      }
    }
    if interruptionConfirmed {
      resetActiveSession()
    }
    errorMessage = operatorMessage
    failureCode = code
    phase = .failed
  }

  nonisolated private static func failureCode(for error: Error) -> String {
    if let recordingError = error as? LiveMicrophoneRecordingError {
      return recordingError.failureCode
    }
    if let captureError = error as? MicrophoneCaptureAdapterError {
      return "capture-\(String(describing: captureError))"
    }
    return "capture-start-or-setup"
  }

  nonisolated private static func sessionTitle() -> String {
    "Conversation \(ISO8601DateFormatter().string(from: Date()))"
  }

  nonisolated private static func displayName(for source: NativeMediaSourceKind) -> String {
    switch source {
    case .microphone: "Mac microphone"
    case .applicationAudio: "Selected application audio"
    case .systemAudio: "Mac system audio"
    }
  }

  private func rememberSession(_ id: String?) {
    activeSessionId = id
    if let id { diagnosticSessionId = id }
  }

  private func notePhaseChange(from previous: LiveMicrophoneRecordingPhase) {
    guard phase != previous else { return }
    if phase != .starting && phase != .capturing {
      permissionWatchTask?.cancel()
      permissionWatchTask = nil
    }
    let session = DiagnosticPrivacy.token(activeSessionId ?? diagnosticSessionId ?? "none")
    var detail = "from=\(previous.rawValue) to=\(phase.rawValue) session=\(session)"
    if phase == .failed {
      let code = DiagnosticPrivacy.token(failureCode ?? "none")
      detail += " code=\(code)"
    }
    AppTelemetry.captureProof(stage: "phase", detail: detail)
    publishRetirementIfNeeded()
  }

  private func resetActiveSession() {
    permissionWatchTask?.cancel()
    permissionWatchTask = nil
    storageWatchTask?.cancel()
    storageWatchTask = nil
    if let applicationExitObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(applicationExitObserver)
    }
    applicationExitObserver = nil
    preparation = nil
    writers = [:]
    microphoneCapture = nil
    systemCapture = nil
    sourcesWithFirstSample = []
    failedSources = []
    microphoneSourceHealth = nil
    microphoneCaptureIdentity = nil
    acceptedMicrophoneObservationSequence = 0
    activeSessionId = nil
    activeAttempt = nil
    selectedMicrophoneDevice = nil
    pendingDifferentDevice = nil
    sealedMicrophoneWriter = nil
    microphoneRestoreCapture = nil
    restoreSampleGate?.resume(false)
    restoreSampleGate = nil
    restorePermissionTask?.cancel()
    restorePermissionTask = nil
    approvedPausedMicrophoneRestore = nil
    pendingPausedRestoreNotice = nil
    microphoneRestoreSegmentOpen = false
    restorePermissionWithdrawn = false
    restoreCancelled = false
  }

  private func startMixdown(
    preparation: NativeRecordingPreparationProtocol, sessionId: String
  ) {
    guard segmentedCapture else { return }
    guard let storagePath = savedPaths.first else {
      mixdownStatus = "Source tracks saved; stereo mix unavailable"
      return
    }
    lastSavedSessionId = sessionId
    mixdownStatus = "Source tracks saved; preparing stereo mix…"
    let proofCheckpoint = proofCheckpoint
    Task.detached(priority: .utility) { [weak self] in
      let verified: Bool
      do {
        _ = try ValidatedMixdownBuilder.buildIfNeeded(
          preparation: preparation, sessionId: sessionId,
          storagePath: storagePath,
          beforeEncoding: { proofCheckpoint(.processing, sessionId) })
        verified = true
      } catch {
        verified = false
      }
      await MainActor.run {
        AppTelemetry.captureProof(
          stage: "mixdown",
          detail:
            "\(verified ? "verified" : "unavailable") session=\(DiagnosticPrivacy.token(sessionId))"
        )
        guard let self, self.lastSavedSessionId == sessionId, self.phase == .saved else { return }
        self.mixdownStatus =
          verified
          ? "Recording saved with verified stereo mix"
          : "Source tracks saved; stereo mix unavailable"
      }
    }
  }

  func selectCaptureSource(_ selection: RecorderCaptureSelection) {
    guard canStart || canResume else { return }
    guard selection.kind != nil || !isMicrophoneRetired else {
      errorMessage =
        "The microphone stopped earlier in this recording, so Microphone only has nothing to record. The previous selection is retained."
      return
    }
    do {
      if let preparation, let activeSessionId {
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId,
          action: .selectAudio(
            kind: selection.kind, identity: selection.identity, displayName: selection.name))
        writers = writers.filter { $0.key == .microphone }
      }
      captureSelection = selection
      requiredSources = [.microphone] + (selection.kind.map { [$0] } ?? [])
      // A new scope is a new plan for the next span; only a retired microphone stays retired.
      failedSources = failedSources.intersection([.microphone])
      errorMessage = nil
      publishRetirementIfNeeded()
    } catch {
      errorMessage =
        "The source change could not be made durable. The previous selection is retained."
    }
  }

  func addMarker(label: String = "") {
    guard canMark, let preparation, let activeSessionId else { return }
    do {
      recorderDetail = try preparation.recorderAction(
        sessionId: activeSessionId,
        action: .marker(hostTime: mach_absolute_time(), label: label))
    } catch { errorMessage = "The marker could not be saved." }
  }

  /// PRD 11.6: sleep is logged and stops capture through the sealed-pause
  /// path, so recorded audio is kept. Wake is logged and never resumes.
  func systemWillSleep() async {
    guard let preparation, let activeSessionId else { return }
    if let detail = try? preparation.recorderAction(
      sessionId: activeSessionId,
      action: .observeSystemPower(hostTime: hostTime(), asleep: true))
    {
      recorderDetail = detail
    }
    guard canPause else { return }
    await stop(pausing: true)
    if phase == .paused {
      errorMessage =
        "Recording paused because the Mac went to sleep. Audio recorded so far is saved; resume when ready."
    }
  }

  func systemDidWake() {
    guard let preparation, let activeSessionId else { return }
    if let detail = try? preparation.recorderAction(
      sessionId: activeSessionId,
      action: .observeSystemPower(hostTime: hostTime(), asleep: false))
    {
      recorderDetail = detail
    }
  }

  private func observeSystemPower() {
    let center = NSWorkspace.shared.notificationCenter
    systemPowerObservers = [
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor [weak self] in await self?.systemWillSleep() }
      },
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor [weak self] in self?.systemDidWake() }
      },
    ]
  }

  func detail(sessionId: String) throws -> NativeRecorderDetail {
    let authority = try preparation ?? preparationFactory()
    return try authority.recorderDetail(sessionId: sessionId)
  }

  private func beginStorageWatch() {
    storageWatchTask?.cancel()
    storageWatchTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard let self, self.phase == .capturing else { return }
        await self.checkStorage()
      }
    }
    if let applicationExitObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(applicationExitObserver)
    }
    applicationExitObserver = nil
    if let processId = captureSelection.processId {
      let attempt = activeAttempt
      applicationExitObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          application.processIdentifier == processId
        else { return }
        Task { @MainActor [weak self] in
          guard let self, self.activeAttempt == attempt else { return }
          await self.selectedApplicationExited(processId: application.processIdentifier)
        }
      }
    }
  }

  /// TCC can change without a route or engine callback. Observe it off the
  /// audio hot path while this attempt is starting or recording. Cancellation
  /// and identity checks prevent an old observer from reaching a later span.
  private func beginPermissionWatch() {
    permissionWatchTask?.cancel()
    guard let sessionId = activeSessionId, let attempt = activeAttempt,
      !failedSources.contains(.microphone)
    else { return }
    permissionWatchTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard !Task.isCancelled, let self, self.activeSessionId == sessionId,
          self.activeAttempt == attempt, !self.failedSources.contains(.microphone),
          await self.checkMicrophonePermission()
        else { return }
      }
    }
  }

  /// Native permission is an observation, never capture authority. Existing
  /// Rust admission decides interruption or degraded continuation; restoring
  /// access cannot resurrect a retired source or start a new attempt.
  private func checkMicrophonePermission() async -> Bool {
    guard phase == .starting || phase == .capturing else { return false }
    guard !failedSources.contains(.microphone) || microphoneRestoreSegmentOpen else { return true }
    guard permission.currentState == .authorized else {
      await handleCaptureFailure(
        "Microphone permission was withdrawn. Audio recorded so far is preserved.",
        code: "permission-revoked", source: .microphone,
        interruptionReason: .permissionRevoked)
      return false
    }
    return true
  }

  /// Both the timer and the injected process proof use the same storage probe
  /// and Rust policy. Unknown capacity is never treated as unlimited space.
  func checkStorage() async {
    guard phase == .capturing, let preparation, let sessionId = activeSessionId,
      let path = writers.values.first?.authorization.absolutePath
    else { return }
    do {
      recorderDetail = try preparation.recorderAction(
        sessionId: sessionId,
        action: .observeStorage(availableBytes: availableBytes(path)))
      if recorderDetail?.storageLevel == "critical" {
        await stop()
        errorMessage = "Recording stopped at the storage reserve. Existing audio is preserved."
      }
    } catch {
      await stop()
      errorMessage =
        "Storage availability could not be checked. Recording was stopped to preserve audio."
    }
  }

  /// A stale or unrelated application exit cannot change this recording.
  func selectedApplicationExited(processId: pid_t) async {
    guard captureSelection.kind == .applicationAudio,
      captureSelection.processId == processId
    else { return }
    await handleCaptureFailure(
      "The selected application exited.", code: "application-exited",
      source: .applicationAudio, interruptionReason: .captureFailed)
  }

  func reconnectMicrophone() {
    beginMicrophoneRestore(approvedDevice: selectedMicrophoneDevice)
  }

  func confirmDifferentMicrophone() {
    guard showsUseThisMicrophone, restoreTask == nil, let pending = pendingDifferentDevice else {
      return
    }
    selectedMicrophoneDevice = pending
    pendingDifferentDevice = nil
    beginMicrophoneRestore(approvedDevice: pending)
  }

  func dismissDifferentMicrophone() {
    pendingDifferentDevice = nil
    errorMessage = nil
    publishRetirementIfNeeded()
  }

  private func beginMicrophoneRestore(approvedDevice: MicrophoneDeviceIdentity?) {
    guard showsReconnect, restoreTask == nil else { return }
    let generation = UUID()
    restoreGeneration = generation
    restoreCancelled = false
    restorePermissionWithdrawn = false
    restoreTask = Task { @MainActor in
      await self.performMicrophoneRestore(
        generation: generation, approvedDevice: approvedDevice)
      if self.restoreGeneration == generation {
        self.restoreTask = nil
      }
    }
  }

  /// Permission, device, and free space are decided before any restore journal.
  /// A paused recording reuses resume. A live recording does not restart the
  /// other source. This task never calls `stop()`.
  private func performMicrophoneRestore(
    generation: UUID, approvedDevice: MicrophoneDeviceIdentity?
  ) async {
    guard showsReconnect, let preparation, let sessionId = activeSessionId else { return }
    var permissionState = permission.currentState
    if permissionState == .notDetermined {
      permissionState = await permission.request()
      guard restoreGeneration == generation, !restoreCancelled, showsReconnect else {
        return
      }
    }
    if permissionState == .notDetermined {
      errorMessage = "Microphone access is needed before the microphone can rejoin."
      return
    }
    if permissionState == .denied || permissionState == .restricted {
      errorMessage = microphoneAccessOffSentence
      return
    }
    guard permissionState == .authorized else {
      errorMessage = "Microphone access is needed before the microphone can rejoin."
      return
    }
    let currentDevice = microphoneDeviceProbe()
    guard let currentDevice else {
      errorMessage = unavailableMicrophoneSentence
      return
    }
    // Approval belongs to the device offered to the user, even if the default
    // input changes before this task runs or while permission is being granted.
    if let approvedDevice, approvedDevice.uniqueID != currentDevice.uniqueID {
      pendingDifferentDevice = currentDevice
      errorMessage = differentMicrophoneSentence
      return
    }
    selectedMicrophoneDevice = currentDevice
    if !microphoneRestoreHasReserve() {
      errorMessage = microphoneRestoreReserveSentence
      return
    }
    guard restoreGeneration == generation, !restoreCancelled, showsReconnect else { return }
    do {
      recorderDetail = try preparation.recorderAction(
        sessionId: sessionId, action: .restoreMicrophone)
    } catch {
      errorMessage = microphoneCouldNotBeRestoredSentence
      return
    }
    guard restoreGeneration == generation, !restoreCancelled else {
      cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
      return
    }
    if phase == .paused {
      guard canResume else {
        cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
        errorMessage = microphoneCouldNotBeRestoredSentence
        return
      }
      approvedPausedMicrophoneRestore = currentDevice
      await start(resuming: true)
      return
    }
    await performLiveMicrophoneRestore(
      generation: generation, preparation: preparation, sessionId: sessionId)
  }

  private func microphoneRestoreHasReserve() -> Bool {
    guard
      let path = (writers.first { $0.key != .microphone }?.value ?? writers.values.first)?
        .authorization.absolutePath
    else { return false }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard let bytes = try? availableBytes(directory) else { return false }
    return bytes >= Self.microphoneRestoreReserveBytes
  }

  private func performLiveMicrophoneRestore(
    generation: UUID,
    preparation: NativeRecordingPreparationProtocol,
    sessionId: String
  ) async {
    let gate = RestoreSampleGate()
    restoreSampleGate = gate
    do {
      let authorization = try preparation.authorizeInitialMedia(
        sessionId: sessionId, sourceKind: .microphone,
        sourceDisplayName: Self.displayName(for: .microphone))
      let writer = try writerFactory(authorization)
      let mediaOpen = try preparation.acceptMediaOpen(receipt: writer.receipt())
      guard mediaOpen.journalDurable, !mediaOpen.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidMediaOpen
      }
      sealedMicrophoneWriter = writers[.microphone]
      if segmentedCapture {
        guard let nativeWriter = writer as? ManagedCAFWriter else {
          throw LiveMicrophoneRecordingError.invalidMediaOpen
        }
        writers[.microphone] = SegmentedCAFWriter(
          current: nativeWriter, preparation: preparation,
          makeSuccessor: segmentedSuccessorWriterFactory)
      } else {
        writers[.microphone] = writer
      }
      microphoneRestoreSegmentOpen = true
      let identity = MicrophoneCaptureIdentity(authorization: writer.authorization)
      microphoneCaptureIdentity = identity
      acceptedMicrophoneObservationSequence = 0
      microphoneSourceHealth = nil
      let capture = captureFactory(writers[.microphone] ?? writer)
      microphoneRestoreCapture = capture
      try capture.start(
        onFirstSample: { [weak self] receipt in
          Task { @MainActor in
            self?.acceptRestoredMicrophoneSample(receipt, generation: generation)
          }
        },
        onObservation: { [weak self] observation in
          Task { @MainActor in
            guard let self, self.restoreGeneration == generation,
              self.activeSessionId == sessionId, self.microphoneCaptureIdentity == identity
            else { return }
            await self.acceptMicrophoneObservation(observation)
          }
        },
        onFailure: { [weak self] error in
          Task { @MainActor in
            guard let self, self.restoreGeneration == generation,
              self.activeSessionId == sessionId, self.microphoneCaptureIdentity == identity
            else { return }
            let withdrawn = self.permission.currentState != .authorized
            await self.handleCaptureFailure(
              String(describing: error), code: "capture-\(String(describing: error))",
              source: .microphone,
              interruptionReason: withdrawn ? .permissionRevoked : .captureFailed)
          }
        }
      )
      restorePermissionTask = Task { @MainActor in
        while !Task.isCancelled {
          guard self.restoreGeneration == generation, self.microphoneRestoreSegmentOpen else {
            return
          }
          if self.permission.currentState != .authorized {
            self.restorePermissionWithdrawn = true
            self.restoreSampleGate?.resume(false)
            return
          }
          try? await Task.sleep(for: .seconds(2))
        }
      }
      let accepted = await gate.wait()
      restorePermissionTask?.cancel()
      restorePermissionTask = nil
      guard restoreGeneration == generation, activeSessionId == sessionId, !restoreCancelled else {
        return
      }
      if accepted, !failedSources.contains(.microphone) { return }
      finishRejectedMicrophoneRestore(sessionId: sessionId, preparation: preparation)
    } catch {
      restorePermissionTask?.cancel()
      restorePermissionTask = nil
      finishRejectedMicrophoneRestore(sessionId: sessionId, preparation: preparation)
    }
  }

  private func acceptRestoredMicrophoneSample(
    _ receipt: NativeFirstSampleReceipt, generation: UUID
  ) {
    // An older adapter cannot resolve the current attempt's sample gate.
    guard restoreGeneration == generation else { return }
    guard !restoreCancelled, microphoneRestoreSegmentOpen,
      let preparation
    else {
      restoreSampleGate?.resume(false)
      return
    }
    do {
      let evidence: NativeFirstSampleEvidence
      if let accepted = writers[.microphone]?.acceptedFirstSampleEvidence(
        segmentId: receipt.segmentId)
      {
        evidence = accepted
      } else {
        evidence = try preparation.acceptFirstSample(receipt: receipt)
      }
      guard evidence.journalDurable, evidence.firstSampleDurable else {
        throw LiveMicrophoneRecordingError.invalidFirstSample
      }
      microphoneRestoreSegmentOpen = false
      failedSources.remove(.microphone)
      sourcesWithFirstSample.insert(.microphone)
      if let capture = microphoneRestoreCapture {
        microphoneCapture = capture
      }
      microphoneRestoreCapture = nil
      pendingDifferentDevice = nil
      errorMessage = nil
      if let activeSessionId {
        _ = try? preparation.confirmRecording(sessionId: activeSessionId)
      }
      beginPermissionWatch()
      restoreSampleGate?.resume(true)
    } catch {
      restoreSampleGate?.resume(false)
    }
  }

  private func finishRejectedMicrophoneRestore(
    sessionId: String, preparation: NativeRecordingPreparationProtocol
  ) {
    if microphoneRestoreSegmentOpen {
      cancelOpenMicrophoneRestore()
    } else {
      cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
    }
    guard !restoreCancelled else { return }
    errorMessage =
      restorePermissionWithdrawn
      ? microphonePermissionWithdrawnSentence
      : microphoneCouldNotBeRestoredSentence
  }

  private func openRestoredMicrophone(
    preparation: NativeRecordingPreparationProtocol,
    sessionId: String,
    previousWriters: [NativeMediaSourceKind: ManagedSegmentWriting]
  ) {
    do {
      let authorization = try preparation.authorizeInitialMedia(
        sessionId: sessionId, sourceKind: .microphone,
        sourceDisplayName: Self.displayName(for: .microphone))
      let writer = try writerFactory(authorization)
      let mediaOpen = try preparation.acceptMediaOpen(receipt: writer.receipt())
      guard mediaOpen.journalDurable, !mediaOpen.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidMediaOpen
      }
      sealedMicrophoneWriter = writers[.microphone] ?? previousWriters[.microphone]
      if segmentedCapture {
        guard let nativeWriter = writer as? ManagedCAFWriter else {
          throw LiveMicrophoneRecordingError.invalidMediaOpen
        }
        writers[.microphone] = SegmentedCAFWriter(
          current: nativeWriter, preparation: preparation,
          makeSuccessor: segmentedSuccessorWriterFactory)
      } else {
        writers[.microphone] = writer
      }
      microphoneRestoreSegmentOpen = true
    } catch {
      cancelJournaledMicrophoneRestore(sessionId: sessionId, preparation: preparation)
      if let previous = previousWriters[.microphone] { writers[.microphone] = previous }
      failedSources.insert(.microphone)
      // Preparing has not confirmed the surviving source. Describe resume until
      // Rust does. Paused preflight and live capture keep their own sentences.
      if phase == .preparing || phase == .starting {
        pendingPausedRestoreNotice = microphoneCouldNotBeRestoredContinuingSentence
        errorMessage = microphoneCouldNotBeRestoredResumingSentence
      } else {
        errorMessage = microphoneCouldNotBeRestoredSentence
      }
    }
  }

  private func cancelJournaledMicrophoneRestore(
    sessionId: String, preparation: NativeRecordingPreparationProtocol
  ) {
    microphoneRestoreSegmentOpen = false
    microphoneRestoreCapture = nil
    sealedMicrophoneWriter = nil
    approvedPausedMicrophoneRestore = nil
    failedSources.insert(.microphone)
    if let detail = try? preparation.recorderAction(
      sessionId: sessionId, action: .cancelMicrophoneRestore)
    {
      recorderDetail = detail
    }
  }

  /// Drops a restore that never accepted a sample. Captured microphone audio
  /// stays sealed. Stop calls this before it seals the source that kept going.
  private func cancelOpenMicrophoneRestore() {
    guard microphoneRestoreSegmentOpen else { return }
    microphoneRestoreSegmentOpen = false
    approvedPausedMicrophoneRestore = nil
    _ = microphoneRestoreCapture?.stop()
    microphoneRestoreCapture = nil
    _ = microphoneCapture?.stop()
    microphoneCapture = nil
    if let sealedMicrophoneWriter {
      writers[.microphone] = sealedMicrophoneWriter
    }
    self.sealedMicrophoneWriter = nil
    failedSources.insert(.microphone)
    microphoneCaptureIdentity = nil
    guard let preparation, let activeSessionId else { return }
    if let detail = try? preparation.recorderAction(
      sessionId: activeSessionId, action: .cancelMicrophoneRestore)
    {
      recorderDetail = detail
    }
  }

  private func retireUnstartedMicrophone() async -> Bool {
    guard let preparation, let activeSessionId else { return false }
    do {
      _ = microphoneCapture?.stop()
      microphoneCapture = nil
      recorderDetail = try preparation.recorderAction(
        sessionId: activeSessionId, action: .retireUnstartedMicrophone)
      failedSources.insert(.microphone)
      microphoneCaptureIdentity = nil
      sourcesWithFirstSample.remove(.microphone)
      let recording = try preparation.confirmRecording(sessionId: activeSessionId)
      guard recording.journalDurable, recording.recordingStarted else {
        throw LiveMicrophoneRecordingError.invalidRecordingAuthority
      }
      errorMessage = capturingMicrophoneSentence
      phase = .capturing
      permissionWatchTask?.cancel()
      permissionWatchTask = nil
      if segmentedCapture { beginStorageWatch() }
      return true
    } catch {
      return false
    }
  }

  private func publishRetirementIfNeeded() {
    guard phase == .paused || phase == .capturing, isMicrophoneRetired, activeSessionId != nil
    else { return }
    let replacement = phase == .paused ? pausedMicrophoneSentence : capturingMicrophoneSentence
    if errorMessage == nil || errorMessage == pausedMicrophoneSentence
      || errorMessage == capturingMicrophoneSentence
    {
      errorMessage = replacement
    }
  }
}

@MainActor
private final class RestoreSampleGate {
  private var continuation: CheckedContinuation<Bool, Never>?
  private var result: Bool?

  func resume(_ value: Bool) {
    guard result == nil else { return }
    result = value
    let pending = continuation
    continuation = nil
    pending?.resume(returning: value)
  }

  func wait() async -> Bool {
    if let result { return result }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }
}

private enum LiveMicrophoneRecordingError: LocalizedError {
  case invalidPreparation
  case invalidMediaOpen
  case invalidFirstSample
  case invalidRecordingAuthority
  case invalidSegmentSeal
  case invalidSourcePlan
  case invalidSourceFailure
  case missingFailedSourceSample
  case managedRootUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidPreparation: "Rust did not confirm durable session preparation."
    case .invalidMediaOpen: "Rust did not confirm durable media-open evidence."
    case .invalidFirstSample: "Rust did not confirm the first microphone sample."
    case .invalidRecordingAuthority: "Rust did not confirm every required recording source."
    case .invalidSegmentSeal: "Rust did not confirm the closed microphone segment."
    case .invalidSourcePlan: "The required recording sources could not be initialized."
    case .invalidSourceFailure: "Rust did not confirm degraded source-failure evidence."
    case .missingFailedSourceSample: "The failed source had no final durable sample."
    case .managedRootUnavailable: "The managed recording directory is unavailable."
    }
  }

  var failureCode: String {
    switch self {
    case .invalidPreparation: "durable-preparation"
    case .invalidMediaOpen: "media-open-evidence"
    case .invalidFirstSample: "first-sample-evidence"
    case .invalidRecordingAuthority: "recording-authority"
    case .invalidSegmentSeal: "segment-seal"
    case .invalidSourcePlan: "required-source-plan"
    case .invalidSourceFailure: "source-failure-evidence"
    case .missingFailedSourceSample: "source-failure-sample"
    case .managedRootUnavailable: "managed-root"
    }
  }
}
