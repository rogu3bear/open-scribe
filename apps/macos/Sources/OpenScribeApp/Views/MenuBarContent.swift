import AppKit
import SwiftUI

struct MenuBarContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: FixtureSessionStore

  var body: some View {
    Text(store.displayedLabel)
      .accessibilityLabel(store.displayedAccessibilityValue)
    Text("Fixture only — no media captured")
      .foregroundStyle(.secondary)
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

  var body: some View {
    Group {
      if let symbol = store.snapshot.resolvedSymbolName {
        Label(store.displayedLabel, systemImage: symbol)
      } else {
        Text(store.displayedLabel)
      }
    }
    .accessibilityLabel(store.displayedAccessibilityValue)
    .onAppear {
      AppTelemetry.sceneAppeared("menu-bar", snapshot: store.snapshot)
    }
  }
}
