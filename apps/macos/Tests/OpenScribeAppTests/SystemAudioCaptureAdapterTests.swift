import AVFoundation
import CoreMedia
import ScreenCaptureKit
import XCTest

@testable import OpenScribeApp

private final class SystemStreamFake: SystemAudioStreamControlling, @unchecked Sendable {
  var synchronizationClock: CMClock? = CMClockGetHostTimeClock()
  var startError: Error?
  var stopError: Error?
  var removeError: Error?
  var startGate: StreamStartGate?
  let stopped = XCTestExpectation(description: "Platform stream stopped")
  private let lock = NSLock()
  private var adapter: SystemAudioCaptureAdapter?
  private var queue: DispatchQueue?
  private(set) var stopCount = 0
  private(set) var removeCount = 0

  func addStreamOutput(
    _ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?
  ) throws {
    XCTAssertEqual(type, .audio)
    lock.withLock {
      adapter = output as? SystemAudioCaptureAdapter
      queue = sampleHandlerQueue
    }
  }

  func removeStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws {
    removeCount += 1
    if let removeError { throw removeError }
    // Deliberately retain the callback to reproduce delivery after detachment.
  }

  func startCapture() async throws {
    if let startGate { await startGate.wait() }
    if let startError { throw startError }
  }

  func stopCapture() async throws {
    stopCount += 1
    stopped.fulfill()
    if let stopError { throw stopError }
  }

  func emit(_ buffer: CMSampleBuffer) {
    let captured = SampleBox(buffer)
    let (adapter, queue) = lock.withLock { (adapter, queue) }
    queue?.async { adapter?.consume(captured.value, type: .audio) }
  }

  func drain() async {
    let queue = lock.withLock { queue }
    await withCheckedContinuation { continuation in
      guard let queue else {
        continuation.resume()
        return
      }
      queue.async { continuation.resume() }
    }
  }
}

private struct SampleBox: @unchecked Sendable {
  let value: CMSampleBuffer
  init(_ value: CMSampleBuffer) { self.value = value }
}

private actor StreamStartGate {
  let entered = XCTestExpectation(description: "Platform start pending")
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered.fulfill()
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private final class SystemWriterFake: CapturedAudioWriting, @unchecked Sendable {
  let writeEntered = XCTestExpectation(description: "Write entered")
  var writeGate: DispatchSemaphore?
  private let lock = NSLock()
  private var writes = 0
  var writeCount: Int { lock.withLock { writes } }

  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    let first = lock.withLock {
      writes += 1
      return writes == 1
    }
    if first { writeEntered.fulfill() }
    if let writeGate {
      guard writeGate.wait(timeout: .now() + 5) == .success else {
        throw SystemAudioCaptureAdapterError.writerFailed
      }
    }
    return input.frameLength
  }

  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws
    -> NativeFirstSampleReceipt
  {
    NativeFirstSampleReceipt(
      sessionId: "session-system", trackId: "track-system", segmentId: "segment-system",
      openToken: "token-system", writerGeneration: 1, relativePath: "audio/system.caf",
      firstSampleHostTime: hostTime, firstSampleFrameCount: frameCount, observedByteLength: 128
    )
  }
}

private final class StopResult: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  var isCompleted: Bool { lock.withLock { completed } }
  func complete() { lock.withLock { completed = true } }
}

final class SystemAudioCaptureAdapterTests: XCTestCase {
  func testStopDrainsAcceptedWriteAndRejectsLateSamplesBeforeSealing() async throws {
    let writer = SystemWriterFake()
    let gate = DispatchSemaphore(value: 0)
    writer.writeGate = gate
    let backend = SystemStreamFake()
    let adapter = SystemAudioCaptureAdapter(writer: writer, stream: backend)
    try await adapter.start(
      onFirstSample: { _ in }, onFailure: { _ in XCTFail("Unexpected failure") })
    backend.emit(try sample())
    await fulfillment(of: [writer.writeEntered], timeout: 2)
    let result = StopResult()
    let stopping = Task {
      let time = try await adapter.stop()
      result.complete()
      return time
    }
    await fulfillment(of: [backend.stopped], timeout: 2)
    XCTAssertFalse(result.isCompleted, "Stop must not authorize sealing an in-flight write")
    gate.signal()
    let finalTime = try await stopping.value
    XCTAssertNotNil(finalTime)
    backend.emit(try sample())
    await backend.drain()
    XCTAssertEqual(writer.writeCount, 1)
    let repeatedTime = try await adapter.stop()
    XCTAssertEqual(finalTime, repeatedTime)
    XCTAssertEqual(backend.stopCount, 1)
    XCTAssertEqual(backend.removeCount, 1)
  }

  func testAlreadyStoppedPlatformStreamRetainsItsFinalSample() async throws {
    let writer = SystemWriterFake()
    let backend = SystemStreamFake()
    backend.stopError = NSError(
      domain: SCStreamErrorDomain, code: SCStreamError.attemptToStopStreamState.rawValue
    )
    let adapter = SystemAudioCaptureAdapter(writer: writer, stream: backend)
    let failure = expectation(description: "Named stream loss")
    try await adapter.start(
      onFirstSample: { _ in },
      onFailure: { error in
        XCTAssertEqual(error, .streamStopped)
        failure.fulfill()
      })
    backend.emit(try sample())
    await backend.drain()
    adapter.handleStreamStopped(NSError(domain: SCStreamErrorDomain, code: -3806))
    await fulfillment(of: [failure], timeout: 2)
    let finalTime = try await adapter.stop()
    XCTAssertNotNil(finalTime)
    XCTAssertEqual(writer.writeCount, 1)
    XCTAssertEqual(backend.removeCount, 1)
  }

  func testStopWaitsForPendingStartThenDetachesTheStartedStream() async throws {
    let backend = SystemStreamFake()
    let gate = StreamStartGate()
    backend.startGate = gate
    let adapter = SystemAudioCaptureAdapter(writer: SystemWriterFake(), stream: backend)
    let starting = Task {
      try await adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
    }
    await fulfillment(of: [gate.entered], timeout: 2)
    let stopping = Task { try await adapter.stop() }
    await gate.release()
    try await starting.value
    let finalTime = try await stopping.value
    XCTAssertNil(finalTime)
    XCTAssertEqual(backend.stopCount, 1)
    XCTAssertEqual(backend.removeCount, 1)
  }

  func testUnexpectedStopAndDetachErrorsRemainFailures() async throws {
    for failsRemoval in [false, true] {
      let backend = SystemStreamFake()
      let error = NSError(domain: "test.stream", code: 42)
      if failsRemoval { backend.removeError = error } else { backend.stopError = error }
      let adapter = SystemAudioCaptureAdapter(writer: SystemWriterFake(), stream: backend)
      try await adapter.start(onFirstSample: { _ in }, onFailure: { _ in })
      do {
        _ = try await adapter.stop()
        XCTFail("Unproven stream teardown must not authorize a successful seal")
      } catch {
        XCTAssertEqual((error as NSError).domain, "test.stream")
      }
      XCTAssertEqual(backend.removeCount, 1)
    }
  }

  func testUserCancellationAndPermissionDenialAreNotWriterFailures() async throws {
    for (code, expected) in [
      (SCStreamError.userStopped.rawValue, SystemAudioCaptureAdapterError.userStopped),
      (SCStreamError.userDeclined.rawValue, .permissionDenied),
    ] {
      let backend = SystemStreamFake()
      let adapter = SystemAudioCaptureAdapter(writer: SystemWriterFake(), stream: backend)
      let received = expectation(description: "Typed source termination")
      try await adapter.start(
        onFirstSample: { _ in },
        onFailure: { error in
          XCTAssertEqual(error, expected)
          received.fulfill()
        })
      adapter.handleStreamStopped(NSError(domain: SCStreamErrorDomain, code: code))
      await fulfillment(of: [received], timeout: 2)
      _ = try await adapter.stop()
    }
  }

  func testMissingClockCannotWriteUnmappableAudio() async throws {
    let writer = SystemWriterFake()
    let backend = SystemStreamFake()
    backend.synchronizationClock = nil
    let adapter = SystemAudioCaptureAdapter(writer: writer, stream: backend)
    let failure = expectation(description: "Timestamp rejected")
    try await adapter.start(
      onFirstSample: { _ in XCTFail("No first sample") },
      onFailure: { error in
        XCTAssertEqual(error, .invalidSampleBuffer)
        failure.fulfill()
      })
    backend.emit(try sample())
    await fulfillment(of: [failure], timeout: 2)
    _ = try await adapter.stop()
    XCTAssertEqual(writer.writeCount, 0)
  }

  func testFailedStartDrainsAndRejectsLateCallbacks() async throws {
    let writer = SystemWriterFake()
    let backend = SystemStreamFake()
    backend.startError = NSError(domain: "test.start", code: 1)
    let adapter = SystemAudioCaptureAdapter(writer: writer, stream: backend)
    do {
      try await adapter.start(
        onFirstSample: { _ in XCTFail("No first sample") }, onFailure: { _ in })
      XCTFail("Start must fail")
    } catch {
      XCTAssertEqual((error as NSError).domain, "test.start")
    }
    backend.emit(try sample())
    await backend.drain()
    _ = try await adapter.stop()
    XCTAssertEqual(writer.writeCount, 0)
    XCTAssertEqual(backend.removeCount, 1)
    XCTAssertEqual(backend.stopCount, 0)
  }

  private func sample() throws -> CMSampleBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48))
    pcm.frameLength = 48
    memset(pcm.floatChannelData![0], 0, 48 * MemoryLayout<Float>.size)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid
    )
    var buffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
        sampleCount: 48, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
      ), noErr)
    let result = try XCTUnwrap(buffer)
    XCTAssertEqual(
      CMSampleBufferSetDataBufferFromAudioBufferList(
        result, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
        bufferList: pcm.audioBufferList
      ), noErr)
    XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
    return result
  }
}
