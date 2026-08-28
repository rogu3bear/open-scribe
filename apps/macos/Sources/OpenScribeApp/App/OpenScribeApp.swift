import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var instanceGuard: SingleInstanceGuard?
  private var launchAdmitted = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    do {
      instanceGuard = try SingleInstanceGuard.acquireDefault()
      launchAdmitted = true
    } catch {
      if (error as? SingleInstanceGuardError)?.shouldActivateExistingInstance == true {
        activateExistingInstance()
      } else {
        AppTelemetry.launchFailed(String(describing: error))
      }
      NSApp.terminate(nil)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard launchAdmitted else { return }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func activateExistingInstance() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let currentProcess = ProcessInfo.processInfo.processIdentifier
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first { $0.processIdentifier != currentProcess }?
      .activate(options: [.activateAllWindows])
  }
}

@main
struct OpenScribeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var sessionStore: FixtureSessionStore
  @StateObject private var liveRecording: LiveMicrophoneRecordingController
  @StateObject private var recoveredSessions: RecoveredSessionController

  private let status = RustStatusSource.load()

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    let fixture = FixtureLaunchSelection.selected(from: arguments)
    let liveProofRoot = Self.argumentRoot("--m1-live-microphone-proof-root", from: arguments)
    let forcedCaptureRoot = Self.argumentRoot(
      "--m1-forced-termination-capture-root",
      from: arguments
    )
    let forcedRecoveryRoot = Self.argumentRoot(
      "--m1-forced-termination-recovery-root",
      from: arguments
    )
    let managedRoot = liveProofRoot ?? forcedCaptureRoot ?? forcedRecoveryRoot ?? Self.defaultRoot()
    let controller =
      managedRoot.map(LiveMicrophoneRecordingController.init(managedRoot:))
      ?? LiveMicrophoneRecordingController(managedRoot: nil)
    let recovery = RecoveredSessionController(managedRoot: managedRoot)
    _sessionStore = StateObject(wrappedValue: FixtureSessionStore(fixture: fixture))
    _liveRecording = StateObject(wrappedValue: controller)
    _recoveredSessions = StateObject(wrappedValue: recovery)
    if liveProofRoot != nil {
      Task { @MainActor in
        await Self.runLiveMicrophoneProof(controller: controller)
      }
    } else if forcedCaptureRoot != nil {
      Task { @MainActor in
        await Self.runForcedTerminationCaptureProof(controller: controller)
      }
    } else {
      Task { @MainActor in
        recovery.recoverOnLaunch()
        if forcedRecoveryRoot != nil {
          await Self.runForcedTerminationRecoveryProof(controller: recovery)
        }
      }
    }
  }

  var body: some Scene {
    WindowGroup("Open Scribe", id: "main") {
      ContentView(store: sessionStore, recoveredSessions: recoveredSessions)
    }
    .defaultSize(width: 520, height: 560)

    MenuBarExtra {
      MenuBarContent(
        store: sessionStore,
        liveRecording: liveRecording,
        recoveredSessions: recoveredSessions
      )
    } label: {
      MenuBarLabel(store: sessionStore, liveRecording: liveRecording)
    }

    Settings {
      SettingsView(status: status)
    }
  }

  private static func argumentRoot(_ argument: String, from arguments: [String]) -> URL? {
    guard let marker = arguments.firstIndex(of: argument),
      arguments.indices.contains(marker + 1)
    else { return nil }
    return URL(fileURLWithPath: arguments[marker + 1], isDirectory: true)
  }

  private static func defaultRoot() -> URL? {
    try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("Open Scribe", isDirectory: true)
  }

  @MainActor
  private static func runLiveMicrophoneProof(
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
  private static func runForcedTerminationCaptureProof(
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
  private static func runForcedTerminationRecoveryProof(
    controller: RecoveredSessionController
  ) async {
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
    controller.play(recovered)
    guard controller.playingSessionId == recovered.sessionId else {
      AppTelemetry.recoveryProof(stage: "recovery-failed", detail: "playback-open-failed")
      NSApp.terminate(nil)
      return
    }
    AppTelemetry.recoveryProof(stage: "playback-opened", detail: "native-audio-engine")
    try? await Task.sleep(nanoseconds: 750_000_000)
    controller.stopPlayback()
    NSApp.terminate(nil)
  }
}
