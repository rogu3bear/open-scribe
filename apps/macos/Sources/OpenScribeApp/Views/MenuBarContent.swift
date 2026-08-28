import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: FixtureSessionStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController

  @MainActor
  init(
    store: FixtureSessionStore,
    liveRecording: LiveMicrophoneRecordingController? = nil,
    recoveredSessions: RecoveredSessionController? = nil
  ) {
    self.store = store
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController()
    self.recoveredSessions =
      recoveredSessions ?? RecoveredSessionController(managedRoot: nil)
  }

  var body: some View {
    Text(liveRecording.statusText)
      .accessibilityLabel(liveRecording.statusText)
    if let errorMessage = liveRecording.errorMessage {
      Text(errorMessage)
        .foregroundStyle(.red)
    }
    if liveRecording.savedPaths.count > 1 {
      Text("Saved: \(liveRecording.savedPaths.count) local audio tracks")
        .foregroundStyle(.secondary)
    } else if let savedPath = liveRecording.savedPath {
      Text("Saved: \(URL(fileURLWithPath: savedPath).lastPathComponent)")
        .foregroundStyle(.secondary)
    }
    if liveRecording.canStart {
      Button("Record Microphone + System Audio") {
        Task {
          await liveRecording.start()
        }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
    }
    if liveRecording.canStop {
      Button("Stop Capture") {
        Task {
          await liveRecording.stop()
        }
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
    }
    if let recovered = recoveredSessions.sessions.first {
      Divider()
      Label("Recovered conversation", systemImage: "waveform.badge.checkmark")
      Text("Playable local audio")
        .foregroundStyle(.secondary)
      if recoveredSessions.playingSessionId == recovered.sessionId {
        Button("Stop Recovered Audio") {
          recoveredSessions.stopPlayback()
        }
      } else {
        Button("Play Recovered Audio") {
          recoveredSessions.play(recovered)
        }
      }
    }
    if let recoveryError = recoveredSessions.errorMessage {
      Text(recoveryError)
        .foregroundStyle(.red)
    }
    Divider()
    Text("Development session fixture")
      .foregroundStyle(.secondary)
    Text(store.displayedLabel)
      .accessibilityLabel(store.displayedAccessibilityValue)
    ForEach(store.snapshot.sources, id: \.id) { source in
      Text("\(source.name): \(source.activity)")
    }
    Divider()
    SessionCommands(store: store)
    Divider()
    Button("Open Open Scribe") {
      AppTelemetry.commandInvoked("open-primary")
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }
    Button("Inspect state") {
      store.inspect()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    .accessibilityValue(store.displayedAccessibilityValue)
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
}

struct MenuBarLabel: View {
  @ObservedObject var store: FixtureSessionStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController

  var body: some View {
    Group {
      if liveRecording.isCapturing {
        Label("Recording microphone + system audio", systemImage: "record.circle.fill")
      } else if liveRecording.phase == .starting {
        Label("Starting microphone + system audio", systemImage: "waveform")
      } else if liveRecording.phase == .failed {
        Label("Recording needs attention", systemImage: "exclamationmark.circle")
      } else if liveRecording.phase == .saved {
        Label("Conversation audio saved", systemImage: "waveform.badge.checkmark")
      } else if let symbol = store.snapshot.resolvedSymbolName {
        Label(store.displayedLabel, systemImage: symbol)
      } else {
        Text(store.displayedLabel)
      }
    }
    .accessibilityLabel(
      liveRecording.isCapturing
        ? "Recording microphone and system audio"
        : liveRecording.statusText
    )
    .onAppear {
      AppTelemetry.sceneAppeared("menu-bar", snapshot: store.snapshot)
    }
  }
}
