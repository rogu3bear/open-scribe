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
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.standard) {
        Image(systemName: statusSymbol)
          .foregroundStyle(statusColor)
        Text(statusText)
          .font(.title.weight(.semibold))
        if let current = store.currentSession {
          Text(current.timerText)
            .font(.title.monospacedDigit().weight(.semibold))
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityStatus)

      if let current = store.currentSession {
        Text(ConversationIdentityPresentation.title(current.title))
          .font(.headline)
          .textSelection(.enabled)

        VStack(alignment: .leading, spacing: ScribeSpacing.related) {
          Text("Sources")
            .scribeSectionHeading()
          ForEach(current.sources, id: \.kind) { source in
            HStack(spacing: ScribeSpacing.related) {
              Image(systemName: source.symbolName)
                .frame(width: 18)
              Text(source.name)
              Spacer()
              Text(source.stateText)
                .foregroundStyle(source.lifecycle == "failed" ? .primary : .secondary)
                .fontWeight(source.lifecycle == "failed" ? .semibold : nil)
            }
            .accessibilityElement(children: .combine)
          }
        }

        if let interruption = current.interruptionText {
          CaptureIssueLabel(message: interruption)
            .font(.callout)
            .accessibilityLabel("Capture needs attention. \(interruption)")
        }

        StorageNoticeMount(notice: storagePressureNotice)
          .frame(
            maxWidth: .infinity,
            minHeight: Self.storageNoticeHeight(storagePressureNotice),
            alignment: .topLeading)

        if liveRecording.contextBinding != nil {
          ContextInspector(model: context)
        }

        let events = liveRecording.recorderDetail?.events ?? []
        LiveMarkerListMount(events: events)
          .frame(
            maxWidth: .infinity,
            minHeight: Self.markerListHeight(events),
            alignment: .topLeading)
        let details = events.filter { $0.kind != "marker_added" }
        if !details.isEmpty {
          DisclosureGroup("Recording events") {
            ScrollView {
              RecorderEventList(events: details, heading: "Events")
            }
            .frame(maxHeight: 180)
          }
        }
      } else {
        Text(
          "Start deliberately from this window or the menu bar. Open Scribe will show Recording only after both required sources are durably active."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

    }
    .frame(maxWidth: 760, alignment: .leading)
    .padding(ScribeSpacing.section)
    .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
    .onAppear {
      AppTelemetry.runtimeSceneAppeared("live-session", session: store.currentSession)
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
