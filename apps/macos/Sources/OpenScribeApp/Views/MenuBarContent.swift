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
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
