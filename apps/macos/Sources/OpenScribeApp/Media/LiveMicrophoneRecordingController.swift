@preconcurrency import AVFoundation
import AppKit
import Darwin
import Foundation

/// The recorder's state machine: start, pause, resume and stop a capture span,
/// accept first samples and source failures, and publish what views show.
/// Rust owns every durable step. `RecordingSpan` checks its media evidence,
/// `MicrophoneRestore.swift` brings a lost microphone back, `CaptureWatchers`
/// observes storage, permission, application exit and power, and
/// `RecorderNotice` holds the wording.
@MainActor
final class LiveMicrophoneRecordingController: NSObject, ObservableObject {
  @Published private(set) var phase: LiveMicrophoneRecordingPhase = .idle {
    didSet { notePhaseChange(from: oldValue) }
  }
  /// What the recorder last told the person recording. Set only by the
  /// recorder and its restore extension.
  @Published var notice: RecorderNotice?
  var errorMessage: String? { notice?.text }
  private(set) var failure: RecorderFailureCode?
  /// The last failure's log code, for proofs and tests.
  var failureCode: String? { failure?.rawValue }
  @Published private(set) var savedPath: String?
  @Published private(set) var savedPaths: [String] = []
  /// Set only by the recorder and its restore extension.
  @Published var microphoneSourceHealth: MicrophoneSourceHealthObservation?
  @Published private(set) var captureSelection: RecorderCaptureSelection = .system
  /// Set only by the recorder and its restore extension.
  @Published var recorderDetail: NativeRecorderDetail?
  @Published private(set) var mixdownStatus: String?
  @Published private(set) var lastSavedSessionId: String?
  /// The live transcript for the current recording; see `LiveCaptionModel`.
  let liveCaptions: LiveCaptionModel
  /// No recording or import may begin while launch recovery scans the library.
  var isLaunchRecoveryPending: @MainActor () -> Bool

  let environment: CaptureEnvironment
  let watchers = CaptureWatchers()

  // Span state. The restore extension reads and changes it on the main actor.
  var requiredSources: [NativeMediaSourceKind]
  var preparation: NativeRecordingPreparationProtocol?
  var writers: [NativeMediaSourceKind: ManagedSegmentWriting] = [:]
  var microphoneCapture: MicrophoneCapturing?
  private var systemCapture: SystemAudioCapturing?
  var sourcesWithFirstSample: Set<NativeMediaSourceKind> = []
  var failedSources: Set<NativeMediaSourceKind> = []
  private var sourceFailureTask: Task<Void, Never>?
  var activeSessionId: String?
  /// Kept after the active id is cleared so a Saved or Failed line still
  /// names the session. Titles and paths are never stored here.
  private var diagnosticSessionId: String?
  var activeAttempt: UUID?
  /// Identity the microphone adapter binds when capture starts. Segment
  /// generations advance on every rotation, so observations are matched
  /// against this snapshot, never against the current segment.
  var microphoneCaptureIdentity: MicrophoneCaptureIdentity?
  var acceptedMicrophoneObservationSequence: UInt64 = 0
  var selectedMicrophoneDevice: MicrophoneDeviceIdentity?
  var restore: MicrophoneRestoreState
  /// Shown only while a missing capture permission is about to be requested.
  private var permissionPreflight: String?

  init(environment: CaptureEnvironment) {
    self.environment = environment
    requiredSources = environment.requiredSources
    liveCaptions = environment.liveCaptions
    isLaunchRecoveryPending = environment.isLaunchRecoveryPending
    restore = MicrophoneRestoreState(
      monitor: MicrophoneRestoreMonitor(wait: environment.restoreTimeoutWait))
    super.init()
    watchers.observePower(
      sleep: { [weak self] in await self?.systemWillSleep() },
      wake: { [weak self] in self?.systemDidWake() })
  }

  convenience init(
    permission: MicrophonePermissionProviding,
    preparationFactory: @escaping CaptureEnvironment.PreparationFactory,
    writerFactory: @escaping CaptureEnvironment.WriterFactory,
    captureFactory: @escaping CaptureEnvironment.CaptureFactory,
    requiredSources: [NativeMediaSourceKind] = [.microphone],
    systemCaptureFactory: (
      @Sendable (ManagedSegmentWriting) async throws -> SystemAudioCapturing
    )? = nil,
    segmentedCapture: Bool = false,
    hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
    availableBytes: @escaping @Sendable (String) throws -> UInt64 = {
      try RecorderStorage.availableBytes(at: $0)
    },
    segmentedSuccessorWriterFactory:
      @escaping CaptureEnvironment.SuccessorWriterFactory = {
        try ManagedCAFWriter(authorization: $0)
      },
    observer: RecordingObserver? = nil,
    captureHealthTelemetry: @escaping CaptureEnvironment.CaptureHealthTelemetry = {
      AppTelemetry.captureSourceHealth($0)
    },
    microphoneDeviceProbe: @escaping @MainActor () -> MicrophoneDeviceIdentity? = { nil },
    restoreTimeoutWait: @escaping MicrophoneRestoreMonitor.Wait = {
      try await MicrophoneRestoreMonitor.waitForTimeout($0)
    },
    screenCaptureAuthorized: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
  ) {
    var selectionFactory: CaptureEnvironment.SystemCaptureFactory?
    if let systemCaptureFactory {
      selectionFactory = { writer, _ in try await systemCaptureFactory(writer) }
    }
    self.init(
      environment: CaptureEnvironment(
        permission: permission, preparationFactory: preparationFactory,
        writerFactory: writerFactory, captureFactory: captureFactory,
        requiredSources: requiredSources,
        systemCaptureFactory: selectionFactory,
        segmentedCapture: segmentedCapture, hostTime: hostTime, availableBytes: availableBytes,
        successorWriterFactory: segmentedSuccessorWriterFactory, observer: observer,
        captureHealthTelemetry: captureHealthTelemetry,
        microphoneDeviceProbe: microphoneDeviceProbe, restoreTimeoutWait: restoreTimeoutWait,
        screenCaptureAuthorized: screenCaptureAuthorized))
  }

  convenience init(managedRoot: URL?) {
    self.init(environment: .production(managedRoot: managedRoot))
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

  private var continuingSourceName: String {
    captureSelection.kind == .applicationAudio ? captureSelection.name : "System audio"
  }

  /// Live wording for a source that is recording. Stored for publication
  /// after Rust confirms `.capturing`; never replaced by the paused clause.
  var continuingRecording: RecorderNotice.Continuation {
    .recording(source: continuingSourceName)
  }

  /// Paused restore preflight has not resumed the other source. Capturing
  /// and the future notice keep the caller's live continuation.
  func restoreContinuation(
    _ live: RecorderNotice.Continuation
  ) -> RecorderNotice.Continuation {
    phase == .paused ? .paused : live
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

  var canPause: Bool { environment.segmentedCapture && phase == .capturing }
  var canResume: Bool { environment.segmentedCapture && phase == .paused }
  var canMark: Bool {
    environment.segmentedCapture && (phase == .capturing || phase == .paused)
  }

  /// The session journal's one writer and its open session, for context
  /// scope changes and proposals (ADR 0011). `nil` when no capture is open.
  var contextBinding: ContextBinding? {
    guard let preparation, let activeSessionId,
      [.starting, .capturing, .pausing, .paused].contains(phase)
    else { return nil }
    return ContextBinding(preparation: preparation, sessionId: activeSessionId)
  }

  var readinessText: String {
    CaptureStatusPresentation.readiness(
      recordedAudio: captureSelection.recordedAudio,
      launchRecoveryPending: isLaunchRecoveryPending())
  }

  /// Named before macOS asks, and only when microphone access is still undecided.
  static let microphonePermissionExplanation =
    "Microphone access is needed to record this conversation. macOS will ask before any microphone audio is captured."

  /// Named before macOS asks, and only when the selected computer-audio source needs it.
  static func screenRecordingPermissionExplanation(sourceName: String) -> String {
    "Screen Recording permission is needed to record \(sourceName). macOS will ask before that audio is captured."
  }

  var statusFacts: RecorderStatusFacts {
    RecorderStatusFacts(
      phase: phase, recordedAudio: captureSelection.recordedAudio,
      permissionPreflight: permissionPreflight, launchRecoveryPending: isLaunchRecoveryPending(),
      lostSource: !failedSources.isEmpty,
      checkingMicrophoneRoute: microphoneSourceHealth?.event == .routeInterrupted,
      savedNote: mixdownStatus)
  }

  var statusText: String { CaptureStatusPresentation.recorderText(statusFacts) }

  /// Warning is a notice, not a failure. Capture continues, and the reserve
  /// stop keeps its own message in `errorMessage`.
  var storagePressureNotice: String? {
    guard phase == .capturing, recorderDetail?.storageLevel == .warning else { return nil }
    return "Storage is low. Recording continues. Free space before the reserve stops capture."
  }

  func span(_ preparation: NativeRecordingPreparationProtocol) -> RecordingSpan {
    RecordingSpan(preparation: preparation, environment: environment)
  }

  func start(resuming: Bool = false) async {
    guard resuming ? canResume : canStart else { return }
    let approvedPausedRestore = resuming ? restore.approvedPausedDevice : nil
    restore.approvedPausedDevice = nil
    var restoringMicrophone = approvedPausedRestore != nil
    let previousWriters = resuming ? writers : [:]
    let previousSession = resuming ? activeSessionId : nil
    let previousSavedPaths = savedPaths
    let attempt = UUID()
    activeAttempt = attempt
    lastSavedSessionId = nil
    mixdownStatus = nil
    if !resuming { recorderDetail = nil }
    notice = nil
    restore.pendingNotice = nil
    failure = nil
    savedPath = nil
    savedPaths = []
    activeSessionId = nil
    if !resuming {
      diagnosticSessionId = nil
      selectedMicrophoneDevice = nil
      restore.pendingDifferentDevice = nil
      restore.sealedWriter = nil
      restore.segmentOpen = false
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
      let permission = environment.permission
      if permission.currentState == .notDetermined {
        permissionPreflight = Self.microphonePermissionExplanation
        phase = .requestingPermission
      }
      let permissionState = await permission.request()
      permissionPreflight = nil
      guard permissionState == .authorized else {
        if resuming {
          writers = previousWriters
          rememberSession(previousSession)
          savedPaths = previousSavedPaths
          savedPath = previousSavedPaths.first
          activeAttempt = nil
          phase = .paused
          notice = .resumeMicrophoneAccessUnavailable
          return
        }
        await fail(
          .microphoneAccess(permissionState),
          code: RecorderFailureCode(permission: permissionState))
        return
      }
      selectedMicrophoneDevice = environment.microphoneDeviceProbe()
    }

    phase = .preparing
    do {
      let preparation = try self.preparation ?? environment.preparationFactory()
      let sessionId: String
      if let previousSession {
        sessionId = previousSession
        do {
          if let path = previousWriters.values.first?.authorization.absolutePath {
            recorderDetail = try preparation.recorderAction(
              sessionId: sessionId,
              action: .observeStorage(availableBytes: environment.availableBytes(path)))
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
          notice =
            recorderDetail?.storageLevel == .critical
            ? .resumeNoSpace : .resumeFailed(.detail(error.localizedDescription))
          phase = .paused
          return
        }
      } else {
        let prepared = try preparation.prepareSessionWithRequiredSources(
          title: nil, requiredSources: requiredSources)
        guard prepared.journalDurable, !prepared.recordingStarted else {
          throw LiveMicrophoneRecordingError.invalidPreparation
        }
        sessionId = prepared.sessionId
        if environment.segmentedCapture {
          _ = try preparation.recorderAction(
            sessionId: sessionId,
            action: .selectAudio(
              kind: captureSelection.kind, identity: captureSelection.identity,
              displayName: captureSelection.name))
        }
      }
      self.preparation = preparation
      rememberSession(sessionId)
      environment.observer?.recording(reached: .preparation, sessionId: sessionId)
      // Retired sources keep their sealed writer for the saved-path list but
      // get no successor authorization and no capture in this span.
      for source in requiredSources where failedSources.contains(source) {
        if let previous = previousWriters[source] { writers[source] = previous }
      }
      if restoringMicrophone {
        openRestoredMicrophone(
          preparation: preparation, sessionId: sessionId, previousWriters: previousWriters)
      }
      let span = span(preparation)
      let spanSources = requiredSources.filter { !failedSources.contains($0) }
      for (index, source) in spanSources.enumerated() {
        let authorization = try span.authorize(
          source, sessionId: sessionId, after: previousWriters[source],
          displayName: source == .microphone
            ? Self.displayName(for: source) : captureSelection.name)
        if environment.segmentedCapture {
          let storage = try preparation.recorderAction(
            sessionId: sessionId,
            action: .observeStorage(
              availableBytes: environment.availableBytes(
                URL(fileURLWithPath: authorization.absolutePath).deletingLastPathComponent().path)))
          guard storage.storageLevel != .critical else {
            throw ManagedCAFWriterError.storagePressure
          }
          recorderDetail = storage
        }
        writers[source] = try span.openWriter(
          authorization, allMediaOpen: index == spanSources.count - 1)
      }

      if restore.segmentOpen {
        failedSources.remove(.microphone)
      }

      let microphoneCapture: MicrophoneCapturing?
      if failedSources.contains(.microphone) {
        microphoneCapture = nil
      } else {
        guard let microphoneWriter = writers[.microphone] else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        microphoneCapture = environment.captureFactory(microphoneWriter)
        microphoneCaptureIdentity = MicrophoneCaptureIdentity(
          authorization: microphoneWriter.authorization)
      }
      self.microphoneCapture = microphoneCapture

      let audioSource = spanSources.first { $0 != .microphone }
      if let audioSource {
        guard let systemWriter = writers[audioSource] else {
          throw LiveMicrophoneRecordingError.invalidSourcePlan
        }
        if !environment.screenCaptureAuthorized() {
          permissionPreflight = Self.screenRecordingPermissionExplanation(
            sourceName: captureSelection.name)
          phase = .requestingPermission
        }
        do {
          guard let systemCaptureFactory = environment.systemCaptureFactory else {
            throw LiveMicrophoneRecordingError.invalidSourcePlan
          }
          systemCapture = try await systemCaptureFactory(systemWriter, captureSelection)
        } catch {
          permissionPreflight = nil
          if restore.segmentOpen { cancelOpenMicrophoneRestore() }
          await fail(
            .systemAudioUnavailable(.detail(error.localizedDescription)),
            code: .systemAudioUnavailable,
            interruptionReason: .captureStartFailed
          )
          return
        }
      }

      if environment.segmentedCapture {
        if resuming {
          _ = try preparation.recorderAction(
            sessionId: sessionId, action: .anchorResume(hostTime: environment.hostTime()))
        } else {
          try SegmentedCAFWriter.anchor(
            preparation: preparation, sessionId: sessionId, hostAnchor: environment.hostTime())
        }
      }
      permissionPreflight = nil
      phase = .starting
      guard await checkMicrophonePermission() else { return }
      beginPermissionWatch()
      beginLiveCaptions(preparation: preparation, sessionId: sessionId, audioSource: audioSource)
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
                .detail(String(describing: error)),
                code: RecorderFailureCode(error),
                source: audioSource,
                interruptionReason: error == .permissionDenied ? .permissionRevoked : .captureFailed
              )
            }
          }
        )
        // Rust can confirm the surviving span before this await returns.
        // Keep that span. A stale or cancelled attempt still stops its source.
        guard activeAttempt == attempt, activeSessionId == sessionId, !restore.cancelled,
          phase == .starting || phase == .capturing
        else {
          _ = try? await systemCapture.stop()
          if restore.cancelled { cancelOpenMicrophoneRestore() }
          return
        }
        guard await checkMicrophonePermission() else { return }
      }
      if let approvedPausedRestore {
        guard
          await continueApprovedPausedRestore(
            approvedPausedRestore, sessionId: sessionId, attempt: attempt)
        else { return }
      }
      let microphoneIdentity = microphoneCaptureIdentity
      do {
        try microphoneCapture?.bindInput(to: approvedPausedRestore ?? selectedMicrophoneDevice)
        if restore.segmentOpen { beginRestoreDeadline(sessionId: sessionId) }
        try microphoneCapture?.start(
          onFirstSample: { [weak self] receipt in
            Task { @MainActor [weak self] in
              guard self?.activeSessionId == sessionId else { return }
              guard self?.activeAttempt == attempt else { return }
              guard self?.microphoneCaptureIdentity == microphoneIdentity else { return }
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
                .detail(String(describing: error)),
                code: RecorderFailureCode(error),
                source: .microphone,
                interruptionReason: .captureFailed,
                expectedMicrophoneIdentity: microphoneIdentity
              )
            }
          }
        )
      } catch {
        if restore.segmentOpen {
          await handleCaptureFailure(
            .approvedMicrophoneDidNotStart,
            code: .microphoneRestoreStart, source: .microphone,
            interruptionReason: .captureFailed, expectedMicrophoneIdentity: microphoneIdentity)
          return
        }
        throw error
      }
    } catch {
      guard activeAttempt == attempt, !restore.cancelled else {
        if restore.cancelled { cancelOpenMicrophoneRestore() }
        return
      }
      if restore.segmentOpen { cancelOpenMicrophoneRestore() }
      await fail(
        .detail(error.localizedDescription),
        code: Self.failureCode(for: error),
        interruptionReason: .captureStartFailed
      )
    }
  }

  /// Ends the span, sealing every source that is still recording. With
  /// `pausing`, Rust keeps the session open for a later resume.
  func stop(pausing: Bool = false) async {
    let sessionToStop = activeSessionId
    cancelRestoreForStop()
    while let sourceFailureTask {
      await sourceFailureTask.value
    }
    await settleRestoreForStop()
    guard activeSessionId == sessionToStop else { return }
    guard canStop, let preparation else { return }
    // Settle the live transcript while its tracks still accept Draft text.
    await liveCaptions.endSpan()
    // Settling suspends; another stop or a failure may have ended the span.
    guard activeSessionId == sessionToStop, canStop else { return }
    watchers.stopStorage()
    if phase == .paused, let activeSessionId {
      do {
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId, action: .finishPaused)
        resetActiveSession()
        phase = .saved
        startMixdown(preparation: preparation, sessionId: activeSessionId)
      } catch {
        notice = .pausedRecordingNotFinished
      }
      return
    }
    if pausing {
      guard canPause, let activeSessionId else { return }
      do {
        _ = try preparation.recorderAction(sessionId: activeSessionId, action: .beginPause)
      } catch {
        notice = .pauseNotSaved
        return
      }
    }
    phase = pausing ? .pausing : .stopping
    if let activeSessionId {
      environment.observer?.recording(reached: .stop, sessionId: activeSessionId)
    }
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
        .systemAudioNotStopped,
        code: .systemAudioStop,
        stopCapture: false,
        interruptionReason: .captureFailed
      )
      return
    }
    guard Set(finalSampleTimes.keys) == continuingSources else {
      let missingSources = continuingSources.subtracting(finalSampleTimes.keys)
      await fail(
        missingSources == [.microphone] ? .noMicrophoneSample : .noSourceSample,
        code: .noDurableSample,
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
        try span(preparation).seal(
          writer, finalSampleHostTime: finalSampleHostTime, reportsBoundary: true)
      }
      savedPaths = requiredSources.compactMap { writers[$0]?.authorization.absolutePath }
      savedPath = savedPaths.first
      if pausing, let activeSessionId {
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId, action: .completePause(hostTime: environment.hostTime()))
        microphoneCapture = nil
        systemCapture = nil
        activeAttempt = nil
        phase = .paused
        return
      }
      if environment.segmentedCapture, let activeSessionId,
        try preparation.recorderDetail(sessionId: activeSessionId).lifecycle != .readyForReview
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
        .detail(error.localizedDescription),
        code: .segmentSeal,
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
          .detail(error.localizedDescription),
          code: .firstSampleEvidence,
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
        .detail(LiveMicrophoneRecordingError.invalidFirstSample.localizedDescription),
        code: .firstSampleEvidence,
        interruptionReason: .firstSampleRejected
      )
      return
    }
    liveCaptions.anchor(
      trackId: receipt.trackId, hostTime: receipt.firstSampleHostTime,
      sessionNanoseconds: evidence.firstSampleSessionNanoseconds)
    sourcesWithFirstSample.insert(source)
    if source == .microphone {
      restore.segmentOpen = false
      restore.monitor.cancel()
    }
    await confirmRecordingIfReady(sessionId: receipt.sessionId, attempt: attempt)
  }

  /// Enters Recording only when this attempt's active sources all have durable
  /// first samples. A device comparison never assigns `.capturing` by itself.
  func confirmRecordingIfReady(sessionId: String, attempt: UUID) async {
    guard phase == .starting else { return }
    guard activeSessionId == sessionId, activeAttempt == attempt, let preparation else { return }
    let spanSources = Set(requiredSources).subtracting(failedSources)
    guard !spanSources.isEmpty, sourcesWithFirstSample == spanSources else { return }
    let recording: NativeRecordingStartedEvidence
    do {
      recording = try preparation.confirmRecording(sessionId: sessionId)
    } catch {
      restore.pendingNotice = nil
      await handleCaptureFailure(
        .detail(error.localizedDescription),
        code: .recordingAuthority,
        interruptionReason: .firstSampleRejected
      )
      return
    }
    guard recording.journalDurable, recording.mediaFilesOpen, recording.recordingStarted,
      Set(recording.requiredSources) == spanSources,
      Set(recording.activeSources) == spanSources
    else {
      restore.pendingNotice = nil
      await handleCaptureFailure(
        .detail(LiveMicrophoneRecordingError.invalidRecordingAuthority.localizedDescription),
        code: .recordingAuthority,
        interruptionReason: .firstSampleRejected
      )
      return
    }
    phase = .capturing
    if let pendingNotice = restore.pendingNotice {
      notice = pendingNotice
      restore.pendingNotice = nil
    }
    environment.observer?.recording(reached: .recording, sessionId: sessionId)
    if environment.segmentedCapture { beginStorageWatch() }
  }

  func acceptMicrophoneObservation(
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
    guard !failedSources.contains(.microphone) || restore.segmentOpen else { return }
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
    environment.captureHealthTelemetry(
      CaptureSourceHealthTelemetryRecord(
        observation: observation,
        rustSourceState: rustSourceState,
        visibleState: phase.rawValue
      )
    )
    guard await checkMicrophonePermission() else { return }
    if observation.event == .routeInterrupted {
      await handleCaptureFailure(
        .microphoneRouteStopped,
        code: .captureRouteInterrupted,
        source: .microphone,
        interruptionReason: .captureFailed,
        expectedMicrophoneIdentity: observation.identity
      )
    }
  }

  /// One source failed. A restore that has not started is dropped, a lone
  /// failed source with another still recording degrades the session, and
  /// anything else interrupts it for recovery.
  func handleCaptureFailure(
    _ cause: RecorderNotice,
    code: RecorderFailureCode,
    source: NativeMediaSourceKind? = nil,
    interruptionReason: NativeSessionInterruptionReason,
    expectedMicrophoneIdentity: MicrophoneCaptureIdentity? = nil,
    expectedRestoreGeneration: UUID? = nil,
    requiresUnstartedRestore: Bool = false
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
    guard expectedMicrophoneIdentity.map({ $0 == microphoneCaptureIdentity }) ?? true,
      expectedRestoreGeneration.map({ $0 == restore.generation }) ?? true
    else { return }
    if requiresUnstartedRestore {
      guard restore.segmentOpen else { return }
      // Recheck after the serialized wait: writer durability precedes the UI
      // notification, and a first sample may have landed while we waited.
      if let writer = writers[.microphone],
        writer.acceptedFirstSampleEvidence(segmentId: writer.authorization.segmentId) != nil
      {
        return
      }
      _ = (restore.capture ?? microphoneCapture)?.stop()
      // A final drain can accept the first sample. Publish that real receipt,
      // then retire/seal the captured span through normal failure handling.
      if let writer = writers[.microphone],
        writer.acceptedFirstSampleEvidence(segmentId: writer.authorization.segmentId) != nil,
        let receipt = writer.firstAcceptedReceipt()
      {
        if phase == .starting, let attempt = activeAttempt {
          await acceptFirstSample(receipt, from: .microphone, attempt: attempt)
        } else {
          acceptRestoredMicrophoneSample(receipt, generation: restore.generation)
        }
        await handleCaptureFailure(
          cause, code: code, source: source, interruptionReason: interruptionReason,
          expectedMicrophoneIdentity: expectedMicrophoneIdentity,
          expectedRestoreGeneration: expectedRestoreGeneration)
        return
      }
    }
    if source == .microphone, restore.segmentOpen {
      await dropOpenRestore(
        withdrawn: interruptionReason == .permissionRevoked,
        failedSessionId: failedSessionId, failedAttempt: failedAttempt)
      return
    }
    if environment.segmentedCapture, source == .microphone,
      !sourcesWithFirstSample.contains(.microphone),
      requiredSources.contains(where: { $0 != .microphone && sourcesWithFirstSample.contains($0) })
    {
      if await retireUnstartedMicrophone() { return }
    }
    if environment.segmentedCapture, let preparation, let activeSessionId,
      let path = writers.values.first?.authorization.absolutePath
    {
      do {
        // A writer can encounter ENOSPC before the timer runs. This fresh
        // observation lets Rust release its emergency journal space first.
        recorderDetail = try preparation.recorderAction(
          sessionId: activeSessionId,
          action: .observeStorage(availableBytes: environment.availableBytes(path)))
        if recorderDetail?.storageLevel == .critical {
          await stop()
          // The reserve is the cause even when sealing on a full volume fails.
          notice = .stoppedForReserveAfterFailure
          return
        }
      } catch {
        await fail(
          .storageUnchecked, code: .storageObservationFailed,
          interruptionReason: interruptionReason)
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
            source: source, cause: cause, code: code,
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
    await fail(
      preserveMicrophoneOnly ? .microphoneStoppedRecordingKept : cause,
      code: code, interruptionReason: interruptionReason)
  }

  private func degradeCaptureAfterSourceFailure(
    source: NativeMediaSourceKind,
    cause: RecorderNotice,
    code: RecorderFailureCode,
    reason: NativeSourceFailureReason
  ) async {
    let interruptionReason: NativeSessionInterruptionReason =
      reason == .permissionRevoked ? .permissionRevoked : .captureFailed
    guard let preparation, let activeSessionId, let writer = writers[source] else {
      await fail(cause, code: code, interruptionReason: interruptionReason)
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
      if environment.segmentedCapture,
        writer.acceptedFirstSampleEvidence(segmentId: segmentId) == nil
      {
        // A rotation sealed the predecessor, then the successor failed before
        // its first sample and never became a real segment. Rust abandons it,
        // leaving the source on its sealed media as a seal would.
        try span(preparation).abandon(segmentId: segmentId, sessionId: activeSessionId)
      } else {
        guard let finalSampleHostTime else {
          throw LiveMicrophoneRecordingError.missingFailedSourceSample
        }
        try span(preparation).seal(writer, finalSampleHostTime: finalSampleHostTime)
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
      if environment.segmentedCapture {
        recorderDetail = try preparation.recorderDetail(sessionId: activeSessionId)
      }
      if source == .microphone {
        notice =
          reason == .permissionRevoked
          ? .microphoneAccessWithdrawn(restoreContinuation(continuingRecording))
          : .microphoneStopped(continuingRecording)
      } else {
        let name = Self.displayName(for: source)
        notice =
          reason == .permissionRevoked
          ? .sourceAccessWithdrawn(source: name) : .sourceStopped(source: name, cause: cause)
      }
      self.failure = code
      phase = .capturing
    } catch {
      let failed: RecorderNotice =
        if source == .microphone, !sourceWasSealed {
          .microphoneNotSealed
        } else if sourceWasSealed {
          .failedSourceSealedContinuationUnconfirmed(.detail(error.localizedDescription))
        } else {
          .failedSourceNotSealed(.detail(error.localizedDescription))
        }
      await fail(failed, code: code, interruptionReason: interruptionReason)
    }
  }

  /// Interrupts the session, or only ends the span when `interruptionReason`
  /// is nil, and shows `cause`. An interruption Rust did not confirm keeps the
  /// session so Start stays blocked.
  private func fail(
    _ cause: RecorderNotice,
    code: RecorderFailureCode,
    stopCapture: Bool = true,
    interruptionReason: NativeSessionInterruptionReason? = nil
  ) async {
    phase = .stopping
    if stopCapture {
      _ = microphoneCapture?.stop()
      _ = try? await systemCapture?.stop()
    }
    var recoveryUnconfirmed = false
    var interruptionConfirmed = interruptionReason == nil || activeSessionId == nil
    if let interruptionReason, let preparation, let activeSessionId {
      do {
        let evidence = try preparation.interruptSession(
          sessionId: activeSessionId,
          reason: interruptionReason
        )
        interruptionConfirmed =
          evidence.journalDurable && evidence.sessionInterrupted && !evidence.recordingStarted
        recoveryUnconfirmed = !interruptionConfirmed
      } catch {
        recoveryUnconfirmed = true
      }
    }
    if interruptionConfirmed {
      resetActiveSession()
    }
    notice = recoveryUnconfirmed ? .recoveryUnconfirmed(cause) : cause
    failure = code
    phase = .failed
  }

  nonisolated private static func failureCode(for error: Error) -> RecorderFailureCode {
    if let recordingError = error as? LiveMicrophoneRecordingError {
      return recordingError.failureCode
    }
    if let captureError = error as? MicrophoneCaptureAdapterError {
      return RecorderFailureCode(captureError)
    }
    return .captureStartOrSetup
  }

  nonisolated static func displayName(for source: NativeMediaSourceKind) -> String {
    NativeCapturePolicy.current.source(source).displayName
  }

  private func rememberSession(_ id: String?) {
    activeSessionId = id
    if let id { diagnosticSessionId = id }
  }

  private func notePhaseChange(from previous: LiveMicrophoneRecordingPhase) {
    guard phase != previous else { return }
    if phase != .starting && phase != .capturing {
      watchers.stopPermission()
    }
    let session = DiagnosticPrivacy.token(activeSessionId ?? diagnosticSessionId ?? "none")
    var detail = "from=\(previous.rawValue) to=\(phase.rawValue) session=\(session)"
    if phase == .failed {
      let code = failure?.rawValue ?? "none"
      detail += " code=\(code)"
    }
    AppTelemetry.captureProof(stage: .phase, detail: detail)
    publishRetirementIfNeeded()
  }

  private func resetActiveSession() {
    liveCaptions.cancel()
    watchers.stopSession()
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
    restore.endSession()
  }

  private func startMixdown(
    preparation: NativeRecordingPreparationProtocol, sessionId: String
  ) {
    guard environment.segmentedCapture else { return }
    guard let storagePath = savedPaths.first else {
      mixdownStatus = RecorderSavedNote.mixUnavailable
      return
    }
    lastSavedSessionId = sessionId
    mixdownStatus = RecorderSavedNote.mixing
    let observer = environment.observer
    Task.detached(priority: .utility) { [weak self] in
      let verified: Bool
      do {
        _ = try ValidatedMixdownBuilder.buildIfNeeded(
          preparation: preparation, sessionId: sessionId,
          storagePath: storagePath,
          beforeEncoding: { observer?.recording(reached: .processing, sessionId: sessionId) })
        verified = true
      } catch {
        verified = false
      }
      await MainActor.run {
        AppTelemetry.captureProof(
          stage: .mixdown,
          detail:
            "\(verified ? "verified" : "unavailable") session=\(DiagnosticPrivacy.token(sessionId))"
        )
        guard let self, self.lastSavedSessionId == sessionId, self.phase == .saved else { return }
        self.mixdownStatus =
          verified ? RecorderSavedNote.mixed : RecorderSavedNote.mixUnavailable
      }
    }
  }

  func selectCaptureSource(_ selection: RecorderCaptureSelection) {
    guard canStart || canResume else { return }
    guard selection.kind != nil || !isMicrophoneRetired else {
      notice = .microphoneOnlyAfterLoss
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
      notice = nil
      publishRetirementIfNeeded()
    } catch {
      notice = .sourceChangeNotSaved
    }
  }

  func addMarker(label: String = "") {
    guard canMark, let preparation, let activeSessionId else { return }
    do {
      recorderDetail = try preparation.recorderAction(
        sessionId: activeSessionId,
        action: .marker(hostTime: environment.hostTime(), label: label))
    } catch { notice = .markerNotSaved }
  }

  /// PRD 11.6: sleep is logged and stops capture through the sealed-pause
  /// path, so recorded audio is kept. Wake is logged and never resumes.
  func systemWillSleep() async {
    guard let preparation, let activeSessionId else { return }
    if let detail = try? preparation.recorderAction(
      sessionId: activeSessionId,
      action: .observeSystemPower(hostTime: environment.hostTime(), asleep: true))
    {
      recorderDetail = detail
    }
    guard canPause else { return }
    await stop(pausing: true)
    if phase == .paused {
      notice = .pausedForSleep
    }
  }

  func systemDidWake() {
    guard let preparation, let activeSessionId else { return }
    if let detail = try? preparation.recorderAction(
      sessionId: activeSessionId,
      action: .observeSystemPower(hostTime: environment.hostTime(), asleep: false))
    {
      recorderDetail = detail
    }
  }

  func detail(sessionId: String) throws -> NativeRecorderDetail {
    let authority = try preparation ?? environment.preparationFactory()
    return try authority.recorderDetail(sessionId: sessionId)
  }

  private func beginStorageWatch() {
    watchers.watchStorage { [weak self] in
      guard let self, self.phase == .capturing else { return false }
      await self.checkStorage()
      return true
    }
    let attempt = activeAttempt
    watchers.watchApplicationExit(processId: captureSelection.processId) { [weak self] processId in
      guard let self, self.activeAttempt == attempt else { return }
      await self.selectedApplicationExited(processId: processId)
    }
  }

  /// TCC can change without a route or engine callback. Observe it off the
  /// audio hot path while this attempt is starting or recording. Cancellation
  /// and identity checks prevent an old observer from reaching a later span.
  func beginPermissionWatch() {
    watchers.stopPermission()
    guard let sessionId = activeSessionId, let attempt = activeAttempt,
      !failedSources.contains(.microphone)
    else { return }
    watchers.watchPermission { [weak self] in
      guard let self, self.activeSessionId == sessionId,
        self.activeAttempt == attempt, !self.failedSources.contains(.microphone)
      else { return false }
      return await self.checkMicrophonePermission()
    }
  }

  /// Native permission is an observation, never capture authority. Existing
  /// Rust admission decides interruption or degraded continuation; restoring
  /// access cannot resurrect a retired source or start a new attempt.
  private func checkMicrophonePermission() async -> Bool {
    guard phase == .starting || phase == .capturing else { return false }
    guard !failedSources.contains(.microphone) || restore.segmentOpen else { return true }
    guard environment.permission.currentState == .authorized else {
      await handleCaptureFailure(
        .microphonePermissionWithdrawnAudioKept,
        code: .permissionRevoked, source: .microphone,
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
        action: .observeStorage(availableBytes: environment.availableBytes(path)))
      if recorderDetail?.storageLevel == .critical {
        await stop()
        notice = .stoppedAtReserve
      }
    } catch {
      await stop()
      notice = .storageUnchecked
    }
  }

  /// A stale or unrelated application exit cannot change this recording.
  func selectedApplicationExited(processId: pid_t) async {
    guard captureSelection.kind == .applicationAudio,
      captureSelection.processId == processId
    else { return }
    await handleCaptureFailure(
      .applicationExited, code: .applicationExited,
      source: .applicationAudio, interruptionReason: .captureFailed)
  }

  /// Starts live captions on the sources this span records. Captions never
  /// gate capture: they attach to written audio and may start late or not at all.
  private func beginLiveCaptions(
    preparation: NativeRecordingPreparationProtocol, sessionId: String,
    audioSource: NativeMediaSourceKind?
  ) {
    let microphone = microphoneCapture.flatMap { capture in
      writers[.microphone].map { ($0.authorization, capture.liveAudio) }
    }
    let computer = audioSource.flatMap { source in
      systemCapture.flatMap { capture in
        writers[source].map { (source, $0.authorization, capture.liveAudio) }
      }
    }
    liveCaptions.beginSpan(
      preparation: preparation,
      tracks: LiveCaptionTrack.span(sessionId: sessionId, microphone: microphone, computer: computer))
  }

  /// The microphone failed before its first sample while another source
  /// recorded. Rust retires it and the other source keeps the session.
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
      notice = .microphoneStopped(continuingRecording)
      phase = .capturing
      watchers.stopPermission()
      if environment.segmentedCapture { beginStorageWatch() }
      return true
    } catch {
      return false
    }
  }
}
