import AppKit
import SwiftUI

@MainActor
enum MainWindow {
  static func isPrimary(_ window: NSWindow) -> Bool {
    guard window.canBecomeMain, window.level == .normal, window.styleMask.contains(.titled) else {
      return false
    }
    return window.title != "Settings" && window.title != "Open Scribe Settings"
  }

  static func existing() -> [NSWindow] {
    NSApp.windows.filter(isPrimary)
  }

  static func keepOne() {
    let windows = existing()
    guard windows.count > 1 else { return }
    let keeper = windows.first(where: { $0.isKeyWindow }) ?? windows[0]
    for window in windows where window !== keeper {
      window.close()
    }
  }

  @discardableResult
  static func focusExisting() -> Bool {
    keepOne()
    guard let window = existing().first else { return false }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }
}

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
    // WindowGroup restores the previous window and also creates a new one.
    MainWindow.keepOne()
    DispatchQueue.main.async { MainWindow.keepOne() }
    let microphone = AVFoundationMicrophonePermissionAuthority().currentState.rawValue
    let screenCapture = CGPreflightScreenCaptureAccess() ? "authorized" : "not_authorized"
    AppTelemetry.launchAdmitted(microphone: microphone, screenCapture: screenCapture)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if flag {
      MainWindow.keepOne()
      MainWindow.focusExisting()
      return false
    }
    return true
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
  @StateObject private var runtimeStore: RuntimeLibraryStore
  @StateObject private var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @StateObject private var liveRecording: LiveMicrophoneRecordingController
  @StateObject private var recoveredSessions: RecoveredSessionController
  @StateObject private var transcripts: TranscriptLibraryModel
  @StateObject private var speech: SpeechTranscriptionModel
  @StateObject private var context: ContextScopeModel
  @StateObject private var navigation = MainWorkspaceNavigation()

  private let status = RustStatusSource.load()

  init() {
    let arguments = ProcessInfo.processInfo.arguments
    let injectedRoot = Self.argumentRoot("--m1-injected-proof-root", from: arguments)
    let injectedRecoveryRoot = Self.argumentRoot("--m1-injected-recovery-root", from: arguments)
    let injectedMediaRoot = Self.argumentRoot("--m1-proof-media-root", from: arguments)
    let injectedScenario = arguments.firstIndex(of: "--m1-injected-case").flatMap { index in
      arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    } ?? "invalid"
    let foundationReviewRoot = Self.argumentRoot("--foundation-review-root", from: arguments)
    let foundationLiveRecoveryRoot = Self.argumentRoot(
      "--foundation-live-recovery-root", from: arguments)
    let timelineCaptureRoot = Self.argumentRoot(
      "--foundation-synthetic-capture-root", from: arguments)
    let timelineRecoveryRoot = Self.argumentRoot(
      "--foundation-synthetic-recovery-root", from: arguments)
    let liveProofRoot = Self.argumentRoot("--m1-live-microphone-proof-root", from: arguments)
    let forcedCaptureRoot = Self.argumentRoot(
      "--m1-forced-termination-capture-root",
      from: arguments
    )
    let forcedRecoveryRoot = Self.argumentRoot(
      "--m1-forced-termination-recovery-root",
      from: arguments
    )
    let localOnlyRoot = Self.argumentRoot("--local-only-proof-root", from: arguments)
    let driftRunRoot = Self.argumentRoot("--m1-drift-run-root", from: arguments)
    let driftRunSeconds = arguments.firstIndex(of: "--m1-drift-run-seconds").flatMap { index in
      arguments.indices.contains(index + 1) ? UInt64(arguments[index + 1]) : nil
    } ?? 0
    let proofRoots: [URL?] = [
      injectedMediaRoot, injectedRoot, injectedRecoveryRoot, foundationReviewRoot,
      foundationLiveRecoveryRoot, timelineCaptureRoot, timelineRecoveryRoot,
      liveProofRoot, forcedCaptureRoot, forcedRecoveryRoot,
      localOnlyRoot?.appendingPathComponent("Library", isDirectory: true),
      driftRunRoot?.appendingPathComponent("Library", isDirectory: true),
    ]
    let managedRoot = proofRoots.compactMap { $0 }.first ?? Self.defaultRoot()
    let injectedProof = injectedRoot.map {
      M1FailureRuntimeProof(root: $0, mediaRoot: injectedMediaRoot ?? $0, scenario: injectedScenario)
    }
    let controller = injectedProof?.controller
      ?? managedRoot.map(LiveMicrophoneRecordingController.init(managedRoot:))
      ?? LiveMicrophoneRecordingController(managedRoot: nil)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot)
    let recovery = RecoveredSessionController(managedRoot: managedRoot)
    let importAuthority = ImportedMediaAuthorityAdapter(
      canBeginImport: { controller.canStart },
      importer: { title, sourceURL in
        try runtime.importManagedAudio(title: title, sourceURL: sourceURL)
      },
      packageOpener: { packageURL in
        try runtime.openPortablePackage(packageURL: packageURL)
      }
    )
    _runtimeStore = StateObject(wrappedValue: runtime)
    _importedMediaAuthority = StateObject(wrappedValue: importAuthority)
    _liveRecording = StateObject(wrappedValue: controller)
    _recoveredSessions = StateObject(wrappedValue: recovery)
    _transcripts = StateObject(wrappedValue: TranscriptLibraryModel(managedRoot: managedRoot))
    _speech = StateObject(wrappedValue: SpeechTranscriptionModel(managedRoot: managedRoot))
    _context = StateObject(wrappedValue: ContextScopeModel(recorder: controller))
    if let proof = injectedProof {
      Task { @MainActor in await proof.run(runtime: runtime) }
    } else if let root = injectedRecoveryRoot {
      controller.isLaunchRecoveryPending = { recovery.phase == .scanning }
      runtime.isLaunchRecoveryPending = { recovery.phase == .scanning }
      Task { @MainActor in
        await M1FailureRuntimeProof.recover(root: root, mediaRoot: injectedMediaRoot ?? root,
          recovery: recovery, runtime: runtime)
      }
    } else if let root = foundationLiveRecoveryRoot {
      Task { @MainActor in await TimelineRuntimeProof.verifyLive(root: root) }
    } else if let root = timelineCaptureRoot ?? timelineRecoveryRoot {
      Task { @MainActor in
        await TimelineRuntimeProof.run(root: root, captureMode: timelineCaptureRoot != nil)
      }
    } else if liveProofRoot != nil {
      Task { @MainActor in
        await Self.runLiveMicrophoneProof(controller: controller)
      }
    } else if forcedCaptureRoot != nil {
      Task { @MainActor in
        await Self.runForcedTerminationCaptureProof(controller: controller)
      }
    } else if let root = localOnlyRoot {
      // The proof owns its library; launch recovery never scans the user's.
      Task { @MainActor in await LocalOnlyWorkflowProof.run(root: root) }
    } else if let root = driftRunRoot {
      // The two-hour run owns its library and stops at its own deadline.
      Task { @MainActor in
        _ = await DriftRunProof.run(controller: controller, root: root, seconds: driftRunSeconds)
        NSApp.terminate(nil)
      }
    } else {
      // Launch recovery scans the library off the main actor. A recording or
      // import begun during that scan could be recovered as abandoned, and a
      // session the scan has not recovered yet is not a live recording.
      controller.isLaunchRecoveryPending = { recovery.phase == .scanning }
      runtime.isLaunchRecoveryPending = { recovery.phase == .scanning }
      Task { @MainActor in
        recovery.recoverOnLaunch()
        if forcedRecoveryRoot != nil {
          await recovery.waitForLaunchRecovery()
          await Self.runForcedTerminationRecoveryProof(controller: recovery)
        }
      }
    }
  }

  var body: some Scene {
    WindowGroup("Open Scribe", id: "main") {
      ContentView(
        store: runtimeStore,
        importedMediaAuthority: importedMediaAuthority,
        liveRecording: liveRecording,
        recoveredSessions: recoveredSessions,
        transcripts: transcripts,
        speech: speech,
        context: context,
        navigation: navigation
      )
    }
    .defaultSize(width: 1040, height: 720)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }

    MenuBarExtra {
      MenuBarContent(
        store: runtimeStore,
        importedMediaAuthority: importedMediaAuthority,
        liveRecording: liveRecording,
        recoveredSessions: recoveredSessions,
        context: context,
        navigation: navigation
      )
    } label: {
      MenuBarLabel(store: runtimeStore, liveRecording: liveRecording)
    }

    Settings {
      SettingsView(
        status: status, speech: speech, library: runtimeStore, recovery: recoveredSessions)
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
