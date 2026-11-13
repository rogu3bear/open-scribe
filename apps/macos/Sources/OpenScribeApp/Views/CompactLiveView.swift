import AppKit
import SwiftUI

struct CompactLiveView: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var context: ContextScopeModel

  @MainActor
  init(
    store: RuntimeLibraryStore,
    liveRecording: LiveMicrophoneRecordingController,
    context: ContextScopeModel? = nil
  ) {
    self.store = store
    self.liveRecording = liveRecording
    self.context = context ?? ContextScopeModel(binding: { nil })
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        InterviewColumn {
          VStack(alignment: .leading, spacing: 0) {
            statusLine
              .padding(.top, 34)
            if let current = store.currentSession {
              Text(liveTitle(current))
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
              notices(current)
                .padding(.top, 14)
              let events = liveRecording.recorderDetail?.events ?? []
              LiveMarkerListMount(events: events)
                .frame(
                  maxWidth: .infinity,
                  minHeight: Self.markerListHeight(events),
                  alignment: .topLeading)
                .padding(.top, events.contains { $0.kind == "marker_added" } ? 16 : 0)
              InterviewRule()
                .padding(.top, 22)
                .padding(.bottom, 20)
              LiveTranscriptColumn(captions: liveRecording.liveCaptions)
              Color.clear.frame(height: 1).id("live-end")
              recordingDetails(events: events)
                .padding(.top, 40)
            } else {
              Text(
                "Start deliberately from this window or the menu bar. Open Scribe will show Recording only after both required sources are durably active."
              )
              .font(Interview.speech())
              .foregroundStyle(Interview.quiet)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 14)
            }
          }
          .padding(.leading, Interview.shoulder)
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
    .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
    .onAppear {
      AppTelemetry.runtimeSceneAppeared("live-session", session: store.currentSession)
    }
  }

  @State private var followsLive = true
  @State private var copyNote: String?

  /// "● Recording  12:04", the word and the timer always together.
  private var statusLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: statusSymbol)
        .foregroundStyle(statusColor)
      Text(statusText)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(store.currentSession?.isRecording == true ? Interview.ink : Interview.quiet)
      if let current = store.currentSession {
        Text(current.timerText)
          .font(.system(size: 13, weight: .medium).monospacedDigit())
          .foregroundStyle(Interview.quiet)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityStatus)
  }

  private func liveTitle(_ current: RuntimeSessionPresentation) -> String {
    ConversationIdentityPresentation.title(for: current)
  }

  private func facts(_ current: RuntimeSessionPresentation) -> [String] {
    current.sources.map { source in
      source.lifecycle == "capturing" ? source.name : "\(source.name): \(source.stateText)"
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
      .disabled(liveRecording.liveCaptions.lines.isEmpty)
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

  @ViewBuilder private func notices(_ current: RuntimeSessionPresentation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let interruption = current.interruptionText {
        CaptureIssueLabel(message: interruption)
          .font(Interview.meta)
          .accessibilityLabel("Capture needs attention. \(interruption)")
      }
      StorageNoticeMount(notice: storagePressureNotice)
        .frame(
          maxWidth: .infinity,
          minHeight: Self.storageNoticeHeight(storagePressureNotice),
          alignment: .topLeading)
      LiveCaptionStatusNotice(captions: liveRecording.liveCaptions)
      if liveRecording.contextBinding != nil {
        ContextInspector(model: context)
      }
    }
  }

  @ViewBuilder private func recordingDetails(events: [NativeRecorderEvent]) -> some View {
    let details = events.filter { $0.kind != "marker_added" }
    if !details.isEmpty {
      DisclosureGroup("Recording journal") {
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
    let lines = liveRecording.liveCaptions.lines
    guard !lines.isEmpty, let current = store.currentSession else { return }
    let text = LiveTranscriptColumn.clipboardText(
      title: liveTitle(current), timer: current.timerText, lines: lines)
    ConversationClipboard.copy(text)
    AccessibilityAnnouncer.post("Copied the live transcript so far")
    copyNote = "Copied"
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      copyNote = nil
    }
  }

  private var statusText: String {
    if liveRecording.phase == .requestingPermission { return liveRecording.statusText }
    if let current = store.currentSession { return current.statusText }
    return switch liveRecording.phase {
    case .requestingPermission, .preparing, .starting: liveRecording.statusText
    case .capturing: "Confirming durable recording…"
    case .stopping: "Securing recording…"
    case .saved: liveRecording.statusText
    case .failed: liveRecording.statusText
    default: "Ready to record"
    }
  }

  var statusSymbol: String {
    if store.currentSession?.isRecording == true { return "record.circle.fill" }
    if store.currentSession?.needsAttention == true || liveRecording.phase == .failed {
      return "exclamationmark.circle"
    }
    if let paused = store.currentSession?.pausedStatusSymbolName { return paused }
    if store.currentSession == nil,
      liveRecording.phase == .pausing || liveRecording.phase == .paused
    {
      return SymbolResolver.pausedCaptureSymbolName
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

  /// The storage notice is created with the live session. Its height grows only
  /// while Rust reports a warning, so a normal recording does not reserve a row.
  private static func storageNoticeHeight(_ notice: String?) -> CGFloat {
    notice == nil ? 0 : 48
  }

  /// The marker list is created with the live session. Its height grows only
  /// when a marker has been saved, so an empty recording does not reserve a row.
  private static func markerListHeight(_ events: [NativeRecorderEvent]) -> CGFloat {
    let count = events.filter { $0.kind == "marker_added" }.count
    return count == 0 ? 0 : CGFloat(24 + count * 28)
  }

  /// The same notice the live surface shows while Rust reports storage warning.
  var storagePressureNotice: String? { liveRecording.storagePressureNotice }

  var accessibilityStatus: String {
    let base: String
    if liveRecording.phase == .requestingPermission {
      base = statusText
    } else if let current = store.currentSession {
      let sources = current.sources.map { "\($0.name): \($0.stateText)" }.joined(separator: ", ")
      base = "\(current.statusText), \(current.timerText). \(sources)."
    } else {
      base = statusText
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

  struct Paragraph: Identifiable {
    let id: String
    let speaker: String
    let start: Int64
    var text: String
  }

  /// For Copy So Far only: settled lines of one voice join into a turn until
  /// a pause of four seconds or about ninety words, as a saved conversation's
  /// Copy does. The screen shows each phrase on its own line.
  static func paragraphs(_ lines: [LiveCaptionLine]) -> [Paragraph] {
    var result: [Paragraph] = []
    var lastEnd: Int64 = 0
    for line in lines where line.isFinal {
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      if var last = result.last, last.speaker == line.speaker,
        line.startNanoseconds - lastEnd < 4_000_000_000,
        last.text.split(separator: " ").count < 90
      {
        last.text += " " + text
        result[result.count - 1] = last
      } else {
        result.append(
          Paragraph(id: line.id, speaker: line.speaker, start: line.startNanoseconds, text: text))
      }
      lastEnd = max(lastEnd, line.endNanoseconds)
    }
    return result
  }

  /// The live transcript as clipboard text, in the same shape as a saved
  /// conversation's Copy.
  static func clipboardText(title: String, timer: String, lines: [LiveCaptionLine]) -> String {
    let body = paragraphs(lines).map { paragraph in
      "\(paragraph.speaker) [\(InterviewTime.stamp(paragraph.start))]: \(paragraph.text)"
    }.joined(separator: "\n\n")
    return "\(title)\nRecording in progress · \(timer)\nLive draft: some words may be misheard.\n\n\(body)\n"
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
      Text(InterviewTime.stamp(line.startNanoseconds))
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
    .padding(.leading, -Interview.shoulder)
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

/// Markers written while capture is open. The control is created with the live
/// session and fills when Add Marker saves one, so the row is an update. It
/// names the stored session time and does not play while the writer holds the file.
private struct LiveMarkerListMount: NSViewRepresentable {
  let events: [NativeRecorderEvent]

  func makeNSView(context: Context) -> LiveMarkerListControl {
    let view = LiveMarkerListControl()
    view.bind(events: events)
    return view
  }

  func updateNSView(_ view: LiveMarkerListControl, context: Context) {
    view.bind(events: events)
  }
}

private final class LiveMarkerListControl: NSView {
  private let heading = NSTextField(labelWithString: "Markers")
  private let column = NSStackView()
  private var signature: [String] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Live markers")
    heading.font = .preferredFont(forTextStyle: .headline)
    heading.setAccessibilityLabel("Markers")
    heading.setAccessibilityIdentifier("Markers")
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.tight
    column.detachesHiddenViews = false
    heading.translatesAutoresizingMaskIntoConstraints = false
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(heading)
    addSubview(column)
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: leadingAnchor),
      heading.topAnchor.constraint(equalTo: topAnchor),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: ScribeSpacing.tight),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    let count = column.arrangedSubviews.count
    let height: CGFloat = isHidden || count == 0 ? 0 : 24 + CGFloat(count) * 28
    return NSSize(width: NSView.noIntrinsicMetric, height: height)
  }

  func bind(events: [NativeRecorderEvent]) {
    let markers = events.filter { $0.kind == "marker_added" }
    let next = markers.map { "\($0.id)\n\($0.label)\n\($0.sessionNanoseconds)" }
    let shown = !markers.isEmpty
    isHidden = !shown
    heading.isHidden = !shown
    column.isHidden = !shown
    guard next != signature else { return }
    signature = next
    for view in column.arrangedSubviews {
      column.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for marker in markers {
      column.addArrangedSubview(row(for: marker))
    }
    invalidateIntrinsicContentSize()
  }

  private func row(for marker: NativeRecorderEvent) -> NSView {
    let stamp = TranscriptSection.timestamp(marker.sessionNanoseconds)
    let spoken = ConversationControlLabels.liveMarkerAccessibility(
      stamp: stamp, label: marker.label)
    let nameText = marker.label.isEmpty ? "Marker" : marker.label
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = ScribeSpacing.related
    row.detachesHiddenViews = false
    let time = NSTextField(labelWithString: stamp)
    time.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    time.setAccessibilityLabel(spoken)
    time.setAccessibilityIdentifier(marker.id)
    time.setAccessibilityRole(.staticText)
    let name = NSTextField(labelWithString: nameText)
    name.font = .preferredFont(forTextStyle: .body)
    name.textColor = .labelColor
    name.setAccessibilityLabel(nameText)
    name.setAccessibilityRole(.staticText)
    for item in [time, name] {
      item.setContentCompressionResistancePriority(.required, for: .horizontal)
      item.setContentCompressionResistancePriority(.required, for: .vertical)
      row.addArrangedSubview(item)
    }
    time.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    time.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
    name.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
    return row
  }
}

/// The low-space sentence on the live surface. The field is created with the
/// recording and fills when the storage watch reports a warning.
private struct StorageNoticeMount: NSViewRepresentable {
  let notice: String?

  func makeNSView(context: Context) -> StorageNoticeControl {
    let view = StorageNoticeControl()
    view.bind(notice: notice)
    return view
  }

  func updateNSView(_ view: StorageNoticeControl, context: Context) {
    view.bind(notice: notice)
  }
}

private final class StorageNoticeControl: NSView {
  private let field = NSTextField(wrappingLabelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Storage notice")
    field.font = .preferredFont(forTextStyle: .callout)
    field.textColor = .labelColor
    field.maximumNumberOfLines = 3
    field.lineBreakMode = .byWordWrapping
    field.preferredMaxLayoutWidth = 640
    field.setAccessibilityIdentifier("Storage notice")
    field.setAccessibilityRole(.staticText)
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor),
      field.topAnchor.constraint(equalTo: topAnchor),
      field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      field.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
    ])
    bind(notice: nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(notice: String?) {
    let text = notice ?? ""
    let shown = !text.isEmpty
    isHidden = !shown
    field.isHidden = !shown
    field.stringValue = shown ? text : ""
    field.setAccessibilityLabel(shown ? text : "Storage notice")
  }
}
