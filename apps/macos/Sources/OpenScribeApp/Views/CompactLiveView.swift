import SwiftUI

struct CompactLiveView: View {
  @ObservedObject var store: FixtureSessionStore

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Deterministic state fixture — no media is captured.", systemImage: "testtube.2")
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        if let symbol = store.snapshot.resolvedSymbolName {
          Image(systemName: symbol)
            .foregroundStyle(statusColor)
        }
        Text(store.snapshot.statusText)
          .font(.title2.weight(.semibold))
        Spacer()
        if let timer = store.displayedTimerText {
          Text(timer)
            .font(.title3.monospacedDigit())
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(store.displayedAccessibilityValue)

      VStack(alignment: .leading, spacing: 10) {
        Text("Sources")
          .font(.headline)
        ForEach(store.snapshot.sources, id: \.id) { source in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(source.name)
              Spacer()
              Text(source.activity.capitalized)
                .foregroundStyle(.secondary)
            }
            if let detail = source.healthDetail {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let recoveryHint = source.permissionRecoveryHint {
              Text(recoveryHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }

      GroupBox("Rust evidence") {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
          EvidenceRow(label: "Lifecycle", value: store.snapshot.lifecycle)
          EvidenceRow(label: "Health", value: store.snapshot.health)
          EvidenceRow(label: "Journal durable", value: yesNo(store.snapshot.journalDurable))
          EvidenceRow(label: "Media-open evidence", value: yesNo(store.snapshot.mediaFilesOpen))
          EvidenceRow(label: "Recovery", value: store.snapshot.recoveryStatus)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
      }

      if let error = store.commandError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityLabel("Command failed: \(error)")
      }

      HStack {
        SessionCommands(store: store)
        Spacer()
        Button("Inspect state") {
          store.inspect()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .accessibilityValue(store.displayedAccessibilityValue)
      }
    }
    .padding(24)
    .frame(minWidth: 460, minHeight: 500, alignment: .topLeading)
    .onAppear {
      AppTelemetry.sceneAppeared("primary", snapshot: store.snapshot)
    }
  }

  private var statusColor: Color {
    if store.snapshot.isWarning { return .orange }
    if store.snapshot.isDurableRecording { return .red }
    return .secondary
  }

  private func yesNo(_ value: Bool) -> String {
    value ? "Yes" : "No"
  }
}

struct SessionCommands: View {
  @ObservedObject var store: FixtureSessionStore

  var body: some View {
    switch store.snapshot.presentation {
    case "idle":
      Button("Prepare fixture") { store.send(.prepare) }
    case "ready":
      Button("Start fixture") { store.send(.requestStart) }
    case "starting":
      Button("Confirm evidence") {
        store.send(.confirmRecording, journalDurable: true, mediaFilesOpen: true)
      }
      Button("Cancel") { store.send(.cancelStart) }
    case "recording", "recording_degraded", "permission_revoked":
      Button("Pause") { store.send(.pause) }
      Button("Finalize fixture") { store.send(.beginFinalizing, mediaSafe: true) }
    case "paused":
      Button("Resume") { store.send(.resume) }
      Button("Finalize fixture") { store.send(.beginFinalizing, mediaSafe: true) }
    case "finalizing":
      Button("Complete fixture") { store.send(.complete) }
    default:
      EmptyView()
    }
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
