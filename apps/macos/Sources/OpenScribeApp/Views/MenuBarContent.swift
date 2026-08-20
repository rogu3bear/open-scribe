import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let status: AppStatus

    var body: some View {
        Text("Rust core \(status.coreVersion)")
        Text("Capture: \(status.capture)")
        Divider()
        Button("Open Open Scribe") {
            AppTelemetry.commandInvoked("open-primary")
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
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
    let status: AppStatus

    var body: some View {
        Label("Open Scribe", systemImage: "waveform")
            .onAppear {
                AppTelemetry.sceneAppeared("menu-bar", status: status)
            }
    }
}
