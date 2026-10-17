import AppKit
import SwiftUI

@MainActor
enum MainWindow {
  static let minimumFrameSize = NSSize(width: 760, height: 520)

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

/// SwiftUI owns the sizing constraint; AppKit measures the chrome included in
/// the product's outer-window minimum, without assuming a toolbar height.
private struct MainWindowMinimumSize: ViewModifier {
  @State private var chromeHeight: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .frame(
        minWidth: MainWindow.minimumFrameSize.width,
        minHeight: max(0, MainWindow.minimumFrameSize.height - chromeHeight)
      )
      .background {
        WindowChromeReader { chromeHeight = $0 }
      }
  }
}

private struct WindowChromeReader: NSViewRepresentable {
  let onChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ nsView: ChromeView, context: Context) {
    nsView.onChange = onChange
  }

  final class ChromeView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var lastHeight: CGFloat?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if AppDelegate.isVerificationLaunch { window?.isRestorable = false }
      reportChromeHeight()
    }

    override func layout() {
      super.layout()
      reportChromeHeight()
    }

    private func reportChromeHeight() {
      guard let window else { return }
      let height = max(0, window.frame.height - window.contentLayoutRect.height)
      guard height != lastHeight else { return }
      lastHeight = height
      DispatchQueue.main.async { [weak self] in self?.onChange?(height) }
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  static var isVerificationLaunch = false
  private var launchAdmitted = false
  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
    !Self.isVerificationLaunch
  }
  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
    !Self.isVerificationLaunch
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    // The app acquires its root-scoped lock before constructing any store.
    launchAdmitted = true
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

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if flag {
      MainWindow.keepOne()
      MainWindow.focusExisting()
      return false
    }
    return true
  }

  static func activateExistingInstance() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let currentProcess = ProcessInfo.processInfo.processIdentifier
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first { $0.processIdentifier != currentProcess }?
      .activate(options: [.activateAllWindows])
  }
}

@main
struct OpenScribeApp: App {
  private let instanceGuard: SingleInstanceGuard
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var runtimeStore: RuntimeLibraryStore
  @StateObject private var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @StateObject private var liveRecording: LiveMicrophoneRecordingController
  @StateObject private var recoveredSessions: RecoveredSessionController
  @StateObject private var transcripts: TranscriptLibraryModel
  @StateObject private var speech: SpeechTranscriptionModel
  @StateObject private var pressure: SystemPressureMonitor
  @StateObject private var scheduler: TranscriptionScheduler
  @StateObject private var context: ContextScopeModel
  @StateObject private var navigation = MainWorkspaceNavigation()

  private let status = RustStatusSource.load()
  private let launchConfiguration: LaunchConfiguration

  init() {
    let configuration: LaunchConfiguration
    do {
      guard
        let normalRoot = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first?
        .appendingPathComponent("Open Scribe", isDirectory: true)
      else { throw LaunchConfiguration.Rejection.missingRoot }
      configuration = try LaunchConfiguration.resolve(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment, normalRoot: normalRoot)
      instanceGuard = try SingleInstanceGuard(
        lockFileURL: configuration.libraryRoot.appendingPathComponent("open-scribe-instance.lock"))
    } catch {
      if (error as? SingleInstanceGuardError)?.shouldActivateExistingInstance == true {
        AppDelegate.activateExistingInstance()
        exit(0)
      }
      fputs("OPEN_SCRIBE_LAUNCH_REFUSED: invalid storage isolation or launch mode\n", stderr)
      exit(64)
    }
    let managedRoot: URL? = configuration.libraryRoot
    launchConfiguration = configuration
    #if DEBUG
      ProofLaunchRunner.configurePresentation(configuration)
    #endif
    let injectedProof: M1FailureRuntimeProof?
    #if DEBUG
      if case .injected(let scenario) = configuration.action, let root = configuration.proofRoot {
        injectedProof = M1FailureRuntimeProof(
          root: root, mediaRoot: configuration.mediaRoot ?? root, scenario: scenario)
      } else {
        injectedProof = nil
      }
    #else
      injectedProof = nil
    #endif
    let controller =
      injectedProof?.controller
      ?? managedRoot.map(LiveMicrophoneRecordingController.init(managedRoot:))
      ?? LiveMicrophoneRecordingController(managedRoot: nil)
    let recovery = RecoveredSessionController(managedRoot: managedRoot)
    let runtime = RuntimeLibraryStore(
      managedRoot: managedRoot, isLaunchRecoveryPending: { !recovery.captureSafetyComplete })
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
    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    _speech = StateObject(wrappedValue: speech)
    let pressure = SystemPressureMonitor(libraryRoot: managedRoot)
    _pressure = StateObject(wrappedValue: pressure)
    // All proof/test launches use the validated isolated library and preferences.
    let scheduler = TranscriptionScheduler(
      managedRoot: managedRoot, speech: speech, store: runtime, liveRecording: controller,
      recovery: recovery,
      pressure: pressure, defaults: configuration.preferences)
    scheduler.automationSuspended =
      configuration.suspendsAutomation
    _scheduler = StateObject(wrappedValue: scheduler)
    _context = StateObject(wrappedValue: ContextScopeModel(recorder: controller))
    controller.isLaunchRecoveryPending = { !recovery.captureSafetyComplete }
    #if DEBUG
      ProofLaunchRunner.start(
        configuration: configuration, injected: injectedProof,
        controller: controller, runtime: runtime, recovery: recovery)
    #else
      recovery.recoverOnLaunch()
    #endif
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
        scheduler: scheduler,
        pressure: pressure,
        context: context,
        navigation: navigation
      )
      .modifier(MainWindowMinimumSize())
      .defaultAppStorage(launchConfiguration.preferences)
      .environment(\.isSceneVerification, launchConfiguration.mode == .scenes)
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
        navigation: navigation,
        scheduler: scheduler,
        speech: speech
      )
      .defaultAppStorage(launchConfiguration.preferences)
    } label: {
      MenuBarLabel(store: runtimeStore, liveRecording: liveRecording)
        .environment(\.isSceneVerification, launchConfiguration.mode == .scenes)
    }

    Settings {
      SettingsView(
        status: status, speech: speech, library: runtimeStore, recovery: recoveredSessions,
        scheduler: scheduler, pressure: pressure
      )
      .defaultAppStorage(launchConfiguration.preferences)
    }
  }

}
