import SwiftUI

struct CompactLiveView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController

  @MainActor
  init(
    store: RuntimeLibraryStore,
    liveRecording: LiveMicrophoneRecordingController
  ) {
    self.store = store
    self.liveRecording = liveRecording
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
        Text(statusText)
          .font(.title2.weight(.semibold))
        Spacer()
        if let current = store.currentSession {
          Text(current.timerText)
            .font(.title3.monospacedDigit())
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityStatus)

      if let current = store.currentSession {
        Text(current.title)
          .font(.headline)
          .textSelection(.enabled)

        VStack(alignment: .leading, spacing: 10) {
          Text("Sources")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          ForEach(current.sources, id: \.kind) { source in
            HStack(spacing: 10) {
              Image(systemName: source.symbolName)
                .frame(width: 18)
              Text(source.name)
              Spacer()
              Text(source.stateText)
                .foregroundStyle(source.lifecycle == "failed" ? .orange : .secondary)
            }
            .accessibilityElement(children: .combine)
          }
        }

        if let interruption = current.interruptionText {
          Label(interruption, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .accessibilityLabel("Recording needs attention. \(interruption)")
        }

        if current.isRecording {
          Label("Audio is being saved locally as you record.", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        RecorderEventList(events: liveRecording.recorderDetail?.events ?? [])
      } else {
        Text(
          "Start deliberately from this window or the menu bar. Open Scribe will show Recording only after both required sources are durably active."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

    }
    .padding(24)
    .frame(minWidth: 500, minHeight: 430, alignment: .topLeading)
    .onAppear {
      AppTelemetry.runtimeSceneAppeared("live-session", session: store.currentSession)
    }
  }

  private var statusText: String {
    if let current = store.currentSession { return current.statusText }
    return switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
    case .saved: liveRecording.statusText
    case .failed: "Recording needs attention"
    default: "Ready to record"
    }
  }

  private var statusSymbol: String {
    if store.currentSession?.isRecording == true { return "record.circle.fill" }
    if store.currentSession?.needsAttention == true || liveRecording.phase == .failed {
      return "exclamationmark.circle"
    }
    if liveRecording.phase == .starting || liveRecording.phase == .preparing {
      return "waveform"
    }
    return "record.circle"
  }

  private var statusColor: Color {
    if store.currentSession?.isRecording == true { return .red }
    if store.currentSession?.needsAttention == true || liveRecording.phase == .failed {
      return .orange
    }
    return .secondary
  }

  private var accessibilityStatus: String {
    guard let current = store.currentSession else { return statusText }
    let sources = current.sources.map { "\($0.name): \($0.stateText)" }.joined(separator: ", ")
    return "\(current.statusText), \(current.timerText). \(sources)."
  }
}
