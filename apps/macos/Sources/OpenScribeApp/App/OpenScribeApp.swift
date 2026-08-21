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
  @StateObject private var sessionStore: FixtureSessionStore

  private let status = RustStatusSource.load()

  init() {
    let fixture = FixtureLaunchSelection.selected(from: ProcessInfo.processInfo.arguments)
    _sessionStore = StateObject(wrappedValue: FixtureSessionStore(fixture: fixture))
  }

  var body: some Scene {
    WindowGroup("Open Scribe", id: "main") {
      ContentView(store: sessionStore)
    }
    .defaultSize(width: 520, height: 560)

    MenuBarExtra {
      MenuBarContent(store: sessionStore)
    } label: {
      MenuBarLabel(store: sessionStore)
    }

    Settings {
      SettingsView(status: status)
    }
  }
}
