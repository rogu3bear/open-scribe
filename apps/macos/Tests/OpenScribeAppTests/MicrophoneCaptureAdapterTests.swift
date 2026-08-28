import AVFoundation
import CoreMedia
import ScreenCaptureKit
import XCTest

@testable import OpenScribeApp

private enum FakeBackendError: Error {
  case startFailed
}

private final class FakeMicrophoneBackend: MicrophoneCaptureBackend, @unchecked Sendable {
  let inputFormat: AVAudioFormat
  let startEntered: DispatchSemaphore?
  let allowStart: DispatchSemaphore?
  let shouldFailStart: Bool
  private var handler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
  private(set) var started = false

  init(
    inputFormat: AVAudioFormat,
    startEntered: DispatchSemaphore? = nil,
    allowStart: DispatchSemaphore? = nil,
    shouldFailStart: Bool = false
  ) {
    self.inputFormat = inputFormat
    self.startEntered = startEntered
    self.allowStart = allowStart
    self.shouldFailStart = shouldFailStart
  }

  func installTap(
    bufferSize _: AVAudioFrameCount,
    handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  ) {
    self.handler = handler
  }

  func start() throws {
    startEntered?.signal()
    allowStart?.wait()
    if shouldFailStart {
      throw FakeBackendError.startFailed
    }
    started = true
  }

  func stop() {
    started = false
    handler = nil
  }

  func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
    handler?(buffer, AVAudioTime(hostTime: hostTime))
  }
}

private final class FailingCapturedWriter: CapturedAudioWriting, @unchecked Sendable {
  func writeCapturedBuffer(_: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    throw MicrophoneCaptureAdapterError.writerFailed
  }

  func firstSampleReceipt(hostTime _: UInt64, frameCount _: UInt64) throws
    -> NativeFirstSampleReceipt
  {
    throw MicrophoneCaptureAdapterError.writerFailed
  }
}

private final class BlockingCapturedWriter: CapturedAudioWriting, @unchecked Sendable {
  let writeEntered = DispatchSemaphore(value: 0)
  let allowWrite = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private(set) var writeCount = 0

  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    lock.lock()
    writeCount += 1
    let shouldBlock = writeCount == 1
    lock.unlock()
    if shouldBlock {
      writeEntered.signal()
      allowWrite.wait()
    }
    return input.frameLength
  }

  func firstSampleReceipt(hostTime _: UInt64, frameCount _: UInt64) throws
    -> NativeFirstSampleReceipt
  {
    throw MicrophoneCaptureAdapterError.writerFailed
  }
}

private final class ReceiptBox: @unchecked Sendable {
  private let lock = NSLock()
  private var receipts: [NativeFirstSampleReceipt] = []

  func append(_ receipt: NativeFirstSampleReceipt) {
    lock.lock()
    receipts.append(receipt)
    lock.unlock()
  }

  func snapshot() -> [NativeFirstSampleReceipt] {
    lock.lock()
    defer { lock.unlock() }
    return receipts
  }
}

final class MicrophoneCaptureAdapterTests: XCTestCase {
  private var managedRoots: [URL] = []

  override func tearDownWithError() throws {
    for root in managedRoots {
      try? FileManager.default.removeItem(at: root)
    }
    managedRoots.removeAll()
    try super.tearDownWithError()
  }

  func testPermissionAuthorityMapsEveryKnownTCCStateWithoutInventingAccess() {
    XCTAssertEqual(
      AVFoundationMicrophonePermissionAuthority.map(.notDetermined),
      .notDetermined
    )
    XCTAssertEqual(AVFoundationMicrophonePermissionAuthority.map(.restricted), .restricted)
    XCTAssertEqual(AVFoundationMicrophonePermissionAuthority.map(.denied), .denied)
    XCTAssertEqual(AVFoundationMicrophonePermissionAuthority.map(.authorized), .authorized)
  }

  func testCapturedBufferProducesOneDurableCoarseReceiptWithoutRecording() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-microphone-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    managedRoots.append(root)
    let controller = try NativeRecordingPreparation.open(managedRoot: root.path)
    let prepared = try controller.prepareSession(title: "Microphone adapter proof")
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone"
    )
    let writer = try ManagedCAFWriter(authorization: authorization)
    let mediaOpen = try controller.acceptMediaOpen(receipt: writer.receipt())
    XCTAssertTrue(mediaOpen.mediaFilesOpen)
    XCTAssertFalse(mediaOpen.recordingStarted)

    let inputFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: 2,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: inputFormat)
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    let receiptBox = ReceiptBox()
    let firstSample = expectation(description: "first sample receipt")
    let failure = expectation(description: "no capture failure")
    failure.isInverted = true
    try adapter.start(
      onFirstSample: { receipt in
        receiptBox.append(receipt)
        firstSample.fulfill()
      },
      onFailure: { _ in failure.fulfill() }
    )
    XCTAssertTrue(backend.started)

    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 441)
    )
    buffer.frameLength = 441
    for channel in 0..<Int(inputFormat.channelCount) {
      let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
      for frame in 0..<Int(buffer.frameLength) {
        samples[frame] = Float(frame % 32) / 32.0
      }
    }
    backend.emit(buffer, hostTime: 42_000)
    wait(for: [firstSample, failure], timeout: 1)
    _ = adapter.stop()

    let receipts = receiptBox.snapshot()
    XCTAssertEqual(receipts.count, 1)
    let evidence = try controller.acceptFirstSample(receipt: try XCTUnwrap(receipts.first))
    XCTAssertTrue(evidence.firstSampleDurable)
    XCTAssertFalse(evidence.recordingStarted)
    XCTAssertEqual(evidence.firstSampleSessionNanoseconds, 0)

    let media = try AVAudioFile(
      forReading: URL(fileURLWithPath: authorization.absolutePath)
    )
    XCTAssertEqual(media.processingFormat.sampleRate, 48_000)
    XCTAssertEqual(media.processingFormat.channelCount, 1)
    XCTAssertGreaterThan(media.length, 0)
  }

  func testNinetySixKilohertzMonoBufferProducesDurableFrames() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-microphone-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    managedRoots.append(root)
    let controller = try NativeRecordingPreparation.open(managedRoot: root.path)
    let prepared = try controller.prepareSession(title: "96 kHz microphone proof")
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "96 kHz synthetic microphone"
    )
    let writer = try ManagedCAFWriter(authorization: authorization)
    _ = try controller.acceptMediaOpen(receipt: writer.receipt())

    let inputFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 96_000,
        channels: 1,
        interleaved: false
      )
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096)
    )
    buffer.frameLength = 4_096
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(buffer.frameLength) {
      samples[frame] = Float(frame % 64) / 64.0
    }

    let writtenFrames = try writer.writeCapturedBuffer(buffer)

    XCTAssertGreaterThan(writtenFrames, 0)
    let receipt = try writer.firstSampleReceipt(
      hostTime: 42_000,
      frameCount: UInt64(writtenFrames)
    )
    let evidence = try controller.acceptFirstSample(receipt: receipt)
    XCTAssertTrue(evidence.firstSampleDurable)
    XCTAssertFalse(evidence.recordingStarted)
  }

  func testCaptureAdapterCannotRestartAfterStop() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-microphone-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    managedRoots.append(root)
    let controller = try NativeRecordingPreparation.open(managedRoot: root.path)
    let prepared = try controller.prepareSession(title: "One-shot adapter proof")
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone"
    )
    let writer = try ManagedCAFWriter(authorization: authorization)
    _ = try controller.acceptMediaOpen(receipt: writer.receipt())
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let adapter = MicrophoneCaptureAdapter(
      backend: FakeMicrophoneBackend(inputFormat: format),
      writer: writer
    )
    try adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    _ = adapter.stop()

    XCTAssertThrowsError(
      try adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    ) { error in
      XCTAssertEqual(error as? MicrophoneCaptureAdapterError, .alreadyStarted)
    }
  }

  func testOversizedCallbackFailsWithoutEnteringTheWriter() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    let failed = expectation(description: "invalid callback fails closed")
    failed.assertForOverFulfill = true
    try adapter.start(
      onFirstSample: { _ in XCTFail("invalid callback produced a receipt") },
      onFailure: { error in
        XCTAssertEqual(error, .bufferFrameCapacityExceeded)
        failed.fulfill()
      }
    )
    let oversized = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_385)
    )
    oversized.frameLength = 16_385
    backend.emit(oversized, hostTime: 1)
    backend.emit(oversized, hostTime: 2)
    wait(for: [failed], timeout: 1)
    _ = adapter.stop()
    XCTAssertEqual(writer.writeCount, 0)
  }

  func testMissingHostTimeFailsBeforeWriting() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    let failed = expectation(description: "missing host time fails closed")
    try adapter.start(
      onFirstSample: { _ in XCTFail("missing time produced a receipt") },
      onFailure: { error in
        XCTAssertEqual(error, .missingHostTime)
        failed.fulfill()
      }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    backend.emit(buffer, hostTime: 0)
    wait(for: [failed], timeout: 1)
    _ = adapter.stop()
    XCTAssertEqual(writer.writeCount, 0)
  }

  func testBackendStartFailureRemovesTheInstalledTap() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format, shouldFailStart: true)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    XCTAssertThrowsError(
      try adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    ) { error in
      XCTAssertTrue(error is FakeBackendError)
    }
    XCTAssertFalse(backend.started)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    backend.emit(buffer, hostTime: 1)
    XCTAssertEqual(writer.writeCount, 0)
  }

  func testWriterFailureIsReportedOnce() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: FailingCapturedWriter())
    let failed = expectation(description: "writer failure reported once")
    failed.assertForOverFulfill = true
    try adapter.start(
      onFirstSample: { _ in XCTFail("failed writer produced a receipt") },
      onFailure: { error in
        XCTAssertEqual(error, .writerFailed)
        failed.fulfill()
      }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    backend.emit(buffer, hostTime: 1)
    backend.emit(buffer, hostTime: 2)
    wait(for: [failed], timeout: 1)
    _ = adapter.stop()
  }

  func testPoolExhaustionFailsClosedWithoutBlockingTheCallback() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    let failed = expectation(description: "bounded pool fails closed")
    try adapter.start(
      onFirstSample: { _ in XCTFail("exhausted capture produced a receipt") },
      onFailure: { error in
        XCTAssertEqual(error, .bufferPoolExhausted)
        failed.fulfill()
      }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    backend.emit(buffer, hostTime: 1)
    XCTAssertEqual(writer.writeEntered.wait(timeout: .now() + 1), .success)
    for hostTime in 2...9 {
      backend.emit(buffer, hostTime: UInt64(hostTime))
    }
    writer.allowWrite.signal()
    wait(for: [failed], timeout: 1)
    _ = adapter.stop()
  }

  func testStopSerializesAgainstStartAndLeavesBackendStopped() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let startEntered = DispatchSemaphore(value: 0)
    let allowStart = DispatchSemaphore(value: 0)
    let backend = FakeMicrophoneBackend(
      inputFormat: format,
      startEntered: startEntered,
      allowStart: allowStart
    )
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: BlockingCapturedWriter())
    let startReturned = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      try? adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
      startReturned.signal()
    }
    XCTAssertEqual(startEntered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global().async {
      _ = adapter.stop()
      stopReturned.signal()
    }
    XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut)
    allowStart.signal()
    XCTAssertEqual(startReturned.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(backend.started)
  }

  func testStopWaitsForAnInFlightWriteAndPreventsLaterWrites() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    try adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    backend.emit(buffer, hostTime: 1)
    XCTAssertEqual(writer.writeEntered.wait(timeout: .now() + 1), .success)

    let stopReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = adapter.stop()
      stopReturned.signal()
    }
    XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut)
    writer.allowWrite.signal()
    XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
    backend.emit(buffer, hostTime: 2)
    XCTAssertEqual(writer.writeCount, 1)
  }

  func testStopReturnsTheLastSuccessfullyWrittenSampleHostTime() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    try adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64

    backend.emit(buffer, hostTime: 42_000)
    XCTAssertEqual(writer.writeEntered.wait(timeout: .now() + 1), .success)
    writer.allowWrite.signal()

    XCTAssertEqual(adapter.stop(), 42_000)
  }

  func testSystemAudioPresentationTimeMapsToNativeHostClockUnits() throws {
    let hostClock = CMClockGetHostTimeClock()
    var sourceTimebase: CMTimebase?
    XCTAssertEqual(
      CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault,
        sourceClock: hostClock,
        timebaseOut: &sourceTimebase
      ),
      noErr
    )
    let sourceAnchor = CMTime(value: 123_456, timescale: 48_000)
    let hostAnchor = CMClockGetTime(hostClock)
    let timebase = try XCTUnwrap(sourceTimebase)
    XCTAssertEqual(
      CMTimebaseSetRateAndAnchorTime(
        timebase,
        rate: 1,
        anchorTime: sourceAnchor,
        immediateSourceTime: hostAnchor
      ),
      noErr
    )
    let oneSecond = CMTime(value: 48_000, timescale: 48_000)
    let presentationTime = CMTimeAdd(sourceAnchor, oneSecond)
    let expectedHostTime = CMClockConvertHostTimeToSystemUnits(CMTimeAdd(hostAnchor, oneSecond))

    XCTAssertEqual(
      SystemAudioCaptureAdapter.hostTime(
        from: presentationTime,
        synchronizationClock: timebase
      ),
      expectedHostTime
    )
    XCTAssertNil(
      SystemAudioCaptureAdapter.hostTime(
        from: .invalid,
        synchronizationClock: timebase
      )
    )
  }

  func testInvalidSystemAudioSampleIsReportedAsCaptureFailure() throws {
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: nil,
        sampleCount: 0,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
      ),
      noErr
    )
    let zeroSample = try XCTUnwrap(sampleBuffer)
    XCTAssertTrue(zeroSample.isValid)
    XCTAssertNil(
      SystemAudioCaptureAdapter.sampleFailure(for: zeroSample, type: .audio)
    )
    CMSampleBufferInvalidate(zeroSample)

    XCTAssertEqual(
      SystemAudioCaptureAdapter.sampleFailure(for: zeroSample, type: .audio),
      .invalidSampleBuffer
    )
    XCTAssertNil(
      SystemAudioCaptureAdapter.sampleFailure(for: zeroSample, type: .screen)
    )
  }
}
