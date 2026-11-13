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
      if !AppDelegate.restoresState { window?.isRestorable = false }
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
  /// Set once by `adoptStatePolicy` before any window exists.
  private(set) static var restoresState = true
  private var launchAdmitted = false

  /// A launch that keeps no window state answers no to AppKit's save and
  /// restore questions, tells AppKit to ignore saved state and keep no windows
  /// on quit, and marks the main window not restorable as it appears.
  static func adoptStatePolicy(_ configuration: LaunchConfiguration) {
    guard !configuration.restoresState else { return }
    restoresState = false
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["ApplePersistenceIgnoreState"] = true
    arguments["NSQuitAlwaysKeepsWindows"] = false
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
  }

  func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
    Self.restoresState
  }
  func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
    Self.restoresState
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
  @StateObject private var suggestions: ConversationSuggestionModel

  private let status = AppStatus.load()
  private let launchConfiguration: LaunchConfiguration

  init() {
    let configuration: LaunchConfiguration
    do {
      guard let normalRoot = LaunchConfiguration.productionRoot
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
    let managedRoot = configuration.libraryRoot
    launchConfiguration = configuration
    AppDelegate.adoptStatePolicy(configuration)
    // This is the one place that builds the app's stores and capture
    // sources. Recovery comes first: its scan holds recording and import.
    let recovery = RecoveredSessionController(managedRoot: managedRoot)
    let launchHold: @MainActor () -> Bool = { !recovery.captureSafetyComplete }
    let production = CaptureEnvironment.production(
      managedRoot: managedRoot, isLaunchRecoveryPending: launchHold,
      liveCaptions: LiveCaptionModel(
        defaults: configuration.preferences, suspended: configuration.suspendsAutomation))
    #if DEBUG
      let injectedCapture = M1InjectedCapture(configuration)
      let capture = injectedCapture?.environment(production) ?? production
    #else
      let capture = production
    #endif
    let controller = LiveMicrophoneRecordingController(environment: capture)
    let runtime = RuntimeLibraryStore(managedRoot: managedRoot, isLaunchRecoveryPending: launchHold)
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
    let transcriptLibrary = TranscriptLibraryModel(managedRoot: managedRoot)
    _transcripts = StateObject(wrappedValue: transcriptLibrary)
    // Suggestions share the transcript library's connection.
    _suggestions = StateObject(
      wrappedValue: ConversationSuggestionModel(
        library: { try await transcriptLibrary.connectedLibrary() },
        suspended: configuration.suspendsAutomation))
    let speech = SpeechTranscriptionModel(managedRoot: managedRoot)
    _speech = StateObject(wrappedValue: speech)
    let pressure = SystemPressureMonitor(libraryRoot: managedRoot)
    _pressure = StateObject(wrappedValue: pressure)
    // All proof/test launches use the validated isolated library and preferences.
    let scheduler = TranscriptionScheduler(
      managedRoot: managedRoot, speech: speech, store: runtime, liveRecording: controller,
      recovery: recovery, pressure: pressure, defaults: configuration.preferences,
      automationSuspended: configuration.suspendsAutomation)
    _scheduler = StateObject(wrappedValue: scheduler)
    _context = StateObject(
      wrappedValue: ContextScopeModel(
        binding: { [weak controller] in controller?.contextBinding },
        bindingChanges: controller.$phase.map { _ in () }.eraseToAnyPublisher()))
    #if DEBUG
      ProofLaunchRunner.start(
        configuration: configuration,
        injected: injectedCapture.map { M1FailureRuntimeProof(capture: $0, controller: controller) },
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
        navigation: navigation,
        suggestions: suggestions
      )
      .modifier(MainWindowMinimumSize())
      .defaultAppStorage(launchConfiguration.preferences)
      .environment(\.isSceneVerification, launchConfiguration.mode == .scenes)
    }
    .defaultSize(width: 1040, height: 720)
    .commands {
      CommandGroup(replacing: .newItem) {}
      TranscriptTextSizeCommands(preferences: launchConfiguration.preferences)
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
        speech: speech,
        copyConversation: { [transcripts] session in
          Task { @MainActor in await transcripts.copyConversation(session) }
        }
      )
      .defaultAppStorage(launchConfiguration.preferences)
    } label: {
      MenuBarLabel(store: runtimeStore, liveRecording: liveRecording)
        .environment(\.isSceneVerification, launchConfiguration.mode == .scenes)
    }

    Settings {
      SettingsView(
        status: status, speech: speech, library: runtimeStore, recovery: recoveredSessions,
        scheduler: scheduler, pressure: pressure, liveCaptions: liveRecording.liveCaptions
      )
      .defaultAppStorage(launchConfiguration.preferences)
    }
  }

}

/// View > Bigger, Smaller and Actual Size for transcript text, stored where
/// the reader reads it.
struct TranscriptTextSizeCommands: Commands {
  @AppStorage private var stored: String

  init(preferences: UserDefaults) {
    _stored = AppStorage(
      wrappedValue: TranscriptTextScale.standard.rawValue, TranscriptTextScale.storageKey,
      store: preferences)
  }

  private var scale: TranscriptTextScale { TranscriptTextScale.resolve(stored) }

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Bigger Transcript Text") { stored = scale.stepped(1).rawValue }
        .keyboardShortcut("+", modifiers: .command)
        .disabled(scale == .largest)
      Button("Smaller Transcript Text") { stored = scale.stepped(-1).rawValue }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(scale == .standard)
      Button("Actual Size") { stored = TranscriptTextScale.standard.rawValue }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(scale == .standard)
      Divider()
    }
  }
}
