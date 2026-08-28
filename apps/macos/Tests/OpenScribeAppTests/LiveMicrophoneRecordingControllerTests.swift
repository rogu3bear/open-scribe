import AVFoundation
import XCTest

@testable import OpenScribeApp

@MainActor
private final class AuthorizedMicrophonePermission: MicrophonePermissionProviding {
  var currentState: MicrophonePermissionState

  init(currentState: MicrophonePermissionState = .authorized) {
    self.currentState = currentState
  }

  func request() async -> MicrophonePermissionState {
    currentState
  }
}

private final class RecordingPreparationFake: NativeRecordingPreparation, @unchecked Sendable {
  private(set) var acceptedFirstSample = false
  private(set) var sealed = false
  private(set) var interruptionReasons: [NativeSessionInterruptionReason] = []
  var authorizeError: Error?
  var firstSampleDurable = true
  var interruptionError: Error?
  var interruptionEvidenceIsDurable = true
  var sealError: Error?

  init() {
    super.init(noHandle: NoHandle())
  }

  required init(unsafeFromHandle handle: UInt64) {
    super.init(unsafeFromHandle: handle)
  }

  override func prepareSession(title _: String) throws -> NativePreparedSession {
    NativePreparedSession(
      sessionId: "session-live",
      schemaVersion: 2,
      journalVersion: 1,
      lastJournalSequence: 1,
      journalDurable: true,
      mediaFilesOpen: false,
      recordingStarted: false
    )
  }

  override func prepareSessionWithRequiredSources(
    title _: String,
    requiredSources: [NativeMediaSourceKind]
  ) throws -> NativePreparedSession {
    XCTAssertEqual(requiredSources, [.microphone])
    return try prepareSession(title: "")
  }

  override func confirmRecording(sessionId: String) throws -> NativeRecordingStartedEvidence {
    NativeRecordingStartedEvidence(
      sessionId: sessionId,
      requiredSources: [.microphone],
      activeSources: [.microphone],
      journalDurable: true,
      mediaFilesOpen: true,
      recordingStarted: true,
      lastJournalSequence: 5
    )
  }

  override func authorizeInitialMedia(
    sessionId: String,
    sourceKind _: NativeMediaSourceKind,
    sourceDisplayName _: String
  ) throws -> NativeMediaOpenAuthorization {
    if let authorizeError {
      throw authorizeError
    }
    return NativeMediaOpenAuthorization(
      sessionId: sessionId,
      sourceId: "source-live",
      trackId: "track-live",
      segmentId: "segment-live",
      openToken: "token-live",
      writerGeneration: 1,
      relativePath: "audio/microphone/segment-live.caf",
      absolutePath: "/tmp/segment-live.caf",
      mappedStartNanoseconds: 0
    )
  }

  override func acceptMediaOpen(receipt: NativeMediaOpenReceipt) throws
    -> NativeMediaOpenEvidence
  {
    NativeMediaOpenEvidence(
      sessionId: receipt.sessionId,
      segmentId: receipt.segmentId,
      journalDurable: true,
      mediaFilesOpen: true,
      recordingStarted: false,
      lastJournalSequence: 3
    )
  }

  override func acceptFirstSample(receipt: NativeFirstSampleReceipt) throws
    -> NativeFirstSampleEvidence
  {
    acceptedFirstSample = true
    return NativeFirstSampleEvidence(
      sessionId: receipt.sessionId,
      segmentId: receipt.segmentId,
      firstSampleSessionNanoseconds: 0,
      journalDurable: true,
      mediaFilesOpen: true,
      firstSampleDurable: firstSampleDurable,
      recordingStarted: false,
      lastJournalSequence: 4
    )
  }

  override func sealSegment(receipt: NativeSealSegmentReceipt) throws
    -> NativeSealedSegmentEvidence
  {
    if let sealError {
      throw sealError
    }
    sealed = true
    return NativeSealedSegmentEvidence(
      sessionId: receipt.sessionId,
      segmentId: receipt.segmentId,
      finalSampleCount: receipt.finalSampleCount,
      finalByteLength: receipt.finalByteLength,
      digestSha256: String(repeating: "a", count: 64),
      segmentSealed: true,
      recordingStarted: false,
      lastJournalSequence: 5
    )
  }

  override func interruptSession(
    sessionId: String,
    reason: NativeSessionInterruptionReason
  ) throws -> NativeSessionInterruptionEvidence {
    if let interruptionError {
      throw interruptionError
    }
    interruptionReasons.append(reason)
    return NativeSessionInterruptionEvidence(
      sessionId: sessionId,
      reason: reason,
      journalDurable: interruptionEvidenceIsDurable,
      sessionInterrupted: interruptionEvidenceIsDurable,
      recordingStarted: false,
      lastJournalSequence: 5
    )
  }
}

private final class SegmentWriterFake: ManagedSegmentWriting, @unchecked Sendable {
  let authorization: NativeMediaOpenAuthorization

  init(authorization: NativeMediaOpenAuthorization) {
    self.authorization = authorization
  }

  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    input.frameLength
  }

  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws
    -> NativeFirstSampleReceipt
  {
    NativeFirstSampleReceipt(
      sessionId: authorization.sessionId,
      trackId: authorization.trackId,
      segmentId: authorization.segmentId,
      openToken: authorization.openToken,
      writerGeneration: authorization.writerGeneration,
      relativePath: authorization.relativePath,
      firstSampleHostTime: hostTime,
      firstSampleFrameCount: frameCount,
      observedByteLength: 512
    )
  }

  func receipt() throws -> NativeMediaOpenReceipt {
    NativeMediaOpenReceipt(
      sessionId: authorization.sessionId,
      trackId: authorization.trackId,
      segmentId: authorization.segmentId,
      openToken: authorization.openToken,
      writerGeneration: authorization.writerGeneration,
      relativePath: authorization.relativePath,
      initialByteLength: 128
    )
  }

  func sealSegmentReceipt(finalSampleHostTime: UInt64) throws -> NativeSealSegmentReceipt {
    NativeSealSegmentReceipt(
      sessionId: authorization.sessionId,
      trackId: authorization.trackId,
      segmentId: authorization.segmentId,
      openToken: authorization.openToken,
      writerGeneration: authorization.writerGeneration,
      relativePath: authorization.relativePath,
      finalSampleHostTime: finalSampleHostTime,
      finalSampleCount: 4_800,
      finalByteLength: 9_728
    )
  }
}

private final class MicrophoneCaptureFake: MicrophoneCapturing, @unchecked Sendable {
  private var firstSampleHandler: MicrophoneFirstSampleHandler?
  private var failureHandler: MicrophoneFailureHandler?
  var lastHostTime: UInt64? = 52_000
  var startError: Error?
  private(set) var stopCount = 0

  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onFailure: @escaping MicrophoneFailureHandler
  ) throws {
    if let startError {
      throw startError
    }
    firstSampleHandler = onFirstSample
    failureHandler = onFailure
  }

  func stop() -> UInt64? {
    stopCount += 1
    return lastHostTime
  }

  func emitFirstSample(_ receipt: NativeFirstSampleReceipt) {
    firstSampleHandler?(receipt)
  }

  func emitFailure(_ error: MicrophoneCaptureAdapterError) {
    failureHandler?(error)
  }
}

private enum CaptureFakeError: Error {
  case authorizationFailed
  case interruptionFailed
  case startFailed
  case sealFailed
}

private final class InvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.withLock {
      count += 1
    }
  }

  var value: Int {
    lock.withLock { count }
  }
}

private final class SegmentWriterHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedWriter: SegmentWriterFake?

  var writer: SegmentWriterFake? {
    lock.withLock { storedWriter }
  }

  func store(_ writer: SegmentWriterFake) {
    lock.withLock {
      storedWriter = writer
    }
  }
}

@MainActor
final class LiveMicrophoneRecordingControllerTests: XCTestCase {
  func testCaptureAppearsOnlyAfterDurableFirstSampleAndStopSealsTheSegment() async throws {
    let preparation = RecordingPreparationFake()
    let writerHolder = SegmentWriterHolder()
    let capture = MicrophoneCaptureFake()
    let controller = LiveMicrophoneRecordingController(
      permission: AuthorizedMicrophonePermission(),
      preparationFactory: { preparation },
      writerFactory: { authorization in
        let created = SegmentWriterFake(authorization: authorization)
        writerHolder.store(created)
        return created
      },
      captureFactory: { _ in capture }
    )

    await controller.start()
    XCTAssertEqual(controller.phase, .starting)
    XCTAssertFalse(controller.isCapturing)

    let createdWriter = try XCTUnwrap(writerHolder.writer)
    capture.emitFirstSample(
      try createdWriter.firstSampleReceipt(hostTime: 42_000, frameCount: 480)
    )
    for _ in 0..<10 where !controller.isCapturing {
      await Task.yield()
    }
    XCTAssertEqual(controller.phase, .capturing)
    XCTAssertTrue(preparation.acceptedFirstSample)

    controller.stop()
    XCTAssertEqual(controller.phase, .saved)
    XCTAssertTrue(preparation.sealed)
  }

  func testDeniedPermissionFailsBeforePreparationAndCanRetryAfterAuthorization() async {
    let preparationCalls = InvocationCounter()
    let permission = AuthorizedMicrophonePermission(currentState: .denied)
    let controller = LiveMicrophoneRecordingController(
      permission: permission,
      preparationFactory: {
        preparationCalls.increment()
        return RecordingPreparationFake()
      },
      writerFactory: { SegmentWriterFake(authorization: $0) },
      captureFactory: { _ in MicrophoneCaptureFake() }
    )

    await controller.start()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertEqual(controller.failureCode, "permission-denied")
    XCTAssertTrue(controller.canStart)
    XCTAssertEqual(preparationCalls.value, 0)
    XCTAssertTrue(controller.errorMessage?.contains("denied") == true)

    permission.currentState = .authorized
    await controller.start()

    XCTAssertEqual(controller.phase, .starting)
    XCTAssertEqual(preparationCalls.value, 1)
    XCTAssertNil(controller.errorMessage)
    XCTAssertNil(controller.failureCode)
  }

  func testCaptureStartFailureDoesNotClaimCapture() async {
    let preparation = RecordingPreparationFake()
    let capture = MicrophoneCaptureFake()
    capture.startError = CaptureFakeError.startFailed
    let controller = makeController(preparation: preparation, capture: capture)

    await controller.start()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertFalse(controller.isCapturing)
    XCTAssertEqual(preparation.interruptionReasons, [.captureStartFailed])
  }

  func testPostPreparationSetupFailureRecordsInterruptedState() async {
    let preparation = RecordingPreparationFake()
    preparation.authorizeError = CaptureFakeError.authorizationFailed
    let controller = makeController(
      preparation: preparation,
      capture: MicrophoneCaptureFake()
    )

    await controller.start()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertEqual(preparation.interruptionReasons, [.captureStartFailed])
  }

  func testInterruptionWriteFailureRetainsPreparedSessionAndBlocksRestart() async {
    let preparation = RecordingPreparationFake()
    preparation.authorizeError = CaptureFakeError.authorizationFailed
    preparation.interruptionError = CaptureFakeError.interruptionFailed
    let controller = makeController(
      preparation: preparation,
      capture: MicrophoneCaptureFake()
    )

    await controller.start()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertFalse(controller.canStart)
    XCTAssertTrue(
      controller.errorMessage?.contains("Recovery state could not be confirmed") == true)
  }

  func testInvalidInterruptionEvidenceRetainsPreparedSessionAndBlocksRestart() async {
    let preparation = RecordingPreparationFake()
    preparation.authorizeError = CaptureFakeError.authorizationFailed
    preparation.interruptionEvidenceIsDurable = false
    let controller = makeController(
      preparation: preparation,
      capture: MicrophoneCaptureFake()
    )

    await controller.start()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertFalse(controller.canStart)
    XCTAssertTrue(
      controller.errorMessage?.contains("Recovery state could not be confirmed") == true)
  }

  func testCaptureFailureStopsCaptureAndLeavesControllerFailed() async {
    let preparation = RecordingPreparationFake()
    let capture = MicrophoneCaptureFake()
    let controller = makeController(preparation: preparation, capture: capture)
    await controller.start()
    XCTAssertEqual(controller.phase, .starting)

    capture.emitFailure(.writerFailed)
    for _ in 0..<10 where controller.phase != .failed {
      await Task.yield()
    }

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertEqual(controller.failureCode, "capture-writerFailed")
    XCTAssertTrue(controller.canStart)
    XCTAssertFalse(controller.isCapturing)
    XCTAssertEqual(capture.stopCount, 1)
    XCTAssertEqual(preparation.interruptionReasons, [.captureFailed])
  }

  func testStopBeforeFirstSampleFailsWithoutSealing() async {
    let preparation = RecordingPreparationFake()
    let capture = MicrophoneCaptureFake()
    capture.lastHostTime = nil
    let controller = makeController(preparation: preparation, capture: capture)
    await controller.start()
    XCTAssertEqual(controller.phase, .starting)

    controller.stop()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertFalse(preparation.sealed)
    XCTAssertTrue(controller.errorMessage?.contains("No microphone sample") == true)
    XCTAssertEqual(preparation.interruptionReasons, [.stopWithoutDurableSample])
  }

  func testRejectedFirstSampleRecordsInterruptedState() async throws {
    let preparation = RecordingPreparationFake()
    preparation.firstSampleDurable = false
    let writerHolder = SegmentWriterHolder()
    let capture = MicrophoneCaptureFake()
    let controller = LiveMicrophoneRecordingController(
      permission: AuthorizedMicrophonePermission(),
      preparationFactory: { preparation },
      writerFactory: { authorization in
        let writer = SegmentWriterFake(authorization: authorization)
        writerHolder.store(writer)
        return writer
      },
      captureFactory: { _ in capture }
    )
    await controller.start()

    let writer = try XCTUnwrap(writerHolder.writer)
    capture.emitFirstSample(try writer.firstSampleReceipt(hostTime: 42_000, frameCount: 480))
    for _ in 0..<10 where controller.phase != .failed {
      await Task.yield()
    }

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertEqual(preparation.interruptionReasons, [.firstSampleRejected])
  }

  func testSealFailureRecordsInterruptedState() async throws {
    let preparation = RecordingPreparationFake()
    preparation.sealError = CaptureFakeError.sealFailed
    let writerHolder = SegmentWriterHolder()
    let capture = MicrophoneCaptureFake()
    let controller = LiveMicrophoneRecordingController(
      permission: AuthorizedMicrophonePermission(),
      preparationFactory: { preparation },
      writerFactory: { authorization in
        let writer = SegmentWriterFake(authorization: authorization)
        writerHolder.store(writer)
        return writer
      },
      captureFactory: { _ in capture }
    )
    await controller.start()
    let writer = try XCTUnwrap(writerHolder.writer)
    capture.emitFirstSample(try writer.firstSampleReceipt(hostTime: 42_000, frameCount: 480))
    for _ in 0..<10 where controller.phase != .capturing {
      await Task.yield()
    }

    controller.stop()

    XCTAssertEqual(controller.phase, .failed)
    XCTAssertEqual(preparation.interruptionReasons, [.segmentSealFailed])
  }

  private func makeController(
    preparation: RecordingPreparationFake = RecordingPreparationFake(),
    capture: MicrophoneCaptureFake
  ) -> LiveMicrophoneRecordingController {
    LiveMicrophoneRecordingController(
      permission: AuthorizedMicrophonePermission(),
      preparationFactory: { preparation },
      writerFactory: { SegmentWriterFake(authorization: $0) },
      captureFactory: { _ in capture }
    )
  }
}
