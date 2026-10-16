import AppKit
import Foundation
import SwiftUI

private struct SceneVerificationKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var isSceneVerification: Bool {
    get { self[SceneVerificationKey.self] }
    set { self[SceneVerificationKey.self] = newValue }
  }
}

#if DEBUG
  /// Development-only dispatch. Storage routing has already been validated before
  /// this receives any production component; release builds cannot invoke it.
  @MainActor
  enum ProofLaunchRunner {
    static func configurePresentation(_ configuration: LaunchConfiguration) {
      guard configuration.mode != .normal else { return }
      AppDelegate.isVerificationLaunch = true
      var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      arguments["ApplePersistenceIgnoreState"] = true
      arguments["NSQuitAlwaysKeepsWindows"] = false
      UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    static func start(
      configuration: LaunchConfiguration, injected: M1FailureRuntimeProof?,
      controller: LiveMicrophoneRecordingController, runtime: RuntimeLibraryStore,
      recovery: RecoveredSessionController
    ) {
      let root = configuration.proofRoot
      switch configuration.action {
      case .injected:
        if let injected { Task { await injected.run(runtime: runtime) } }
      case .injectedRecovery:
        if let root {
          Task {
            await M1FailureRuntimeProof.recover(
              root: root, mediaRoot: configuration.mediaRoot ?? root, recovery: recovery,
              runtime: runtime)
          }
        }
      case .liveRecovery:
        if let root { Task { await TimelineRuntimeProof.verifyLive(root: root) } }
      case .syntheticCapture, .syntheticRecovery:
        if let root {
          Task {
            await TimelineRuntimeProof.run(
              root: root, captureMode: configuration.action == .syntheticCapture)
          }
        }
      case .microphone:
        Task { await runLiveMicrophoneProof(controller: controller) }
      case .forcedCapture:
        Task { await runForcedTerminationCaptureProof(controller: controller) }
      case .localOnly:
        if let root { Task { await LocalOnlyWorkflowProof.run(root: root) } }
      case .drift(let seconds):
        if let root {
          Task {
            _ = await DriftRunProof.run(controller: controller, root: root, seconds: seconds)
            NSApp.terminate(nil)
          }
        }
      case .forcedRecovery:
        recovery.recoverOnLaunch()
        Task {
          await recovery.waitForLaunchRecovery()
          await runForcedTerminationRecoveryProof(controller: recovery)
        }
      case .none, .review:
        recovery.recoverOnLaunch()
      }
    }

    @MainActor
    static func runLiveMicrophoneProof(
      controller: LiveMicrophoneRecordingController
    ) async {
      AppTelemetry.captureProof(stage: "requested", detail: "explicit-command")
      await controller.start()
      for _ in 0..<600 where controller.phase == .starting {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard controller.phase == .capturing else {
        AppTelemetry.captureProof(
          stage: "failed",
          detail: controller.failureCode ?? "unknown"
        )
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
        return
      }
      AppTelemetry.captureProof(stage: "capturing", detail: "first-sample-durable")
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      await controller.stop()
      let result = controller.phase == .saved ? "saved" : "failed"
      AppTelemetry.captureProof(stage: result, detail: controller.phase.rawValue)
      try? await Task.sleep(nanoseconds: 500_000_000)
      NSApp.terminate(nil)
    }

    @MainActor
    static func runForcedTerminationCaptureProof(
      controller: LiveMicrophoneRecordingController
    ) async {
      AppTelemetry.recoveryProof(stage: "capture-requested", detail: "explicit-command")
      await controller.start()
      for _ in 0..<600 where controller.phase == .starting {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard controller.phase == .capturing else {
        AppTelemetry.recoveryProof(
          stage: "capture-failed",
          detail: controller.failureCode ?? "unknown"
        )
        return
      }
      AppTelemetry.recoveryProof(stage: "capture-durable", detail: "awaiting-external-kill")
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }

    @MainActor
    static func runForcedTerminationRecoveryProof(
      controller: RecoveredSessionController
    ) async {
      // Launch recovery scans off the main actor; wait for it to publish.
      for _ in 0..<600 where controller.phase == .scanning {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard let recovered = controller.sessions.first else {
        let stage = controller.phase == .none ? "recovery-empty" : "recovery-failed"
        AppTelemetry.recoveryProof(stage: stage, detail: "no-playable-session")
        NSApp.terminate(nil)
        return
      }
      AppTelemetry.recoveryProof(
        stage: "recovered",
        detail: "bytes-\(recovered.byteLength)-frames-\(recovered.sampleCount)"
      )
      guard let generation = controller.play(recovered) else {
        AppTelemetry.recoveryProof(stage: "recovery-failed", detail: "playback-not-admitted")
        NSApp.terminate(nil)
        return
      }
      let recoveredIdentity = RecoveredPlaybackMediaIdentity(recovered)
      var startup = controller.playbackStartupState(
        generation: generation,
        identity: recoveredIdentity
      )
      for _ in 0..<200 where startup == .pending {
        do {
          try await Task.sleep(nanoseconds: 25_000_000)
        } catch {
          controller.stopPlayback(generation: generation)
          AppTelemetry.recoveryProof(stage: "recovery-failed", detail: "playback-wait-cancelled")
          NSApp.terminate(nil)
          return
        }
        startup = controller.playbackStartupState(
          generation: generation,
          identity: recoveredIdentity
        )
      }
      guard startup == .playing else {
        controller.stopPlayback(generation: generation)
        let detail =
          switch startup {
          case .some(.failed): "playback-open-failed"
          case .some(.superseded): "playback-open-superseded"
          case .some(.pending): "playback-open-timeout"
          case .some(.playing): "playback-opened"
          case nil: "playback-open-state-unavailable"
          }
        AppTelemetry.recoveryProof(stage: "recovery-failed", detail: detail)
        NSApp.terminate(nil)
        return
      }
      AppTelemetry.recoveryProof(stage: "playback-opened", detail: "native-audio-engine")
      try? await Task.sleep(nanoseconds: 750_000_000)
      controller.stopPlayback(generation: generation)
      NSApp.terminate(nil)
    }
  }

  struct VerificationSettingsTrigger: View {
    var body: some View {
      if #available(macOS 14.0, *) {
        ModernSettingsTrigger()
      } else {
        Color.clear.frame(width: 0, height: 0).onAppear {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
      }
    }
  }
  @available(macOS 14.0, *)
  private struct ModernSettingsTrigger: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View { Color.clear.frame(width: 0, height: 0).onAppear { openSettings() } }
  }
#endif
