import AVFoundation
import Darwin
import XCTest

@testable import OpenScribeApp

/// Real journal/SQLite, UniFFI, segmented CAF writers and controller; injected
/// sources supply PCM instead of requesting TCC or opening audio devices.
@MainActor
final class RecorderPauseResumeTests: XCTestCase {
  func testRepeatedPauseResumeDrainsSourcesAndPreservesContiguousPlayback() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    var sealedBytes: [String: Data] = [:]

    for cycle in 0..<2 {
      let microphone = try XCTUnwrap(harness.captures.microphones.last)
      let system = try XCTUnwrap(harness.captures.systems.last)
      let sessionId = microphone.writer.authorization.sessionId
      if cycle > 0 {
        let previous = harness.captures.microphones[cycle - 1]
        XCTAssertEqual(
          microphone.writer.authorization.sessionId, previous.writer.authorization.sessionId)
        XCTAssertEqual(
          microphone.writer.authorization.trackId, previous.writer.authorization.trackId)
        XCTAssertEqual(
          microphone.writer.authorization.writerGeneration,
          previous.writer.authorization.writerGeneration + 1)
        XCTAssertNotEqual(
          microphone.writer.authorization.absolutePath, previous.writer.authorization.absolutePath)
        previous.repeatFirstCallback()
        harness.captures.systems[cycle - 1].repeatFirstCallback()
        await settle()
        XCTAssertEqual(harness.controller.phase, .starting)
      }
      try microphone.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
      await settle()
      XCTAssertEqual(
        harness.controller.phase, .starting, "resuming requires fresh samples from both sources")
      try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await settle()
      XCTAssertEqual(harness.controller.phase, .capturing)
      XCTAssertTrue(harness.controller.canPause)
      microphone.pendingDrain = (harness.clock.now + AVAudioTime.hostTime(forSeconds: 1), 12288)
      system.pendingDrain = (harness.clock.now + AVAudioTime.hostTime(forSeconds: 1), 20480)
      harness.clock.advance(seconds: 1.01)
      await harness.controller.stop(pausing: true)

      XCTAssertEqual(harness.controller.phase, .paused)
      XCTAssertFalse(harness.controller.canPause)
      XCTAssertFalse(harness.controller.canStart)
      XCTAssertTrue(harness.controller.canResume)
      XCTAssertTrue(harness.controller.canStop)
      XCTAssertEqual(microphone.stopCount, 1)
      XCTAssertEqual(system.stopCount, 1)
      let paused = try harness.preparation.recorderDetail(sessionId: sessionId)
      XCTAssertEqual(paused.lifecycle, "paused")
      XCTAssertEqual(paused.capturedNanoseconds, Int64(cycle + 1) * 1_010_000_000)
      for path in harness.controller.savedPaths {
        sealedBytes[path] = try Data(contentsOf: URL(fileURLWithPath: path))
      }
      harness.clock.advance(seconds: 600)
      XCTAssertEqual(
        try harness.preparation.recorderDetail(sessionId: sessionId).capturedNanoseconds,
        paused.capturedNanoseconds)
      XCTAssertEqual(harness.controller.statusText, "Paused — captured time is stopped")
      if cycle == 0 { await harness.controller.start(resuming: true) }
    }

    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertTrue(harness.controller.canStart)
    XCTAssertEqual(harness.captures.microphones.count, 2)
    XCTAssertEqual(harness.captures.systems.count, 2)
    for (path, bytes) in sealedBytes {
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }
    let sessionId = try XCTUnwrap(harness.captures.microphones.first).writer.authorization.sessionId
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    let plan = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 4)
    XCTAssertEqual(Set(plan.map(\.trackId)).count, 2)
    for segment in plan {
      XCTAssertEqual(segment.sampleCount, 48_480)
      XCTAssertEqual(segment.startNanoseconds, Int64(segment.sequence) * 1_010_000_000)
      XCTAssertEqual(segment.gapNanoseconds, 0)
    }
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    var frame: Int64 = 0
    while let buffer = try reader.read(maximumFrames: 4096) {
      for index in 0..<Int(buffer.frameLength) {
        let expected: Float = (frame + Int64(index)) % 48_480 < 48_000 ? 0.375 : 0.5
        XCTAssertEqual(buffer.floatChannelData![0][index], expected, accuracy: 0.0001)
      }
      frame += Int64(buffer.frameLength)
    }
    XCTAssertEqual(
      frame, 96_960, "idle time adds no playback silence and drained samples appear exactly once")
  }

  func testDeniedResumeKeepsPausedSessionAndAllowsExplicitRetry() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    try await harness.captureAndPause()
    let paths = harness.controller.savedPaths
    let sessionId = try XCTUnwrap(harness.captures.microphones.first).writer.authorization.sessionId
    harness.permission.currentState = .denied
    await harness.controller.start(resuming: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertEqual(harness.controller.savedPaths, paths)
    XCTAssertEqual(harness.captures.microphones.count, 1)
    XCTAssertEqual(try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "paused")
    XCTAssertFalse(
      try harness.preparation.recorderDetail(sessionId: sessionId).events.contains {
        $0.kind == "capture_resumed"
      })
    harness.permission.currentState = .authorized
    harness.clock.advance(seconds: 600)
    await harness.controller.start(resuming: true)
    try await harness.capture()
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    _ = try harness.preparation.recoverPlayableSessions()
    XCTAssertEqual(try harness.preparation.playbackTimeline(sessionId: sessionId).count, 4)
  }

  func testPauseDrainsAcrossThirtySecondRotation() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    for source in [microphone, system] {
      try source.emit(frames: 1_439_760, hostTime: harness.clock.now, value: 8192)
      source.pendingDrain = (harness.clock.now + AVAudioTime.hostTime(forSeconds: 29.995), 8192)
    }
    for _ in 0..<30 { await Task.yield() }
    XCTAssertEqual(harness.controller.phase, .capturing)
    harness.clock.advance(seconds: 30.005)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    let sessionId = microphone.writer.authorization.sessionId
    _ = try harness.preparation.recoverPlayableSessions()
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 4)
    XCTAssertEqual(plan.filter { $0.sequence == 0 }.map(\.sampleCount), [1_440_000, 1_440_000])
    XCTAssertEqual(plan.filter { $0.sequence == 1 }.map(\.sampleCount), [240, 240])
    XCTAssertTrue(plan.allSatisfy { $0.gapNanoseconds == 0 })
  }

  func testPauseDrainFailureIsInterruptedAndSourceAudioRemainsRecoverable() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = system.writer.authorization.sessionId
    system.failStop = true
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .failed)
    XCTAssertFalse(harness.controller.canResume)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "interrupted")
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    XCTAssertEqual(try reopened.playbackTimeline(sessionId: sessionId).count, 2)
  }

  func testResumeStartupFailurePreservesPreviouslySealedAudio() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    try await harness.captureAndPause()
    let sessionId = try XCTUnwrap(harness.captures.microphones.first).writer.authorization.sessionId
    let bytes = try harness.controller.savedPaths.map {
      try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    let paths = harness.controller.savedPaths
    harness.captures.failNextSystemStart = true
    harness.clock.advance(seconds: 600)
    await harness.controller.start(resuming: true)
    XCTAssertEqual(harness.controller.phase, .failed)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "interrupted")
    for (path, expected) in zip(paths, bytes) {
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), expected)
    }
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    XCTAssertEqual(try reopened.playbackTimeline(sessionId: sessionId).count, 2)
  }

  private func settle() async {
    for _ in 0..<30 { await Task.yield() }
  }
}

@MainActor
private final class PausePermission: MicrophonePermissionProviding {
  var currentState: MicrophonePermissionState = .authorized
  func request() async -> MicrophonePermissionState { currentState }
}

private final class PauseClock: @unchecked Sendable {
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

private enum PauseSourceError: Error { case startup, drain }

private final class PauseSource: MicrophoneCapturing, SystemAudioCapturing, @unchecked Sendable {
  let writer: ManagedSegmentWriting
  var pendingDrain: (UInt64, Int16)?
  var failStart = false
  var failStop = false
  private(set) var stopCount = 0
  private var firstHandler: MicrophoneFirstSampleHandler?
  private var first: NativeFirstSampleReceipt?
  private var lastEnd: UInt64?
  init(writer: ManagedSegmentWriting) { self.writer = writer }
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler, onFailure: @escaping MicrophoneFailureHandler
  ) throws {
    firstHandler = onFirstSample
  }
  func start(
    onFirstSample: @escaping SystemAudioFirstSampleHandler,
    onFailure: @escaping SystemAudioFailureHandler
  ) async throws {
    if failStart { throw PauseSourceError.startup }
    firstHandler = onFirstSample
  }
  func emit(frames: AVAudioFrameCount, hostTime: UInt64, value: Int16) throws {
    _ = try writer.writeCapturedBuffer(
      TimelineRuntimeProof.buffer(frames: frames, value: value), hostTime: hostTime)
    lastEnd = hostTime + AVAudioTime.hostTime(forSeconds: Double(frames) / 48_000)
    if first == nil {
      first = try writer.firstSampleReceipt(hostTime: hostTime, frameCount: UInt64(frames))
      firstHandler?(first!)
    }
  }
  func repeatFirstCallback() { if let first { firstHandler?(first) } }
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
private final class PauseSources: @unchecked Sendable {
  var microphones: [PauseSource] = []
  var systems: [PauseSource] = []
  var failNextSystemStart = false
  func microphone(_ writer: ManagedSegmentWriting) -> PauseSource {
    let source = PauseSource(writer: writer)
    microphones.append(source)
    return source
  }
  func system(_ writer: ManagedSegmentWriting) -> PauseSource {
    let source = PauseSource(writer: writer)
    source.failStart = failNextSystemStart
    failNextSystemStart = false
    systems.append(source)
    return source
  }
}

@MainActor
private final class PauseHarness {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let preparation: NativeRecordingPreparation
  let permission = PausePermission()
  let clock = PauseClock()
  let captures = PauseSources()
  let controller: LiveMicrophoneRecordingController
  init() throws {
    preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let preparation = preparation
    let captures = captures
    let clock = clock
    controller = LiveMicrophoneRecordingController(
      permission: permission, preparationFactory: { preparation },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { captures.microphone($0) },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { captures.system($0) }, segmentedCapture: true,
      hostTime: { clock.now }, captureHealthTelemetry: { _ in }
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
