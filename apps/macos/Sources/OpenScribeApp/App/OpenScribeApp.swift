import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct OpenScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let status = RustStatusSource.load()

    var body: some Scene {
        WindowGroup("Open Scribe", id: "main") {
            ContentView(status: status)
        }
        .defaultSize(width: 680, height: 440)

        MenuBarExtra("Open Scribe", systemImage: "waveform") {
            MenuBarContent(status: status)
        }

        Settings {
            SettingsView(status: status)
        }
    }
}
