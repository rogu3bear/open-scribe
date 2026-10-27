import AVFoundation
import XCTest

@testable import OpenScribeApp

/// Real store, journal and CAF writers; no microphone permission or device use.
@MainActor
final class RecorderMicrophoneRestoreTests: XCTestCase {
  private let device = MicrophoneDeviceIdentity(uniqueID: "restore-a", localizedName: "Microphone")

  func testSilentRestoreTimesOutAndRetriesWithoutStoppingTheOtherSource() async throws {
    let deadlines = ManualRestoreDeadlines()
    defer { deadlines.releaseAll() }
    let harness = try makeHarness(deadlines)
    defer { harness.removeFiles() }
    let original = try await captureAndRetire(harness)
    let originalURL = URL(fileURLWithPath: original.writer.authorization.absolutePath)
    let originalBytes = try Data(contentsOf: originalURL)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let restored = try await reconnect(harness)
    let lateReceipt = untrustedFirstReceipt(restored, harness: harness)
    await waitUntil { deadlines.count == 1 }
    harness.controller.reconnectMicrophone()
    XCTAssertEqual(harness.captures.microphones.count, 2, "a pending attempt cannot duplicate")
    for _ in 0..<10 {
      try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      harness.clock.advance(seconds: 1)
    }
    deadlines.releaseNext()
    await waitUntil {
      harness.controller.errorMessage == microphoneCouldNotBeRestoredContinuingSentence
    }
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertGreaterThanOrEqual(restored.stopCount, 1)
    restored.deliverFirstNotification(lateReceipt)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)

    let retry = try await reconnect(harness)
    restored.deliverFirstNotification(lateReceipt)
    restored.failMicrophone(.writerFailed)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired, "old audio cannot complete the retry")
    try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await waitUntil { !harness.controller.isMicrophoneRetired }
    await waitUntil { deadlines.count == 1 }
    deadlines.releaseNext()
    original.failMicrophone(.writerFailed)
    await settle()
    XCTAssertFalse(
      harness.controller.isMicrophoneRetired, "successful restore cancels its deadline")
    XCTAssertNil(harness.controller.errorMessage)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
    await finish(harness)
  }

  func testDeadlineDoesNotDiscardDurableAudioAwaitingFirstNotification() async throws {
    let deadlines = ManualRestoreDeadlines()
    defer { deadlines.releaseAll() }
    let harness = try makeHarness(deadlines)
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    let restored = try await reconnect(harness)
    restored.holdsFirstNotification = true
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await waitUntil { deadlines.count == 1 }
    deadlines.releaseNext()
    await settle()
    XCTAssertEqual(restored.stopCount, 0, "writer durability precedes the UI notification")
    XCTAssertEqual(harness.captures.systems.last?.stopCount, 0)
    restored.repeatFirstCallback()
    await waitUntil { !harness.controller.isMicrophoneRetired }
    XCTAssertNil(harness.controller.errorMessage)
    await finish(harness)
  }

  func testStoppedRestoreCannotPublishIntoTheNextConversation() async throws {
    let deadlines = ManualRestoreDeadlines()
    defer { deadlines.releaseAll() }
    let harness = try makeHarness(deadlines)
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    let restored = try await reconnect(harness)
    let lateReceipt = untrustedFirstReceipt(restored, harness: harness)
    let oldSession = restored.writer.authorization.sessionId
    await waitUntil { deadlines.count == 1 }
    await finish(harness)
    await harness.controller.start()
    try await harness.capture()
    let newSession = try XCTUnwrap(
      harness.captures.microphones.last?.writer.authorization.sessionId)
    XCTAssertNotEqual(newSession, oldSession)
    deadlines.releaseNext()
    restored.deliverFirstNotification(lateReceipt)
    restored.failMicrophone(.writerFailed)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    XCTAssertNil(harness.controller.errorMessage)
    XCTAssertEqual(harness.captures.microphones.last?.writer.authorization.sessionId, newSession)
    await finish(harness)
  }

  func testPausedRestoreDeadlineKeepsTruthfulStateInBothSystemSampleOrders() async throws {
    for systemFirst in [true, false] {
      let deadlines = ManualRestoreDeadlines()
      defer { deadlines.releaseAll() }
      let harness = try makeHarness(deadlines)
      defer { harness.removeFiles() }
      _ = try await captureAndRetire(harness)
      await harness.controller.stop(pausing: true)
      harness.clock.advance(seconds: 1)
      let restored = try await reconnect(harness)
      let system = try XCTUnwrap(harness.captures.systems.last)
      await waitUntil { deadlines.count == 1 }
      if systemFirst {
        try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
        await settle()
      }
      deadlines.releaseNext()
      await waitUntil { harness.controller.isMicrophoneRetired }
      if !systemFirst {
        XCTAssertEqual(harness.controller.phase, .starting)
        XCTAssertEqual(
          harness.controller.errorMessage, microphoneCouldNotBeRestoredResumingSentence)
        try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      }
      await waitUntil { harness.controller.phase == .capturing }
      XCTAssertEqual(
        harness.controller.errorMessage, microphoneCouldNotBeRestoredContinuingSentence)
      XCTAssertEqual(system.stopCount, 0)
      XCTAssertGreaterThanOrEqual(restored.stopCount, 1)
      let retry = try await reconnect(harness)
      try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
      await waitUntil { !harness.controller.isMicrophoneRetired }
      await finish(harness)
    }
  }

  func testFirstSampleSavedDuringDeadlineDrainIsPreserved() async throws {
    let deadlines = ManualRestoreDeadlines()
    defer { deadlines.releaseAll() }
    let harness = try makeHarness(deadlines)
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    let restored = try await reconnect(harness)
    let sessionId = restored.writer.authorization.sessionId
    let restoredTrack = restored.writer.authorization.trackId
    restored.pendingDrain = (harness.clock.now, 8192)
    await waitUntil { deadlines.count == 1 }
    deadlines.releaseNext()
    await waitUntil {
      harness.controller.isMicrophoneRetired
        && harness.controller.failureCode == "microphone-restore-timeout"
    }
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(harness.captures.systems.last?.stopCount, 0)
    XCTAssertTrue(harness.controller.showsReconnect)
    await finish(harness)
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    let timeline = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertTrue(timeline.contains { $0.trackId == restoredTrack && $0.sampleCount >= 480 })
  }

  func testAtAndBelowReserveRefuseRestoreInLiveAndPausedConversations() async throws {
    let reserve: UInt64 = 512 * 1024 * 1024
    for paused in [false, true] {
      for available in [reserve - 1, reserve] {
        let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
        defer { harness.removeFiles() }
        let original = try await captureAndRetire(harness)
        if paused { await harness.controller.stop(pausing: true) }
        let system = try XCTUnwrap(harness.captures.systems.last)
        let stops = system.stopCount
        harness.storage.set(available)
        harness.controller.reconnectMicrophone()
        await waitUntil {
          harness.controller.errorMessage?.hasPrefix("Not enough free space") == true
        }
        XCTAssertEqual(harness.controller.phase, paused ? .paused : .capturing)
        XCTAssertEqual(harness.captures.microphones.count, 1)
        XCTAssertEqual(system.stopCount, stops)
        let events = try harness.preparation.recorderDetail(
          sessionId: original.writer.authorization.sessionId
        ).events
        XCTAssertFalse(events.contains { $0.kind == "microphone_restore_requested" })
        if paused {
          XCTAssertFalse(harness.controller.errorMessage?.contains("is still recording") == true)
        }
        harness.storage.set(nil)
        await finish(harness)
      }
    }
  }

  func testStopSealsFirstRestoredSampleSavedDuringItsFinalDrain() async throws {
    let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    let restored = try await reconnect(harness)
    let sessionId = restored.writer.authorization.sessionId
    let restoredTrack = restored.writer.authorization.trackId
    restored.pendingDrain = (harness.clock.now, 8192)
    await finish(harness)
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    let timeline = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertTrue(timeline.contains { $0.trackId == restoredTrack && $0.sampleCount >= 480 })
    XCTAssertFalse(harness.controller.showsReconnect)
  }

  func testAboveReserveCanProceedThroughLiveRestore() async throws {
    let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    harness.storage.set(512 * 1024 * 1024 + 1)
    let restored = try await reconnect(harness)
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await waitUntil { !harness.controller.isMicrophoneRetired }
    harness.storage.set(nil)
    await finish(harness)
  }

  func testUnknownSpaceRefusesRestoreWithAnHonestRetryMessage() async throws {
    for paused in [false, true] {
      let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
      defer { harness.removeFiles() }
      _ = try await captureAndRetire(harness)
      if paused { await harness.controller.stop(pausing: true) }
      let stops = harness.captures.systems.last?.stopCount
      harness.storage.setUnavailable(true)
      harness.controller.reconnectMicrophone()
      await waitUntil {
        harness.controller.errorMessage?.hasPrefix("Available space could not be checked.") == true
      }
      XCTAssertTrue(harness.controller.errorMessage?.hasSuffix("Try again.") == true)
      XCTAssertEqual(harness.controller.phase, paused ? .paused : .capturing)
      XCTAssertEqual(harness.captures.microphones.count, 1)
      XCTAssertEqual(harness.captures.systems.last?.stopCount, stops)
      harness.storage.setUnavailable(false)
      await finish(harness)
    }
  }

  func testMatchingDeviceNamesStillRequireFreshReplacementApproval() async throws {
    var current = device
    let harness = try PauseHarness(microphoneDeviceProbe: { current })
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    current = MicrophoneDeviceIdentity(uniqueID: "restore-b", localizedName: device.localizedName)
    harness.controller.reconnectMicrophone()
    await waitUntil { harness.controller.showsUseThisMicrophone }
    XCTAssertEqual(harness.captures.microphones.count, 1)
    harness.controller.confirmDifferentMicrophone()
    await waitUntil { harness.captures.microphones.count == 2 }
    try XCTUnwrap(harness.captures.microphones.last).emit(
      frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await waitUntil { !harness.controller.isMicrophoneRetired }
    await finish(harness)
  }

  func testReturningSelectedDeviceWaitsForExplicitReconnect() async throws {
    var current: MicrophoneDeviceIdentity? = device
    let harness = try PauseHarness(microphoneDeviceProbe: { current })
    defer { harness.removeFiles() }
    let original = try await captureAndRetire(harness)
    current = nil
    harness.controller.reconnectMicrophone()
    await waitUntil { harness.controller.errorMessage == unavailableMicrophoneSentence }
    current = device
    original.observe(
      .routeRecovered,
      identity: MicrophoneCaptureIdentity(authorization: original.writer.authorization), sequence: 2
    )
    await settle()
    XCTAssertEqual(harness.captures.microphones.count, 1)
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertTrue(harness.controller.showsReconnect)
    let restored = try await reconnect(harness)
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await waitUntil { !harness.controller.isMicrophoneRetired }
    await finish(harness)
  }

  func testBindingAndStartFailurePreserveTheSurvivorAndAllowRetryLiveOrPaused() async throws {
    for paused in [false, true] {
      for startFailure in [false, true] {
        let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
        defer { harness.removeFiles() }
        _ = try await captureAndRetire(harness)
        if paused {
          await harness.controller.stop(pausing: true)
          harness.clock.advance(seconds: 1)
        }
        harness.captures.failNextMicrophoneBinding = !startFailure
        harness.captures.failNextMicrophoneStart = startFailure
        let refused = try await reconnect(harness)
        await waitUntil {
          harness.controller.errorMessage?.hasPrefix("The microphone could not be restored.")
            == true
        }
        let system = try XCTUnwrap(harness.captures.systems.last)
        if paused {
          XCTAssertEqual(harness.controller.phase, .starting)
          XCTAssertEqual(
            harness.controller.errorMessage, microphoneCouldNotBeRestoredResumingSentence)
          try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
        }
        await waitUntil { harness.controller.phase == .capturing }
        XCTAssertEqual(refused.microphoneStartCount, startFailure ? 1 : 0)
        XCTAssertEqual(system.stopCount, 0)
        XCTAssertTrue(harness.controller.showsReconnect)
        let retry = try await reconnect(harness)
        try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
        await waitUntil { !harness.controller.isMicrophoneRetired }
        await finish(harness)
      }
    }
  }

  func testPermissionExplanationIsVisibleWhilePromptIsPending() async throws {
    let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
    defer { harness.removeFiles() }
    _ = try await captureAndRetire(harness)
    let gate = PauseStartGate()
    harness.permission.currentState = .notDetermined
    harness.permission.requestGate = gate
    harness.controller.reconnectMicrophone()
    await fulfillment(of: [gate.entered], timeout: 2)
    XCTAssertEqual(
      harness.controller.errorMessage,
      "Microphone access is needed before the microphone can rejoin.")
    XCTAssertEqual(harness.captures.microphones.count, 1)
    harness.permission.currentState = .authorized
    await gate.release()
    await waitUntil { harness.captures.microphones.count == 2 }
    try XCTUnwrap(harness.captures.microphones.last).emit(
      frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await waitUntil { !harness.controller.isMicrophoneRetired }
    await finish(harness)
  }

  func testTwoRestoresRemainPlayableAfterReopeningTheConversation() async throws {
    let harness = try PauseHarness(microphoneDeviceProbe: { self.device })
    defer { harness.removeFiles() }
    let original = try await captureAndRetire(harness)
    let sessionId = original.writer.authorization.sessionId
    var microphoneTrackIds = Set([original.writer.authorization.trackId])
    for attempt in 0..<2 {
      harness.clock.advance(seconds: 2)
      let restored = try await reconnect(harness)
      microphoneTrackIds.insert(restored.writer.authorization.trackId)
      try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
      try XCTUnwrap(harness.captures.systems.last).emit(
        frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil { !harness.controller.isMicrophoneRetired }
      harness.clock.advance(seconds: 1)
      if attempt == 0 {
        restored.observe(
          .routeInterrupted,
          identity: MicrophoneCaptureIdentity(authorization: restored.writer.authorization),
          sequence: 1)
        await waitUntil { harness.controller.isMicrophoneRetired }
      }
    }
    await finish(harness)
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    let timeline = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertTrue(microphoneTrackIds.isSubset(of: Set(timeline.map(\.trackId))))
    let microphone = timeline.filter { microphoneTrackIds.contains($0.trackId) }
      .sorted { $0.nativeStartNanoseconds < $1.nativeStartNanoseconds }
    XCTAssertGreaterThanOrEqual(microphone.count, 3)
    for segment in microphone {
      let reader = try TimelinePCMReader(
        segments: [segment], startNanoseconds: segment.startNanoseconds)
      let buffer = try XCTUnwrap(reader.read(maximumFrames: 48_000))
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
      XCTAssertTrue(samples.contains { abs($0) > 0.01 }, "each restored span independently decodes")
    }
    for pair in zip(microphone, microphone.dropFirst()) {
      let end = pair.0.nativeStartNanoseconds + Int64(pair.0.sampleCount * 1_000_000_000 / 48_000)
      XCTAssertGreaterThan(pair.1.nativeStartNanoseconds, end, "saved gaps survive reopen")
    }
    XCTAssertEqual(try reopened.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
  }

  private func makeHarness(_ deadlines: ManualRestoreDeadlines) throws -> PauseHarness {
    try PauseHarness(
      microphoneDeviceProbe: { self.device }, restoreTimeoutWait: { _ in await deadlines.wait() })
  }

  private func captureAndRetire(_ harness: PauseHarness) async throws -> PauseSource {
    await harness.controller.start()
    try await harness.capture()
    let source = try XCTUnwrap(harness.captures.microphones.last)
    source.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: source.writer.authorization), sequence: 1)
    await waitUntil { harness.controller.isMicrophoneRetired }
    return source
  }

  private func reconnect(_ harness: PauseHarness) async throws -> PauseSource {
    let count = harness.captures.microphones.count
    harness.controller.reconnectMicrophone()
    await waitUntil { harness.captures.microphones.count == count + 1 }
    return try XCTUnwrap(harness.captures.microphones.last)
  }

  private func untrustedFirstReceipt(_ source: PauseSource, harness: PauseHarness)
    -> NativeFirstSampleReceipt
  {
    let authorization = source.writer.authorization
    return NativeFirstSampleReceipt(
      sessionId: authorization.sessionId, trackId: authorization.trackId,
      segmentId: authorization.segmentId, openToken: authorization.openToken,
      writerGeneration: authorization.writerGeneration, relativePath: authorization.relativePath,
      firstSampleHostTime: harness.clock.now, firstSampleFrameCount: 1, observedByteLength: 0)
  }

  private func finish(_ harness: PauseHarness) async {
    harness.clock.advance(seconds: 1)
    await harness.controller.stop()
    await waitUntil {
      harness.controller.phase == .saved && !harness.controller.statusText.hasSuffix("…")
    }
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line,
    _ predicate: @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !predicate(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(predicate(), file: file, line: line)
  }

  private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

/// Non-cooperating waits also exercise cancellation of an old timer after Stop
/// or successful restoration. Every test releases all continuations on exit.
@MainActor
private final class ManualRestoreDeadlines {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  var count: Int { waiters.count }
  func wait() async { await withCheckedContinuation { waiters.append($0) } }
  func releaseNext() {
    guard !waiters.isEmpty else { return }
    waiters.removeFirst().resume()
  }
  func releaseAll() { while !waiters.isEmpty { releaseNext() } }
}
