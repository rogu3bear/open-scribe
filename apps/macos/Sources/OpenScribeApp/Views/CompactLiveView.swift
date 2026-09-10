import SwiftUI

struct CompactLiveView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController

  @MainActor
  init(
    store: RuntimeLibraryStore,
    liveRecording: LiveMicrophoneRecordingController? = nil
  ) {
    self.store = store
    self.liveRecording = liveRecording ?? LiveMicrophoneRecordingController(managedRoot: nil)
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

        GroupBox("Durable state") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            EvidenceRow(label: "Lifecycle", value: current.lifecycle)
            EvidenceRow(label: "Health", value: current.health)
            EvidenceRow(label: "Journal durable", value: yesNo(current.journalDurable))
            EvidenceRow(label: "Media open", value: yesNo(current.mediaFilesOpen))
            EvidenceRow(label: "Recovery", value: current.recoveryText)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(4)
        }
      } else {
        Text(
          "Start deliberately from this window or the menu bar. Open Scribe will show Recording only after both required sources are durably active."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if let error = liveRecording.errorMessage ?? store.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .accessibilityLabel("Recording or library error: \(error)")
      }

      HStack {
        if liveRecording.canStart {
          Button("Record Microphone + System Audio") {
            Task {
              await liveRecording.start()
              store.refresh()
            }
          }
          .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        if liveRecording.canStop {
          Button("Stop and Save") {
            Task {
              await liveRecording.stop()
              store.refresh()
            }
          }
          .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        Spacer()
        Button("Refresh Library") {
          store.refresh()
        }
      }
    }
    .padding(24)
    .frame(minWidth: 500, minHeight: 430, alignment: .topLeading)
    .onAppear {
      store.refresh()
      AppTelemetry.runtimeSceneAppeared("primary", session: store.currentSession)
    }
  }

  private var statusText: String {
    if let current = store.currentSession { return current.statusText }
    return switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
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

  private func yesNo(_ value: Bool) -> String {
    value ? "Yes" : "No"
  }
}

private struct EvidenceRow: View {
  let label: String
  let value: String

  var body: some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value.replacingOccurrences(of: "_", with: " ").capitalized)
        .textSelection(.enabled)
    }
  }
}
