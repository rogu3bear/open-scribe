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

  private let status = RustStatusSource.load()

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    let fixture = FixtureLaunchSelection.selected(from: arguments)
    let proofRoot = Self.liveMicrophoneProofRoot(from: arguments)
    let controller =
      proofRoot.map(LiveMicrophoneRecordingController.init(managedRoot:))
      ?? LiveMicrophoneRecordingController()
    _sessionStore = StateObject(wrappedValue: FixtureSessionStore(fixture: fixture))
    _liveRecording = StateObject(wrappedValue: controller)
    if proofRoot != nil {
      Task { @MainActor in
        await Self.runLiveMicrophoneProof(controller: controller)
      }
    }
  }

  var body: some Scene {
    WindowGroup("Open Scribe", id: "main") {
      ContentView(store: sessionStore)
    }
    .defaultSize(width: 520, height: 560)

    MenuBarExtra {
      MenuBarContent(store: sessionStore, liveRecording: liveRecording)
    } label: {
      MenuBarLabel(store: sessionStore, liveRecording: liveRecording)
    }

    Settings {
      SettingsView(status: status)
    }
  }

  private static func liveMicrophoneProofRoot(from arguments: [String]) -> URL? {
    guard let marker = arguments.firstIndex(of: "--m1-live-microphone-proof-root"),
      arguments.indices.contains(marker + 1)
    else { return nil }
    return URL(fileURLWithPath: arguments[marker + 1], isDirectory: true)
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
    controller.stop()
    let result = controller.phase == .saved ? "saved" : "failed"
    AppTelemetry.captureProof(stage: result, detail: controller.phase.rawValue)
    try? await Task.sleep(nanoseconds: 500_000_000)
    NSApp.terminate(nil)
  }
}
