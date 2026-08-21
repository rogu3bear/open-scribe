import SwiftUI

struct ContentView: View {
  @ObservedObject var store: FixtureSessionStore

  var body: some View {
    CompactLiveView(store: store)
      .background {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--m0-proof-settings") {
            if #available(macOS 14.0, *) {
              SettingsProofTrigger()
            }
          }
        #endif
      }
  }
}

#if DEBUG
  @available(macOS 14.0, *)
  private struct SettingsProofTrigger: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      Color.clear
        .frame(width: 0, height: 0)
        .onAppear {
          openSettings()
        }
    }
  }
#endif
