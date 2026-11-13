import AppKit
import AVFoundation
import CoreMedia
import Darwin
import ScreenCaptureKit
import SwiftUI
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
  private var routeEventHandler: MicrophoneRouteEventHandler?
  private(set) var started = false
  private(set) var boundInputUID: String?
  var bufferDuringStart: AVAudioPCMBuffer?
  let stopped = DispatchSemaphore(value: 0)

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

  func bindInput(to device: MicrophoneDeviceIdentity?) throws { boundInputUID = device?.uniqueID }

  func start() throws {
    startEntered?.signal()
    allowStart?.wait()
    if let bufferDuringStart { emit(bufferDuringStart, hostTime: 42_000) }
    if shouldFailStart {
      throw FakeBackendError.startFailed
    }
    started = true
  }

  func stop() {
    started = false
    handler = nil
    stopped.signal()
  }

  func setRouteEventHandler(_ handler: MicrophoneRouteEventHandler?) {
    routeEventHandler = handler
  }

  func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
    handler?(buffer, AVAudioTime(hostTime: hostTime))
  }

  func emitRouteEvent(_ event: MicrophoneRouteEvent) {
    routeEventHandler?(event)
  }
}

private final class InputBindingHardware: @unchecked Sendable {
  let systemDefaultID: UInt32 = 3
  var selectedID: UInt32 = 3
  var reusedID = false
  var binding: MicrophoneInputBinding {
    MicrophoneInputBinding(
      resolve: { $0 == "b" ? 2 : 0 },
      select: { [self] in selectedID = $0 },
      selectedUID: { [self] in selectedID == 2 && !reusedID ? "b" : "c" })
  }
}

private final class AdmissionCountingWriter: CapturedAudioWriting, @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  var count: Int { lock.withLock { writes } }
  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    lock.withLock { writes += 1 }
    return input.frameLength
  }
  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws -> NativeFirstSampleReceipt {
    try ProgressCapturedWriter().firstSampleReceipt(hostTime: hostTime, frameCount: frameCount)
  }
}

private final class ProgressCapturedWriter: CapturedAudioWriting, @unchecked Sendable {
  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    input.frameLength
  }

  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws
    -> NativeFirstSampleReceipt
  {
    NativeFirstSampleReceipt(
      sessionId: "session-observation",
      trackId: "track-microphone",
      segmentId: "segment-microphone",
      openToken: "token-microphone",
      writerGeneration: 7,
      relativePath: "audio/microphone/segment.caf",
      firstSampleHostTime: hostTime,
      firstSampleFrameCount: frameCount,
      observedByteLength: 512
    )
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

private final class ObservationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [MicrophoneSourceHealthObservation] = []

  func append(_ observation: MicrophoneSourceHealthObservation) {
    lock.withLock {
      observations.append(observation)
    }
  }

  func snapshot() -> [MicrophoneSourceHealthObservation] {
    lock.withLock { observations }
  }
}

private final class PCMBufferBox: @unchecked Sendable {
  let value: AVAudioPCMBuffer

  init(_ value: AVAudioPCMBuffer) {
    self.value = value
  }
}

final class MicrophoneCaptureAdapterTests: XCTestCase {
  func testApprovedInputIsBoundBeforeCaptureStarts() throws {
    let backend = FakeMicrophoneBackend(
      inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: ProgressCapturedWriter())
    try adapter.bindInput(
      to: MicrophoneDeviceIdentity(uniqueID: "approved-b", localizedName: "Mic"))
    XCTAssertEqual(backend.boundInputUID, "approved-b")
    XCTAssertFalse(backend.started)
    try adapter.start(
      onFirstSample: { _ in }, onFailure: { _ in XCTFail("unexpected capture failure") })
    _ = adapter.stop()
  }

  func testBuffersBeforeBackendAdmissionAreNotWritten() throws {
    let backend = FakeMicrophoneBackend(
      inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
    let buffer = try TimelineRuntimeProof.buffer(frames: 480, value: 8192, channels: 1)
    backend.bufferDuringStart = buffer
    let writer = AdmissionCountingWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    let first = expectation(description: "first sample after backend admission")
    try adapter.start(
      onFirstSample: { _ in first.fulfill() },
      onFailure: { _ in XCTFail("unexpected capture failure") })
    backend.emit(buffer, hostTime: 43_000)
    wait(for: [first], timeout: 2)
    _ = adapter.stop()
    XCTAssertEqual(writer.count, 1, "the startup buffer must not become captured evidence")
  }

  func testBindingSelectsBWhenTheSystemDefaultHasAlreadyBecomeC() throws {
    let hardware = InputBindingHardware()
    let binding = hardware.binding
    try binding.bind(MicrophoneDeviceIdentity(uniqueID: "b", localizedName: "Same name"))
    XCTAssertEqual(hardware.selectedID, 2)
    XCTAssertEqual(
      hardware.systemDefaultID, 3, "per-engine binding must not mutate the system route")
  }

  func testBindingRejectsReusedDeviceIDAndUnavailableIdentity() throws {
    let hardware = InputBindingHardware()
    hardware.reusedID = true
    XCTAssertThrowsError(
      try hardware.binding.bind(MicrophoneDeviceIdentity(uniqueID: "b", localizedName: "Same name"))
    ) {
      XCTAssertEqual($0 as? MicrophoneCaptureAdapterError, .inputDeviceChanged)
    }
    XCTAssertThrowsError(try hardware.binding.bind(nil)) {
      XCTAssertEqual($0 as? MicrophoneCaptureAdapterError, .inputDeviceUnavailable)
    }
  }

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
    let prepared = try controller.prepareSessionWithRequiredSources(
      title: "Microphone adapter proof", requiredSources: [.microphone])
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
    let prepared = try controller.prepareSessionWithRequiredSources(
      title: "96 kHz microphone proof", requiredSources: [.microphone])
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
    let prepared = try controller.prepareSessionWithRequiredSources(
      title: "One-shot adapter proof", requiredSources: [.microphone])
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

  func testStopPreservesEveryBufferAcceptedBeforeTheStopBoundary() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let writer = BlockingCapturedWriter()
    let adapter = MicrophoneCaptureAdapter(backend: backend, writer: writer)
    try adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    backend.emit(buffer, hostTime: 1)
    XCTAssertEqual(writer.writeEntered.wait(timeout: .now() + 1), .success)
    backend.emit(buffer, hostTime: 2)
    backend.emit(buffer, hostTime: 3)

    let stopped = expectation(description: "All accepted microphone buffers drained")
    DispatchQueue.global().async {
      XCTAssertEqual(adapter.stop(), 3)
      stopped.fulfill()
    }
    // Hold the first write while Stop closes admission and waits for the queue.
    XCTAssertEqual(backend.stopped.wait(timeout: .now() + 1), .success)
    writer.allowWrite.signal()
    wait(for: [stopped], timeout: 2)
    XCTAssertEqual(writer.writeCount, 3)
  }

  func testCallbackProgressIsObservableBeforeABlockedWriteWithoutBlockingTheCallback() throws {
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
    let observations = ObservationBox()
    let callbackObserved = expectation(description: "callback observation")
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: writer,
      identity: .testFixture(generation: 7),
      observationCadenceNanoseconds: 0
    )
    try adapter.start(
      onFirstSample: { _ in },
      onObservation: { observation in
        observations.append(observation)
        if observation.callbackCount == 1, observation.successfullyWrittenFrameCount == 0 {
          callbackObserved.fulfill()
        }
      },
      onFailure: { _ in }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64

    backend.emit(buffer, hostTime: 42_000)

    XCTAssertEqual(writer.writeEntered.wait(timeout: .now() + 1), .success)
    wait(for: [callbackObserved], timeout: 1)
    writer.allowWrite.signal()
    _ = adapter.stop()
  }

  func testSuccessfulWriteProgressIsObservedWithoutPretendingRustProjectionOccurred() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let observations = ObservationBox()
    let writeObserved = expectation(description: "write observation")
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: ProgressCapturedWriter(),
      identity: .testFixture(generation: 7),
      observationCadenceNanoseconds: 0
    )
    try adapter.start(
      onFirstSample: { _ in },
      onObservation: { observation in
        observations.append(observation)
        if observation.successfullyWrittenFrameCount == 64 {
          writeObserved.fulfill()
        }
      },
      onFailure: { _ in }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64

    backend.emit(buffer, hostTime: 42_000)

    wait(for: [writeObserved], timeout: 1)
    let latest = try XCTUnwrap(observations.snapshot().last)
    XCTAssertEqual(latest.identity.writerGeneration, 7)
    XCTAssertEqual(latest.callbackCount, 1)
    XCTAssertEqual(latest.successfullyWrittenFrameCount, 64)
    XCTAssertGreaterThan(latest.lastProgressMonotonicNanoseconds, 0)
    _ = adapter.stop()
  }

  func testAuthoritativeRouteInterruptionAndRecoveryRemainDistinctFromWriterFailure() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let observations = ObservationBox()
    let eventsObserved = expectation(description: "route events")
    eventsObserved.expectedFulfillmentCount = 2
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: ProgressCapturedWriter(),
      identity: .testFixture(generation: 7),
      observationCadenceNanoseconds: 0
    )
    try adapter.start(
      onFirstSample: { _ in },
      onObservation: { observation in
        observations.append(observation)
        if observation.event == .routeInterrupted || observation.event == .routeRecovered {
          eventsObserved.fulfill()
        }
      },
      onFailure: { _ in }
    )

    backend.emitRouteEvent(.interrupted)
    backend.emitRouteEvent(.recovered)

    wait(for: [eventsObserved], timeout: 1)
    XCTAssertEqual(
      observations.snapshot().map(\.event).filter { $0 != .progress },
      [.routeInterrupted, .routeRecovered]
    )
    _ = adapter.stop()
  }

  func testWriterThrowEmitsWriterFailedObservationBeforeTheExistingFailurePath() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let observations = ObservationBox()
    let writerFailureObserved = expectation(description: "writer failure observation")
    let failureReported = expectation(description: "existing failure path")
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: FailingCapturedWriter(),
      identity: .testFixture(generation: 7),
      observationCadenceNanoseconds: 0
    )
    try adapter.start(
      onFirstSample: { _ in },
      onObservation: { observation in
        observations.append(observation)
        if observation.event == .writerFailed {
          writerFailureObserved.fulfill()
        }
      },
      onFailure: { failure in
        XCTAssertEqual(failure, .writerFailed)
        failureReported.fulfill()
      }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64

    backend.emit(buffer, hostTime: 42_000)

    wait(for: [writerFailureObserved, failureReported], timeout: 1)
    let failureObservation = try XCTUnwrap(
      observations.snapshot().first { $0.event == .writerFailed }
    )
    XCTAssertEqual(failureObservation.identity.writerGeneration, 7)
    XCTAssertEqual(failureObservation.callbackCount, 1)
    XCTAssertEqual(failureObservation.successfullyWrittenFrameCount, 0)
    _ = adapter.stop()
  }

  func testStopDetachesRouteAndProgressObservationForTheOldGeneration() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let observations = ObservationBox()
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: ProgressCapturedWriter(),
      identity: .testFixture(generation: 7),
      observationCadenceNanoseconds: 0
    )
    try adapter.start(
      onFirstSample: { _ in },
      onObservation: { observations.append($0) },
      onFailure: { _ in }
    )
    _ = adapter.stop()
    let countAfterStop = observations.snapshot().count
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64

    backend.emit(buffer, hostTime: 50_000)
    backend.emitRouteEvent(.interrupted)
    Thread.sleep(forTimeInterval: 0.05)

    XCTAssertEqual(observations.snapshot().count, countAfterStop)
  }

  func testBlockingObservationConsumerNeverBlocksTheCaptureCallback() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let consumerEntered = DispatchSemaphore(value: 0)
    let releaseConsumer = DispatchSemaphore(value: 0)
    let callbackReturned = DispatchSemaphore(value: 0)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: ProgressCapturedWriter(),
      identity: .testFixture(generation: 7),
      observationCadenceNanoseconds: 0
    )
    try adapter.start(
      onFirstSample: { _ in },
      onObservation: { _ in
        consumerEntered.signal()
        releaseConsumer.wait()
      },
      onFailure: { _ in }
    )
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    let bufferBox = PCMBufferBox(buffer)

    DispatchQueue.global().async {
      backend.emit(bufferBox.value, hostTime: 42_000)
      callbackReturned.signal()
    }

    XCTAssertEqual(consumerEntered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(callbackReturned.wait(timeout: .now() + 0.1), .success)
    releaseConsumer.signal()
    _ = adapter.stop()
  }

  func testTelemetryRecordContainsOnlyContentFreeBoundedFields() {
    let observation = MicrophoneSourceHealthObservation(
      identity: .testFixture(generation: 7),
      sequence: 3,
      event: .routeInterrupted,
      callbackCount: 11,
      successfullyWrittenFrameCount: 512,
      lastProgressMonotonicNanoseconds: 42_000
    )

    let record = CaptureSourceHealthTelemetryRecord(
      observation: observation,
      rustSourceState: "active",
      visibleState: "capturing"
    )

    XCTAssertEqual(
      record.privacySafeMessage,
      "source=microphone generation=7 sequence=3 event=route_interrupted callbacks=11 written_frames=512 last_progress_uptime_ns=42000 rust_state=active visible_state=capturing"
    )
    XCTAssertFalse(record.privacySafeMessage.contains("/"))
    XCTAssertFalse(record.privacySafeMessage.localizedCaseInsensitiveContains("transcript"))
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

  func testProvisionalDraftWindowDefaultsAreTwelveSecondsWithTwoSecondOverlap() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false))
    let adapter = MicrophoneCaptureAdapter(
      backend: FakeMicrophoneBackend(inputFormat: format),
      writer: ProgressCapturedWriter()
    )
    adapter.installProvisionalDraftAdmission(
      preparation: NativeRecordingPreparation(noHandle: .init()))

    XCTAssertEqual(adapter.provisionalDraftWindowFrameCount(), 576_000)
    XCTAssertEqual(adapter.provisionalDraftOverlapFrameCount(), 96_000)
    XCTAssertEqual(
      ProvisionalDraftQueue.defaultWindowFrames / ProvisionalDraftQueue.captureSampleRate, 12)
    XCTAssertEqual(
      ProvisionalDraftQueue.defaultOverlapFrames / ProvisionalDraftQueue.captureSampleRate, 2)
    XCTAssertEqual(ProvisionalDraftQueue.maximumWindows, 2)
  }

  func testAcceptedAudioCommitsAProvisionalDraftThroughTheWriter() throws {
    let fixture = try openedMicrophone(title: "Live draft writer")
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in provisionalFixture("provisional meadow") },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()

    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: fixture.authorization.sessionId),
      ["provisional meadow"]
    )
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertGreaterThanOrEqual(try capturedLength(fixture.authorization), 480)
    _ = adapter.stop()
  }

  /// A later overlapping draft replaces the readable words while recording
  /// stays open. The earlier samples remain in the capture file.
  func testProvisionalTextCanChangeWithoutChangingCapturedAudio() throws {
    let fixture = try openedMicrophone(title: "Changing live draft")
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { start, _ in
        provisionalFixture(start == 0 ? "early meadow" : "later brook")
      },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    let sessionId = fixture.authorization.sessionId
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()

    XCTAssertEqual(
      try fixture.controller.recorderDetail(sessionId: sessionId).lifecycle, .recording)
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: sessionId), ["early meadow"])
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let firstReading = try labeledDraft(library, sessionId: sessionId)
    XCTAssertEqual(firstReading.map(\.effectiveText), ["early meadow"])
    XCTAssertEqual(firstReading.map(\.verbatimText), ["early meadow"])
    let preserved = try capturedSamples(fixture.authorization)
    XCTAssertGreaterThanOrEqual(preserved.count, 480)

    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 30)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()

    XCTAssertEqual(
      try fixture.controller.recorderDetail(sessionId: sessionId).lifecycle, .recording)
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: sessionId), ["later brook"])
    let changed = try labeledDraft(library, sessionId: sessionId)
    XCTAssertEqual(changed.map(\.effectiveText), ["later brook"])
    XCTAssertEqual(changed.map(\.verbatimText), ["later brook"])
    XCTAssertNotEqual(changed.map(\.revisionId), firstReading.map(\.revisionId))
    let kept = try capturedSamples(fixture.authorization)
    XCTAssertGreaterThan(kept.count, preserved.count)
    XCTAssertEqual(Array(kept.prefix(preserved.count)), preserved)
    XCTAssertTrue(failures.snapshot().isEmpty)
    _ = adapter.stop()
  }

  /// A saved later draft names itself as provisional and Play opens that
  /// interval. No speech model is installed. Final and corrected revisions are
  /// not created here.
  func testALaterDraftSeeksToItsAudioIntervalAndSaysDraft() async throws {
    let fixture = try openedMicrophone(title: "Draft seek")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    let anchor = mach_absolute_time()
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: anchor,
      numerator: timebase.numer,
      denominator: timebase.denom)
    let firstHost = anchor
    let rising = RisingSamples()
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { start, _ in
        provisionalFixture(start == 0 ? "early meadow" : "later brook")
      },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format,
      firstHostTime: firstHost)
    let sessionId = fixture.authorization.sessionId
    backend.emit(try rising.fill(fixture.format, 384), hostTime: firstHost &+ 1)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    backend.emit(
      try rising.fill(fixture.format, 384),
      hostTime: firstHost &+ AVAudioTime.hostTime(forSeconds: 0.01))
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: sessionId), ["later brook"])
    let stoppedAt = adapter.stop() ?? firstHost
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(
        finalSampleHostTime: max(stoppedAt, firstHost &+ AVAudioTime.hostTime(forSeconds: 0.02))))
    XCTAssertTrue(sealed.segmentSealed)
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let model = await MainActor.run { TranscriptLibraryModel(library: library) }
    await model.load(session: RuntimeSessionPresentation(native: saved))
    let passage = try await MainActor.run {
      try XCTUnwrap(model.segments.first { $0.effectiveText == "later brook" })
    }
    XCTAssertGreaterThan(passage.startNanoseconds, 0)
    XCTAssertEqual(passage.finality, .draft)
    XCTAssertFalse(passage.corrected)
    XCTAssertEqual(passage.verbatimText, "later brook")
    let spoken = ConversationControlLabels.passageAccessibility(
      speaker: passage.speakerLabel,
      text: passage.effectiveText,
      finality: passage.finality,
      corrected: passage.corrected,
      isPlaying: false,
      isCited: false)
    XCTAssertTrue(spoken.hasSuffix(" Draft."))
    XCTAssertFalse(spoken.contains("Corrected."))
    XCTAssertFalse(spoken.contains(" Final."))
    let stamp = await MainActor.run { TranscriptSection.timestamp(passage.startNanoseconds) }
    XCTAssertEqual(
      ConversationControlLabels.seekAccessibility(stamp: stamp, canSeek: true),
      "Play from \(stamp)")

    let timeline = try fixture.controller.playbackTimeline(sessionId: sessionId)
    let fromStart = try TimelinePCMReader(segments: timeline, startNanoseconds: 0)
    let sought = try TimelinePCMReader(
      segments: timeline, startNanoseconds: passage.startNanoseconds)
    XCTAssertEqual(sought.playbackStartNanoseconds, passage.startNanoseconds)
    let head = try XCTUnwrap(fromStart.read(maximumFrames: 1))
    let jumped = try XCTUnwrap(sought.read(maximumFrames: 1))
    let headSample = try XCTUnwrap(head.floatChannelData?[0][0])
    let jumpedSample = try XCTUnwrap(jumped.floatChannelData?[0][0])
    XCTAssertNotEqual(headSample, jumpedSample)
    fromStart.close()
    sought.close()

    let preparation = fixture.controller
    let playback = await MainActor.run {
      RecoveredSessionController(
        recoveryFactory: { preparation },
        player: RecoveredAudioPlayerFake(),
        timelineProvider: { _ in try preparation.playbackTimeline(sessionId: sessionId) }
      )
    }
    await MainActor.run {
      playback.playSynchronized(
        sessionId: sessionId, startNanoseconds: passage.startNanoseconds)
    }
    var opened: Int64?
    var playbackError: String?
    for _ in 0..<100 {
      let observation = await MainActor.run {
        (playback.timelinePlayer.lastOpenedStartNanoseconds, playback.errorMessage)
      }
      opened = observation.0
      playbackError = observation.1
      if opened != nil || playbackError != nil { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    await MainActor.run { playback.stopPlayback() }
    XCTAssertNil(playbackError)
    XCTAssertEqual(opened, passage.startNanoseconds)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    XCTAssertTrue(failures.snapshot().isEmpty)
  }

  func testARejectedDraftDoesNotStopCaptureOrInventText() throws {
    let fixture = try openedMicrophone(title: "Rejected live draft")
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in provisionalFixture("not stored", digest: "not-a-digest") },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    backend.emit(try microphoneFrames(fixture.format, 96), hostTime: 30)
    adapter.waitForAcceptedAudio()

    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: fixture.authorization.sessionId),
      []
    )
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertGreaterThanOrEqual(try capturedLength(fixture.authorization), 576)
    _ = adapter.stop()
  }

  func testNilHypothesisDoesNotInventProvisionalText() throws {
    let fixture = try openedMicrophone(title: "No live recognizer")
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: nil,
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()

    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: fixture.authorization.sessionId),
      []
    )
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertGreaterThanOrEqual(try capturedLength(fixture.authorization), 480)
    _ = adapter.stop()
  }

  /// A saved recording with no speech model has the same empty transcript,
  /// search, and correction posture an untranscribed import uses. The source
  /// default is the microphone's own label.
  func testAnUntranscribedRecordingMatchesTheImportedReviewPosture() async throws {
    let fixture = try openedMicrophone(title: "Untranscribed recording")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: mach_absolute_time(),
      numerator: timebase.numer,
      denominator: timebase.denom)
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: nil,
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    let stoppedAt = adapter.stop() ?? 20
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(finalSampleHostTime: max(stoppedAt, 20)))
    XCTAssertTrue(sealed.segmentSealed)
    let sessionId = fixture.authorization.sessionId
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let model = await MainActor.run { TranscriptLibraryModel(library: library) }
    await model.load(session: RuntimeSessionPresentation(native: saved))
    let posture = await MainActor.run {
      (
        model.availability, model.availabilityText, model.speakerDiarizationText,
        model.speakers.first?.label, model.segments.map(\.effectiveText), model.message
      )
    }
    XCTAssertEqual(posture.0, .unavailable)
    XCTAssertEqual(posture.1, "No transcript yet.")
    XCTAssertEqual(posture.1, TranscriptLibraryModel.text(for: .unavailable))
    XCTAssertEqual(
      posture.2,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    XCTAssertEqual(posture.3, "You")
    XCTAssertEqual(posture.4, [])
    XCTAssertNil(posture.5)
    let decision = try library.prepareSpeakerDiarization(sessionId: sessionId)
    XCTAssertEqual(decision.clusteringState, "unavailable")
    XCTAssertEqual(decision.reason, "no calibrated diarization model")
    XCTAssertEqual(decision.tracks.first?.labelOrigin, .sourceDefault)
    let hits = try library.search(query: "brook", sessionId: sessionId, limit: 20)
    XCTAssertTrue(hits.isEmpty)
    do {
      _ = try library.correctSegment(
        sessionId: sessionId, revisionId: "missing-revision", sequence: 0, text: "changed words")
      XCTFail("a recording without a final transcript accepted a correction")
    } catch {}
    let trackId = try await MainActor.run { try XCTUnwrap(model.speakers.first?.trackId) }
    let renamed = await model.renameSpeaker(trackId: trackId, label: " Dana ")
    let cleared = await model.renameSpeaker(trackId: trackId, label: nil)
    XCTAssertTrue(renamed)
    XCTAssertTrue(cleared)
    let restored = await MainActor.run { model.speakers.first?.label }
    XCTAssertEqual(restored, "You")
    let markdown = fixture.root.appendingPathComponent("Transcript.md")
    let wroteTranscript = await model.export(format: .markdown, to: markdown)
    let exportMessage = await MainActor.run { model.message }
    XCTAssertTrue(wroteTranscript, exportMessage ?? "")
    XCTAssertGreaterThan(try Data(contentsOf: markdown).count, 0)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    XCTAssertTrue(failures.snapshot().isEmpty)
  }

  /// Silence stays in the capture file. A window that is only silence does not
  /// become transcript text, and it does not journal source loss.
  func testQuietIntervalStaysOnTheCaptureTimelineWithoutInventingSpeech() throws {
    let fixture = try openedMicrophone(title: "Quiet interval")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    let anchor = mach_absolute_time()
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: anchor,
      numerator: timebase.numer,
      denominator: timebase.denom)
    let speechHost = anchor + AVAudioTime.hostTime(forSeconds: 0.02)
    let quietHost = anchor + AVAudioTime.hostTime(forSeconds: 0.04)
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { start, _ in provisionalFixture("spoken \(start)") },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format,
      firstHostTime: speechHost)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: speechHost &+ 1)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    backend.emit(try silentMicrophoneFrames(fixture.format, 768), hostTime: quietHost)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()

    let sessionId = fixture.authorization.sessionId
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: sessionId),
      ["spoken 8000000"])
    let detail = try fixture.controller.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, .recording)
    XCTAssertFalse(detail.events.contains { $0.kind == .sourceFailed })
    let current = try XCTUnwrap(fixture.controller.runtimeLibrarySnapshot().currentSession)
    XCTAssertEqual(current.sessionId, sessionId)
    XCTAssertEqual(current.lifecycle, .recording)
    XCTAssertNil(current.interruptionReason)
    XCTAssertTrue(current.hasCaptureTimeline)
    let microphone = try XCTUnwrap(current.sources.first { $0.kind == .microphone })
    XCTAssertEqual(microphone.lifecycle, .capturing)
    XCTAssertTrue(failures.snapshot().isEmpty)
    try assertQuietInterval(in: fixture.authorization, speechFrames: 480, quietFrames: 768)

    let stoppedAt = adapter.stop() ?? quietHost
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(finalSampleHostTime: max(stoppedAt, quietHost)))
    XCTAssertTrue(sealed.segmentSealed)
    let savedDetail = try fixture.controller.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(savedDetail.lifecycle, .readyForReview)
    XCTAssertFalse(savedDetail.events.contains { $0.kind == .sourceFailed })
    let plan = try fixture.controller.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 1)
    let segment = try XCTUnwrap(plan.first)
    XCTAssertEqual(segment.sampleCount, 1_248)
    XCTAssertEqual(segment.gapNanoseconds, 0)
    XCTAssertEqual(segment.channels, 1)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    XCTAssertTrue(saved.hasCaptureTimeline)
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: sessionId),
      ["spoken 8000000"])
    try assertQuietInterval(in: fixture.authorization, speechFrames: 480, quietFrames: 768)
  }

  func testAThirdProvisionalWindowDropsTheOldestPendingOneAndKeepsAudio() throws {
    let fixture = try openedMicrophone(title: "Bounded live draft")
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    let blocker = BlockingDraftHypothesis()
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in blocker.next() },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    XCTAssertEqual(blocker.entered.wait(timeout: .now() + 2), .success)
    backend.emit(try microphoneFrames(fixture.format, 768), hostTime: 30)
    adapter.waitForAcceptedAudio()
    blocker.allow.signal()
    adapter.waitForProvisionalDraftAdmission()

    XCTAssertEqual(blocker.callCount, 2)
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: fixture.authorization.sessionId),
      ["provisional meadow", "later brook"]
    )
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertGreaterThanOrEqual(try capturedLength(fixture.authorization), 1_248)
    _ = adapter.stop()
  }

  /// Transcription stays on the utility queue. A live recording keeps accepting
  /// audio, then the transcription yields without changing either recording.
  func testCaptureKeepsAcceptingAudioWhileTranscriptionIsSlow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "open-scribe-capture-priority-\(UUID().uuidString)", isDirectory: true)
    managedRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let source = root.appendingPathComponent("existing.caf")
    let sourceFile = try AVAudioFile(
      forWriting: source,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ],
      commonFormat: .pcmFormatInt16,
      interleaved: true)
    let sourceBuffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: 4_800))
    sourceBuffer.frameLength = 4_800
    sourceBuffer.int16ChannelData?[0].initialize(repeating: 1, count: 4_800)
    try sourceFile.write(from: sourceBuffer)
    let original = try Data(contentsOf: source)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let controller = try NativeRecordingPreparation.open(managedRoot: library.path)
    let imported = try controller.importRecoverableCaf(title: "Existing review", sourcePath: source.path)
    let captureIsActive = CaptureActivity()
    let slow = SlowTranscription()
    let job = NativeTranscriptionJob()
    let defaults = UserDefaults(suiteName: "OpenScribe.Proof.CapturePriority.\(UUID().uuidString)")!
    let coordinator = try NativeWorkCoordinator.open(managedRoot: library.path)
    let scheduler = await MainActor.run {
      TranscriptionScheduler(
        coordinator: coordinator,
        runner: { _ in await slow.run(job) },
        observations: {
          NativeWorkObservations(
            automatic: true, paused: false, captureActive: captureIsActive.value,
            mediaRecoveryPending: false, model: .ready, availableDiskBytes: nil,
            memoryCritical: false, thermalCritical: false)
        },
        stop: { preempt in
          if preempt {
            job.preemptForCapture()
          } else {
            job.cancel()
          }
        },
        defaults: defaults)
    }
    await MainActor.run { scheduler.reconsider() }
    let entered = await slow.waitUntilEntered()
    XCTAssertTrue(entered, "transcription did not enter its slow work")
    XCTAssertFalse(job.isCancelled())

    let prepared = try controller.prepareSessionWithRequiredSources(

      title: "Live while transcribing", requiredSources: [.microphone])
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone")
    let writer = try ManagedCAFWriter(authorization: authorization)
    let opened = try controller.acceptMediaOpen(receipt: writer.receipt())
    XCTAssertTrue(opened.journalDurable)
    XCTAssertTrue(opened.mediaFilesOpen)
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false))
    let backend = FakeMicrophoneBackend(inputFormat: format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend, writer: writer,
      identity: MicrophoneCaptureIdentity(authorization: authorization))
    let receipts = ReceiptBox()
    let failures = FailureBox()
    let firstSample = DispatchSemaphore(value: 0)
    try adapter.start(
      onFirstSample: { receipt in
        receipts.append(receipt)
        firstSample.signal()
      },
      onFailure: { failures.append($0) })
    backend.emit(try microphoneFrames(format, 96), hostTime: 10)
    XCTAssertEqual(firstSample.wait(timeout: .now() + 2), .success)
    let evidence = try controller.acceptFirstSample(
      receipt: try XCTUnwrap(receipts.snapshot().first))
    XCTAssertTrue(evidence.firstSampleDurable)
    let started = try controller.confirmRecording(sessionId: evidence.sessionId)
    XCTAssertTrue(started.recordingStarted)
    backend.emit(try microphoneFrames(format, 4_096), hostTime: 20)
    adapter.waitForAcceptedAudio()
    let lengthWhileSlow = try capturedLength(authorization)
    XCTAssertGreaterThanOrEqual(lengthWhileSlow, 4_192)
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertFalse(job.isCancelled())
    XCTAssertEqual(
      try controller.recorderDetail(sessionId: evidence.sessionId).lifecycle, .recording)
    XCTAssertEqual(try Data(contentsOf: source), original)

    await MainActor.run {
      captureIsActive.set(true)
      scheduler.reconsider()
    }
    var yielded = false
    for _ in 0..<200 {
      let paused = await MainActor.run {
        scheduler.runningSessionId == nil && scheduler.hold == .recordingInProgress
          && scheduler.queue.contains { $0.sessionId == imported.sessionId }
      }
      if paused {
        yielded = true
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(yielded, "slow transcription did not yield to the recording")
    XCTAssertTrue(job.isCancelled())
    XCTAssertEqual(job.stopOutcome(), .capturePreempted)
    backend.emit(try microphoneFrames(format, 4_096), hostTime: 30)
    adapter.waitForAcceptedAudio()
    XCTAssertGreaterThan(try capturedLength(authorization), lengthWhileSlow)
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertEqual(
      try controller.recorderDetail(sessionId: evidence.sessionId).lifecycle, .recording)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let managedCopy = library
      .appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(imported.sessionId, isDirectory: true)
      .appendingPathComponent(imported.relativePath)
    XCTAssertEqual(try Data(contentsOf: managedCopy), original)
    _ = adapter.stop()
    withExtendedLifetime(scheduler) {}
  }

  func testReviewInspectsStoredModelProvenanceWithoutClaimingIdenticalOutput() async throws {
    let fixture = try openedMicrophone(title: "Provenance review")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: mach_absolute_time(),
      numerator: timebase.numer,
      denominator: timebase.denom)
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    let digest = String(repeating: "a", count: 64)
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in provisionalFixture("provisional meadow", digest: digest) },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    XCTAssertEqual(
      try fixture.controller.readableDraftTexts(sessionId: fixture.authorization.sessionId),
      ["provisional meadow"])
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    XCTAssertGreaterThanOrEqual(try capturedLength(fixture.authorization), 480)
    let stoppedAt = adapter.stop() ?? 20
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(finalSampleHostTime: max(stoppedAt, 20)))
    XCTAssertTrue(sealed.segmentSealed)
    XCTAssertFalse(sealed.recordingStarted)
    XCTAssertEqual(
      try fixture.controller.recorderDetail(sessionId: fixture.authorization.sessionId).lifecycle,
      .readyForReview)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == fixture.authorization.sessionId
      })
    XCTAssertTrue(saved.hasCaptureTimeline)
    let presentation = RuntimeSessionPresentation(native: saved)
    XCTAssertNil(presentation.transcriptionUnavailableReason)
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let inspected = try library.inspectProvenance(sessionId: fixture.authorization.sessionId)
    XCTAssertEqual(inspected.count, 1)
    let item = try XCTUnwrap(inspected.first)
    XCTAssertEqual(item.engine, "fixture-engine")
    XCTAssertEqual(item.engineVersion, "1")
    XCTAssertEqual(item.modelId, "fixture-model")
    XCTAssertEqual(item.modelSha256, digest)
    XCTAssertEqual(item.inputDigest, "live-unsealed")
    XCTAssertEqual(item.runState, .complete)
    XCTAssertEqual(item.finality, .draft)
    XCTAssertEqual(
      item.ranges,
      [NativeTranscriptProvenanceRange(startNanoseconds: 0, endNanoseconds: 10_000_000)])
    let model = await MainActor.run { TranscriptLibraryModel(library: library) }
    await model.load(session: presentation)
    let review = await MainActor.run {
      (
        model.message, model.messageIsFailure, model.provenance, model.provenanceText,
        model.segments.map(\.effectiveText)
      )
    }
    XCTAssertNil(review.0)
    XCTAssertFalse(review.1)
    XCTAssertEqual(review.2, inspected)
    let text = try XCTUnwrap(review.3)
    XCTAssertEqual(text, TranscriptLibraryModel.provenanceText(for: inspected))
    XCTAssertTrue(text.contains("Engine fixture-engine 1."))
    XCTAssertTrue(text.contains("Model fixture-model, revision \(digest)."))
    XCTAssertTrue(text.contains("Input live-unsealed."))
    XCTAssertTrue(text.contains("Run complete."))
    XCTAssertTrue(text.contains("Finality draft."))
    XCTAssertTrue(text.contains("Evidence 0-10000000 ns."))
    XCTAssertTrue(
      text.hasSuffix(
        "Open Scribe does not claim that running this model again produces the same words."))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("identical"))
    XCTAssertFalse(text.localizedCaseInsensitiveContains("deterministic"))
    XCTAssertEqual(review.4, ["provisional meadow"])
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
  }

  /// The transcript section shows the stored run. The test reads that field.
  /// It does not call `load` or `provenanceText`.
  @MainActor
  func testHostedReviewReadsModelProvenanceWithoutClaimingIdenticalOutput() async throws {
    let fixture = try openedMicrophone(title: "Hosted provenance")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: mach_absolute_time(),
      numerator: timebase.numer,
      denominator: timebase.denom)
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    let digest = String(repeating: "b", count: 64)
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in provisionalFixture("provisional meadow", digest: digest) },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    let stoppedAt = adapter.stop() ?? 20
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(finalSampleHostTime: max(stoppedAt, 20)))
    XCTAssertTrue(sealed.segmentSealed)
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == fixture.authorization.sessionId
      })
    let presentation = RuntimeSessionPresentation(native: saved)
    XCTAssertNil(presentation.transcriptionUnavailableReason)
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let inspected = try library.inspectProvenance(sessionId: fixture.authorization.sessionId)
    let item = try XCTUnwrap(inspected.first)
    let evidence = try XCTUnwrap(item.ranges.first)

    let model = TranscriptLibraryModel(library: library)
    let section = TranscriptSection(
      session: presentation,
      transcripts: model,
      speech: SpeechTranscriptionModel(preview: []),
      scheduler: TranscriptionScheduler.inert(),
      canSeek: false,
      onSeek: { _ in }
    ).frame(width: 720, height: 420)
    let host = NSHostingView(rootView: section)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 720, height: 420))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }

    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      guard let field = self.provenanceField(in: host) else { return false }
      return !field.isHidden && field.frame.width > 1 && field.frame.height > 1
        && field.stringValue.contains("does not claim")
        && field.isDescendant(of: host)
    }
    let field = try XCTUnwrap(self.provenanceField(in: host))
    XCTAssertTrue(shown && window.contentView === host && field.isDescendant(of: host))
    let visible = field.stringValue
    XCTAssertTrue(visible.contains("Engine \(item.engine) \(item.engineVersion)."))
    XCTAssertTrue(visible.contains("Model \(item.modelId), revision \(item.modelSha256)."))
    XCTAssertEqual(item.modelSha256, digest)
    XCTAssertTrue(visible.contains("Input \(item.inputDigest)."))
    XCTAssertTrue(visible.contains("Run \(item.runState)."))
    XCTAssertTrue(visible.contains("Finality \(item.finality)."))
    XCTAssertTrue(
      visible.contains("Evidence \(evidence.startNanoseconds)-\(evidence.endNanoseconds) ns."))
    XCTAssertTrue(
      visible.hasSuffix(
        "Open Scribe does not claim that running this model again produces the same words."))
    XCTAssertFalse(visible.localizedCaseInsensitiveContains("identical"))
    XCTAssertFalse(visible.localizedCaseInsensitiveContains("deterministic"))
    XCTAssertFalse(visible.contains("provisional meadow"))
    XCTAssertTrue(failures.snapshot().isEmpty)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    withExtendedLifetime(model) {}
    withExtendedLifetime(adapter) {}
  }

  /// A saved capture already has a later draft on its timeline. The conversation
  /// view's Play control opens that interval. The test does not call
  /// `playSynchronized` or `load`.
  @MainActor
  func testHostedCaptureTimelineSeekOpensTheDraftInterval() async throws {
    let fixture = try openedMicrophone(title: "Hosted draft seek")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    let anchor = mach_absolute_time()
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: anchor,
      numerator: timebase.numer,
      denominator: timebase.denom)
    let firstHost = anchor
    let rising = RisingSamples()
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { start, _ in
        provisionalFixture(start == 0 ? "early meadow" : "later brook")
      },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format,
      firstHostTime: firstHost)
    let sessionId = fixture.authorization.sessionId
    backend.emit(try rising.fill(fixture.format, 384), hostTime: firstHost &+ 1)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    backend.emit(
      try rising.fill(fixture.format, 384),
      hostTime: firstHost &+ AVAudioTime.hostTime(forSeconds: 0.01))
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    let stoppedAt = adapter.stop() ?? firstHost
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(
        finalSampleHostTime: max(stoppedAt, firstHost &+ AVAudioTime.hostTime(forSeconds: 0.02))))
    XCTAssertTrue(sealed.segmentSealed)
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let presentation = RuntimeSessionPresentation(native: saved)
    XCTAssertEqual(presentation.lifecycle, .readyForReview)
    XCTAssertTrue(presentation.hasCaptureTimeline)
    let preparation = fixture.controller
    let playback = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: RecoveredAudioPlayerFake(),
      timelineProvider: { _ in try preparation.playbackTimeline(sessionId: sessionId) }
    )
    let transcripts = TranscriptLibraryModel(
      library: try NativeTranscriptLibrary.open(managedRoot: fixture.root.path))
    let store = RuntimeLibraryStore(managedRoot: fixture.root)
    let workspace = ConversationWorkspaceView(
      session: presentation,
      store: store,
      playbackController: playback,
      transcripts: transcripts,
      speech: SpeechTranscriptionModel(preview: []),
      scheduler: TranscriptionScheduler.inert(),
      reference: nil,
      audioReviewRequest: nil,
      canStartNewRecording: false,
      newRecordingUnavailableReason: "A recording is already saved.",
      onStartNewRecording: {},
      loadRecorderEvents: { _ in [] }
    )
    let host = NSHostingView(rootView: workspace)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 1400))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.seekButton(containing: "Play from", in: host) != nil
        && transcripts.segments.contains { $0.effectiveText == "later brook" }
    }
    let button = try XCTUnwrap(self.seekButton(containing: "Play from", in: host))
    let passage = try XCTUnwrap(transcripts.segments.first { $0.effectiveText == "later brook" })
    XCTAssertTrue(shown && window.contentView === host && button.isDescendant(of: host))
    XCTAssertGreaterThan(passage.startNanoseconds, 0)
    XCTAssertEqual(passage.finality, .draft)
    XCTAssertTrue(button.accessibilityLabel()?.contains("Draft") == true)
    button.performClick(nil)
    let opened = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      playback.timelinePlayer.lastOpenedStartNanoseconds == passage.startNanoseconds
    }
    XCTAssertTrue(opened, playback.errorMessage ?? "timeline did not open")
    XCTAssertNil(playback.errorMessage)
    XCTAssertEqual(playback.playingSessionId, sessionId)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    XCTAssertTrue(failures.snapshot().isEmpty)
    playback.stopPlayback()
    withExtendedLifetime(store) {}
    withExtendedLifetime(transcripts) {}
    withExtendedLifetime(playback) {}
    withExtendedLifetime(adapter) {}
  }

  /// A marker written during capture stays on the session clock. Playing it
  /// from the saved conversation opens that time and leaves the audio in place.
  @MainActor
  func testHostedSavedMarkerPlaysFromItsTime() async throws {
    let fixture = try openedMicrophone(title: "Hosted marker seek")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    let anchor = mach_absolute_time()
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: anchor,
      numerator: timebase.numer,
      denominator: timebase.denom)
    let firstHost = anchor
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format,
      firstHostTime: firstHost)
    let sessionId = fixture.authorization.sessionId
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: firstHost &+ 1)
    adapter.waitForAcceptedAudio()
    backend.emit(
      try microphoneFrames(fixture.format, 384),
      hostTime: firstHost &+ AVAudioTime.hostTime(forSeconds: 0.01))
    adapter.waitForAcceptedAudio()
    XCTAssertEqual(
      try fixture.controller.recorderDetail(sessionId: sessionId).lifecycle, .recording)
    let markerHost = firstHost &+ AVAudioTime.hostTime(forSeconds: 0.005)
    let marked = try fixture.controller.recorderAction(
      sessionId: sessionId,
      action: .marker(hostTime: markerHost, label: "Decision"))
    let marker = try XCTUnwrap(marked.events.last { $0.kind == .markerAdded })
    XCTAssertEqual(marker.label, "Decision")
    XCTAssertGreaterThan(marker.sessionNanoseconds, 0)
    XCTAssertLessThan(marker.sessionNanoseconds, 20_000_000)
    let stoppedAt = adapter.stop() ?? markerHost
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(
        finalSampleHostTime: max(stoppedAt, firstHost &+ AVAudioTime.hostTime(forSeconds: 0.02))))
    XCTAssertTrue(sealed.segmentSealed)
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let persisted = try fixture.controller.recorderDetail(sessionId: sessionId).events.filter {
      $0.kind == .markerAdded
    }
    XCTAssertEqual(persisted.map(\.label), ["Decision"])
    XCTAssertEqual(persisted.map(\.sessionNanoseconds), [marker.sessionNanoseconds])
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let presentation = RuntimeSessionPresentation(native: saved)
    XCTAssertEqual(presentation.lifecycle, .readyForReview)
    XCTAssertTrue(presentation.hasCaptureTimeline)
    let preparation = fixture.controller
    let playback = RecoveredSessionController(
      recoveryFactory: { preparation },
      player: RecoveredAudioPlayerFake(),
      timelineProvider: { _ in try preparation.playbackTimeline(sessionId: sessionId) }
    )
    let transcripts = TranscriptLibraryModel(
      library: try NativeTranscriptLibrary.open(managedRoot: fixture.root.path))
    let store = RuntimeLibraryStore(managedRoot: fixture.root)
    let preferences = UserDefaults(
      suiteName: "OpenScribe.Proof.MarkerSeek.\(UUID().uuidString)")!
    let workspace = ConversationWorkspaceView(
      session: presentation,
      store: store,
      playbackController: playback,
      transcripts: transcripts,
      speech: SpeechTranscriptionModel(preview: []),
      scheduler: TranscriptionScheduler.inert(),
      reference: nil,
      audioReviewRequest: nil,
      canStartNewRecording: false,
      newRecordingUnavailableReason: "A recording is already saved.",
      onStartNewRecording: {},
      loadRecorderEvents: { sessionId in
        (try? preparation.recorderDetail(sessionId: sessionId).events) ?? []
      }
    )
    .defaultAppStorage(preferences)
    let host = NSHostingView(rootView: workspace)
    host.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(NSSize(width: 1100, height: 1400))
    host.frame = window.contentLayoutRect
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    defer { window.close() }
    let stamp = TranscriptSection.timestamp(marker.sessionNanoseconds)
    let markerLabel = ConversationControlLabels.markerAccessibility(
      stamp: stamp, label: "Decision", canSeek: true)
    let shown = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      return self.seekButton(containing: "Marker, Decision", in: host) != nil
    }
    let button = try XCTUnwrap(self.seekButton(containing: "Marker, Decision", in: host))
    XCTAssertTrue(shown && window.contentView === host && button.isDescendant(of: host))
    XCTAssertEqual(button.accessibilityLabel(), markerLabel)
    XCTAssertTrue(button.isEnabled)
    button.performClick(nil)
    let opened = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
      guard let started = playback.timelinePlayer.lastOpenedStartNanoseconds else { return false }
      let delta = abs(started - marker.sessionNanoseconds)
      return delta <= 1_000_000
    }
    XCTAssertTrue(opened, playback.errorMessage ?? "marker did not open playback")
    XCTAssertNil(playback.errorMessage)
    XCTAssertEqual(playback.playingSessionId, sessionId)
    let started = try XCTUnwrap(playback.timelinePlayer.lastOpenedStartNanoseconds)
    XCTAssertLessThanOrEqual(abs(started - marker.sessionNanoseconds), 1_000_000)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    XCTAssertEqual(
      try preparation.recorderDetail(sessionId: sessionId).events.filter { $0.kind == .markerAdded }
        .map(\.label),
      ["Decision"])
    XCTAssertTrue(failures.snapshot().isEmpty)
    playback.stopPlayback()
    withExtendedLifetime(store) {}
    withExtendedLifetime(transcripts) {}
    withExtendedLifetime(playback) {}
    withExtendedLifetime(adapter) {}
    withExtendedLifetime(preferences) {}
  }

  /// A saved draft stays readable when voice clustering cannot name the speaker.
  /// The user's source-speaker name leaves the words, the transcript run, and the capture file in place.
  func testManualSpeakerReviewKeepsTheReadableDraftWhenClusteringIsUnavailable() async throws {
    let fixture = try openedMicrophone(title: "Speaker review")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: mach_absolute_time(),
      numerator: timebase.numer,
      denominator: timebase.denom)
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in provisionalFixture("provisional meadow") },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    let stoppedAt = adapter.stop() ?? 20
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(finalSampleHostTime: max(stoppedAt, 20)))
    XCTAssertTrue(sealed.segmentSealed)
    let sessionId = fixture.authorization.sessionId
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let presentation = RuntimeSessionPresentation(native: saved)
    XCTAssertNil(presentation.transcriptionUnavailableReason)
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let model = await MainActor.run { TranscriptLibraryModel(library: library) }
    await model.load(session: presentation)
    let before = await MainActor.run {
      (
        model.availability, model.availabilityText, model.speakerDiarizationText,
        model.speakers, model.segments, model.message, model.messageIsFailure
      )
    }
    XCTAssertEqual(before.0, .draft)
    XCTAssertEqual(before.1, "Draft — the final transcript isn't finished yet")
    XCTAssertEqual(
      before.2,
      "Speakers follow the audio source. Voice diarization is unavailable without a calibrated model."
    )
    let speaker = try XCTUnwrap(before.3.first)
    XCTAssertEqual(speaker.sourceKind, .microphone)
    XCTAssertEqual(speaker.label, "You")
    XCTAssertFalse(speaker.namedByUser)
    let passage = try XCTUnwrap(before.4.first)
    XCTAssertEqual(before.4.map(\.effectiveText), ["provisional meadow"])
    XCTAssertEqual(before.4.map(\.verbatimText), ["provisional meadow"])
    XCTAssertEqual(passage.finality, .draft)
    XCTAssertEqual(passage.speakerLabel, "You")
    XCTAssertFalse(passage.speakerNamedByUser)
    XCTAssertFalse(passage.corrected)
    XCTAssertNil(before.5)
    XCTAssertFalse(before.6)
    let decision = try library.prepareSpeakerDiarization(sessionId: sessionId)
    XCTAssertFalse(decision.inserted)
    XCTAssertEqual(decision.clusteringState, "unavailable")
    XCTAssertEqual(decision.reason, "no calibrated diarization model")
    XCTAssertEqual(decision.tracks.count, 1)
    XCTAssertEqual(decision.tracks[0].sourceKind, .microphone)
    XCTAssertEqual(decision.tracks[0].disposition, .topology)
    XCTAssertEqual(decision.tracks[0].label, "You")
    XCTAssertEqual(decision.tracks[0].labelOrigin, .sourceDefault)
    let provenance = try library.inspectProvenance(sessionId: sessionId)
    XCTAssertEqual(provenance.map(\.revisionId), [passage.revisionId])
    XCTAssertEqual(provenance.map(\.finality), [.draft])
    let detail = try fixture.controller.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, .readyForReview)
    XCTAssertFalse(detail.events.contains { $0.kind == .sourceFailed })
    let sessions = try fixture.controller.runtimeLibrarySnapshot().savedSessions.map(\.sessionId)

    let renamed = await model.renameSpeaker(trackId: speaker.trackId, label: " Dana ")
    let after = await MainActor.run {
      (
        model.availability, model.availabilityText, model.speakerDiarizationText,
        model.speakers, model.segments, model.message, model.messageIsFailure
      )
    }
    XCTAssertTrue(renamed)
    XCTAssertNil(after.5)
    XCTAssertFalse(after.6)
    XCTAssertEqual(after.0, .draft)
    XCTAssertEqual(after.1, before.1)
    XCTAssertEqual(after.2, before.2)
    XCTAssertEqual(after.4.map(\.revisionId), [passage.revisionId])
    XCTAssertEqual(after.4.map(\.effectiveText), ["provisional meadow"])
    XCTAssertEqual(after.4.map(\.verbatimText), ["provisional meadow"])
    XCTAssertEqual(after.4.map(\.finality), [.draft])
    XCTAssertEqual(after.4.map(\.corrected), [false])
    XCTAssertEqual(after.4.first?.speakerLabel, "Dana")
    XCTAssertEqual(after.4.first?.speakerNamedByUser, true)
    XCTAssertEqual(after.3.first?.trackId, speaker.trackId)
    XCTAssertEqual(after.3.first?.label, "Dana")
    XCTAssertEqual(after.3.first?.namedByUser, true)
    XCTAssertEqual(after.3.first?.sourceKind, .microphone)
    let reviewed = try library.prepareSpeakerDiarization(sessionId: sessionId)
    XCTAssertFalse(reviewed.inserted)
    XCTAssertNotEqual(reviewed.runId, decision.runId)
    XCTAssertEqual(reviewed.clusteringState, "unavailable")
    XCTAssertEqual(reviewed.reason, "no calibrated diarization model")
    XCTAssertEqual(reviewed.tracks[0].disposition, .topology)
    XCTAssertEqual(reviewed.tracks[0].label, "Dana")
    XCTAssertEqual(reviewed.tracks[0].labelOrigin, .human)
    XCTAssertEqual(try library.inspectProvenance(sessionId: sessionId), provenance)
    let savedDetail = try fixture.controller.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(savedDetail.lifecycle, .readyForReview)
    XCTAssertFalse(savedDetail.events.contains { $0.kind == .sourceFailed })
    XCTAssertEqual(
      try fixture.controller.runtimeLibrarySnapshot().savedSessions.map(\.sessionId), sessions)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    XCTAssertTrue(failures.snapshot().isEmpty)
  }

  /// Renaming updates the reviewed label. Clearing the name restores the
  /// source default. Each stored name remains in the history. The draft and
  /// the capture file stay put. Merge and split are not available while
  /// clustering is unavailable.
  func testRenamingASpeakerRestoresTheSourceDefaultWithoutChangingTheDraft() async throws {
    let fixture = try openedMicrophone(title: "Speaker rename restore")
    var timebase = mach_timebase_info_data_t()
    XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
    try fixture.controller.anchorCaptureClock(
      sessionId: fixture.authorization.sessionId,
      hostAnchor: mach_absolute_time(),
      numerator: timebase.numer,
      denominator: timebase.denom)
    let backend = FakeMicrophoneBackend(inputFormat: fixture.format)
    let adapter = MicrophoneCaptureAdapter(
      backend: backend,
      writer: fixture.writer,
      identity: MicrophoneCaptureIdentity(authorization: fixture.authorization)
    )
    adapter.installProvisionalDraftAdmission(
      preparation: fixture.controller,
      hypothesis: { _, _ in provisionalFixture("provisional meadow") },
      windowFrames: 480,
      overlapFrames: 96
    )
    let failures = try startAndConfirm(
      adapter: adapter, backend: backend, controller: fixture.controller, format: fixture.format)
    backend.emit(try microphoneFrames(fixture.format, 384), hostTime: 20)
    adapter.waitForAcceptedAudio()
    adapter.waitForProvisionalDraftAdmission()
    let stoppedAt = adapter.stop() ?? 20
    let sealed = try fixture.controller.sealSegment(
      receipt: try fixture.writer.sealSegmentReceipt(finalSampleHostTime: max(stoppedAt, 20)))
    XCTAssertTrue(sealed.segmentSealed)
    let sessionId = fixture.authorization.sessionId
    let mediaURL = URL(fileURLWithPath: fixture.authorization.absolutePath)
    let sealedMedia = try Data(contentsOf: mediaURL)
    let saved = try XCTUnwrap(
      fixture.controller.runtimeLibrarySnapshot().savedSessions.first { $0.sessionId == sessionId })
    let library = try NativeTranscriptLibrary.open(managedRoot: fixture.root.path)
    let model = await MainActor.run { TranscriptLibraryModel(library: library) }
    await model.load(session: RuntimeSessionPresentation(native: saved))
    let speaker = try await MainActor.run { try XCTUnwrap(model.speakers.first) }
    XCTAssertEqual(speaker.label, "You")
    XCTAssertFalse(speaker.namedByUser)
    let initialHistoryRecords = await MainActor.run { model.speakerLabelHistory }
    let initialHistory = try XCTUnwrap(initialHistoryRecords.first)
    XCTAssertEqual(initialHistoryRecords.count, 1)
    XCTAssertEqual(initialHistory.trackId, speaker.trackId)
    XCTAssertEqual(initialHistory.sourceKind, .microphone)
    XCTAssertEqual(initialHistory.sourceDefaultLabel, "You")
    XCTAssertTrue(initialHistory.revisions.isEmpty)
    XCTAssertEqual(
      TranscriptLibraryModel.speakerLabelHistoryText(for: initialHistory),
      "Source default: You")
    let renamed = await model.renameSpeaker(trackId: speaker.trackId, label: " Dana ")
    let named = await MainActor.run { model.speakers.first }
    XCTAssertTrue(renamed)
    XCTAssertEqual(named?.label, "Dana")
    XCTAssertEqual(named?.namedByUser, true)
    XCTAssertEqual(
      try library.prepareSpeakerDiarization(sessionId: sessionId).tracks.first?.labelOrigin,
      .human)
    let restored = await model.renameSpeaker(trackId: speaker.trackId, label: nil)
    let again = await MainActor.run {
      (
        model.speakers.first?.label, model.speakers.first?.namedByUser,
        model.segments.map(\.effectiveText), model.segments.map(\.verbatimText),
        model.availability
      )
    }
    XCTAssertTrue(restored)
    XCTAssertEqual(again.0, "You")
    XCTAssertEqual(again.1, false)
    XCTAssertEqual(again.2, ["provisional meadow"])
    XCTAssertEqual(again.3, ["provisional meadow"])
    XCTAssertEqual(again.4, .draft)
    let decision = try library.prepareSpeakerDiarization(sessionId: sessionId)
    XCTAssertEqual(decision.clusteringState, "unavailable")
    XCTAssertEqual(decision.reason, "no calibrated diarization model")
    XCTAssertEqual(decision.algorithmId, "topology-before-clustering-v1")
    XCTAssertEqual(decision.tracks.first?.label, "You")
    XCTAssertEqual(decision.tracks.first?.labelOrigin, .sourceDefault)
    let renamedAgain = await model.renameSpeaker(trackId: speaker.trackId, label: "Mina")
    let clearedAgain = await model.renameSpeaker(trackId: speaker.trackId, label: nil)
    XCTAssertTrue(renamedAgain)
    XCTAssertTrue(clearedAgain)
    let reviewed = await MainActor.run {
      (model.speakers.first?.label, model.speakerLabelHistory)
    }
    XCTAssertEqual(reviewed.0, "You")
    let history = try XCTUnwrap(reviewed.1.first)
    XCTAssertEqual(reviewed.1.count, 1)
    XCTAssertEqual(history.trackId, speaker.trackId)
    XCTAssertEqual(history.sourceKind, .microphone)
    XCTAssertEqual(history.sourceDefaultLabel, "You")
    XCTAssertEqual(
      history.revisions.map(\.label), ["Dana", "You", "Mina", "You"])
    XCTAssertEqual(
      history.revisions.map(\.origin),
      [.human, .sourceDefault, .human, .sourceDefault])
    XCTAssertTrue(history.revisions.allSatisfy { $0.createdAtMs > 0 })
    XCTAssertTrue(
      zip(history.revisions, history.revisions.dropFirst()).allSatisfy {
        $0.createdAtMs <= $1.createdAtMs
      })
    XCTAssertEqual(
      TranscriptLibraryModel.speakerLabelHistoryText(for: history),
      """
      Source default: You
      Dana, named by you
      You, source name
      Mina, named by you
      You, source name
      """)
    XCTAssertEqual(try Data(contentsOf: mediaURL), sealedMedia)
    XCTAssertTrue(failures.snapshot().isEmpty)
  }

  @MainActor
  private func seekButton(containing text: String, in root: NSView) -> NSButton? {
    if let button = root as? NSButton, !(button is NSPopUpButton) {
      let label = button.accessibilityLabel() ?? ""
      let visible =
        button.isHidden == false && button.isHiddenOrHasHiddenAncestor == false
        && button.frame.width > 1 && button.frame.height > 1
      if visible, button.title.localizedCaseInsensitiveContains(text)
        || label.localizedCaseInsensitiveContains(text)
      {
        return button
      }
    }
    for subview in root.subviews {
      if let found = seekButton(containing: text, in: subview) { return found }
    }
    return nil
  }

  @MainActor
  private func provenanceField(in root: NSView) -> NSTextField? {
    readout(labeled: "Model provenance", in: root)
  }

  @MainActor
  private func readout(labeled label: String, in root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityLabel() == label {
      return field
    }
    for subview in root.subviews {
      if let found = readout(labeled: label, in: subview) { return found }
    }
    return nil
  }

  @MainActor
  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000, _ body: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if body() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return body()
  }

  private func openedMicrophone(title: String) throws -> OpenedMicrophone {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-microphone-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    managedRoots.append(root)
    let controller = try NativeRecordingPreparation.open(managedRoot: root.path)
    let prepared = try controller.prepareSessionWithRequiredSources(
      title: title, requiredSources: [.microphone])
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone"
    )
    let writer = try ManagedCAFWriter(authorization: authorization)
    let opened = try controller.acceptMediaOpen(receipt: writer.receipt())
    XCTAssertTrue(opened.journalDurable)
    XCTAssertTrue(opened.mediaFilesOpen)
    XCTAssertFalse(opened.recordingStarted)
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    return OpenedMicrophone(
      root: root, controller: controller, authorization: authorization, writer: writer,
      format: format)
  }

  private func startAndConfirm(
    adapter: MicrophoneCaptureAdapter,
    backend: FakeMicrophoneBackend,
    controller: NativeRecordingPreparation,
    format: AVAudioFormat,
    firstHostTime: UInt64 = 10
  ) throws -> FailureBox {
    let receipts = ReceiptBox()
    let failures = FailureBox()
    let firstSample = expectation(description: "first sample before the provisional window")
    try adapter.start(
      onFirstSample: { receipt in
        receipts.append(receipt)
        firstSample.fulfill()
      },
      onFailure: { failures.append($0) }
    )
    backend.emit(try microphoneFrames(format, 96), hostTime: firstHostTime)
    wait(for: [firstSample], timeout: 2)
    let evidence = try controller.acceptFirstSample(
      receipt: try XCTUnwrap(receipts.snapshot().first))
    XCTAssertTrue(evidence.firstSampleDurable)
    XCTAssertFalse(evidence.recordingStarted)
    let started = try controller.confirmRecording(sessionId: evidence.sessionId)
    XCTAssertTrue(started.recordingStarted)
    return failures
  }

  private func labeledDraft(
    _ library: NativeTranscriptLibrary, sessionId: String
  ) throws -> [NativeTranscriptSegment] {
    let availability = try library.availability(sessionId: sessionId)
    XCTAssertEqual(availability, .draft)
    XCTAssertEqual(
      TranscriptLibraryModel.text(for: availability),
      "Draft — the final transcript isn't finished yet")
    let segments = try library.document(sessionId: sessionId)
    XCTAssertEqual(segments.map(\.finality), [.draft])
    XCTAssertEqual(segments.map(\.corrected), [false])
    return segments
  }

  private func capturedLength(_ authorization: NativeMediaOpenAuthorization) throws -> Int64 {
    try AVAudioFile(forReading: URL(fileURLWithPath: authorization.absolutePath)).length
  }

  private func capturedSamples(_ authorization: NativeMediaOpenAuthorization) throws -> [Int16] {
    let audio = try AVAudioFile(
      forReading: URL(fileURLWithPath: authorization.absolutePath),
      commonFormat: .pcmFormatInt16,
      interleaved: false)
    let capacity = AVAudioFrameCount(audio.length)
    let decoded = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: capacity))
    try audio.read(into: decoded, frameCount: capacity)
    let samples = try XCTUnwrap(decoded.int16ChannelData?[0])
    return Array(UnsafeBufferPointer(start: samples, count: Int(decoded.frameLength)))
  }
}

private struct OpenedMicrophone {
  let root: URL
  let controller: NativeRecordingPreparation
  let authorization: NativeMediaOpenAuthorization
  let writer: ManagedCAFWriter
  let format: AVAudioFormat
}

private final class RisingSamples {
  private var next: Int = 1

  func fill(_ format: AVAudioFormat, _ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
    for frame in 0..<Int(frames) {
      samples[frame] = Int16(next)
      next += 1
    }
    return buffer
  }
}

private func microphoneFrames(_ format: AVAudioFormat, _ frames: AVAudioFrameCount) throws
  -> AVAudioPCMBuffer
{
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
  buffer.frameLength = frames
  let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
  for frame in 0..<Int(frames) {
    samples[frame] = Int16((frame % 32) + 1)
  }
  return buffer
}

private func silentMicrophoneFrames(_ format: AVAudioFormat, _ frames: AVAudioFrameCount) throws
  -> AVAudioPCMBuffer
{
  let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
  buffer.frameLength = frames
  let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
  samples.update(repeating: 0, count: Int(frames))
  return buffer
}

private func assertQuietInterval(
  in authorization: NativeMediaOpenAuthorization,
  speechFrames: Int,
  quietFrames: Int,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  let audio = try AVAudioFile(
    forReading: URL(fileURLWithPath: authorization.absolutePath),
    commonFormat: .pcmFormatInt16,
    interleaved: false)
  let total = speechFrames + quietFrames
  XCTAssertGreaterThanOrEqual(audio.length, Int64(total), file: file, line: line)
  let capacity = AVAudioFrameCount(total)
  let decoded = try XCTUnwrap(
    AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: capacity),
    file: file, line: line)
  try audio.read(into: decoded, frameCount: capacity)
  XCTAssertEqual(decoded.frameLength, capacity, file: file, line: line)
  let samples = try XCTUnwrap(decoded.int16ChannelData?[0], file: file, line: line)
  XCTAssertEqual(samples[0], 1, file: file, line: line)
  XCTAssertEqual(samples[speechFrames - 1], 32, file: file, line: line)
  var quiet = 0
  for frame in speechFrames..<total where samples[frame] == 0 {
    quiet += 1
  }
  XCTAssertEqual(quiet, quietFrames, file: file, line: line)
}

private func provisionalFixture(
  _ text: String,
  digest: String = String(repeating: "a", count: 64)
) -> ProvisionalDraftHypothesis {
  ProvisionalDraftHypothesis(
    text: text,
    engine: "fixture-engine",
    engineVersion: "1",
    modelId: "fixture-model",
    modelSha256: digest,
    optionsDigest: "live-options",
    reconciliationVersion: "overlap-midpoint-v3"
  )
}

private final class FailureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failures: [MicrophoneCaptureAdapterError] = []

  func append(_ failure: MicrophoneCaptureAdapterError) {
    lock.withLock { failures.append(failure) }
  }

  func snapshot() -> [MicrophoneCaptureAdapterError] {
    lock.withLock { failures }
  }
}

private final class CaptureActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false

  var value: Bool { lock.withLock { active } }

  func set(_ active: Bool) { lock.withLock { self.active = active } }
}

private final class SlowTranscription: @unchecked Sendable {
  private let lock = NSLock()
  private var didEnter = false

  func run(_ job: NativeTranscriptionJob) async -> NativeTranscriptionResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        self.lock.withLock { self.didEnter = true }
        let deadline = Date().addingTimeInterval(5)
        while !job.isCancelled(), Date() < deadline {
          Thread.sleep(forTimeInterval: 0.005)
        }
        continuation.resume(
          returning: NativeTranscriptionResult(
            outcome: job.stopOutcome() ?? .failed, summary: nil, reason: nil, failure: nil))
      }
    }
  }

  func waitUntilEntered() async -> Bool {
    for _ in 0..<200 {
      if lock.withLock({ didEnter }) { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private final class BlockingDraftHypothesis: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let allow = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var calls = 0

  var callCount: Int { lock.withLock { calls } }

  func next() -> ProvisionalDraftHypothesis {
    let index = lock.withLock { () -> Int in
      calls += 1
      return calls
    }
    if index == 1 {
      entered.signal()
      allow.wait()
      return provisionalFixture("provisional meadow")
    }
    return provisionalFixture("later brook")
  }
}
