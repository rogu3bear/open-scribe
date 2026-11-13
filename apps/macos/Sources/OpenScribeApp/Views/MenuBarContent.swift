import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @ObservedObject var context: ContextScopeModel
  @ObservedObject var navigation: MainWorkspaceNavigation
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var speech: SpeechTranscriptionModel
  /// Copies a saved conversation's transcript, as the window's Copy does.
  var copyConversation: (@MainActor (RuntimeSessionPresentation) -> Void)?

  @MainActor
  init(
    store: RuntimeLibraryStore,
    importedMediaAuthority: ImportedMediaAuthorityAdapter,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil,
    context: ContextScopeModel? = nil,
    navigation: MainWorkspaceNavigation? = nil,
    scheduler: TranscriptionScheduler? = nil,
    speech: SpeechTranscriptionModel? = nil,
    copyConversation: (@MainActor (RuntimeSessionPresentation) -> Void)? = nil
  ) {
    self.copyConversation = copyConversation
    self.store = store
    self.importedMediaAuthority = importedMediaAuthority
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController()
    self.recoveredSessions =
      recoveredSessions ?? RecoveredSessionController(managedRoot: nil)
    self.context = context ?? ContextScopeModel(binding: { nil })
    self.navigation = navigation ?? MainWorkspaceNavigation()
    self.scheduler = scheduler ?? TranscriptionScheduler.inert()
    self.speech = speech ?? SpeechTranscriptionModel(speech: nil)
  }

  var body: some View {
    if let current = store.currentSession {
      if liveRecording.phase == .requestingPermission {
        Text(liveRecording.statusText)
          .accessibilityLabel(liveRecording.statusText)
      } else {
        CaptureStatusLabel(text: current.statusText, symbolName: Self.statusSymbol(for: current))
        Text(current.timerText)
          .font(.system(.body, design: .monospaced))
      }
      ForEach(current.sources, id: \.kind) { source in
        Label("\(source.name): \(source.stateText)", systemImage: source.symbolName)
      }
      if let interruption = current.interruptionText {
        CaptureIssueLabel(message: interruption)
      }
    } else {
      Text(pendingStatusText)
        .accessibilityLabel(pendingStatusText)
    }
    if let errorMessage = liveRecording.errorMessage {
      CaptureIssueLabel(message: errorMessage, isFailure: true)
    }
    if let storageNotice = liveRecording.storagePressureNotice {
      CaptureIssueLabel(message: storageNotice)
    }
    if let libraryError = store.errorMessage {
      CaptureIssueLabel(message: libraryError, isFailure: true)
    }
    let savedCount = LibraryConversationLists.saved(store.savedSessions).count
    if savedCount > 0 {
      Text(
        "\(store.isSnapshotStale ? "Last known: " : "")\(savedCount) saved conversation\(savedCount == 1 ? "" : "s")"
      )
      .foregroundStyle(.secondary)
    }
    if let copyConversation, let latest = Self.latestCopyable(store.savedSessions) {
      Button("Copy “\(ConversationIdentityPresentation.title(for: latest))”") {
        copyConversation(latest)
      }
      .help("Copy the most recent conversation's transcript, ready to paste")
    }
    if let activity = scheduler.summaryText(
      titles: Dictionary(
        uniqueKeysWithValues: store.savedSessions.map {
          ($0.sessionId, ConversationIdentityPresentation.title(for: $0))
        }),
      progress: speech.progressFraction)
    {
      Text(activity)
        .foregroundStyle(.secondary)
        .accessibilityLabel(activity)
    }
    if liveRecording.canStart {
      MenuBarRecordMount(
        title: Self.recordTitle(
          lifecycle: store.currentSession?.lifecycle,
          summary: liveRecording.sourceSelectionPresentation.summary),
        enabled: recordActionEnabled,
        onRecord: {
          Task {
            await liveRecording.start()
            store.refresh()
          }
        }
      )
      .frame(width: 420, height: 32, alignment: .leading)
    }
    if liveRecording.canStop {
      MenuBarStopMount(
        onStop: {
          Task {
            await liveRecording.stop()
            store.refresh()
          }
        }
      )
      .frame(width: 180, height: 32, alignment: .leading)
    }
    RecorderControls(recorder: liveRecording, store: store, sourcesPresentation: .menu)
    ContextMenuSection(model: context)
    let conversations = (store.currentSession.map { [$0] } ?? []) + store.savedSessions
    if let recovered = Self.preservedConversation(
      in: conversations, media: recoveredSessions.sessions
    ) {
      Divider()
      let title = ConversationIdentityPresentation.title(for: recovered)
      let reference = ConversationIdentityPresentation.references(for: conversations)[
        recovered.sessionId]
      Text("\(title)\(reference.map { " · \($0)" } ?? "")")
        .help(recovered.title)
        .accessibilityLabel("\(title)\(reference.map { ", reference \($0)" } ?? "")")
      Text("Verified local audio is available for review.")
        .foregroundStyle(.secondary)
      Button(ConversationControlLabels.reviewPreservedAudio) {
        navigation.reviewPreservedAudio(sessionId: recovered.sessionId)
        openPrimaryWindow()
      }
    }
    if recoveredSessions.activePlaybackSessionId != nil {
      let playbackAction = PlaybackControlAction.resolve(
        isPending: recoveredSessions.playingSessionId == nil,
        isPlaying: recoveredSessions.playingSessionId != nil
      )
      Button("\(playbackAction.title) Audio") {
        recoveredSessions.stopPlayback()
      }
    }
    if let recoveryError = recoveredSessions.errorMessage {
      CaptureIssueLabel(message: recoveryError, isFailure: true)
    }
    Divider()
    Button("Open Open Scribe") {
      openPrimaryWindow()
    }
    Button("Refresh Library") {
      store.refresh()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    if #available(macOS 14.0, *) {
      SettingsLink {
        Text("Settings…")
      }
    } else {
      Button("Settings…") {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      }
    }
    Divider()
    Button("Quit Open Scribe") {
      AppTelemetry.commandInvoked("quit")
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  var recordActionEnabled: Bool {
    MainWorkspaceActions.canRecord(
      liveCanStart: liveRecording.canStart,
      importIsBusy: importedMediaAuthority.isBusy
    )
  }

  /// The one capture action in an idle menu. An interrupted session offers a
  /// new recording; every other idle menu names the selected sources.
  static func recordTitle(lifecycle: String?, summary: String) -> String {
    lifecycle == "interrupted" ? "Start New Recording" : "Record — \(summary)"
  }

  /// The newest saved conversation that has any transcript text.
  static func latestCopyable(_ sessions: [RuntimeSessionPresentation]) -> RuntimeSessionPresentation?
  {
    LibraryConversationLists.saved(sessions)
      .filter {
        $0.transcript.documentAvailability != .unavailable || $0.transcript.hasDraftText
      }
      .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
  }

  static func statusSymbol(for session: RuntimeSessionPresentation) -> String {
    session.captureStatusSymbolName
  }

  static func preservedConversation(
    in sessions: [RuntimeSessionPresentation], media: [NativeRecoveredPlayableSession]
  ) -> RuntimeSessionPresentation? {
    sessions.first {
      ($0.lifecycle == "interrupted" || $0.lifecycle == "ready_for_review")
        && ($0.needsAttention || $0.recovered) && $0.hasVerifiedPreservedAudio(from: media)
    }
  }

  private func openPrimaryWindow() {
    AppTelemetry.commandInvoked("open-primary")
    if !MainWindow.focusExisting() {
      openWindow(id: "main")
    }
  }

  private var pendingStatusText: String {
    switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting, .pausing, .paused: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
    case .saved: liveRecording.statusText
    case .failed: liveRecording.statusText
    default: liveRecording.readinessText
    }
  }
}

/// The menu bar's idle Record control. The button is created with the first
/// layout and calls the same start the menu action used.
private struct MenuBarRecordMount: NSViewRepresentable {
  let title: String
  let enabled: Bool
  let onRecord: () -> Void

  func makeNSView(context: Context) -> MenuBarRecordControl {
    let view = MenuBarRecordControl()
    view.bind(title: title, enabled: enabled, onRecord: onRecord)
    return view
  }

  func updateNSView(_ view: MenuBarRecordControl, context: Context) {
    view.bind(title: title, enabled: enabled, onRecord: onRecord)
  }
}

private final class MenuBarRecordControl: NSView {
  private let button = NSButton(title: "", target: nil, action: nil)
  private var onRecord: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Menu bar record")
    button.bezelStyle = .rounded
    button.setAccessibilityIdentifier("Menu bar record")
    let shortcut = ConversationControlLabels.recordShortcut
    button.keyEquivalent = String(shortcut.key.character)
    button.keyEquivalentModifierMask = Self.modifierMask(shortcut.modifiers)
    button.target = self
    button.action = #selector(record)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(title: String, enabled: Bool, onRecord: @escaping () -> Void) {
    self.onRecord = onRecord
    button.title = title
    button.setAccessibilityLabel(title)
    button.isEnabled = enabled
  }

  @objc private func record() {
    guard button.isEnabled else { return }
    onRecord?()
  }

  private static func modifierMask(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { mask.insert(.command) }
    if modifiers.contains(.shift) { mask.insert(.shift) }
    if modifiers.contains(.option) { mask.insert(.option) }
    if modifiers.contains(.control) { mask.insert(.control) }
    return mask
  }
}

/// The menu bar's Stop and Save control. The button is created with the first
/// layout and calls the same stop the toolbar uses.
private struct MenuBarStopMount: NSViewRepresentable {
  let onStop: () -> Void

  func makeNSView(context: Context) -> MenuBarStopControl {
    let view = MenuBarStopControl()
    view.bind(onStop: onStop)
    return view
  }

  func updateNSView(_ view: MenuBarStopControl, context: Context) {
    view.bind(onStop: onStop)
  }
}

private final class MenuBarStopControl: NSView {
  private let button = NSButton(
    title: ConversationControlLabels.stopAndSave, target: nil, action: nil)
  private var onStop: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Menu bar stop")
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(ConversationControlLabels.stopAndSave)
    button.setAccessibilityIdentifier("Menu bar stop")
    let shortcut = ConversationControlLabels.stopShortcut
    button.keyEquivalent = String(shortcut.key.character)
    button.keyEquivalentModifierMask = Self.modifierMask(shortcut.modifiers)
    button.target = self
    button.action = #selector(stop)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(onStop: @escaping () -> Void) {
    self.onStop = onStop
    button.isEnabled = true
  }

  @objc private func stop() {
    guard button.isEnabled else { return }
    onStop?()
  }

  private static func modifierMask(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { mask.insert(.command) }
    if modifiers.contains(.shift) { mask.insert(.shift) }
    if modifiers.contains(.option) { mask.insert(.option) }
    if modifiers.contains(.control) { mask.insert(.control) }
    return mask
  }
}

struct MenuBarLabel: View {
  @Environment(\.isSceneVerification) private var isSceneVerification
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController

  var body: some View {
    let presentation = Self.presentation(
      session: store.currentSession,
      snapshotStale: store.isSnapshotStale,
      livePhase: liveRecording.phase,
      liveStatus: liveRecording.statusText
    )
    CaptureStatusLabel(text: presentation.text, symbolName: presentation.symbolName)
      .accessibilityLabel(presentation.accessibilityText)
      .onAppear {
        store.refresh()
        AppTelemetry.runtimeSceneAppeared("menu-bar", session: store.currentSession)
        #if DEBUG
          // The explicit scene proof must also work after macOS restores a
          // menu-bar-only launch. Its primary scene opens Settings in turn.
          if isSceneVerification,
            !MainWindow.focusExisting()
          {
            openWindow(id: "main")
          }
        #endif
      }
  }

  static func accessibilityStatus(
    session: RuntimeSessionPresentation?,
    snapshotStale: Bool,
    livePhase: LiveMicrophoneRecordingPhase,
    liveStatus: String
  ) -> String {
    presentation(
      session: session,
      snapshotStale: snapshotStale,
      livePhase: livePhase,
      liveStatus: liveStatus
    ).accessibilityText
  }

  static func presentation(
    session: RuntimeSessionPresentation?,
    snapshotStale: Bool,
    livePhase: LiveMicrophoneRecordingPhase,
    liveStatus: String
  ) -> (text: String, symbolName: String, accessibilityText: String) {
    if snapshotStale {
      return ("State unavailable", "exclamationmark.circle", "Live recording state unavailable")
    }
    if livePhase == .requestingPermission {
      return (liveStatus, SymbolResolver.captureSymbol(for: .starting), liveStatus)
    }
    if let session {
      if let paused = session.pausedStatusSymbolName {
        return (
          "\(session.statusText) · \(session.timerText)", paused,
          "\(session.statusText), \(session.timerText)"
        )
      }
      if session.isRecording {
        return (
          "Recording · \(session.timerText)",
          session.captureStatusSymbolName,
          "Recording \(session.capturingSourcesText), \(session.timerText)"
        )
      }
      return (
        session.statusText,
        session.captureStatusSymbolName,
        session.statusText
      )
    }
    return switch livePhase {
    case .capturing:
      (
        "Confirming recording", SymbolResolver.captureSymbol(for: .starting),
        "Confirming durable recording"
      )
    case .starting:
      (liveStatus, SymbolResolver.captureSymbol(for: .starting), liveStatus)
    case .paused:
      (liveStatus, SymbolResolver.pausedCaptureSymbolName, liveStatus)
    case .failed:
      (liveStatus, "exclamationmark.circle", liveStatus)
    case .saved:
      (liveStatus, "waveform.badge.checkmark", liveStatus)
    case .requestingPermission, .preparing, .pausing, .stopping:
      (liveStatus, SymbolResolver.captureSymbol(for: .starting), liveStatus)
    case .idle:
      ("Open Scribe", SymbolResolver.captureSymbol(for: .ready), liveStatus)
    }
  }
}

private struct CaptureStatusLabel: View {
  let text: String
  let symbolName: String

  var body: some View {
    if symbolName.isEmpty {
      Text(text)
    } else {
      Label(text, systemImage: symbolName)
    }
  }
}
