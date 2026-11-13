import AppKit
import SwiftUI

/// The recording in progress: status, title, sources, Copy So Far, the
/// window's notices, markers, and the live interview.
struct CompactLiveView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var context: ContextScopeModel
  /// Copy So Far acts through the window's one action owner; it copies the
  /// Draft windows stored so far.
  let actions: ConversationActions?
  let notices: WindowNotices

  @MainActor
  init(
    store: RuntimeLibraryStore,
    liveRecording: LiveMicrophoneRecordingController,
    context: ContextScopeModel? = nil,
    actions: ConversationActions? = nil,
    notices: WindowNotices = .none
  ) {
    self.store = store
    self.liveRecording = liveRecording
    self.context = context ?? ContextScopeModel(binding: { nil })
    self.actions = actions
    self.notices = notices
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        InterviewColumn {
          VStack(alignment: .leading, spacing: 0) {
            statusLine
              .padding(.top, 34)
            if let current = store.currentSession {
              Text(ConversationIdentityPresentation.title(for: current))
                .font(Interview.title())
                .foregroundStyle(Interview.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
              InterviewFacts(items: facts(current))
                .padding(.top, 8)
              actionRow
                .padding(.top, 16)
              noticeList(current)
                .padding(.top, 14)
              let events = liveRecording.recorderDetail?.events ?? []
              HostedList(
                heading: "Markers", identifier: "Live markers", rows: markerRows(events),
                lead: .stampText)
              InterviewRule()
                .padding(.top, 22)
                .padding(.bottom, 20)
              LiveTranscriptColumn(captions: liveRecording.liveCaptions)
              Color.clear.frame(height: 1).id("live-end")
              recordingDetails(events: events)
                .padding(.top, 40)
            } else {
              WindowNoticeList(notices: notices)
                .padding(.top, 14)
              Text(
                "Press Record to capture your microphone and the other side of the call. The words appear here as people speak."
              )
              .font(Interview.speech())
              .foregroundStyle(Interview.quiet)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 14)
            }
          }
          .padding(.bottom, 64)
        }
      }
      .background(Interview.paper)
      .onReceive(liveRecording.liveCaptions.$lines) { _ in
        guard followsLive else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("live-end", anchor: .bottom) }
      }
      // The words still being heard stay in view too, not only settled ones.
      .onReceive(liveRecording.liveCaptions.$current) { _ in
        guard followsLive else { return }
        proxy.scrollTo("live-end", anchor: .bottom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      AppTelemetry.runtimeSceneAppeared("live-session", session: store.currentSession)
    }
  }

  @State private var followsLive = true
  @State private var copyNote: String?

  private var status: CaptureStatusPresentation {
    CaptureStatusPresentation.current(
      session: store.currentSession, snapshotStale: false, livePhase: liveRecording.phase,
      liveText: liveRecording.statusText)
  }

  /// "● Recording  12:04", the word and the timer always together.
  private var statusLine: some View {
    let status = status
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: status.symbolName)
        .foregroundStyle(status.tint.color)
      Text(status.text)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(status.tint == .recording ? Interview.ink : Interview.quiet)
      if let timer = status.timer {
        Text(timer)
          .font(.system(size: 13, weight: .medium).monospacedDigit())
          .foregroundStyle(Interview.quiet)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityStatus)
  }

  private func facts(_ current: RuntimeSessionPresentation) -> [String] {
    current.sources.map { source in
      source.lifecycle == .capturing ? source.name : "\(source.name): \(source.stateText)"
    }
  }

  private var actionRow: some View {
    HStack(spacing: 12) {
      Button {
        copySoFar()
      } label: {
        Label("Copy So Far", systemImage: "doc.on.doc")
      }
      .controlSize(.large)
      .disabled(actions == nil || liveRecording.liveCaptions.lines.isEmpty)
      .help("Copy the live transcript so far")
      Toggle("Follow", isOn: $followsLive)
        .toggleStyle(.checkbox)
        .font(Interview.meta)
        .foregroundStyle(Interview.quiet)
        .help("Keep the newest words in view")
      if let copyNote {
        Label(copyNote, systemImage: "checkmark")
          .font(Interview.meta)
          .foregroundStyle(Interview.quiet)
          .accessibilityHidden(true)
      }
      Spacer()
    }
  }

  /// The window's notices, then the recording's own: interruption, storage,
  /// live transcript status and context.
  private func noticeList(_ current: RuntimeSessionPresentation) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      WindowNoticeList(notices: notices)
      if let interruption = current.interruptionText {
        CaptureIssueLabel(message: interruption)
          .font(Interview.meta)
          .accessibilityLabel("Needs attention. \(interruption)")
          .padding(.bottom, 10)
      }
      HostedText(
        text: storagePressureNotice, identifier: "Storage notice",
        font: .preferredFont(forTextStyle: .callout), maximumLines: 3)
      .padding(.bottom, storagePressureNotice == nil ? 0 : 10)
      LiveCaptionStatusNotice(captions: liveRecording.liveCaptions)
      if liveRecording.contextBinding != nil {
        ContextInspector(model: context)
          .padding(.top, 10)
      }
    }
  }

  /// Markers written while capture is open. Each names the stored session
  /// time and does not play while the writer holds the file.
  private func markerRows(_ events: [NativeRecorderEvent]) -> [HostedListRow] {
    events.filter { $0.kind == .markerAdded }.map { marker in
      let stamp = TranscriptSection.timestamp(marker.sessionNanoseconds)
      return HostedListRow(
        id: marker.id, lead: stamp, detail: marker.label.isEmpty ? "Marker" : marker.label,
        label: ConversationControlLabels.liveMarkerAccessibility(stamp: stamp, label: marker.label))
    }
  }

  @ViewBuilder private func recordingDetails(events: [NativeRecorderEvent]) -> some View {
    let details = events.filter { $0.kind != .markerAdded }
    if !details.isEmpty {
      DisclosureGroup("Recording events") {
        ScrollView {
          RecorderEventList(events: details, heading: "Events")
        }
        .frame(maxHeight: 180)
      }
      .font(Interview.meta)
      .foregroundStyle(Interview.quiet)
    }
  }

  private func copySoFar() {
    guard let actions, let current = store.currentSession else { return }
    Task {
      guard let note = await actions.copy(current) else { return }
      copyNote = note
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      if copyNote == note { copyNote = nil }
    }
  }

  var statusSymbol: String { status.symbolName }

  /// The same notice the live surface shows while Rust reports storage warning.
  var storagePressureNotice: String? { liveRecording.storagePressureNotice }

  var accessibilityStatus: String {
    var base = status.accessibilityText
    if liveRecording.phase != .requestingPermission, let current = store.currentSession {
      let sources = current.sources.map { "\($0.name): \($0.stateText)" }.joined(separator: ", ")
      base += ". \(sources)."
    }
    guard let storagePressureNotice else { return base }
    return "\(base) \(storagePressureNotice)"
  }
}

/// The words of the recording in progress, as an interview: each settled
/// phrase on its own line in ink, with the speaker's name where the voice
/// changes, and the phrase still being heard in quiet ink beneath them.
/// Phrases are shown as they settle and never merged on screen. Nothing here
/// waits for the recognizer; capture never depends on it.
struct LiveTranscriptColumn: View {
  @ObservedObject var captions: LiveCaptionModel

  var body: some View {
    let settled = captions.lines.filter(\.isFinal)
    let current = [captions.current[.microphone], captions.current[.computer]].compactMap { $0 }
      .sorted { $0.startNanoseconds < $1.startNanoseconds }
    VStack(alignment: .leading, spacing: 0) {
      if settled.isEmpty, current.isEmpty {
        Text(emptyText)
          .font(Interview.speech())
          .foregroundStyle(Interview.quiet)
          .fixedSize(horizontal: false, vertical: true)
      }
      // Settled lines redraw only when one is added, not with every word.
      SettledLiveLines(lines: settled).equatable()
      ForEach(Array(current.enumerated()), id: \.element.id) { index, line in
        LiveLineRow(
          line: line,
          startsTurn: (index == 0 ? settled.last?.speaker : current[index - 1].speaker)
            != line.speaker)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Live transcript")
  }

  private var emptyText: String {
    switch captions.status {
    case .listening: "Listening. Words appear here as people speak."
    case .off: "The live transcript is off. The recording is saved and transcribed when you stop."
    case .unavailable: "The recording is saved and transcribed when you stop."
    case .idle: "Words appear here as people speak."
    }
  }
}

/// The settled live lines, one row per phrase in time order.
private struct SettledLiveLines: View, Equatable {
  let lines: [LiveCaptionLine]

  var body: some View {
    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
      LiveLineRow(line: line, startsTurn: index == 0 || lines[index - 1].speaker != line.speaker)
    }
  }
}

/// One live phrase: its time, the speaker's name where the voice changes,
/// and the words, in ink once settled and quiet ink while still heard.
private struct LiveLineRow: View {
  let line: LiveCaptionLine
  let startsTurn: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Text(transcriptClock(nanoseconds: line.startNanoseconds))
        .font(Interview.stamp)
        .foregroundStyle(Interview.quiet)
        .frame(width: Interview.shoulder - 12, alignment: .trailing)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .accessibilityHidden(true)
      Text(attributed)
        .lineSpacing(Interview.speechLineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Interview.measure, alignment: .leading)
        .accessibilityLabel(
          "\(line.speaker): \(line.text)\(line.isFinal ? "" : ". Still listening.")")
      Spacer(minLength: 0)
    }
    .interviewMargins()
    .padding(.top, startsTurn ? Interview.turnSpacing : 6)
  }

  private var attributed: AttributedString {
    var result = AttributedString()
    if startsTurn {
      var name = AttributedString(line.speaker.uppercased() + "  ")
      name.font = .system(size: 12, weight: .bold)
      name.foregroundColor = Interview.ink
      name.kern = 0.6
      result += name
    }
    var body = AttributedString(line.text)
    body.font = Interview.speech()
    body.foregroundColor = line.isFinal ? Interview.ink : Interview.quiet
    result += body
    return result
  }
}

/// Why the live transcript is not running, with the one action that helps.
struct LiveCaptionStatusNotice: View {
  @ObservedObject var captions: LiveCaptionModel

  var body: some View {
    switch captions.status {
    case .unavailable(let reason):
      InterviewNotice(message: reason)
    case .off:
      InterviewNotice(
        message: "The live transcript is off.",
        actions: [("Turn On for Next Recording", { captions.isEnabled = true })])
    case .idle, .listening:
      EmptyView()
    }
  }
}
