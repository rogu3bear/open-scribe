import AVFoundation
import Darwin
import XCTest

@testable import OpenScribeApp

/// Real journal/SQLite, UniFFI, segmented CAF writers and controller; injected
/// sources supply PCM instead of requesting TCC or opening audio devices.
@MainActor
final class RecorderPauseResumeTests: XCTestCase {
  func testRestoreFailureBeforeFirstSampleLeavesReconnectAvailable() async throws {
    for failure in [MicrophoneSourceHealthEvent.routeInterrupted, .writerFailed] {
      let device = MicrophoneDeviceIdentity(uniqueID: "selected-microphone", localizedName: "Mic")
      let harness = try PauseHarness(microphoneDeviceProbe: { device })
      defer { harness.removeFiles() }
      _ = try await captureAndRetireMicrophone(harness)
      let system = try XCTUnwrap(harness.captures.systems.last)
      let restored = try await reconnectMicrophone(harness)
      if failure == .routeInterrupted {
        restored.observe(
          failure,
          identity: MicrophoneCaptureIdentity(authorization: restored.writer.authorization),
          sequence: 1)
      } else {
        restored.failMicrophone(.writerFailed)
      }
      await settle()
      XCTAssertTrue(harness.controller.isMicrophoneRetired)
      XCTAssertTrue(harness.controller.showsReconnect)
      XCTAssertEqual(
        harness.controller.errorMessage,
        "The microphone could not be restored. System audio is still recording.")
      XCTAssertEqual(system.stopCount, 0)

      let retry = try await reconnectMicrophone(harness)
      try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
      try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await settle()
      XCTAssertFalse(harness.controller.isMicrophoneRetired)
      await finishRestoredRecording(harness)
    }
  }

  func testReplacementMicrophoneRestartsObservationSequenceAndCanRecoverAgain() async throws {
    let device = MicrophoneDeviceIdentity(uniqueID: "selected-microphone", localizedName: "Mic")
    let harness = try PauseHarness(microphoneDeviceProbe: { device })
    defer { harness.removeFiles() }
    let original = try await captureAndRetireMicrophone(harness, sequence: 100)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let restored = try await reconnectMicrophone(harness)
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)

    restored.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: restored.writer.authorization),
      sequence: 1)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired, "sequence 1 belongs to the new adapter")
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertEqual(restored.stopCount, 1)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(harness.controller.microphoneSourceHealth?.sequence, 1)

    let second = try await reconnectMicrophone(harness)
    // Late callbacks from the previous adapter cannot cancel this new restore.
    restored.failMicrophone(.writerFailed)
    restored.repeatFirstCallback()
    original.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: original.writer.authorization),
      sequence: 101)
    await settle()
    XCTAssertEqual(second.stopCount, 0)
    harness.clock.advance(seconds: 1)
    try second.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    XCTAssertEqual(harness.captures.microphones.count, 3)
    await finishRestoredRecording(harness)
  }

  func testWriterFailureAfterRestoreRetiresTheMicrophoneAndAllowsAnotherAttempt() async throws {
    let device = MicrophoneDeviceIdentity(uniqueID: "selected-microphone", localizedName: "Mic")
    let harness = try PauseHarness(microphoneDeviceProbe: { device })
    defer { harness.removeFiles() }
    _ = try await captureAndRetireMicrophone(harness)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let restored = try await reconnectMicrophone(harness)
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    restored.failMicrophone(.writerFailed)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(restored.stopCount, 1)
    XCTAssertEqual(system.stopCount, 0)

    let retry = try await reconnectMicrophone(harness)
    harness.clock.advance(seconds: 1)
    try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try system.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    await finishRestoredRecording(harness)
  }

  func testConfirmingMicrophoneBRequiresFreshConfirmationWhenInputChangesToC() async throws {
    let microphoneA = MicrophoneDeviceIdentity(uniqueID: "microphone-a", localizedName: "A")
    let microphoneB = MicrophoneDeviceIdentity(uniqueID: "microphone-b", localizedName: "B")
    let microphoneC = MicrophoneDeviceIdentity(uniqueID: "microphone-c", localizedName: "C")
    var currentDevice = microphoneA
    let harness = try PauseHarness(microphoneDeviceProbe: { currentDevice })
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    microphone.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: microphone.writer.authorization),
      sequence: 1)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    let originalAudioURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    let originalAudio = try Data(contentsOf: originalAudioURL)

    currentDevice = microphoneB
    harness.controller.reconnectMicrophone()
    await settle()
    XCTAssertTrue(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(harness.captures.microphones.count, 1)

    // The displayed choice concerned B. The later asynchronous probe sees C.
    harness.controller.confirmDifferentMicrophone()
    currentDevice = microphoneC
    await settle()
    XCTAssertTrue(harness.controller.showsUseThisMicrophone, "C needs its own confirmation")
    XCTAssertEqual(
      harness.controller.errorMessage,
      "This is a different microphone. System audio is still recording.")
    XCTAssertEqual(harness.captures.microphones.count, 1, "confirming B must not start C")
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertFalse(
      try harness.preparation.recorderDetail(sessionId: sessionId).events.contains {
        $0.kind == "microphone_restore_requested"
      }, "no restore may be journaled for unapproved C")

    // Fresh approval for C permits exactly one new microphone in this session.
    harness.controller.confirmDifferentMicrophone()
    await settle()
    XCTAssertEqual(harness.captures.microphones.count, 2)
    let restored = try XCTUnwrap(harness.captures.microphones.last)
    XCTAssertEqual(restored.writer.authorization.sessionId, sessionId)
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    XCTAssertFalse(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(harness.captures.systems.count, 1)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: microphone.writer.authorization.absolutePath)),
      originalAudio)
    harness.clock.advance(seconds: 1)
    await harness.controller.stop()
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while harness.controller.statusText.hasSuffix("…"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertFalse(harness.controller.statusText.hasSuffix("…"))
  }

  func testPausedRestoreRejectsDeviceChangeDuringSuspendedSystemStartup() async throws {
    let microphoneC = MicrophoneDeviceIdentity(uniqueID: "microphone-c", localizedName: "C")
    for order in [PausedRestoreSampleOrder.beforeStartupReturns, .afterStartupReturns] {
      try await assertPausedRestoreDoesNotStartAnUnapprovedMicrophone(
        sampleArrives: order, replacement: microphoneC)
    }
  }

  func testPausedRestoreRejectsMissingDeviceDuringSuspendedSystemStartup() async throws {
    for order in [PausedRestoreSampleOrder.beforeStartupReturns, .afterStartupReturns] {
      try await assertPausedRestoreDoesNotStartAnUnapprovedMicrophone(
        sampleArrives: order, replacement: nil)
    }
  }

  func testPausedRestoreCaptureFailureBeforeMicrophoneSampleConfirmsTheSurvivingSource()
    async throws
  {
    for order in [PausedRestoreSampleOrder.beforeStartupReturns, .afterStartupReturns] {
      try await assertApprovedPausedRestoreFailsBeforeMicrophoneSample(
        sampleArrives: order, failure: .captureFailed)
    }
  }

  func testPausedRestorePermissionWithdrawalBeforeMicrophoneSampleConfirmsTheSurvivingSource()
    async throws
  {
    for order in [PausedRestoreSampleOrder.beforeStartupReturns, .afterStartupReturns] {
      try await assertApprovedPausedRestoreFailsBeforeMicrophoneSample(
        sampleArrives: order, failure: .permissionWithdrawn)
    }
  }

  /// Fail the paused restore while opening the replacement microphone, before
  /// that adapter starts and before the resumed system writer is accepted.
  /// Both orders of the surviving system sample are covered. A sample that
  /// confirms Recording while system startup is still suspended must leave
  /// that source running when startup returns. Until Rust confirms, Starting
  /// says the recording is resuming.
  func testPausedRestoreMediaOpenFailureBeforeResumedSystemSampleKeepsResumingWording()
    async throws
  {
    for order in [PausedRestoreSampleOrder.beforeStartupReturns, .afterStartupReturns] {
      try await assertPausedRestoreMediaOpenFailure(sampleArrives: order)
    }
  }

  /// Ordinary resume of a retired microphone starts only system audio. That
  /// start shares the post-await guard. A first sample can confirm the span
  /// before startup returns, and that return must not stop the survivor.
  func testRetiredMicrophoneResumeKeepsConfirmedSystemWhenStartupReturnsLater() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let sessionId = microphone.writer.authorization.sessionId
    let originalURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    microphone.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: microphone.writer.authorization),
      sequence: 1)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    let originalAudio = try Data(contentsOf: originalURL)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    harness.clock.advance(seconds: 1)

    let gate = PauseStartGate()
    harness.captures.nextSystemStartGate = gate
    let microphonesBeforeResume = harness.captures.microphones.count
    let startupReturned = XCTestExpectation(description: "Retired microphone resume returned")
    Task { @MainActor in
      await harness.controller.start(resuming: true)
      startupReturned.fulfill()
    }
    await fulfillment(of: [gate.entered], timeout: 2)
    let resumedSystem = try XCTUnwrap(harness.captures.systems.last)
    XCTAssertEqual(harness.captures.systems.count, 2)
    XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeResume)
    XCTAssertEqual(microphone.microphoneStartCount, 1)
    XCTAssertEqual(harness.controller.phase, .starting)
    XCTAssertEqual(resumedSystem.stopCount, 0)

    let samplesBeforeResume = try journalCount(
      harness, sessionId: sessionId, event: "first_sample_captured")
    try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await waitUntil {
      harness.controller.phase == .capturing
        && harness.controller.statusText == "Recording continues with remaining audio"
        && (try? journalCount(harness, sessionId: sessionId, event: "first_sample_captured"))
          == samplesBeforeResume + 1
        && (try? harness.preparation.recorderDetail(sessionId: sessionId).lifecycle) == "recording"
    }
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeResume)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)

    await gate.release()
    await fulfillment(of: [startupReturned], timeout: 2)
    XCTAssertEqual(
      resumedSystem.stopCount, 0,
      "ordinary resume must not stop a survivor confirmed before startup returns")
    guard resumedSystem.stopCount == 0 else { return }
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(
      harness.controller.statusText, "Recording continues with remaining audio")
    XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeResume)
    XCTAssertEqual(microphone.microphoneStartCount, 1)
    XCTAssertEqual(harness.controller.contextBinding?.sessionId, sessionId)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    let resumed = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(resumed.lifecycle, "recording")

    harness.clock.advance(seconds: 1)
    try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(harness.controller.phase, .capturing)
    await harness.controller.stop()
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while harness.controller.statusText.hasSuffix("…"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    let saved = try reopened.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(saved.lifecycle, "ready_for_review")
    let plan = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.reduce(0) { $0 + $1.sampleCount }, 192_000)
  }

  func testObservedPermissionRevocationPersistsAndNeverRestartsTheRetiredMicrophone() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    harness.permission.currentState = .denied
    // No capture callback: the production permission watch must discover loss.
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !harness.controller.isMicrophoneRetired, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(harness.controller.isMicrophoneRetired, harness.controller.errorMessage ?? "")
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(
      harness.controller.errorMessage,
      "Microphone access was withdrawn. System audio is still recording.")
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertFalse(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 0)
    let detail = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "recording")
    let failure = try XCTUnwrap(detail.events.first { $0.kind == "source_failed" })
    let microphoneURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    let sealedMicrophone = try Data(contentsOf: microphoneURL)

    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertEqual(
      harness.controller.errorMessage,
      "Microphone access was withdrawn. System audio is still recording.")
    // An obsolete watch cannot interrupt a paused session. Permission restoration
    // still requires an explicit start and cannot revive this retired source.
    try await Task.sleep(for: .milliseconds(2_100))
    XCTAssertEqual(harness.controller.phase, .paused)
    harness.permission.currentState = .authorized
    harness.clock.advance(seconds: 600)
    await harness.controller.start(resuming: true)
    XCTAssertEqual(harness.captures.microphones.count, 1)
    XCTAssertEqual(harness.captures.systems.count, 2)
    let resumed = try XCTUnwrap(harness.captures.systems.last)
    try resumed.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertEqual(harness.captures.microphones.count, 1)
    XCTAssertEqual(
      harness.controller.errorMessage,
      "The microphone stopped. System audio is still recording.")
    harness.clock.advance(seconds: 1)
    await harness.controller.stop()
    let mixDeadline = ContinuousClock.now.advanced(by: .seconds(4))
    while harness.controller.statusText.hasSuffix("…"), ContinuousClock.now < mixDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertFalse(harness.controller.statusText.hasSuffix("…"))
    XCTAssertEqual(try Data(contentsOf: microphoneURL), sealedMicrophone)

    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    let restored = try reopened.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(restored.lifecycle, "ready_for_review")
    XCTAssertEqual(restored.events.filter { $0.kind == "source_failed" }, [failure])
    let journalURL = harness.root.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let records = try String(contentsOf: journalURL, encoding: .utf8).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    let failures = records.filter { $0["event_kind"] as? String == "source_failed" }
    XCTAssertEqual(failures.count, 1)
    let payload = try XCTUnwrap(failures.first?["payload"] as? [String: Any])
    XCTAssertEqual(payload["reason"] as? String, "permission_revoked")
    let plan = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 3, "one sealed microphone segment and two continuing system spans")
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    var frames: UInt64 = 0
    while let buffer = try reader.read(maximumFrames: 4096) { frames += UInt64(buffer.frameLength) }
    XCTAssertEqual(frames, 96_000)
    XCTAssertEqual(try Data(contentsOf: microphoneURL), sealedMicrophone)
  }

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

  func testSystemSleepPausesThroughTheSealedPathAndWakeNeverResumes() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let sessionId = try XCTUnwrap(harness.captures.microphones.first).writer.authorization.sessionId

    await harness.controller.systemWillSleep()
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertTrue(harness.controller.canResume)
    XCTAssertEqual(try XCTUnwrap(harness.captures.microphones.last).stopCount, 1)
    XCTAssertEqual(try XCTUnwrap(harness.captures.systems.last).stopCount, 1)
    XCTAssertTrue(harness.controller.errorMessage?.contains("went to sleep") == true)

    harness.clock.advance(seconds: 600)
    harness.controller.systemDidWake()
    XCTAssertEqual(harness.controller.phase, .paused, "wake never resumes capture")
    let kinds = try harness.preparation.recorderDetail(sessionId: sessionId).events.map(\.kind)
    XCTAssertEqual(
      kinds.filter { $0.hasPrefix("system_") }, ["system_sleep_observed", "system_wake_observed"])
    XCTAssertLessThan(
      try XCTUnwrap(kinds.firstIndex(of: "system_sleep_observed")),
      try XCTUnwrap(kinds.firstIndex(of: "capture_paused")))
    XCTAssertEqual(harness.controller.recorderDetail?.events.last?.kind, "system_wake_observed")

    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
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

  /// F1: the adapter binds its identity when capture starts, but every 30 s
  /// rotation advances the segment generation. Route loss reported after the
  /// first rotation must still degrade the microphone instead of being dropped.
  func testRouteInterruptionAfterRotationDegradesMicrophoneCapture() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    let boundIdentity = MicrophoneCaptureIdentity(authorization: microphone.writer.authorization)
    try await harness.capture()
    try microphone.emit(frames: 1_440_000, hostTime: harness.clock.now, value: 8192)
    XCTAssertEqual(
      microphone.writer.authorization.writerGeneration, boundIdentity.writerGeneration + 1,
      "the microphone rotated into its second segment")
    harness.clock.advance(seconds: 30)

    microphone.observe(.routeInterrupted, identity: boundIdentity, sequence: 1)
    await settle()

    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(harness.controller.microphoneSourceHealth?.event, .routeInterrupted)
    XCTAssertEqual(harness.controller.failureCode, "capture-route-interrupted")
    XCTAssertEqual(harness.controller.statusText, "Recording continues with remaining audio")
    XCTAssertTrue(
      harness.controller.recorderDetail?.events.contains { $0.kind == "source_failed" } == true,
      "the durable failure must reach the native recorder event list")
    XCTAssertEqual(harness.telemetry.snapshot().map(\.observation.event), [.routeInterrupted])
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "recording")

    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 3, "two sealed microphone segments and one system segment")
    XCTAssertEqual(plan.filter { $0.sequence == 1 }.map(\.sampleCount), [48_000])
  }

  /// F5: after degraded continuation the failed source leaves the required
  /// set. Resume authorizes only the continuing source and stop finalizes.
  func testResumeAfterSourceFailureContinuesOnTheRemainingSource() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    try await harness.capture()

    system.fail(.streamStopped)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(harness.controller.statusText, "Recording continues with remaining audio")
    XCTAssertEqual(system.stopCount, 1)

    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertEqual(microphone.stopCount, 1)
    harness.clock.advance(seconds: 600)

    await harness.controller.start(resuming: true)
    XCTAssertEqual(harness.controller.phase, .starting, harness.controller.errorMessage ?? "")
    XCTAssertEqual(harness.captures.systems.count, 1, "the failed source is not restarted")
    XCTAssertEqual(harness.captures.microphones.count, 2)
    let resumedMicrophone = try XCTUnwrap(harness.captures.microphones.last)
    try resumedMicrophone.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(harness.controller.statusText, "Recording continues with remaining audio")
    harness.clock.advance(seconds: 1)

    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 3, "one system segment plus two microphone segments")
  }

  /// N1 (F11's stated scenario): a first sample followed at once by a
  /// host-time gap rotates segment 0 before the main-actor first-sample task
  /// runs. Startup must still succeed with the receipt on the right segment.
  func testEarlyRotationBeforeRecordingConfirmationStillStartsCapture() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    let start = harness.clock.now
    try microphone.emit(frames: 480, hostTime: start, value: 8192)
    // Before the controller's task can replay the receipt, a gap forces a rotation.
    try microphone.emit(
      frames: 480, hostTime: start + AVAudioTime.hostTime(forSeconds: 2), value: 8192)
    XCTAssertEqual(microphone.writer.authorization.writerGeneration, 2)
    try system.emit(frames: 480, hostTime: start, value: 16384)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing, harness.controller.errorMessage ?? "")
    harness.clock.advance(seconds: 3)
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(plan.count, 3, "two microphone segments around the gap plus one system segment")
    XCTAssertEqual(plan.filter { $0.sequence == 1 }.map(\.gapNanoseconds), [1_990_000_000])
  }

  /// F6: a resume that fails its storage-reserve preflight must return to Paused
  /// with Resume and Stop available and an explanation, and Rust must stay paused.
  func testResumeBelowStorageReserveReturnsToPausedWithControls() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    try await harness.captureAndPause()
    let sessionId = try XCTUnwrap(harness.captures.microphones.first).writer.authorization.sessionId
    let paths = harness.controller.savedPaths
    XCTAssertEqual(try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "paused")

    // Free space falls below the reserve before the resume attempt.
    harness.storage.set(64 * 1024 * 1024)
    harness.clock.advance(seconds: 600)
    await harness.controller.start(resuming: true)

    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertTrue(harness.controller.canResume)
    XCTAssertTrue(harness.controller.canStop)
    XCTAssertFalse(harness.controller.canStart)
    XCTAssertEqual(harness.controller.savedPaths, paths)
    XCTAssertTrue(
      harness.controller.errorMessage?.contains("Not enough free space") == true,
      harness.controller.errorMessage ?? "no message")
    XCTAssertEqual(harness.captures.microphones.count, 1, "no new span started")
    XCTAssertEqual(try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "paused")
    XCTAssertFalse(
      try harness.preparation.recorderDetail(sessionId: sessionId).events.contains {
        $0.kind == "capture_resumed"
      })

    // With space restored, the explicit retry resumes and finalizes.
    harness.storage.set(nil)
    await harness.controller.start(resuming: true)
    try await harness.capture()
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    XCTAssertEqual(try harness.preparation.playbackTimeline(sessionId: sessionId).count, 4)
  }

  /// F7: rotation reserves the successor before opening and sealing. A failure at
  /// any of those steps must abandon the reserved successor durably so the
  /// remaining source keeps recording and Stop still finalizes; the UI never
  /// shows Saved before Rust reaches ready_for_review.
  func testRotationStepFailureDegradesAndStopStillFinalizes() async throws {
    for step in RotationFailureStep.allCases {
      let harness = try PauseHarness(rotationInjection: true)
      defer { harness.removeFiles() }
      await harness.controller.start()
      let microphone = try XCTUnwrap(harness.captures.microphones.last)
      let system = try XCTUnwrap(harness.captures.systems.last)
      let sessionId = microphone.writer.authorization.sessionId
      try await harness.capture()
      XCTAssertEqual(harness.controller.phase, .capturing, "\(step)")

      // Arm the injected failure, then force the microphone to rotate with a
      // host-time gap. The rotation reserves the successor, then fails.
      harness.rotationInjector!.arm(step)
      try microphone.emit(
        frames: 480, hostTime: harness.clock.now + AVAudioTime.hostTime(forSeconds: 2), value: 8192)
      await settle()

      XCTAssertEqual(
        harness.controller.phase, .capturing,
        "the remaining source keeps recording after \(step): \(harness.controller.errorMessage ?? "")"
      )
      XCTAssertEqual(
        harness.controller.statusText, "Recording continues with remaining audio", "\(step)")
      XCTAssertEqual(microphone.stopCount, 1, "\(step)")
      XCTAssertEqual(system.stopCount, 0, "\(step)")
      XCTAssertEqual(
        try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "recording",
        "\(step)")

      harness.clock.advance(seconds: 1)
      await harness.controller.stop()

      XCTAssertEqual(harness.controller.phase, .saved, "\(step)")
      // The degrade left an informational note; the recording still saved and
      // the stereo mix settles to a terminal saved status.
      for _ in 0..<500 where harness.controller.statusText.hasSuffix("…") {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(
        [
          "Recording saved with verified stereo mix",
          "Source tracks saved; stereo mix unavailable",
        ].contains(harness.controller.statusText),
        "\(step): \(harness.controller.statusText)")
      XCTAssertEqual(
        try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review",
        "\(step)")
      let saved = try harness.preparation.runtimeLibrarySnapshot().savedSessions.first {
        $0.sessionId == sessionId
      }
      XCTAssertEqual(saved?.mediaFilesOpen, false, "media files are closed after \(step)")
      _ = try harness.preparation.recoverPlayableSessions()
      XCTAssertEqual(
        try harness.preparation.playbackTimeline(sessionId: sessionId).count, 2,
        "the microphone predecessor and the system segment remain playable after \(step)")
    }
  }

  /// G8: a rotation sealed the predecessor, then the successor's first sample
  /// was rejected. The successor never became a real segment, so the failure
  /// retires only that source; the recording continues and saves.
  func testFirstSampleFailureAfterRotationDegradesAndStopStillFinalizes() async throws {
    let harness = try PauseHarness(rotationInjection: true)
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    try await harness.capture()

    // A host-time gap rotates the microphone; its successor's first sample fails.
    harness.rotationInjector!.rejectNextFirstSample()
    try microphone.emit(
      frames: 480, hostTime: harness.clock.now + AVAudioTime.hostTime(forSeconds: 2), value: 8192)
    await settle()

    XCTAssertEqual(microphone.writer.authorization.writerGeneration, 2, "the rotation completed")
    XCTAssertEqual(harness.controller.phase, .capturing, harness.controller.errorMessage ?? "")
    XCTAssertEqual(harness.controller.statusText, "Recording continues with remaining audio")
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "recording")

    harness.clock.advance(seconds: 1)
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved, harness.controller.errorMessage ?? "")
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    XCTAssertEqual(
      try harness.preparation.playbackTimeline(sessionId: sessionId).count, 2,
      "the sealed microphone predecessor and the system segment stay playable")
  }

  /// G1: a source that failed while recording can be selected again while
  /// paused. Resume starts it as a new source instead of interrupting.
  func testReselectingAFailedSourceWhilePausedResumesItAsANewSource() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let system = try XCTUnwrap(harness.captures.systems.last)
    let sessionId = microphone.writer.authorization.sessionId
    try await harness.capture()
    system.fail(.streamStopped)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertEqual(harness.controller.sourceSelectionPresentation.summary, "Microphone only")
    XCTAssertTrue(
      harness.controller.sourceSelectionPresentation.unavailableNotice?.contains(
        "Mac system audio stopped earlier") == true)
    harness.clock.advance(seconds: 60)

    harness.controller.selectCaptureSource(.system)
    XCTAssertNil(harness.controller.errorMessage)
    XCTAssertEqual(
      harness.controller.sourceSelectionPresentation.summary, "Microphone + Mac system audio")
    XCTAssertNil(harness.controller.sourceSelectionPresentation.unavailableNotice)
    await harness.controller.start(resuming: true)
    XCTAssertEqual(harness.controller.phase, .starting, harness.controller.errorMessage ?? "")
    XCTAssertEqual(harness.captures.systems.count, 2, "the reselected source starts again")
    try XCTUnwrap(harness.captures.microphones.last)
      .emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try XCTUnwrap(harness.captures.systems.last)
      .emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing, harness.controller.errorMessage ?? "")
    XCTAssertEqual(harness.controller.statusText, "Recording microphone + system audio")
    harness.clock.advance(seconds: 1)

    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved, harness.controller.errorMessage ?? "")
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
    _ = try harness.preparation.recoverPlayableSessions()
    XCTAssertEqual(
      try harness.preparation.playbackTimeline(sessionId: sessionId).count, 4,
      "both microphone spans, the failed system source, and its replacement")
  }

  /// G5: after the microphone failed, a microphone-only scope would record
  /// nothing. Both layers refuse it and the paused session still resumes.
  func testMicrophoneOnlyIsRefusedAfterTheMicrophoneFailed() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let sessionId = microphone.writer.authorization.sessionId
    let boundIdentity = MicrophoneCaptureIdentity(authorization: microphone.writer.authorization)
    try await harness.capture()
    microphone.observe(.routeInterrupted, identity: boundIdentity, sequence: 1)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertEqual(harness.controller.sourceSelectionPresentation.summary, "Mac system audio")
    XCTAssertTrue(
      harness.controller.sourceSelectionPresentation.unavailableNotice?.contains(
        "Microphone stopped earlier") == true)
    XCTAssertFalse(
      harness.controller.sourceSelectionPresentation.help.contains("Microphone audio is included"))
    harness.clock.advance(seconds: 60)

    harness.controller.selectCaptureSource(.microphoneOnly)
    XCTAssertEqual(harness.controller.captureSelection.kind, .systemAudio)
    XCTAssertTrue(
      harness.controller.errorMessage?.contains("Microphone only has nothing to record") == true,
      harness.controller.errorMessage ?? "")
    XCTAssertThrowsError(
      try harness.preparation.recorderAction(
        sessionId: sessionId,
        action: .selectAudio(kind: nil, identity: "microphone-only", displayName: "Microphone only")
      ),
      "Rust refuses a scope with no source that can capture")

    harness.permission.currentState = .denied
    await harness.controller.start(resuming: true)
    XCTAssertEqual(harness.controller.phase, .starting, harness.controller.errorMessage ?? "")
    XCTAssertEqual(harness.captures.microphones.count, 1, "the retired microphone stays stopped")
    XCTAssertEqual(harness.controller.statusText, "Starting the remaining audio…")
    try XCTUnwrap(harness.captures.systems.last)
      .emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertEqual(harness.controller.phase, .capturing, harness.controller.errorMessage ?? "")
    harness.clock.advance(seconds: 1)
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved, harness.controller.errorMessage ?? "")
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "ready_for_review")
  }

  /// F13: the storage probe reports important-usage capacity, which includes
  /// purgeable APFS space, so the reserve preflight is not tripped while space
  /// is available. The existing per-source storage seam consumes this number.
  func testStorageProbeReportsImportantUsageIncludingPurgeableSpace() throws {
    let root = FileManager.default.temporaryDirectory
    let reported = try RecorderStorage.availableBytes(at: root.path)
    // Read the same metric back immediately; free space drifts under concurrent
    // I/O, so compare within a tolerance rather than for exact equality.
    let importantUsage = try XCTUnwrap(
      root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage)
    XCTAssertGreaterThan(reported, 0)
    XCTAssertLessThan(
      abs(Int64(reported) - importantUsage), 64 * 1024 * 1024,
      "the probe tracks important-usage capacity (purgeable included), not the plain free size")
  }

  /// F13: a volume that cannot report capacity is unknown under the reserve
  /// policy. It surfaces as an error the callers treat conservatively, never as
  /// unlimited space.
  func testStorageProbeTreatsAnUnreadableVolumeAsUnknownNotUnlimited() {
    XCTAssertThrowsError(
      try RecorderStorage.availableBytes(at: "/does-not-exist-\(UUID().uuidString)/audio"))
  }

  func testACapturedConversationOpensFromAPortablePackageInAnotherLibrary() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    await harness.controller.stop()
    XCTAssertEqual(harness.controller.phase, .saved)
    let sessionId = try XCTUnwrap(harness.captures.microphones.first).writer.authorization.sessionId
    let sourcePlan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    let exchange = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: exchange) }
    let package = exchange.appendingPathComponent("Call.openscribe", isDirectory: true)
    _ = try NativeTranscriptLibrary.open(managedRoot: harness.root.path)
      .exportPortablePackage(sessionId: sessionId, destinationPath: package.path)

    // The other Mac opens it through the same path the toolbar uses.
    let otherRoot = exchange.appendingPathComponent("Other Mac", isDirectory: true)
    let runtime = RuntimeLibraryStore(managedRoot: otherRoot)
    let adapter = ImportedMediaAuthorityAdapter(
      startSecurityScope: { _ in true },
      stopSecurityScope: { _ in },
      importer: { _, _ in throw CancellationError() },
      packagePicker: { package },
      packageOpener: { try runtime.openPortablePackage(packageURL: $0) }
    )
    adapter.chooseAndOpenPackage()
    for _ in 0..<500 where adapter.phase == .importing {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(adapter.phase, .succeeded, adapter.statusMessage ?? "no status")
    let restoredId = try XCTUnwrap(adapter.importedSessionId)
    XCTAssertNotEqual(restoredId, sessionId)
    XCTAssertTrue(adapter.statusMessage?.contains("2 audio files") == true)

    let other = try NativeRecordingPreparation.open(managedRoot: otherRoot.path)
    let restoredPlan = try other.playbackTimeline(sessionId: restoredId)
    XCTAssertEqual(
      restoredPlan.map { [$0.sequence, $0.sampleCount, UInt64($0.startNanoseconds)] },
      sourcePlan.map { [$0.sequence, $0.sampleCount, UInt64($0.startNanoseconds)] })
    func samples(_ plan: [NativeTimelineSegment]) throws -> [Float] {
      let reader = try TimelinePCMReader(segments: plan)
      defer { reader.close() }
      var values: [Float] = []
      while let buffer = try reader.read(maximumFrames: 4096) {
        values += UnsafeBufferPointer(
          start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      }
      return values
    }
    let restoredSamples = try samples(restoredPlan)
    XCTAssertEqual(restoredSamples.count, 48_000)
    XCTAssertEqual(restoredSamples, try samples(sourcePlan))
    for _ in 0..<500 where !runtime.savedSessions.contains(where: { $0.sessionId == restoredId }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let saved = try XCTUnwrap(runtime.savedSessions.first { $0.sessionId == restoredId })
    XCTAssertTrue(saved.hasCaptureTimeline)

    // The same package cannot be opened once a file inside it changes.
    let media = try XCTUnwrap(
      FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.pathExtension == "caf" })
    var bytes = try Data(contentsOf: media)
    bytes[bytes.count - 1] ^= 0x01
    try bytes.write(to: media)
    adapter.chooseAndOpenPackage()
    for _ in 0..<500 where adapter.phase == .importing {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(adapter.phase, .failed)
    XCTAssertTrue(adapter.statusMessage?.contains("did not verify") == true)
  }

  func testTheDriftRunNeverSleepsOnAnExpiredDeadline() async throws {
    try await assertDriftDeadline(terminalUptime: 1)
  }

  func testTheDriftRunStopsNormallyWhenTheClockCrossesItsDeadline() async throws {
    try await assertDriftDeadline(terminalUptime: 1.1)
  }

  func testTheDriftRunRoundsAPositiveSubnanosecondWaitUp() async throws {
    try await assertDriftDeadline(terminalUptime: 1, lastWaitUptime: Double(1).nextDown)
  }

  private func assertDriftDeadline(
    terminalUptime: TimeInterval, lastWaitUptime: TimeInterval = 0.9
  ) async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let root = harness.root.appendingPathComponent("drift-outcome", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // The clock reaches the deadline between successive reads. A second
    // read for the same wait used to produce zero (or a trapping negative).
    let clockReads: [TimeInterval] = [0, lastWaitUptime, terminalUptime]
    var readIndex = 0
    var recordingWaits: [UInt64] = []
    let outcome = await DriftRunProof.run(
      controller: harness.controller, root: root, seconds: 1,
      uptime: {
        defer { readIndex += 1 }
        return clockReads[min(readIndex, clockReads.count - 1)]
      },
      sleep: { nanoseconds in
        if harness.controller.phase == .capturing {
          recordingWaits.append(nanoseconds)
        } else if harness.controller.phase == .starting {
          try? await harness.capture()
        }
        for _ in 0..<30 { await Task.yield() }
      })
    XCTAssertEqual(recordingWaits.count, 1)
    XCTAssertTrue(recordingWaits.allSatisfy { $0 > 0 && $0 <= 1_000_000_000 })
    XCTAssertEqual(outcome.result, "saved", outcome.detail)
    XCTAssertEqual(outcome.recordedSeconds, terminalUptime)
    let sessionId = try XCTUnwrap(outcome.sessionId)
    let detail = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(detail.lifecycle, "ready_for_review")
    XCTAssertEqual(harness.captures.microphones.last?.stopCount, 1)
    XCTAssertEqual(harness.captures.systems.last?.stopCount, 1)
    let timeline = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(Set(timeline.map(\.trackId)).count, 2)
    let written = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent(DriftRunProof.outcomeName)))
        as? [String: Any])
    XCTAssertEqual(written["result"] as? String, "saved")
    XCTAssertEqual(written["session_id"] as? String, sessionId)
  }

  func testTheDriftRunRecordsBothSourcesUntilItsDeadlineAndRefusesUnboundedRuns() async throws {
    let harness = try PauseHarness()
    defer { harness.removeFiles() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for seconds: UInt64 in [0, DriftRunProof.maximumSeconds + 1] {
      let refused = await DriftRunProof.run(
        controller: harness.controller, root: root, seconds: seconds)
      XCTAssertEqual(refused.result, "refused")
      XCTAssertEqual(harness.controller.phase, .idle)
      XCTAssertTrue(harness.captures.microphones.isEmpty, "an unbounded run never opens a source")
    }

    var uptime: TimeInterval = 0
    let outcome = await DriftRunProof.run(
      controller: harness.controller, root: root, seconds: 3,
      uptime: { uptime },
      sleep: { nanoseconds in
        // Every wait delivers that interval's audio from both sources.
        let interval = Double(nanoseconds) / 1_000_000_000
        if let microphone = harness.captures.microphones.last,
          let system = harness.captures.systems.last
        {
          let frames = AVAudioFrameCount(interval * 48_000)
          try? microphone.emit(frames: frames, hostTime: harness.clock.now, value: 8192)
          try? system.emit(frames: frames, hostTime: harness.clock.now, value: 16384)
        }
        for _ in 0..<30 { await Task.yield() }
        uptime += interval
        harness.clock.advance(seconds: interval)
      })
    XCTAssertEqual(outcome.result, "saved", outcome.detail)
    XCTAssertEqual(outcome.recordedSeconds, 3, accuracy: 0.001)
    let sessionId = try XCTUnwrap(outcome.sessionId)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(DriftRunProof.startedName).path))
    let written = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent(DriftRunProof.outcomeName)))
        as? [String: Any])
    XCTAssertEqual(written["result"] as? String, "saved")
    XCTAssertEqual(written["session_id"] as? String, sessionId)
    let plan = try harness.preparation.playbackTimeline(sessionId: sessionId)
    XCTAssertEqual(Set(plan.map(\.trackId)).count, 2, "both sources are on the saved timeline")
  }

  private func captureAndRetireMicrophone(
    _ harness: PauseHarness, sequence: UInt64 = 1
  ) async throws -> PauseSource {
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    microphone.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: microphone.writer.authorization),
      sequence: sequence)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    return microphone
  }

  private func reconnectMicrophone(_ harness: PauseHarness) async throws -> PauseSource {
    let count = harness.captures.microphones.count
    harness.controller.reconnectMicrophone()
    await settle()
    XCTAssertEqual(harness.captures.microphones.count, count + 1)
    return try XCTUnwrap(harness.captures.microphones.last)
  }

  private func finishRestoredRecording(_ harness: PauseHarness) async {
    harness.clock.advance(seconds: 1)
    await harness.controller.stop()
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while harness.controller.statusText.hasSuffix("…"), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(harness.controller.phase, .saved)
    XCTAssertFalse(harness.controller.statusText.hasSuffix("…"))
  }

  /// The replacement microphone's media open fails before its adapter starts.
  /// The resumed system sample either confirms Recording while that startup is
  /// suspended, or arrives only after startup returns. The early confirmation
  /// is Rust's. Startup returning later must not stop that survivor.
  private func assertPausedRestoreMediaOpenFailure(
    sampleArrives order: PausedRestoreSampleOrder
  ) async throws {
    let microphoneA = MicrophoneDeviceIdentity(uniqueID: "microphone-a", localizedName: "A")
    let harness = try PauseHarness(
      rotationInjection: true, microphoneDeviceProbe: { microphoneA })
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let sessionId = microphone.writer.authorization.sessionId
    let originalURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    microphone.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: microphone.writer.authorization),
      sequence: 1)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    let originalAudio = try Data(contentsOf: originalURL)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    harness.clock.advance(seconds: 1)

    let injector = try XCTUnwrap(harness.rotationInjector)
    injector.arm(.acceptMediaOpen)
    let gate = PauseStartGate()
    harness.captures.nextSystemStartGate = gate
    let microphonesBeforeReconnect = harness.captures.microphones.count
    harness.controller.reconnectMicrophone()
    await fulfillment(of: [gate.entered], timeout: 2)
    let resumedSystem = try XCTUnwrap(harness.captures.systems.last)
    XCTAssertEqual(harness.captures.systems.count, 2)
    XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeReconnect)
    XCTAssertEqual(microphone.microphoneStartCount, 1)
    XCTAssertEqual(harness.controller.phase, .starting)
    XCTAssertEqual(
      harness.controller.errorMessage, microphoneCouldNotBeRestoredResumingSentence)
    XCTAssertFalse(
      harness.controller.errorMessage?.contains("still recording") == true,
      "Starting must not claim the other source is recording")
    XCTAssertFalse(harness.controller.showsReconnect)
    XCTAssertFalse(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)

    let samplesBeforeResume = try journalCount(
      harness, sessionId: sessionId, event: "first_sample_captured")
    if order == .beforeStartupReturns {
      try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil {
        harness.controller.phase == .capturing
          && harness.controller.errorMessage == microphoneCouldNotBeRestoredContinuingSentence
          && (try? journalCount(harness, sessionId: sessionId, event: "first_sample_captured"))
            == samplesBeforeResume + 1
          && (try? harness.preparation.recorderDetail(sessionId: sessionId).lifecycle)
            == "recording"
      }
      XCTAssertEqual(harness.controller.phase, .capturing)
      XCTAssertEqual(
        harness.controller.errorMessage, microphoneCouldNotBeRestoredContinuingSentence)
      XCTAssertEqual(
        resumedSystem.stopCount, 0, "\(order) confirmation happens before startup returns")
      XCTAssertTrue(harness.controller.showsReconnect)
      XCTAssertFalse(harness.controller.showsUseThisMicrophone)
      XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeReconnect)
      XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    }

    await gate.release()
    if order == .afterStartupReturns {
      await settle()
      XCTAssertEqual(harness.controller.phase, .starting)
      XCTAssertEqual(
        harness.controller.errorMessage, microphoneCouldNotBeRestoredResumingSentence)
      XCTAssertFalse(
        harness.controller.errorMessage?.contains("still recording") == true,
        "a pending system sample must not make the open failure claim recording")
      XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeReconnect)
      try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil {
        harness.controller.phase == .capturing
          && harness.controller.errorMessage == microphoneCouldNotBeRestoredContinuingSentence
      }
    }

    // Cancellation is durable before the explicit retry. Counting it later
    // would include the retry's own restore request.
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(
      harness.controller.errorMessage, microphoneCouldNotBeRestoredContinuingSentence)
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertTrue(harness.controller.showsReconnect)
    XCTAssertFalse(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(harness.controller.contextBinding?.sessionId, sessionId)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    XCTAssertEqual(microphone.microphoneStartCount, 1)
    XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeReconnect)
    let rejected = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(rejected.lifecycle, "recording")
    XCTAssertEqual(
      rejected.events.filter { $0.kind == "microphone_restore_requested" }.count, 1)
    XCTAssertEqual(
      rejected.events.filter { $0.kind == "microphone_restore_cancelled" }.count, 1)

    // Explicit retry waits until the suspended start returns and clears its
    // task. That return is where a confirmed survivor used to be stopped.
    let microphonesBeforeRetry = harness.captures.microphones.count
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    var retryStarted = false
    while ContinuousClock.now < deadline {
      if harness.captures.microphones.count == microphonesBeforeRetry {
        harness.controller.reconnectMicrophone()
      }
      if harness.captures.microphones.count == microphonesBeforeRetry + 1,
        harness.captures.microphones.last?.microphoneStartCount == 1
      {
        retryStarted = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(
      retryStarted,
      "\(order) startup did not return; phase \(harness.controller.phase) "
        + "stop \(resumedSystem.stopCount) \(harness.controller.errorMessage ?? "nil")")
    guard retryStarted else { return }
    let retry = try XCTUnwrap(harness.captures.microphones.last)
    XCTAssertEqual(retry.writer.authorization.sessionId, sessionId)
    XCTAssertEqual(microphone.microphoneStartCount, 1)
    XCTAssertEqual(
      harness.controller.contextBinding?.sessionId, sessionId)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    XCTAssertEqual(
      resumedSystem.stopCount, 0,
      "\(order) must not stop a survivor confirmed before or after startup returns")
    guard resumedSystem.stopCount == 0 else { return }

    harness.clock.advance(seconds: 1)
    try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    await finishRestoredRecording(harness)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    let sessions = try FileManager.default.contentsOfDirectory(
      at: harness.root.appendingPathComponent("Sessions"), includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
    XCTAssertEqual(sessions, [sessionId])
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    let saved = try reopened.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(saved.lifecycle, "ready_for_review")
    XCTAssertGreaterThanOrEqual(
      saved.events.filter { $0.kind == "microphone_restore_cancelled" }.count, 1)
    let plan = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertGreaterThanOrEqual(Set(plan.map(\.trackId)).count, 2)
    XCTAssertEqual(plan.reduce(0) { $0 + $1.sampleCount }, 240_000)
  }

  /// Suspend resumed system startup after B is approved. A change to C, or a
  /// disappearance, must not start that microphone. Paused preflight does not
  /// claim the other source is recording. Starting does not either. Once Rust
  /// confirms capture, the existing continuing-source notice appears, and C
  /// still needs its own confirmation.
  private func assertPausedRestoreDoesNotStartAnUnapprovedMicrophone(
    sampleArrives order: PausedRestoreSampleOrder,
    replacement: MicrophoneDeviceIdentity?
  ) async throws {
    let microphoneA = MicrophoneDeviceIdentity(uniqueID: "microphone-a", localizedName: "A")
    let microphoneB = MicrophoneDeviceIdentity(uniqueID: "microphone-b", localizedName: "B")
    let probe = DeviceProbeBox(device: microphoneA)
    let harness = try PauseHarness(microphoneDeviceProbe: { probe.device })
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let sessionId = microphone.writer.authorization.sessionId
    let originalURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    microphone.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: microphone.writer.authorization),
      sequence: 1)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    let originalAudio = try Data(contentsOf: originalURL)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    // Resume must anchor after the pause boundary. This is the test clock,
    // not a wall-time sleep.
    harness.clock.advance(seconds: 1)

    let microphonesBeforeApproval = harness.captures.microphones.count
    probe.device = nil
    harness.controller.reconnectMicrophone()
    await waitUntil { harness.controller.errorMessage == unavailableMicrophonePausedSentence }
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertEqual(harness.controller.errorMessage, unavailableMicrophonePausedSentence)
    XCTAssertFalse(
      harness.controller.errorMessage?.contains("still recording") == true,
      "paused preflight must not claim the other source is recording")
    XCTAssertFalse(harness.controller.showsUseThisMicrophone)
    XCTAssertTrue(harness.controller.showsReconnect)

    probe.device = microphoneB
    harness.controller.reconnectMicrophone()
    await waitUntil { harness.controller.errorMessage == differentMicrophonePausedSentence }
    XCTAssertEqual(harness.controller.phase, .paused)
    XCTAssertEqual(harness.controller.errorMessage, differentMicrophonePausedSentence)
    XCTAssertFalse(
      harness.controller.errorMessage?.contains("still recording") == true,
      "paused preflight must not claim the other source is recording")
    XCTAssertTrue(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(harness.captures.microphones.count, microphonesBeforeApproval)
    XCTAssertEqual(
      try harness.preparation.recorderDetail(sessionId: sessionId).events.filter {
        $0.kind == "microphone_restore_requested"
      }.count, 0, "paused preflight must not journal a microphone restore")

    let gate = PauseStartGate()
    harness.captures.nextSystemStartGate = gate
    harness.controller.confirmDifferentMicrophone()
    await fulfillment(of: [gate.entered], timeout: 2)
    let resumedSystem = try XCTUnwrap(harness.captures.systems.last)
    let unstarted = try XCTUnwrap(harness.captures.microphones.last)
    XCTAssertEqual(harness.captures.systems.count, 2)
    XCTAssertEqual(unstarted.microphoneStartCount, 0)
    let samplesBeforeResume = try journalCount(
      harness, sessionId: sessionId, event: "first_sample_captured")
    if order == .beforeStartupReturns {
      try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil {
        (try? journalCount(harness, sessionId: sessionId, event: "first_sample_captured"))
          == samplesBeforeResume + 1
      }
    }

    probe.device = replacement
    await gate.release()
    let continuing =
      replacement == nil ? unavailableMicrophoneSentence : differentMicrophoneSentence
    let resuming =
      replacement == nil
      ? unavailableMicrophoneResumingSentence : differentMicrophoneResumingSentence
    await waitUntil {
      unstarted.microphoneStartCount > 0
        || harness.controller.errorMessage == resuming
        || harness.controller.errorMessage == continuing
    }
    XCTAssertEqual(
      unstarted.microphoneStartCount, 0,
      "a device change during suspended startup must not start the microphone")
    guard unstarted.microphoneStartCount == 0 else { return }
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    if order == .afterStartupReturns {
      XCTAssertEqual(harness.controller.phase, .starting)
      XCTAssertEqual(harness.controller.errorMessage, resuming)
      XCTAssertFalse(
        harness.controller.errorMessage?.contains("still recording") == true,
        "Starting must not claim the other source is recording")
      XCTAssertFalse(harness.controller.showsUseThisMicrophone)
      XCTAssertFalse(harness.controller.showsReconnect)
      try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil { harness.controller.phase == .capturing }
    }
    await waitUntil {
      harness.controller.phase == .capturing && harness.controller.errorMessage == continuing
    }
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(harness.controller.errorMessage, continuing)
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertEqual(harness.controller.contextBinding?.sessionId, sessionId)
    let rejected = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(rejected.lifecycle, "recording")
    XCTAssertEqual(
      rejected.events.filter { $0.kind == "microphone_restore_requested" }.count, 1)
    XCTAssertEqual(
      rejected.events.filter { $0.kind == "microphone_restore_cancelled" }.count, 1)
    if let replacement {
      XCTAssertTrue(harness.controller.showsUseThisMicrophone)
      probe.device = replacement
      harness.controller.confirmDifferentMicrophone()
    } else {
      XCTAssertFalse(harness.controller.showsUseThisMicrophone)
      XCTAssertTrue(harness.controller.showsReconnect)
      probe.device = MicrophoneDeviceIdentity(uniqueID: "microphone-c", localizedName: "C")
      harness.controller.reconnectMicrophone()
      await waitUntil { harness.controller.showsUseThisMicrophone }
      XCTAssertEqual(unstarted.microphoneStartCount, 0)
      XCTAssertEqual(harness.captures.microphones.count, 2)
      harness.controller.confirmDifferentMicrophone()
    }
    await waitUntil {
      harness.captures.microphones.count == 3
        && harness.captures.microphones.last?.microphoneStartCount == 1
    }
    XCTAssertEqual(unstarted.microphoneStartCount, 0)
    let restored = try XCTUnwrap(harness.captures.microphones.last)
    XCTAssertEqual(restored.writer.authorization.sessionId, sessionId)
    harness.clock.advance(seconds: 1)
    try restored.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    XCTAssertEqual(resumedSystem.stopCount, 0)
    await finishRestoredRecording(harness)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    let sessions = try FileManager.default.contentsOfDirectory(
      at: harness.root.appendingPathComponent("Sessions"), includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
    XCTAssertEqual(sessions, [sessionId])
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    let saved = try reopened.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(saved.lifecycle, "ready_for_review")
    XCTAssertGreaterThanOrEqual(
      saved.events.filter { $0.kind == "microphone_restore_cancelled" }.count, 1)
    let plan = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertGreaterThanOrEqual(Set(plan.map(\.trackId)).count, 2)
    XCTAssertEqual(plan.reduce(0) { $0 + $1.sampleCount }, 240_000)
  }

  /// Approve the paused microphone, let its adapter start, and fail it before
  /// any microphone sample. A system sample already accepted must leave
  /// Starting. A sample still pending stays Starting with resuming wording
  /// until that sample confirms Recording. Permission withdrawal is the
  /// injected observation, not a TCC change or another device.
  private func assertApprovedPausedRestoreFailsBeforeMicrophoneSample(
    sampleArrives order: PausedRestoreSampleOrder,
    failure: PausedRestoreUnstartedFailure
  ) async throws {
    let microphoneA = MicrophoneDeviceIdentity(uniqueID: "microphone-a", localizedName: "A")
    let probe = DeviceProbeBox(device: microphoneA)
    let harness = try PauseHarness(microphoneDeviceProbe: { probe.device })
    defer { harness.removeFiles() }
    await harness.controller.start()
    try await harness.capture()
    let microphone = try XCTUnwrap(harness.captures.microphones.last)
    let sessionId = microphone.writer.authorization.sessionId
    let originalURL = URL(fileURLWithPath: microphone.writer.authorization.absolutePath)
    microphone.observe(
      .routeInterrupted,
      identity: MicrophoneCaptureIdentity(authorization: microphone.writer.authorization),
      sequence: 1)
    await settle()
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    let originalAudio = try Data(contentsOf: originalURL)
    await harness.controller.stop(pausing: true)
    XCTAssertEqual(harness.controller.phase, .paused)
    harness.clock.advance(seconds: 1)

    let gate = PauseStartGate()
    harness.captures.nextSystemStartGate = gate
    harness.controller.reconnectMicrophone()
    await fulfillment(of: [gate.entered], timeout: 2)
    let resumedSystem = try XCTUnwrap(harness.captures.systems.last)
    let restored = try XCTUnwrap(harness.captures.microphones.last)
    XCTAssertEqual(harness.captures.systems.count, 2)
    XCTAssertEqual(harness.captures.microphones.count, 2)
    XCTAssertEqual(restored.microphoneStartCount, 0)
    XCTAssertNotEqual(restored.writer.authorization.absolutePath, originalURL.path)
    let samplesBeforeResume = try journalCount(
      harness, sessionId: sessionId, event: "first_sample_captured")
    if order == .beforeStartupReturns {
      try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil {
        (try? journalCount(harness, sessionId: sessionId, event: "first_sample_captured"))
          == samplesBeforeResume + 1
      }
      await settle()
    }

    await gate.release()
    await waitUntil { restored.microphoneStartCount == 1 }
    XCTAssertEqual(
      restored.microphoneStartCount, 1,
      "\(order) \(failure) must start the approved microphone adapter")
    guard restored.microphoneStartCount == 1 else { return }
    if failure == .permissionWithdrawn {
      harness.permission.currentState = .denied
    }
    restored.failMicrophone(.writerFailed)
    await waitUntil { harness.controller.isMicrophoneRetired }
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertEqual(restored.stopCount, 1, "\(order) \(failure) must stop the failed adapter")
    XCTAssertEqual(
      resumedSystem.stopCount, 0, "\(order) \(failure) must leave system audio running")
    XCTAssertEqual(
      try journalCount(harness, sessionId: sessionId, event: "first_sample_captured"),
      samplesBeforeResume + (order == .beforeStartupReturns ? 1 : 0),
      "\(order) \(failure) must not accept a microphone sample")
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    XCTAssertEqual(harness.controller.contextBinding?.sessionId, sessionId)

    let resuming =
      failure == .permissionWithdrawn
      ? microphonePermissionWithdrawnResumingSentence
      : microphoneCouldNotBeRestoredResumingSentence
    let continuing =
      failure == .permissionWithdrawn
      ? microphonePermissionWithdrawnContinuingSentence
      : microphoneCouldNotBeRestoredContinuingSentence
    if order == .beforeStartupReturns {
      await waitUntil { harness.controller.phase == .capturing }
      XCTAssertEqual(
        harness.controller.phase, .capturing,
        "\(order) \(failure) left \(harness.controller.phase) "
          + "\(harness.controller.errorMessage ?? "nil")")
      XCTAssertEqual(harness.controller.errorMessage, continuing)
      guard harness.controller.phase == .capturing,
        harness.controller.errorMessage == continuing
      else { return }
    } else {
      await waitUntil {
        harness.controller.errorMessage == resuming
          || harness.controller.errorMessage == continuing
      }
      XCTAssertEqual(harness.controller.phase, .starting)
      XCTAssertEqual(
        harness.controller.errorMessage, resuming,
        "\(order) \(failure) left \(harness.controller.phase) "
          + "\(harness.controller.errorMessage ?? "nil")")
      XCTAssertFalse(
        harness.controller.errorMessage?.contains("still recording") == true,
        "Starting must not claim the other source is recording")
      XCTAssertFalse(harness.controller.showsReconnect)
      XCTAssertFalse(harness.controller.showsUseThisMicrophone)
      guard harness.controller.phase == .starting, harness.controller.errorMessage == resuming
      else { return }
      try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
      await waitUntil {
        harness.controller.phase == .capturing && harness.controller.errorMessage == continuing
      }
    }
    XCTAssertEqual(harness.controller.phase, .capturing)
    XCTAssertEqual(harness.controller.errorMessage, continuing)
    XCTAssertTrue(harness.controller.isMicrophoneRetired)
    XCTAssertTrue(
      harness.controller.showsReconnect, "explicit retry becomes available after Recording")
    XCTAssertFalse(harness.controller.showsUseThisMicrophone)
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(harness.controller.contextBinding?.sessionId, sessionId)
    let rejected = try harness.preparation.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(rejected.lifecycle, "recording")
    XCTAssertEqual(
      rejected.events.filter { $0.kind == "microphone_restore_requested" }.count, 1)
    XCTAssertEqual(
      rejected.events.filter { $0.kind == "microphone_restore_cancelled" }.count, 1)

    if failure == .permissionWithdrawn {
      harness.permission.currentState = .authorized
    }
    let retry = try await reconnectMicrophone(harness)
    XCTAssertEqual(retry.writer.authorization.sessionId, sessionId)
    XCTAssertEqual(restored.microphoneStartCount, 1)
    harness.clock.advance(seconds: 1)
    try retry.emit(frames: 48_000, hostTime: harness.clock.now, value: 8192)
    try resumedSystem.emit(frames: 48_000, hostTime: harness.clock.now, value: 16384)
    await settle()
    XCTAssertFalse(harness.controller.isMicrophoneRetired)
    XCTAssertEqual(resumedSystem.stopCount, 0)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    await finishRestoredRecording(harness)
    XCTAssertEqual(try Data(contentsOf: originalURL), originalAudio)
    let sessions = try FileManager.default.contentsOfDirectory(
      at: harness.root.appendingPathComponent("Sessions"), includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
    XCTAssertEqual(sessions, [sessionId])
    let reopened = try NativeRecordingPreparation.open(managedRoot: harness.root.path)
    _ = try reopened.recoverPlayableSessions()
    let saved = try reopened.recorderDetail(sessionId: sessionId)
    XCTAssertEqual(saved.lifecycle, "ready_for_review")
    XCTAssertGreaterThanOrEqual(
      saved.events.filter { $0.kind == "microphone_restore_cancelled" }.count, 1)
    let plan = try reopened.playbackTimeline(sessionId: sessionId)
    XCTAssertGreaterThanOrEqual(Set(plan.map(\.trackId)).count, 2)
    XCTAssertEqual(plan.reduce(0) { $0 + $1.sampleCount }, 240_000)
  }

  private func journalCount(_ harness: PauseHarness, sessionId: String, event: String) throws
    -> Int
  {
    let journalURL = harness.root.appendingPathComponent("Sessions/\(sessionId)/recovery.jsonl")
    let text = try String(contentsOf: journalURL, encoding: .utf8)
    return text.components(separatedBy: event).count - 1
  }

  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line,
    _ predicate: @MainActor () throws -> Bool
  ) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    var matched = false
    while ContinuousClock.now < deadline {
      matched = (try? predicate()) == true
      if matched { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(matched, file: file, line: line)
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

private enum PausedRestoreSampleOrder { case beforeStartupReturns, afterStartupReturns }

private enum PausedRestoreUnstartedFailure { case captureFailed, permissionWithdrawn }

private let differentMicrophoneSentence =
  "This is a different microphone. System audio is still recording."
private let unavailableMicrophoneSentence =
  "The selected microphone is not available. System audio is still recording."
private let differentMicrophoneResumingSentence =
  "This is a different microphone. The recording is resuming."
private let unavailableMicrophoneResumingSentence =
  "The selected microphone is not available. The recording is resuming."
private let differentMicrophonePausedSentence =
  "This is a different microphone. The recording is paused."
private let unavailableMicrophonePausedSentence =
  "The selected microphone is not available. The recording is paused."
private let microphoneCouldNotBeRestoredResumingSentence =
  "The microphone could not be restored. The recording is resuming."
private let microphoneCouldNotBeRestoredContinuingSentence =
  "The microphone could not be restored. System audio is still recording."
private let microphonePermissionWithdrawnResumingSentence =
  "Microphone access was withdrawn. The recording is resuming."
private let microphonePermissionWithdrawnContinuingSentence =
  "Microphone access was withdrawn. System audio is still recording."

private final class DeviceProbeBox: @unchecked Sendable {
  var device: MicrophoneDeviceIdentity?
  init(device: MicrophoneDeviceIdentity?) { self.device = device }
}

private actor PauseStartGate {
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

private enum PauseSourceError: Error { case startup, drain }

private final class PauseSource: MicrophoneCapturing, SystemAudioCapturing, @unchecked Sendable {
  let writer: ManagedSegmentWriting
  var pendingDrain: (UInt64, Int16)?
  var failStart = false
  var failStop = false
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
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler, onFailure: @escaping MicrophoneFailureHandler
  ) throws {
    microphoneStartCount += 1
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
  var nextSystemStartGate: PauseStartGate?
  func microphone(_ writer: ManagedSegmentWriting) -> PauseSource {
    let source = PauseSource(writer: writer)
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

private final class PauseTelemetry: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [CaptureSourceHealthTelemetryRecord] = []
  func append(_ record: CaptureSourceHealthTelemetryRecord) {
    lock.withLock { records.append(record) }
  }
  func snapshot() -> [CaptureSourceHealthTelemetryRecord] { lock.withLock { records } }
}

@MainActor
private final class PauseHarness {
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
    microphoneDeviceProbe: @escaping @MainActor () -> MicrophoneDeviceIdentity? = { nil }
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
      microphoneDeviceProbe: microphoneDeviceProbe
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

private enum RotationFailureStep: CaseIterable { case writerInit, acceptMediaOpen, seal }

private enum RotationInjectedError: Error { case writerInit, acceptMediaOpen, seal, firstSample }

/// Overrides free-space reporting for the injected storage probe. Transparent
/// (real filesystem) until a test sets a value.
private final class StorageOverride: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64?
  func set(_ bytes: UInt64?) { lock.withLock { value = bytes } }
  func bytes(at path: String) throws -> UInt64 {
    if let bytes = lock.withLock({ value }) { return bytes }
    return try RecorderStorage.availableBytes(at: path)
  }
}

/// Forwards every preparation call to a real store, injecting a one-shot failure
/// at one rotation step so the abandon path can be exercised end to end.
private final class RotationFailureInjectingPreparation: NativeRecordingPreparationProtocol,
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
