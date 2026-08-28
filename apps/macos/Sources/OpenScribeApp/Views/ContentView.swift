import SwiftUI

struct ContentView: View {
  @ObservedObject var store: FixtureSessionStore
  @ObservedObject var recoveredSessions: RecoveredSessionController

  var body: some View {
    VStack(spacing: 16) {
      if let recovered = recoveredSessions.sessions.first {
        GroupBox("Recovered conversation") {
          HStack {
            Label("Playable local audio", systemImage: "waveform.badge.checkmark")
            Spacer()
            if recoveredSessions.playingSessionId == recovered.sessionId {
              Button("Stop") {
                recoveredSessions.stopPlayback()
              }
            } else {
              Button("Play") {
                recoveredSessions.play(recovered)
              }
            }
          }
        }
        .accessibilityLabel("Recovered conversation with playable local audio")
      }
      CompactLiveView(store: store)
    }
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
