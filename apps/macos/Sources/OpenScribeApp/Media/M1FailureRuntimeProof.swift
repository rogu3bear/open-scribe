// Proof launches exist only in Debug builds; candidates build Debug.
#if DEBUG
@preconcurrency import AVFoundation
import AppKit
import Foundation

/// An injected case's sources and probes. The app builds its one recorder
/// from `environment(_:)`, then hands that recorder to `M1FailureRuntimeProof`.
@MainActor
struct M1InjectedCapture {
  let root: URL
  let mediaRoot: URL
  let scenario: LaunchConfiguration.InjectedCase
  let inputs: M1ProofInputs

  init(root: URL, mediaRoot: URL, scenario: LaunchConfiguration.InjectedCase) {
    self.root = root
    self.mediaRoot = mediaRoot
    self.scenario = scenario
    inputs = M1ProofInputs(root: root)
    // Reserve-stop is tested separately. Hold the timer's injected probe
    // normal while the parent fills the isolated volume, then restore the
    // real probe before the actual writer failure and explicit storage check.
    if scenario == .storageExhaustion {
      inputs.storage(2 * NativeCapturePolicy.current.storageWarningBytes)
    }
  }

  /// The injected case `configuration` names, when it has a proof root.
  init?(_ configuration: LaunchConfiguration) {
    guard case .injected(let scenario) = configuration.action, let root = configuration.proofRoot
    else { return nil }
    self.init(root: root, mediaRoot: configuration.mediaRoot ?? root, scenario: scenario)
  }

  /// Live pause-resume records with the Mac's real permission authorities and
  /// adapters (`production`); it is never in the permission-free default
  /// matrix. Every other case records synthetic sources against an injected
  /// clock and storage probe, under the app's launch hold and captions.
  func environment(_ production: CaptureEnvironment) -> CaptureEnvironment {
    guard scenario != .livePauseResume else { return production }
    let inputs = inputs
    let mediaRoot = mediaRoot
    return CaptureEnvironment(
      permission: M1ProofPermission(),
      preparationFactory: { try NativeRecordingPreparation.open(managedRoot: mediaRoot.path) },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { inputs.makeMicrophone($0) },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { writer, _ in inputs.makeAudio(writer) },
      segmentedCapture: true,
      hostTime: { inputs.now }, availableBytes: { try inputs.available(at: $0) },
      observer: scenario.killBoundary.map { M1KillCheckpoint(boundary: $0, root: root) },
      isLaunchRecoveryPending: production.isLaunchRecoveryPending,
      liveCaptions: production.liveCaptions)
  }
}

/// Permission-free injections through production controller entry points.
/// These receipts do not qualify TCC, physical devices, or perceptual playback.
@MainActor
final class M1FailureRuntimeProof {
  let controller: LiveMicrophoneRecordingController
  let root: URL
  let mediaRoot: URL
  let scenario: LaunchConfiguration.InjectedCase
  private let inputs: M1ProofInputs

  /// `controller` records with `capture.environment(_:)`.
  init(capture: M1InjectedCapture, controller: LiveMicrophoneRecordingController) {
    self.controller = controller
    root = capture.root
    mediaRoot = capture.mediaRoot
    scenario = capture.scenario
    inputs = capture.inputs
  }

  func run(runtime: RuntimeLibraryStore) async {
    do {
      if scenario == .livePauseResume {
        try await liveControls(runtime: runtime)
        NSApp.terminate(nil)
        return
      }
      if scenario == .pauseResume {
        try await syntheticPauseResume(runtime: runtime)
        NSApp.terminate(nil)
        return
      }
      if scenario == .applicationLoss || scenario == .selectedAppExit {
        controller.selectCaptureSource(
          RecorderCaptureSelection(
            kind: .applicationAudio,
            identity: "injected-application", name: "Injected application", filter: nil,
            processId: 4242))
      }
      await controller.start()
      try requireM1(
        controller.phase == .starting, controller.errorMessage ?? "capture did not start")
      guard let microphone = inputs.microphone, let audio = inputs.audio else {
        throw M1ProofError.failed("missing synthetic source")
      }
      let sessionId = microphone.writer.authorization.sessionId
      try microphone.emit(at: inputs.now)
      try audio.emit(at: inputs.now)
      inputs.advance()
      try await wait { self.controller.phase == .capturing }
      runtime.refresh()
      controller.addMarker(label: "Injected failure boundary")
      try requireM1(
        controller.recorderDetail?.events.contains { $0.kind == .markerAdded } == true,
        "marker was not durably projected")

      if scenario.killBoundary != nil {
        await controller.stop()
        // Processing runs on the utility queue. It must hit its explicit
        // checkpoint before this wait completes; otherwise this is a failure.
        try await Task.sleep(for: .seconds(15))
        throw M1ProofError.failed("forced-termination checkpoint was not reached")
      }
      if scenario == .storageExhaustion {
        try await exhaust(microphone: microphone, sessionId: sessionId)
        NSApp.terminate(nil)
        return
      }

      var expectedEvents: [NativeRecorderEventKind] = []
      var fallback = ""
      switch scenario {
      case .storageWarning, .storageCritical:
        let policy = NativeCapturePolicy.current
        inputs.storage(
          scenario == .storageWarning
            ? (policy.storageReserveBytes + policy.storageWarningBytes) / 2
            : policy.storageReserveBytes / 8)
        await controller.checkStorage()
        let level: NativeStorageLevel = scenario == .storageWarning ? .warning : .critical
        try requireM1(
          controller.recorderDetail?.storageLevel == level,
          "storage policy did not observe \(level)")
        try requireM1(
          controller.phase == (level == .warning ? .capturing : .saved),
          "storage policy did not continue or stop explicitly")
        expectedEvents = [.storageObserved]
        fallback = level == .warning ? "recording-with-storage-warning" : "stopped-at-reserve"
      case .sleepWake:
        await controller.systemWillSleep()
        try requireM1(controller.phase == .paused, "sleep did not seal and pause")
        try requireM1(
          controller.errorMessage?.contains("went to sleep") == true, "sleep not visible")
        controller.systemDidWake()
        try requireM1(controller.phase == .paused && controller.canResume, "wake silently resumed")
        expectedEvents = [.systemSleepObserved, .capturePaused, .systemWakeObserved]
        fallback = "paused-awaiting-explicit-resume"
      default:
        if scenario == .selectedAppExit {
          await controller.selectedApplicationExited(processId: 4243)
          try requireM1(
            !audio.stopped && controller.errorMessage == nil,
            "unrelated application exit changed capture")
          await controller.selectedApplicationExited(processId: 4242)
        } else {
          (scenario == .microphoneLoss ? microphone : audio).lose()
        }
        try await wait {
          self.controller.recorderDetail?.events.contains { $0.kind == .sourceFailed } == true
        }
        try requireM1(controller.phase == .capturing, "surviving source did not continue")
        if scenario == .microphoneLoss {
          try requireM1(
            controller.errorMessage?.contains("The microphone stopped.") == true
              && controller.errorMessage?.contains("is still recording.") == true,
            "microphone loss is not visibly explained")
          try requireM1(controller.showsReconnect, "reconnect is missing after microphone loss")
        } else {
          try requireM1(
            controller.errorMessage?.contains("Remaining audio is still recording") == true,
            "source loss is not visibly explained")
        }
        let lost = scenario == .microphoneLoss ? microphone : audio
        let survivor = scenario == .microphoneLoss ? audio : microphone
        try requireM1(lost.stopped && !survivor.stopped, "failure stopped the wrong source")
        try survivor.emit(at: inputs.now)
        inputs.advance()
        expectedEvents = [.sourceFailed]
        fallback = "recording-remaining-source"
      }

      let visibleEvents = controller.recorderDetail?.events.map(\.kind) ?? []
      try requireM1(
        expectedEvents.allSatisfy { visibleEvents.contains($0) },
        "event missing from native projection")
      let visible = controller.errorMessage ?? controller.statusText
      let phaseAtEvent = controller.phase.rawValue
      // Let the normal scene consume the same observed controller and Rust
      // snapshot. A report describes this projection, not a pixel/AX proof.
      let visibleLifecycle: NativeSessionLifecycle? =
        controller.phase == .saved
        ? .readyForReview : controller.recorderDetail?.lifecycle
      let visibleSession = try await Self.visibleSession(
        runtime, sessionId: sessionId,
        lifecycle: visibleLifecycle)
      if controller.canStop { await controller.stop() }
      try requireM1(
        controller.phase == .saved, controller.errorMessage ?? "sources did not finalize")
      let preparation = try NativeRecordingPreparation.open(managedRoot: mediaRoot.path)
      let plan = try preparation.playbackTimeline(sessionId: sessionId)
      try requireM1(Set(plan.map(\.trackId)).count == 2, "lost a source track")
      try requireM1(plan.allSatisfy { $0.sampleCount >= 48_000 }, "lost the pre-event audio")
      let rendered = try Self.decode(plan)
      if scenario == .storageWarning {
        try await wait {
          self.controller.mixdownStatus == RecorderSavedNote.mixed
        }
        let mix = try preparation.validatedMixdown(sessionId: sessionId)
        try requireM1(mix != nil, "mixdown lacks Rust validation")
      }
      let detail = try preparation.recorderDetail(sessionId: sessionId)
      try requireM1(detail.lifecycle == .readyForReview, "Rust did not finalize")
      try requireM1(
        expectedEvents.allSatisfy { kind in detail.events.contains { $0.kind == kind } },
        "event missing after finalization")
      try ProofFiles.write(
        [
          "scenario": scenario.rawValue, "session_id": sessionId, "phase_at_event": phaseAtEvent,
          "visible_message": visible, "visible_events": visibleEvents.map(\.description),
          "visible_lifecycle": visibleSession.lifecycle.description,
          "visible_status": visibleSession.statusText,
          "expected_events": expectedEvents.map(\.description),
          "fallback": fallback, "tracks": 2, "rendered_frames": rendered,
          "lifecycle": detail.lifecycle.description, "result": "INJECTED_CASE_GREEN",
        ], name: "outcome.json", root: root)
    } catch { ProofFiles.fail(error, root: root) }
    NSApp.terminate(nil)
  }

  private func liveControls(runtime: RuntimeLibraryStore) async throws {
    await controller.start()
    try await wait { self.controller.phase == .capturing }
    runtime.refresh()
    try await wait { runtime.currentSession?.lifecycle == .recording && !runtime.isSnapshotStale }
    guard let sessionId = runtime.currentSession?.sessionId else {
      throw M1ProofError.failed("live session not visible")
    }
    try await Task.sleep(for: .seconds(2))
    controller.addMarker(label: "Live pause boundary")
    await controller.stop(pausing: true)
    try requireM1(controller.phase == .paused, controller.errorMessage ?? "live pause failed")
    let paused = try await Self.visibleSession(runtime, sessionId: sessionId, lifecycle: .paused)
    let preparation = try NativeRecordingPreparation.open(managedRoot: mediaRoot.path)
    // Rust plans playback only for saved sessions, so the pause boundary comes
    // from its journaled capture_paused event and splits the final plan.
    let pausedDetail = try preparation.recorderDetail(sessionId: sessionId)
    guard
      pausedDetail.lifecycle == .paused,
      let pausedAt = pausedDetail.events.last(where: { $0.kind == .capturePaused })?
        .sessionNanoseconds
    else { throw M1ProofError.failed("pause boundary was not journaled") }
    try await Task.sleep(for: .seconds(1))
    await controller.start(resuming: true)
    try await wait { self.controller.phase == .capturing }
    let resumed = try await Self.visibleSession(
      runtime, sessionId: sessionId, lifecycle: .recording)
    try await Task.sleep(for: .seconds(2))
    await controller.stop()
    try requireM1(controller.phase == .saved, controller.errorMessage ?? "live stop failed")
    let final = try preparation.playbackTimeline(sessionId: sessionId)
    // Rust revalidates every accepted digest while producing this final plan.
    let before = final.filter { $0.nativeStartNanoseconds < pausedAt }
    try requireM1(Set(before.map(\.trackId)).count == 2, "pause lost a source")
    for track in Set(before.map(\.trackId)) {
      let priorFrames = before.filter { $0.trackId == track }.reduce(UInt64(0)) {
        $0 + $1.sampleCount
      }
      let finalFrames = final.filter { $0.trackId == track }.reduce(UInt64(0)) {
        $0 + $1.sampleCount
      }
      try requireM1(
        priorFrames >= 48_000 && finalFrames > priorFrames + 48_000,
        "one live source did not continue after resume")
    }
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    let expected: [NativeRecorderEventKind] = [.capturePaused, .captureResumed, .markerAdded]
    try requireM1(
      expected.allSatisfy { kind in detail.events.contains { $0.kind == kind } },
      "live control event missing")
    let saved = try await Self.visibleSession(
      runtime, sessionId: sessionId, lifecycle: .readyForReview)
    try ProofFiles.write(
      [
        "scenario": scenario.rawValue, "session_id": sessionId, "result": "INJECTED_CASE_GREEN",
        "capture_backend": "AVAudioEngine+ScreenCaptureKit",
        "lifecycle": detail.lifecycle.description,
        "visible_message": controller.statusText,
        "visible_events": detail.events.map(\.kind.description),
        "visible_status": saved.statusText, "paused_status": paused.statusText,
        "resumed_status": resumed.statusText, "fallback": "explicit-pause-resume-stop",
        "tracks": 2, "rendered_frames": try Self.decode(final),
      ], name: "outcome.json", root: root)
  }

  /// Same pause, resume, and stop entry points as the live case, with synthetic
  /// sources and a clock that moves only when this runner advances it.
  private func syntheticPauseResume(runtime: RuntimeLibraryStore) async throws {
    await controller.start()
    try requireM1(
      controller.phase == .starting, controller.errorMessage ?? "capture did not start")
    guard let microphone = inputs.microphone, let audio = inputs.audio else {
      throw M1ProofError.failed("missing synthetic source")
    }
    let sessionId = microphone.writer.authorization.sessionId
    try microphone.emit(at: inputs.now)
    try audio.emit(at: inputs.now)
    inputs.advance(seconds: 1)
    try await wait { self.controller.phase == .capturing }
    runtime.refresh()
    controller.addMarker(label: "Synthetic pause boundary")
    try requireM1(
      controller.recorderDetail?.events.contains { $0.kind == .markerAdded } == true,
      "marker was not durably projected")
    await controller.stop(pausing: true)
    try requireM1(controller.phase == .paused, controller.errorMessage ?? "pause failed")
    let paused = try await Self.visibleSession(
      runtime, sessionId: sessionId, lifecycle: .paused)
    let preparation = try NativeRecordingPreparation.open(managedRoot: mediaRoot.path)
    let pausedDetail = try preparation.recorderDetail(sessionId: sessionId)
    guard
      pausedDetail.lifecycle == .paused,
      let pausedAt = pausedDetail.events.last(where: { $0.kind == .capturePaused })?
        .sessionNanoseconds
    else { throw M1ProofError.failed("pause boundary was not journaled") }
    inputs.advance(seconds: 600)
    await controller.start(resuming: true)
    try requireM1(
      controller.phase == .starting || controller.phase == .capturing,
      controller.errorMessage ?? "resume stayed \(controller.phase.rawValue)")
    guard let resumedMicrophone = inputs.microphone, let resumedAudio = inputs.audio else {
      throw M1ProofError.failed("resume did not open synthetic sources")
    }
    try requireM1(
      resumedMicrophone !== microphone && resumedAudio !== audio
        && !resumedMicrophone.stopped && !resumedAudio.stopped,
      "resume reused a stopped source")
    try resumedMicrophone.emit(at: inputs.now, frames: 96_000)
    try resumedAudio.emit(at: inputs.now, frames: 96_000)
    inputs.advance(seconds: 2)
    try await wait { self.controller.phase == .capturing }
    let resumed = try await Self.visibleSession(
      runtime, sessionId: sessionId, lifecycle: .recording)
    await controller.stop()
    try requireM1(controller.phase == .saved, controller.errorMessage ?? "stop failed")
    let final = try preparation.playbackTimeline(sessionId: sessionId)
    let before = final.filter { $0.nativeStartNanoseconds < pausedAt }
    try requireM1(Set(before.map(\.trackId)).count == 2, "pause lost a source")
    for track in Set(before.map(\.trackId)) {
      let priorFrames = before.filter { $0.trackId == track }.reduce(UInt64(0)) {
        $0 + $1.sampleCount
      }
      let finalFrames = final.filter { $0.trackId == track }.reduce(UInt64(0)) {
        $0 + $1.sampleCount
      }
      try requireM1(
        priorFrames >= 48_000 && finalFrames > priorFrames + 48_000,
        "one source did not continue after resume")
    }
    let detail = try preparation.recorderDetail(sessionId: sessionId)
    let expected: [NativeRecorderEventKind] = [.capturePaused, .captureResumed, .markerAdded]
    try requireM1(
      expected.allSatisfy { kind in detail.events.contains { $0.kind == kind } },
      "pause or resume event missing")
    let saved = try await Self.visibleSession(
      runtime, sessionId: sessionId, lifecycle: .readyForReview)
    try ProofFiles.write(
      [
        "scenario": scenario.rawValue, "session_id": sessionId, "result": "INJECTED_CASE_GREEN",
        "capture_backend": "synthetic", "lifecycle": detail.lifecycle.description,
        "visible_message": controller.statusText,
        "visible_events": detail.events.map(\.kind.description),
        "visible_status": saved.statusText, "paused_status": paused.statusText,
        "resumed_status": resumed.statusText, "fallback": "synthetic-pause-resume-stop",
        "tracks": 2, "rendered_frames": try Self.decode(final),
      ], name: "outcome.json", root: root)
  }

  private func exhaust(microphone: M1ProofSource, sessionId: String) async throws {
    try ProofFiles.write(["session_id": sessionId], name: "injection-ready.json", root: root)
    try await ProofFiles.wait(root: root, name: "injection-go")
    inputs.storage(nil)
    let available = try RecorderStorage.availableBytes(at: mediaRoot.path)
    try requireM1(
      available < NativeCapturePolicy.current.storageReserveBytes,
      "dedicated volume is not below reserve")
    try requireM1(!microphone.stopped, "capture stopped before the full-volume write")
    var writeFailed = false
    do { try microphone.emit(at: inputs.now) } catch { writeFailed = true }
    await controller.checkStorage()
    try await wait { self.controller.phase == .failed || self.controller.phase == .saved }
    try requireM1(controller.errorMessage?.isEmpty == false, "storage exhaustion not visible")
    try ProofFiles.write(
      [
        "scenario": scenario.rawValue, "session_id": sessionId, "available_bytes": available,
        "write_failed": writeFailed, "phase_at_event": controller.phase.rawValue,
        "visible_message": controller.errorMessage ?? "", "fallback": "capture-stopped",
        "result": "EXHAUSTION_OBSERVED_REQUIRES_RECOVERY",
      ], name: "outcome.json", root: root)
  }

  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      if controller.phase == .failed {
        throw M1ProofError.failed(controller.errorMessage ?? "capture failed")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw M1ProofError.failed("controller outcome timed out")
  }

  static func decode(_ plan: [NativeTimelineSegment]) throws -> Int64 {
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    var frames: Int64 = 0
    while let buffer = try reader.read(maximumFrames: 16_384) {
      frames += Int64(buffer.frameLength)
    }
    try requireM1(
      frames > 0 && frames == reader.totalFrames, "recovered timeline did not decode completely")
    return frames
  }

  private static func visibleSession(
    _ runtime: RuntimeLibraryStore, sessionId: String,
    lifecycle: NativeSessionLifecycle?
  ) async throws -> RuntimeSessionPresentation {
    runtime.refresh()
    for _ in 0..<500 {
      let sessions = runtime.savedSessions + (runtime.currentSession.map { [$0] } ?? [])
      if let session = sessions.first(where: {
        $0.sessionId == sessionId && $0.lifecycle == lifecycle
      }),
        !runtime.isSnapshotStale
      {
        return session
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw M1ProofError.failed("event lifecycle did not reach the native library projection")
  }

  static func recover(
    root: URL, mediaRoot: URL, recovery: RecoveredSessionController,
    runtime: RuntimeLibraryStore
  ) async {
    do {
      let checkpoint = root.appendingPathComponent("checkpoint.json")
      let source =
        FileManager.default.fileExists(atPath: checkpoint.path)
        ? checkpoint : root.appendingPathComponent("outcome.json")
      guard
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: source))
          as? [String: Any],
        let sessionId = input["session_id"] as? String
      else { throw M1ProofError.failed("missing session identity") }
      recovery.recoverOnLaunch()
      await recovery.waitForLaunchRecovery()
      try requireM1(
        recovery.phase != .scanning && recovery.phase != .failed, "native launch recovery failed")
      let preparation = try NativeRecordingPreparation.open(managedRoot: mediaRoot.path)
      let detail = try preparation.recorderDetail(sessionId: sessionId)
      let preparing = input["phase"] as? String == "preparation"
      let plan = preparing ? [] : try preparation.playbackTimeline(sessionId: sessionId)
      if preparing {
        try requireM1(
          recovery.sessions.isEmpty && detail.lifecycle == .interrupted,
          "preparation recovery falsely claims audio")
      } else {
        try requireM1(
          detail.lifecycle == .readyForReview && Set(plan.map(\.trackId)).count == 2,
          "recovery did not preserve both tracks")
        try requireM1(
          plan.allSatisfy { $0.sampleCount >= 48_000 }, "recovery lost pre-event frames")
      }
      let frames = preparing ? 0 : try decode(plan)
      let visible = try await visibleSession(
        runtime, sessionId: sessionId, lifecycle: detail.lifecycle)
      try ProofFiles.write(
        [
          "session_id": sessionId, "lifecycle": detail.lifecycle.description,
          "rendered_frames": frames,
          "recovery_projection": String(describing: recovery.phase),
          "visible_lifecycle": visible.lifecycle.description,
          "visible_status": visible.statusText,
          "result": "INJECTED_RECOVERY_GREEN",
        ], name: "recovery.json", root: root)
    } catch { ProofFiles.fail(error, root: root) }
    NSApp.terminate(nil)
  }
}
#endif
