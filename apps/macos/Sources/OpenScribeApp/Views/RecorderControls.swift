import SwiftUI

struct RecorderControls: View {
  @ObservedObject var recorder: LiveMicrophoneRecordingController
  @ObservedObject var store: RuntimeLibraryStore
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
    Button("Sources", systemImage: "slider.horizontal.3") { showsSources = true }
      .disabled(!(recorder.canStart || recorder.canResume))
      .help("Pause before changing sources. Microphone audio is included.")
      .popover(isPresented: $showsSources) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Recording sources").font(.headline)
          Text("Microphone + \(recorder.captureSelection.name)")
          Button("Microphone only") { select(.microphoneOnly) }
          Button("Microphone + all computer audio") { select(.system) }
          Button("Choose an application…") {
            picker.onSelection = { selection in select(selection) }
            Task { await picker.choose() }
          }
          ForEach(picker.applications, id: \.processID) { application in
            Button(application.applicationName) { Task { await picker.select(application) } }
          }
          if let error = picker.errorMessage { Text(error).foregroundStyle(.orange) }
          Text("Application selection limits computer audio to the chosen app. Changes take effect when you explicitly record or resume.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 340)
      }
  }

  private func select(_ selection: RecorderCaptureSelection) {
    recorder.selectCaptureSource(selection)
    store.refresh()
    showsSources = false
  }
}

struct RecorderEventList: View {
  let events: [NativeRecorderEvent]
  var body: some View {
    if !events.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Markers and recording events").font(.headline)
        ForEach(events, id: \.id) { event in
          HStack(alignment: .firstTextBaseline) {
            Text(String(format: "%02d:%02d", max(0, event.sessionNanoseconds / 1_000_000_000) / 60, max(0, event.sessionNanoseconds / 1_000_000_000) % 60))
              .monospacedDigit().foregroundStyle(.secondary)
            Text(title(event))
          }
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
    default: event.kind
    }
  }
}
