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
    XCTAssertEqual(harness.telemetry.snapshot().map(\.observation.event), [.routeInterrupted])
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(system.stopCount, 0)
    XCTAssertEqual(try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "recording")

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
        "the remaining source keeps recording after \(step): \(harness.controller.errorMessage ?? "")")
      XCTAssertEqual(harness.controller.statusText, "Recording continues with remaining audio", "\(step)")
      XCTAssertEqual(microphone.stopCount, 1, "\(step)")
      XCTAssertEqual(system.stopCount, 0, "\(step)")
      XCTAssertEqual(
        try harness.preparation.recorderDetail(sessionId: sessionId).lifecycle, "recording", "\(step)")

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
    harness.clock.advance(seconds: 60)

    harness.controller.selectCaptureSource(.system)
    XCTAssertNil(harness.controller.errorMessage)
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
    harness.clock.advance(seconds: 60)

    harness.controller.selectCaptureSource(.microphoneOnly)
    XCTAssertEqual(harness.controller.captureSelection.kind, .systemAudio)
    XCTAssertTrue(
      harness.controller.errorMessage?.contains("Microphone only has nothing to record") == true,
      harness.controller.errorMessage ?? "")
    XCTAssertThrowsError(
      try harness.preparation.recorderAction(
        sessionId: sessionId,
        action: .selectAudio(kind: nil, identity: "microphone-only", displayName: "Microphone only")),
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
  private var observationHandler: MicrophoneHealthHandler?
  private var systemFailureHandler: SystemAudioFailureHandler?
  private var deliverWriteFailure: (@Sendable (Error) -> Void)?
  private var first: NativeFirstSampleReceipt?
  private var lastEnd: UInt64?
  init(writer: ManagedSegmentWriting) { self.writer = writer }
  func start(
    onFirstSample: @escaping MicrophoneFirstSampleHandler,
    onObservation: @escaping MicrophoneHealthHandler, onFailure: @escaping MicrophoneFailureHandler
  ) throws {
    firstHandler = onFirstSample
    observationHandler = onObservation
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
  }
  /// Reports a system-audio stream failure the way the adapter does.
  func fail(_ error: SystemAudioCaptureAdapterError) { systemFailureHandler?(error) }
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

private final class PauseTelemetry: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [CaptureSourceHealthTelemetryRecord] = []
  func append(_ record: CaptureSourceHealthTelemetryRecord) { lock.withLock { records.append(record) } }
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
  init(rotationInjection: Bool = false) throws {
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
      captureHealthTelemetry: { telemetry.append($0) }
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
  func abandonReservedSegment(sessionId: String, segmentId: String) throws {
    try base.abandonReservedSegment(sessionId: sessionId, segmentId: segmentId)
  }
}
