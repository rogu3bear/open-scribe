import SwiftUI

struct RecorderControls: View {
  /// A `.menu`-style `MenuBarExtra` never shows a `.popover`, so the menu bar
  /// presents Sources as a native submenu instead. The main window keeps the
  /// popover.
  enum SourcesPresentation { case popover, menu }

  @ObservedObject var recorder: LiveMicrophoneRecordingController
  @ObservedObject var store: RuntimeLibraryStore
  var sourcesPresentation: SourcesPresentation = .popover
  @StateObject private var picker = RecorderApplicationPicker()
  @State private var showsSources = false

  var body: some View {
    if recorder.canPause {
      Button("Pause", systemImage: "pause.fill") {
        Task { await recorder.stop(pausing: true); store.refresh() }
      }.keyboardShortcut("p", modifiers: [.command, .shift])
    }
    if recorder.canResume {
      Button("Resume", systemImage: "play.fill") {
        Task { await recorder.start(resuming: true); store.refresh() }
      }.keyboardShortcut("p", modifiers: [.command, .shift])
    }
    if recorder.canMark {
      Button("Add Marker", systemImage: "bookmark") { recorder.addMarker(); store.refresh() }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }
    let sourcesEnabled = recorder.canStart || recorder.canResume
    switch sourcesPresentation {
    case .popover:
      Button("Sources", systemImage: "slider.horizontal.3") { showsSources = true }
        .disabled(!sourcesEnabled)
        .help(recorder.sourceSelectionPresentation.help)
        .popover(isPresented: $showsSources) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Recording sources").font(.headline)
              .accessibilityAddTraits(.isHeader)
            sourceSelectionSummary
            sourceButtons
            if let error = picker.errorMessage { CaptureIssueLabel(message: error, isFailure: true) }
            Text("Application selection limits computer audio to the chosen app. Changes take effect when you explicitly record or resume.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }.padding(16).frame(width: 340)
        }
    case .menu:
      Menu("Sources", systemImage: "slider.horizontal.3") {
        sourceSelectionSummary
        sourceButtons
        if let error = picker.errorMessage { CaptureIssueLabel(message: error, isFailure: true) }
      }
      .disabled(!sourcesEnabled)
      .help(recorder.sourceSelectionPresentation.help)
    }
  }

  @ViewBuilder private var sourceSelectionSummary: some View {
    Text(recorder.sourceSelectionPresentation.summary)
      .fixedSize(horizontal: false, vertical: true)
    if let notice = recorder.sourceSelectionPresentation.unavailableNotice {
      Text(notice)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var sourceButtons: some View {
    Button("Microphone only") { select(.microphoneOnly) }
      .disabled(recorder.isMicrophoneRetired)
    Button(recorder.sourceSelectionPresentation.systemAudioOptionTitle) { select(.system) }
    Button("Choose an application…") {
      picker.onSelection = { selection in select(selection) }
      Task { await picker.choose() }
    }
    ForEach(picker.applications, id: \.processID) { application in
      Button(application.applicationName) { Task { await picker.select(application) } }
    }
  }

  private func select(_ selection: RecorderCaptureSelection) {
    recorder.selectCaptureSource(selection)
    store.refresh()
    showsSources = false
  }
}

/// Status color stays on the glyph; body text uses the native readable foreground.
struct CaptureIssueLabel: View {
  let message: String
  var isFailure = false

  var body: some View {
    Label {
      Text(message)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: isFailure ? "exclamationmark.circle" : "exclamationmark.triangle")
        .foregroundStyle(isFailure ? Color.red : Color.orange)
    }
    .accessibilityElement(children: .combine)
  }
}

struct RecorderEventList: View {
  let events: [NativeRecorderEvent]
  var heading = "Markers and recording events"
  var body: some View {
    if !events.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(heading).font(.headline)
          .accessibilityAddTraits(.isHeader)
        ForEach(events, id: \.id) { event in
          HStack(alignment: .firstTextBaseline) {
            Text(String(format: "%02d:%02d", max(0, event.sessionNanoseconds / 1_000_000_000) / 60, max(0, event.sessionNanoseconds / 1_000_000_000) % 60))
              .monospacedDigit().foregroundStyle(.secondary)
            Text(title(event))
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
  private func title(_ event: NativeRecorderEvent) -> String {
    switch event.kind {
    case "marker_added": event.label.isEmpty ? "Marker" : event.label
    case "capture_paused": "Paused"
    case "capture_resumed": "Resumed"
    case "source_scope_selected": "Selected: \(event.label)"
    case "storage_observed": "Storage: \(event.label)"
    case "source_failed": "\(event.label) stopped"
    case "system_sleep_observed": "Mac went to sleep"
    case "system_wake_observed": "Mac woke"
    default: event.kind
    }
  }
}
