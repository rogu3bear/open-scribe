import SwiftUI

struct ContentView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
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
      CompactLiveView(store: store, liveRecording: liveRecording)
      if !store.savedSessions.isEmpty {
        GroupBox(store.isSnapshotStale ? "Conversation library (last known)" : "Conversation library") {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(store.savedSessions) { session in
              HStack(alignment: .firstTextBaseline) {
                Image(
                  systemName: session.recovered
                    ? "arrow.clockwise.circle" : "waveform.badge.checkmark"
                )
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                  Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                  Text("\(session.timerText) · \(session.sources.count) source tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.recovered ? "Recovered" : "Saved")
                  .font(.caption.weight(.medium))
                  .foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
      }
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
