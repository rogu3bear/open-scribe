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
    typealias CaptureProof = @MainActor (LaunchConfiguration.Action) async -> Void

    @discardableResult
    static func start(
      configuration: LaunchConfiguration, injected: M1FailureRuntimeProof?,
      controller: LiveMicrophoneRecordingController, runtime: RuntimeLibraryStore,
      recovery: RecoveredSessionController, captureProof: CaptureProof? = nil
    ) -> Task<Void, Never> {
      Task {
        let root = configuration.proofRoot
        switch configuration.action {
        case .injected, .microphone, .forcedCapture, .drift:
          // These runners use the same controller and launch hold as the UI.
          // Complete media safety first; transcript maintenance is independent.
          recovery.recoverOnLaunch()
          await recovery.waitForLaunchRecovery()
          guard recovery.captureSafetyComplete else {
            AppTelemetry.recoveryProof(stage: .captureProofRefused, detail: "media-recovery")
            if let root { ProofFiles.fail("capture_safety_recovery_failed", root: root) }
            if captureProof == nil { NSApp.terminate(nil) }
            return
          }
          if let captureProof {
            await captureProof(configuration.action)
          } else {
            switch configuration.action {
            case .injected:
              if let injected { await injected.run(runtime: runtime) }
            case .microphone:
              await runLiveMicrophoneProof(controller: controller)
            case .forcedCapture:
              await runForcedTerminationCaptureProof(controller: controller)
            case .drift(let seconds):
              if let root {
                _ = await DriftRunProof.run(controller: controller, root: root, seconds: seconds)
                NSApp.terminate(nil)
              }
            default: break
            }
          }
        case .injectedRecovery:
          if let root {
            await M1FailureRuntimeProof.recover(
              root: root, mediaRoot: configuration.mediaRoot ?? root, recovery: recovery,
              runtime: runtime)
          }
        case .liveRecovery:
          if let root { await TimelineRuntimeProof.verifyLive(root: root) }
        case .syntheticCapture, .syntheticRecovery:
          if let root {
            await TimelineRuntimeProof.run(
              root: root, captureMode: configuration.action == .syntheticCapture)
          }
        case .localOnly:
          if let root {
            await LocalOnlyWorkflowProof.run(
              root: root, contextInput: configuration.mode == .live ? .liveIfAuthorized : .omitted)
          }
        case .forcedRecovery:
          recovery.recoverOnLaunch()
          // The scan publishes before this returns, so `phase` is settled.
          await recovery.waitForLaunchRecovery()
          await runForcedTerminationRecoveryProof(controller: recovery)
        case .none:
          recovery.recoverOnLaunch()
        }
      }
    }

    @MainActor
    static func runLiveMicrophoneProof(
      controller: LiveMicrophoneRecordingController
    ) async {
      AppTelemetry.captureProof(stage: .requested, detail: "explicit-command")
      await controller.start()
      await controller.waitWhile(.starting)
      guard controller.phase == .capturing else {
        AppTelemetry.captureProof(
          stage: .failed,
          detail: controller.failureCode ?? "unknown"
        )
        try? await Task.sleep(nanoseconds: 500_000_000)
        NSApp.terminate(nil)
        return
      }
      AppTelemetry.captureProof(stage: .capturing, detail: "first-sample-durable")
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      await controller.stop()
      let result: CaptureProofStage = controller.phase == .saved ? .saved : .failed
      AppTelemetry.captureProof(stage: result, detail: controller.phase.rawValue)
      try? await Task.sleep(nanoseconds: 500_000_000)
      NSApp.terminate(nil)
    }

    @MainActor
    static func runForcedTerminationCaptureProof(
      controller: LiveMicrophoneRecordingController
    ) async {
      AppTelemetry.recoveryProof(stage: .captureRequested, detail: "explicit-command")
      await controller.start()
      await controller.waitWhile(.starting)
      guard controller.phase == .capturing else {
        AppTelemetry.recoveryProof(
          stage: .captureFailed,
          detail: controller.failureCode ?? "unknown"
        )
        return
      }
      AppTelemetry.recoveryProof(stage: .captureDurable, detail: "awaiting-external-kill")
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }

    @MainActor
    static func runForcedTerminationRecoveryProof(
      controller: RecoveredSessionController
    ) async {
      guard let recovered = controller.sessions.first else {
        let stage: RecoveryProofStage = controller.phase == .none ? .recoveryEmpty : .recoveryFailed
        AppTelemetry.recoveryProof(stage: stage, detail: "no-playable-session")
        NSApp.terminate(nil)
        return
      }
      AppTelemetry.recoveryProof(
        stage: .recovered,
        detail: "bytes-\(recovered.byteLength)-frames-\(recovered.sampleCount)"
      )
      guard let generation = controller.play(recovered) else {
        AppTelemetry.recoveryProof(stage: .recoveryFailed, detail: "playback-not-admitted")
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
          AppTelemetry.recoveryProof(stage: .recoveryFailed, detail: "playback-wait-cancelled")
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
        AppTelemetry.recoveryProof(stage: .recoveryFailed, detail: detail)
        NSApp.terminate(nil)
        return
      }
      AppTelemetry.recoveryProof(stage: .playbackOpened, detail: "native-audio-engine")
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
