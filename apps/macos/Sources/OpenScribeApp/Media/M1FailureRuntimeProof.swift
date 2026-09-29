@preconcurrency import AVFoundation
import AppKit
import Foundation

/// Permission-free injections through production controller entry points.
/// These receipts do not qualify TCC, physical devices, or perceptual playback.
@MainActor
final class M1FailureRuntimeProof {
  let controller: LiveMicrophoneRecordingController
  let root: URL
  let mediaRoot: URL
  let scenario: String
  private let inputs: M1ProofInputs

  init(root: URL, mediaRoot: URL, scenario: String) {
    self.root = root
    self.mediaRoot = mediaRoot
    self.scenario = scenario
    let inputs = M1ProofInputs()
    self.inputs = inputs
    // Reserve-stop is tested separately. Hold the timer's injected probe
    // normal while the parent fills the isolated volume, then restore the
    // real probe before the actual writer failure and explicit storage check.
    if scenario == "storage-exhaustion" { inputs.storage(2 * 1024 * 1024 * 1024) }
    controller = LiveMicrophoneRecordingController(
      permission: M1ProofPermission(),
      preparationFactory: { try NativeRecordingPreparation.open(managedRoot: mediaRoot.path) },
      writerFactory: { try ManagedCAFWriter(authorization: $0) },
      captureFactory: { inputs.makeMicrophone($0) },
      requiredSources: [.microphone, .systemAudio],
      systemCaptureFactory: { inputs.makeAudio($0) }, segmentedCapture: true,
      hostTime: { inputs.now }, availableBytes: { try inputs.available(at: $0) },
      proofCheckpoint: { phase, sessionId in
        if scenario == "kill-\(phase.rawValue)" {
          M1ProofFiles.suspend(phase: phase, sessionId: sessionId, root: root)
        }
      })
    if scenario == "application-loss" || scenario == "selected-app-exit" {
      controller.selectCaptureSource(
        RecorderCaptureSelection(
          kind: .applicationAudio,
          identity: "injected-application", name: "Injected application", filter: nil,
          processId: 4242))
    }
  }

  func run(runtime: RuntimeLibraryStore) async {
    do {
      let scenarios = [
        "storage-warning", "storage-critical", "storage-exhaustion",
        "microphone-loss", "system-loss", "application-loss", "selected-app-exit", "sleep-wake",
      ]
      let phase = RecorderProofPhase(rawValue: String(scenario.dropFirst(5)))
      try requireM1(
        scenarios.contains(scenario) || (scenario.hasPrefix("kill-") && phase != nil),
        "unknown injected case")
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
        controller.recorderDetail?.events.contains { $0.kind == "marker_added" } == true,
        "marker was not durably projected")

      if scenario.hasPrefix("kill-") {
        await controller.stop()
        // Processing runs on the utility queue. It must hit its explicit
        // checkpoint before this wait completes; otherwise this is a failure.
        try await Task.sleep(for: .seconds(15))
        throw M1ProofError.failed("forced-termination checkpoint was not reached")
      }
      if scenario == "storage-exhaustion" {
        try await exhaust(microphone: microphone, sessionId: sessionId)
        NSApp.terminate(nil)
        return
      }

      var expectedEvents: [String] = []
      var fallback = ""
      switch scenario {
      case "storage-warning", "storage-critical":
        inputs.storage(scenario == "storage-warning" ? 768 * 1024 * 1024 : 64 * 1024 * 1024)
        await controller.checkStorage()
        let level = scenario == "storage-warning" ? "warning" : "critical"
        try requireM1(
          controller.recorderDetail?.storageLevel == level,
          "storage policy did not observe \(level)")
        try requireM1(
          controller.phase == (level == "warning" ? .capturing : .saved),
          "storage policy did not continue or stop explicitly")
        expectedEvents = ["storage_observed"]
        fallback = level == "warning" ? "recording-with-storage-warning" : "stopped-at-reserve"
      case "sleep-wake":
        await controller.systemWillSleep()
        try requireM1(controller.phase == .paused, "sleep did not seal and pause")
        try requireM1(
          controller.errorMessage?.contains("went to sleep") == true, "sleep not visible")
        controller.systemDidWake()
        try requireM1(controller.phase == .paused && controller.canResume, "wake silently resumed")
        expectedEvents = ["system_sleep_observed", "capture_paused", "system_wake_observed"]
        fallback = "paused-awaiting-explicit-resume"
      default:
        if scenario == "selected-app-exit" {
          await controller.selectedApplicationExited(processId: 4243)
          try requireM1(
            !audio.stopped && controller.errorMessage == nil,
            "unrelated application exit changed capture")
          await controller.selectedApplicationExited(processId: 4242)
        } else {
          (scenario == "microphone-loss" ? microphone : audio).lose()
        }
        try await wait {
          self.controller.recorderDetail?.events.contains { $0.kind == "source_failed" } == true
        }
        try requireM1(controller.phase == .capturing, "surviving source did not continue")
        try requireM1(
          controller.errorMessage?.contains("Remaining audio is still recording") == true,
          "source loss is not visibly explained")
        let lost = scenario == "microphone-loss" ? microphone : audio
        let survivor = scenario == "microphone-loss" ? audio : microphone
        try requireM1(lost.stopped && !survivor.stopped, "failure stopped the wrong source")
        try survivor.emit(at: inputs.now)
        inputs.advance()
        expectedEvents = ["source_failed"]
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
      let visibleLifecycle =
        controller.phase == .saved
        ? "ready_for_review" : controller.recorderDetail?.lifecycle ?? ""
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
      if scenario == "storage-warning" {
        try await wait {
          self.controller.mixdownStatus == "Recording saved with verified stereo mix"
        }
        let mix = try preparation.validatedMixdown(sessionId: sessionId)
        try requireM1(mix != nil, "mixdown lacks Rust validation")
      }
      let detail = try preparation.recorderDetail(sessionId: sessionId)
      try requireM1(detail.lifecycle == "ready_for_review", "Rust did not finalize")
      try requireM1(
        expectedEvents.allSatisfy { kind in detail.events.contains { $0.kind == kind } },
        "event missing after finalization")
      try M1ProofFiles.write(
        [
          "scenario": scenario, "session_id": sessionId, "phase_at_event": phaseAtEvent,
          "visible_message": visible, "visible_events": visibleEvents,
          "visible_lifecycle": visibleSession.lifecycle,
          "visible_status": visibleSession.statusText,
          "expected_events": expectedEvents,
          "fallback": fallback, "tracks": 2, "rendered_frames": rendered,
          "lifecycle": detail.lifecycle, "result": "INJECTED_CASE_GREEN",
        ], name: "outcome.json", root: root)
    } catch { M1ProofFiles.fail(error, root: root) }
    NSApp.terminate(nil)
  }

  private func exhaust(microphone: M1ProofSource, sessionId: String) async throws {
    try M1ProofFiles.write(["session_id": sessionId], name: "injection-ready.json", root: root)
    try await M1ProofFiles.wait(root: root, name: "injection-go")
    inputs.storage(nil)
    let available = try RecorderStorage.availableBytes(at: mediaRoot.path)
    try requireM1(available < 512 * 1024 * 1024, "dedicated volume is not below reserve")
    try requireM1(!microphone.stopped, "capture stopped before the full-volume write")
    var writeFailed = false
    do { try microphone.emit(at: inputs.now) } catch { writeFailed = true }
    await controller.checkStorage()
    try await wait { self.controller.phase == .failed || self.controller.phase == .saved }
    try requireM1(controller.errorMessage?.isEmpty == false, "storage exhaustion not visible")
    try M1ProofFiles.write(
      [
        "scenario": scenario, "session_id": sessionId, "available_bytes": available,
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
    lifecycle: String
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
      for _ in 0..<500 where recovery.phase == .scanning {
        try await Task.sleep(for: .milliseconds(20))
      }
      try requireM1(
        recovery.phase != .scanning && recovery.phase != .failed, "native launch recovery failed")
      let preparation = try NativeRecordingPreparation.open(managedRoot: mediaRoot.path)
      let detail = try preparation.recorderDetail(sessionId: sessionId)
      let preparing = input["phase"] as? String == "preparation"
      let plan = preparing ? [] : try preparation.playbackTimeline(sessionId: sessionId)
      if preparing {
        try requireM1(
          recovery.sessions.isEmpty && detail.lifecycle == "interrupted",
          "preparation recovery falsely claims audio")
      } else {
        try requireM1(
          detail.lifecycle == "ready_for_review" && Set(plan.map(\.trackId)).count == 2,
          "recovery did not preserve both tracks")
        try requireM1(
          plan.allSatisfy { $0.sampleCount >= 48_000 }, "recovery lost pre-event frames")
      }
      let frames = preparing ? 0 : try decode(plan)
      let visible = try await visibleSession(
        runtime, sessionId: sessionId, lifecycle: detail.lifecycle)
      try M1ProofFiles.write(
        [
          "session_id": sessionId, "lifecycle": detail.lifecycle, "rendered_frames": frames,
          "recovery_projection": String(describing: recovery.phase),
          "visible_lifecycle": visible.lifecycle, "visible_status": visible.statusText,
          "result": "INJECTED_RECOVERY_GREEN",
        ], name: "recovery.json", root: root)
    } catch { M1ProofFiles.fail(error, root: root) }
    NSApp.terminate(nil)
  }
}
