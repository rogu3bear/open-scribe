import AVFoundation
import Darwin
import XCTest

@testable import OpenScribeApp

@MainActor
final class PausePermission: MicrophonePermissionProviding {
  var currentState: MicrophonePermissionState = .authorized
  var requestGate: PauseStartGate?
  func request() async -> MicrophonePermissionState {
    if let requestGate { await requestGate.wait() }
    return currentState
  }
}

final class PauseClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = mach_absolute_time()
  var now: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func advance(seconds: Double) {
    lock.lock()
    defer { lock.unlock() }
    value += AVAudioTime.hostTime(forSeconds: seconds)
  }
}

enum PausedRestoreSampleOrder { case beforeStartupReturns, afterStartupReturns }

enum PausedRestoreUnstartedFailure { case captureFailed, permissionWithdrawn }

let differentMicrophoneSentence =
  "This is a different microphone. System audio is still recording."
let unavailableMicrophoneSentence =
  "The selected microphone is not available. System audio is still recording."
let differentMicrophoneResumingSentence =
  "This is a different microphone. The recording is resuming."
let unavailableMicrophoneResumingSentence =
  "The selected microphone is not available. The recording is resuming."
let differentMicrophonePausedSentence =
  "This is a different microphone. The recording is paused."
let unavailableMicrophonePausedSentence =
  "The selected microphone is not available. The recording is paused."
let microphoneCouldNotBeRestoredResumingSentence =
  "The microphone could not be restored. The recording is resuming."
let microphoneCouldNotBeRestoredContinuingSentence =
  "The microphone could not be restored. System audio is still recording."
let microphonePermissionWithdrawnResumingSentence =
  "Microphone access was withdrawn. The recording is resuming."
let microphonePermissionWithdrawnContinuingSentence =
  "Microphone access was withdrawn. System audio is still recording."

final class DeviceProbeBox: @unchecked Sendable {
  var device: MicrophoneDeviceIdentity?
  init(device: MicrophoneDeviceIdentity?) { self.device = device }
}

actor PauseStartGate {
  nonisolated let entered = XCTestExpectation(description: "Resumed system startup suspended")
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
      if waiters.count == 1 { entered.fulfill() }
    }
  }

  func release() {
    released = true
    let pending = waiters
    waiters = []
    for continuation in pending { continuation.resume() }
  }
}

enum PauseSourceError: Error { case startup, drain }

final class PauseSource: MicrophoneCapturing, SystemAudioCapturing, @unchecked Sendable {
  let writer: ManagedSegmentWriting
  var pendingDrain: (UInt64, Int16)?
  var failStart = false
  var failStop = false
  var failInputBinding = false
  var holdsFirstNotification = false
  var startGate: PauseStartGate?
  private(set) var microphoneStartCount = 0
  private(set) var stopCount = 0
  private var firstHandler: MicrophoneFirstSampleHandler?
  private var observationHandler: MicrophoneHealthHandler?
  private var systemFailureHandler: SystemAudioFailureHandler?
  private var microphoneFailureHandler: MicrophoneFailureHandler?
  private var deliverWriteFailure: (@Sendable (Error) -> Void)?
  private var first: NativeFirstSampleReceipt?
  private var lastEnd: UInt64?
  init(writer: ManagedSegmentWriting) { self.writer = writer }
  func bindInput(to device: MicrophoneDeviceIdentity?) throws {
    if failInputBinding { throw MicrophoneCaptureAdapterError.inputDeviceChanged }
  }
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler, onFailure: @escaping MicrophoneFailureHandler
  ) throws {
    microphoneStartCount += 1
    if failStart { throw PauseSourceError.startup }
    firstHandler = onFirstSample
    observationHandler = onObservation
    microphoneFailureHandler = onFailure
    deliverWriteFailure = { _ in onFailure(.writerFailed) }
  }
  /// Delivers one health observation the way the production adapter does: with
  /// the identity it bound when capture started.
  func observe(
    _ event: MicrophoneSourceHealthEvent, identity: MicrophoneCaptureIdentity, sequence: UInt64
  ) {
    observationHandler?(
      MicrophoneSourceHealthObservation(
        identity: identity, sequence: sequence, event: event, callbackCount: sequence,
        successfullyWrittenFrameCount: 48_000, lastProgressMonotonicNanoseconds: 1_000))
  }
  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws {
    if failStart { throw PauseSourceError.startup }
    firstHandler = onFirstSample
    systemFailureHandler = onFailure
    deliverWriteFailure = { _ in onFailure(.streamStopped) }
    if let startGate { await startGate.wait() }
  }
  /// Reports a system-audio stream failure the way the adapter does.
  func fail(_ error: SystemAudioCaptureAdapterError) { systemFailureHandler?(error) }
  func failMicrophone(_ error: MicrophoneCaptureAdapterError) { microphoneFailureHandler?(error) }
  func emit(frames: AVAudioFrameCount, hostTime: UInt64, value: Int16) throws {
    do {
      _ = try writer.writeCapturedBuffer(
        TimelineRuntimeProof.buffer(
          frames: frames, value: value, channels: writer.authorization.channels),
        hostTime: hostTime)
    } catch {
      // A real capture adapter reports a write/rotation failure through its
      // failure handler rather than crashing the audio thread. Mirror that so
      // the controller degrades the source instead of the test seeing a throw.
      guard let deliverWriteFailure else { throw error }
      deliverWriteFailure(error)
      return
    }
    lastEnd = hostTime + AVAudioTime.hostTime(forSeconds: Double(frames) / 48_000)
    if first == nil {
      first = try writer.firstSampleReceipt(hostTime: hostTime, frameCount: UInt64(frames))
      if !holdsFirstNotification { firstHandler?(first!) }
    }
  }
  func repeatFirstCallback() { if let first { firstHandler?(first) } }
  func deliverFirstNotification(_ receipt: NativeFirstSampleReceipt) { firstHandler?(receipt) }
  func stop() -> UInt64? { try? drain() }
  func stop() async throws -> UInt64? { try drain() }
  private func drain() throws -> UInt64? {
    stopCount += 1
    if let (host, value) = pendingDrain {
      pendingDrain = nil
      try emit(frames: 480, hostTime: host, value: value)
    }
    if failStop { throw PauseSourceError.drain }
    return lastEnd
  }
}

/// Factories and test emissions are serialized by the controller's MainActor.
final class PauseSources: @unchecked Sendable {
  var microphones: [PauseSource] = []
  var systems: [PauseSource] = []
  var failNextSystemStart = false
  var failNextMicrophoneBinding = false
  var failNextMicrophoneStart = false
  var nextSystemStartGate: PauseStartGate?
  func microphone(_ writer: ManagedSegmentWriting) -> PauseSource {
    let source = PauseSource(writer: writer)
    source.failInputBinding = failNextMicrophoneBinding
    source.failStart = failNextMicrophoneStart
    failNextMicrophoneBinding = false
    failNextMicrophoneStart = false
    microphones.append(source)
    return source
  }
  func system(_ writer: ManagedSegmentWriting) -> PauseSource {
    let source = PauseSource(writer: writer)
    source.failStart = failNextSystemStart
    source.startGate = nextSystemStartGate
    failNextSystemStart = false
    nextSystemStartGate = nil
    systems.append(source)
    return source
  }
}

final class PauseTelemetry: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [CaptureSourceHealthTelemetryRecord] = []
  func append(_ record: CaptureSourceHealthTelemetryRecord) {
    lock.withLock { records.append(record) }
  }
  func snapshot() -> [CaptureSourceHealthTelemetryRecord] { lock.withLock { records } }
}

@MainActor
final class PauseHarness {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let preparation: NativeRecordingPreparation
  let permission = PausePermission()
  let clock = PauseClock()
  let captures = PauseSources()
  let telemetry = PauseTelemetry()
  let storage = StorageOverride()
  let rotationInjector: RotationFailureInjectingPreparation?
  let controller: LiveMicrophoneRecordingController
  init(
    rotationInjection: Bool = false,
    microphoneDeviceProbe: @escaping @MainActor () -> MicrophoneDeviceIdentity? = { nil },
    restoreTimeoutWait: @escaping MicrophoneRestoreMonitor.Wait = {
      try await MicrophoneRestoreMonitor.waitForTimeout($0)
    }
  ) throws {
    preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let real = preparation
    let injector = rotationInjection ? RotationFailureInjectingPreparation(base: real) : nil
    rotationInjector = injector
    let effective: NativeRecordingPreparationProtocol = injector ?? real
    let captures = captures
    let clock = clock
    let telemetry = telemetry
    let storage = storage
    controller = LiveMicrophoneRecordingController(
      permission: permission, preparationFactory: { effective },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { captures.microphone($0) },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { captures.system($0) }, segmentedCapture: true,
      hostTime: { clock.now },
      availableBytes: { try storage.bytes(at: $0) },
      segmentedSuccessorWriterFactory: { authorization in
        if let injector { return try injector.makeSuccessor(authorization) }
        return try ManagedCAFWriter(authorization: authorization)
      },
      captureHealthTelemetry: { telemetry.append($0) },
      microphoneDeviceProbe: microphoneDeviceProbe, restoreTimeoutWait: restoreTimeoutWait
    )
  }
  func capture() async throws {
    try XCTUnwrap(captures.microphones.last).emit(frames: 48_000, hostTime: clock.now, value: 8192)
    try XCTUnwrap(captures.systems.last).emit(frames: 48_000, hostTime: clock.now, value: 16384)
    for _ in 0..<30 { await Task.yield() }
    XCTAssertEqual(controller.phase, .capturing)
    clock.advance(seconds: 1)
  }
  func captureAndPause() async throws {
    await controller.start()
    try await capture()
    await controller.stop(pausing: true)
    XCTAssertEqual(controller.phase, .paused)
  }
  func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

enum RotationFailureStep: CaseIterable { case writerInit, acceptMediaOpen, seal }

enum RotationInjectedError: Error { case writerInit, acceptMediaOpen, seal, firstSample }

/// Overrides free-space reporting for the injected storage probe. Transparent
/// (real filesystem) until a test sets a value.
final class StorageOverride: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64?
  private var unavailable = false
  func set(_ bytes: UInt64?) { lock.withLock { value = bytes } }
  func setUnavailable(_ value: Bool) { lock.withLock { unavailable = value } }
  func bytes(at path: String) throws -> UInt64 {
    if lock.withLock({ unavailable }) { throw CocoaError(.fileReadUnknown) }
    if let bytes = lock.withLock({ value }) { return bytes }
    return try RecorderStorage.availableBytes(at: path)
  }
}

/// Forwards every preparation call to a real store, injecting a one-shot failure
/// at one rotation step so the abandon path can be exercised end to end.
final class RotationFailureInjectingPreparation: NativeRecordingPreparationProtocol,
  @unchecked Sendable
{
  private let base: NativeRecordingPreparation
  private let lock = NSLock()
  private var armed: RotationFailureStep?
  private var rejectsNextFirstSample = false
  init(base: NativeRecordingPreparation) { self.base = base }
  func arm(_ step: RotationFailureStep) { lock.withLock { armed = step } }
  /// One-shot: the next first sample (a rotated successor's) is rejected after
  /// the rotation itself completed.
  func rejectNextFirstSample() { lock.withLock { rejectsNextFirstSample = true } }
  private func consume(_ step: RotationFailureStep) -> Bool {
    lock.withLock {
      guard armed == step else { return false }
      armed = nil
      return true
    }
  }
  func makeSuccessor(_ authorization: NativeMediaOpenAuthorization) throws -> ManagedCAFWriter {
    if consume(.writerInit) { throw RotationInjectedError.writerInit }
    return try ManagedCAFWriter(authorization: authorization)
  }
  func acceptMediaOpen(receipt: NativeMediaOpenReceipt) throws -> NativeMediaOpenEvidence {
    if consume(.acceptMediaOpen) { throw RotationInjectedError.acceptMediaOpen }
    return try base.acceptMediaOpen(receipt: receipt)
  }
  func sealSegment(receipt: NativeSealSegmentReceipt) throws -> NativeSealedSegmentEvidence {
    if consume(.seal) { throw RotationInjectedError.seal }
    return try base.sealSegment(receipt: receipt)
  }
  func acceptFirstSample(receipt: NativeFirstSampleReceipt) throws -> NativeFirstSampleEvidence {
    let rejects = lock.withLock {
      defer { rejectsNextFirstSample = false }
      return rejectsNextFirstSample
    }
    if rejects { throw RotationInjectedError.firstSample }
    return try base.acceptFirstSample(receipt: receipt)
  }
  func anchorCaptureClock(
    sessionId: String, hostAnchor: UInt64, numerator: UInt32, denominator: UInt32
  ) throws {
    try base.anchorCaptureClock(
      sessionId: sessionId, hostAnchor: hostAnchor, numerator: numerator, denominator: denominator)
  }

  func runtimeLibrarySnapshotAtHost(hostTime: UInt64) throws -> NativeRuntimeLibrarySnapshot {
    try base.runtimeLibrarySnapshotAtHost(hostTime: hostTime)
  }
  func recoverCaptureSafety() throws -> NativeMediaRecovery { try base.recoverCaptureSafety() }
  func authorizeInitialMedia(
    sessionId: String, sourceKind: NativeMediaSourceKind, sourceDisplayName: String
  ) throws -> NativeMediaOpenAuthorization {
    try base.authorizeInitialMedia(
      sessionId: sessionId, sourceKind: sourceKind, sourceDisplayName: sourceDisplayName)
  }
  func authorizeNextSegment(sessionId: String, previousSegmentId: String) throws
    -> NativeMediaOpenAuthorization
  {
    try base.authorizeNextSegment(sessionId: sessionId, previousSegmentId: previousSegmentId)
  }
  func confirmRecording(sessionId: String) throws -> NativeRecordingStartedEvidence {
    try base.confirmRecording(sessionId: sessionId)
  }
  func importCompressedM4a(
    title: String, sourcePath: String, metadata: NativeCompressedImportMetadata
  ) throws -> NativeImportedMediaEvidence {
    try base.importCompressedM4a(title: title, sourcePath: sourcePath, metadata: metadata)
  }
  func importNormalizedCaf(
    title: String, normalizedPath: String, original: NativeOriginalImportMetadata
  ) throws -> NativeImportedMediaEvidence {
    try base.importNormalizedCaf(title: title, normalizedPath: normalizedPath, original: original)
  }
  func importRecoverableCaf(title: String, sourcePath: String) throws -> NativeImportedMediaEvidence
  {
    try base.importRecoverableCaf(title: title, sourcePath: sourcePath)
  }
  func interruptSession(sessionId: String, reason: NativeSessionInterruptionReason) throws
    -> NativeSessionInterruptionEvidence
  {
    try base.interruptSession(sessionId: sessionId, reason: reason)
  }
  func leaseImportedPlayback(sessionId: String) throws -> NativeImportedPlaybackLease {
    try base.leaseImportedPlayback(sessionId: sessionId)
  }
  func leaseRecoveredPlayback(
    sessionId: String, sourceId: String, trackId: String, segmentId: String
  ) throws -> NativeImportedPlaybackLease {
    try base.leaseRecoveredPlayback(
      sessionId: sessionId, sourceId: sourceId, trackId: trackId, segmentId: segmentId)
  }
  func playbackTimeline(sessionId: String) throws -> [NativeTimelineSegment] {
    try base.playbackTimeline(sessionId: sessionId)
  }
  func prepareSession(title: String) throws -> NativePreparedSession {
    try base.prepareSession(title: title)
  }
  func prepareSessionWithRequiredSources(
    title: String, requiredSources: [NativeMediaSourceKind]
  ) throws -> NativePreparedSession {
    try base.prepareSessionWithRequiredSources(title: title, requiredSources: requiredSources)
  }
  func recordSourceFailure(
    sessionId: String, sourceKind: NativeMediaSourceKind, reason: NativeSourceFailureReason
  ) throws -> NativeSourceFailureEvidence {
    try base.recordSourceFailure(sessionId: sessionId, sourceKind: sourceKind, reason: reason)
  }
  func recoverPlayableSessions() throws -> [NativeRecoveredPlayableSession] {
    try base.recoverPlayableSessions()
  }
  func runtimeLibrarySnapshot() throws -> NativeRuntimeLibrarySnapshot {
    try base.runtimeLibrarySnapshot()
  }
  func recorderAction(sessionId: String, action: NativeRecorderAction) throws
    -> NativeRecorderDetail
  {
    try base.recorderAction(sessionId: sessionId, action: action)
  }
  func recorderDetail(sessionId: String) throws -> NativeRecorderDetail {
    try base.recorderDetail(sessionId: sessionId)
  }
  func contextAction(sessionId: String, action: NativeContextAction) throws -> NativeContextDetail {
    try base.contextAction(sessionId: sessionId, action: action)
  }
  func contextDetail(sessionId: String) throws -> NativeContextDetail {
    try base.contextDetail(sessionId: sessionId)
  }
  func declareSession(sessionId: String, declaration: NativeSessionDeclaration) throws
    -> NativeSessionDeclaration
  {
    try base.declareSession(sessionId: sessionId, declaration: declaration)
  }

  func renameSession(sessionId: String, title: String) throws -> String {
    try base.renameSession(sessionId: sessionId, title: title)
  }
  func proposeContextEvent(sessionId: String, proposal: NativeContextProposal) throws
    -> NativeContextDecision
  {
    try base.proposeContextEvent(sessionId: sessionId, proposal: proposal)
  }
  func abandonReservedSegment(sessionId: String, segmentId: String) throws {
    try base.abandonReservedSegment(sessionId: sessionId, segmentId: segmentId)
  }
}
