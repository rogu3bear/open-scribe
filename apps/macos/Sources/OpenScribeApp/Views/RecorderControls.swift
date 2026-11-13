import AppKit
import SwiftUI

/// Pause, Resume, the microphone choices, and Add Marker for the recording in
/// progress. The toolbar and the menu bar show the same controls.
struct RecorderControls: View {
  @ObservedObject var recorder: LiveMicrophoneRecordingController
  @ObservedObject var store: RuntimeLibraryStore

  var body: some View {
    if recorder.canPause {
      HostedButton(
        title: ConversationControlLabels.pause, identifier: "Pause recording",
        shortcut: ConversationControlLabels.pauseShortcut
      ) {
        Task {
          await recorder.stop(pausing: true)
          store.refresh()
        }
      }
    }
    if recorder.canResume {
      HostedButton(
        title: ConversationControlLabels.resume, identifier: "Resume recording",
        shortcut: ConversationControlLabels.pauseShortcut
      ) {
        Task {
          await recorder.start(resuming: true)
          store.refresh()
        }
      }
    }
    if let microphoneName = recorder.replacementMicrophoneName {
      Button {
        recorder.confirmDifferentMicrophone()
        store.refresh()
      } label: {
        Text("Use \(microphoneName) instead")
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .accessibilityLabel("Use \(microphoneName) instead")
      .help("Use \(microphoneName) instead of the previously selected microphone")
      Button("Keep the selected microphone") {
        recorder.dismissDifferentMicrophone()
        store.refresh()
      }
    } else if recorder.showsReconnect {
      Button("Reconnect microphone") {
        recorder.reconnectMicrophone()
        store.refresh()
      }
    }
    if recorder.canMark {
      HostedButton(
        title: ConversationControlLabels.addMarker, identifier: "Add marker",
        shortcut: ConversationControlLabels.markerShortcut
      ) {
        recorder.addMarker()
        store.refresh()
      }
    }
  }
}

/// Which sources the next recording captures. It is its own control, apart
/// from Record, in the toolbar and in the menu bar.
struct RecorderSourcesControl: View {
  /// A `.menu`-style `MenuBarExtra` never shows a `.popover`, so the menu bar
  /// presents Sources as a native submenu instead. The main window keeps the
  /// popover.
  enum Presentation { case popover, menu }

  @ObservedObject var recorder: LiveMicrophoneRecordingController
  @ObservedObject var store: RuntimeLibraryStore
  var presentation: Presentation = .popover
  @StateObject private var picker = RecorderApplicationPicker()
  @State private var showsSources = false

  var body: some View {
    let sourcesEnabled = recorder.canStart || recorder.canResume
    switch presentation {
    case .popover:
      Button("Sources", systemImage: "slider.horizontal.3") { showsSources = true }
        .disabled(!sourcesEnabled)
        .help(recorder.sourceSelectionPresentation.help)
        .popover(isPresented: $showsSources) {
          VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
            Text("Recording sources").scribeSectionHeading()
            sourceSelectionSummary
            sourceButtons
            if let error = picker.errorMessage {
              CaptureIssueLabel(message: error, isFailure: true)
            }
            Text(
              "Application selection limits computer audio to the chosen app. Changes take effect when you explicitly record or resume."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }.padding(ScribeSpacing.standard).frame(width: 340)
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

struct RecorderEventList: View {
  let events: [NativeRecorderEvent]
  var heading = "Markers and recording events"
  var body: some View {
    if !events.isEmpty {
      LazyVStack(alignment: .leading, spacing: ScribeSpacing.related) {
        Text(heading).scribeSectionHeading()
        ForEach(events, id: \.id) { event in
          HStack(alignment: .firstTextBaseline) {
            Text(
              String(
                format: "%02d:%02d", max(0, event.sessionNanoseconds / 1_000_000_000) / 60,
                max(0, event.sessionNanoseconds / 1_000_000_000) % 60)
            )
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
    case .markerAdded: event.label.isEmpty ? "Marker" : event.label
    case .pauseRequested: "Pausing"
    case .capturePaused: "Paused"
    case .resumeRequested: "Resuming"
    case .captureResumed: "Resumed"
    case .pausedSessionFinalized: "Saved while paused"
    case .sourceScopeSelected: "Selected: \(event.label)"
    case .storageObserved: "Storage: \(event.label)"
    case .sourceFailed: "\(event.label) stopped"
    case .microphoneRestoreRequested: "Reconnect microphone"
    case .microphoneRestoreCancelled: "Microphone reconnect cancelled"
    case .microphoneRetiredUnstarted: "Microphone stopped"
    case .systemSleepObserved: "Mac went to sleep"
    case .systemWakeObserved: "Mac woke"
    }
  }
}
