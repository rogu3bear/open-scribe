import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The transcript Find control. Command-F is the button's key equivalent, so
/// the search field is the only other control and does not own the shortcut.
private struct FindShortcutMount: NSViewRepresentable {
  let onFind: () -> Void

  func makeNSView(context: Context) -> FindShortcutControl {
    let view = FindShortcutControl()
    view.bind(onFind: onFind)
    return view
  }

  func updateNSView(_ view: FindShortcutControl, context: Context) {
    view.bind(onFind: onFind)
  }
}

private final class FindShortcutControl: NSView {
  private let button: NSButton
  private var onFind: (() -> Void)?

  init() {
    let button = NSButton(title: "", target: nil, action: nil)
    self.button = button
    super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    let label = ConversationControlLabels.findInTranscript
    let shortcut = ConversationControlLabels.findShortcut
    button.isBordered = false
    button.bezelStyle = .smallSquare
    button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: label)
    button.imagePosition = .imageOnly
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier("Find in transcript")
    button.keyEquivalent = String(shortcut.key.character)
    button.keyEquivalentModifierMask = Self.modifierMask(shortcut.modifiers)
    button.target = self
    button.action = #selector(activate)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(onFind: @escaping () -> Void) {
    self.onFind = onFind
    button.isEnabled = true
  }

  @objc private func activate() {
    guard button.isEnabled else { return }
    onFind?()
  }

  private static func modifierMask(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { mask.insert(.command) }
    if modifiers.contains(.shift) { mask.insert(.shift) }
    if modifiers.contains(.option) { mask.insert(.option) }
    if modifiers.contains(.control) { mask.insert(.control) }
    return mask
  }
}

/// The clear control stays in the tree. A hosted window can reveal it when a
/// query exists without inserting a new SwiftUI view.
private struct TranscriptFindClearMount: NSViewRepresentable {
  let visible: Bool
  let onClear: () -> Void

  func makeNSView(context: Context) -> TranscriptFindClearControl {
    let view = TranscriptFindClearControl()
    view.bind(visible: visible, onClear: onClear)
    return view
  }

  func updateNSView(_ view: TranscriptFindClearControl, context: Context) {
    view.bind(visible: visible, onClear: onClear)
  }
}

private final class TranscriptFindClearControl: NSView {
  private let button: NSButton
  private var onClear: (() -> Void)?

  override init(frame frameRect: NSRect) {
    let button = NSButton(title: "", target: nil, action: nil)
    self.button = button
    super.init(frame: frameRect)
    let label = ConversationControlLabels.clearTranscriptSearch
    button.isBordered = false
    button.bezelStyle = .smallSquare
    button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: label)
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier(label)
    button.target = self
    button.action = #selector(clear)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func bind(visible: Bool, onClear: @escaping () -> Void) {
    self.onClear = onClear
    button.isHidden = !visible
    button.isEnabled = visible
  }

  @objc private func clear() {
    guard !button.isHidden, button.isEnabled else { return }
    onClear?()
  }
}

/// The prior machine reading stays in the passage. Opening it reveals the
/// stored words without inserting a new SwiftUI view.
private struct MachineReadingMount: NSViewRepresentable {
  let available: Bool
  let verbatim: String

  func makeNSView(context: Context) -> MachineReadingControl {
    let view = MachineReadingControl()
    view.bind(available: available, verbatim: verbatim)
    return view
  }

  func updateNSView(_ view: MachineReadingControl, context: Context) {
    view.bind(available: available, verbatim: verbatim)
  }
}

private final class MachineReadingControl: NSView {
  private let button = NSButton(title: "Corrected · Show machine reading", target: nil, action: nil)
  private let reading = NSTextField(wrappingLabelWithString: "")
  private var expanded = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    button.contentTintColor = .secondaryLabelColor
    button.alignment = .left
    button.setAccessibilityLabel("Corrected · Show machine reading")
    button.setAccessibilityIdentifier("Corrected · Show machine reading")
    button.target = self
    button.action = #selector(toggle)
    reading.font = .preferredFont(forTextStyle: .caption1)
    reading.textColor = .secondaryLabelColor
    reading.maximumNumberOfLines = 4
    reading.preferredMaxLayoutWidth = 420
    reading.setAccessibilityLabel("Machine reading")
    reading.setAccessibilityIdentifier("Machine reading")
    reading.setContentCompressionResistancePriority(.required, for: .vertical)
    let column = NSStackView(views: [button, reading])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.tight
    column.detachesHiddenViews = false
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    let readingHeight = reading.heightAnchor.constraint(greaterThanOrEqualToConstant: 16)
    readingHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(equalTo: trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
      readingHeight,
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    if bounds.width > 1 {
      reading.preferredMaxLayoutWidth = bounds.width
    }
  }

  func bind(available: Bool, verbatim: String) {
    if !available { expanded = false }
    reading.stringValue = verbatim
    button.isHidden = !available
    button.isEnabled = available
    reading.isHidden = !available || !expanded
    isHidden = !available
    button.setAccessibilityValue(expanded ? "expanded" : "collapsed")
  }

  @objc private func toggle() {
    guard !button.isHidden, button.isEnabled else { return }
    expanded.toggle()
    reading.isHidden = !expanded
    button.setAccessibilityValue(expanded ? "expanded" : "collapsed")
  }
}

/// The transcript query. The field publishes its own edits; a SwiftUI binding
/// does not see the field editor.
private struct TranscriptFindFieldMount: NSViewRepresentable {
  var query: String
  var focused: Bool
  var clearGeneration: Int
  var onQuery: (String) -> Void

  func makeNSView(context: Context) -> TranscriptFindField {
    let field = TranscriptFindField()
    field.onQuery = onQuery
    field.clearGeneration = clearGeneration
    field.apply(query: query)
    field.activate()
    return field
  }

  func updateNSView(_ field: TranscriptFindField, context: Context) {
    field.onQuery = onQuery
    if field.clearGeneration != clearGeneration {
      field.clearGeneration = clearGeneration
      field.apply(query: query)
    } else if field.currentEditor() == nil {
      field.apply(query: query)
    }
    guard focused, let window = field.window else { return }
    if window.firstResponder !== field && window.firstResponder !== field.currentEditor() {
      window.makeFirstResponder(field)
    }
  }
}

private final class TranscriptFindField: NSTextField, NSTextFieldDelegate {
  var onQuery: ((String) -> Void)?
  var clearGeneration = 0
  private var ready = false
  private var delivering = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    isBezeled = false
    drawsBackground = false
    focusRingType = .none
    font = .preferredFont(forTextStyle: .body)
    placeholderString = ConversationControlLabels.findInTranscript
    setAccessibilityLabel(ConversationControlLabels.findInTranscript)
    delegate = self
    if let cell = cell as? NSTextFieldCell {
      cell.isScrollable = true
      cell.wraps = false
      cell.lineBreakMode = .byClipping
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  /// `super.init` may assign an empty string. Delivery starts only after the
  /// mount has stored `onQuery`.
  func activate() {
    ready = true
  }

  override var stringValue: String {
    get { super.stringValue }
    set {
      super.stringValue = newValue
      guard ready, !delivering else { return }
      deliver()
    }
  }

  func apply(query: String) {
    guard stringValue != query else { return }
    delivering = true
    stringValue = query
    delivering = false
  }

  override func textDidChange(_ notification: Notification) {
    super.textDidChange(notification)
    guard ready, !delivering else { return }
    deliver()
  }

  func controlTextDidChange(_ notification: Notification) {
    guard ready, !delivering else { return }
    deliver()
  }

  private func deliver() {
    let text = stringValue
    let onQuery = onQuery
    // SwiftUI drops a published query change made inside the field setter.
    DispatchQueue.main.async {
      onQuery?(text)
    }
  }
}

private struct TranscriptSearchCountMount: NSViewRepresentable {
  var text: String

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .preferredFont(forTextStyle: .caption1)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 2
    field.setAccessibilityLabel("Transcript search count")
    field.setAccessibilityIdentifier("Transcript search count")
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    field.stringValue = text
    field.isHidden = text.isEmpty
  }
}

/// The sentence shown when the current person or query has no passages.
/// It stays in the tree so a hosted window can reveal it without inserting a view.
private struct TranscriptReadingEmptyMount: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .preferredFont(forTextStyle: .callout)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 3
    field.setAccessibilityLabel("Transcript reading")
    field.setAccessibilityIdentifier("Transcript reading")
    field.isHidden = text.isEmpty
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    field.stringValue = text
    field.isHidden = text.isEmpty
  }
}

private typealias TranscriptPersonFilter = TranscriptReadingPerson

/// The person menu. It is created with the reader so a hosted window can
/// narrow the reading without a second SwiftUI control.
private struct TranscriptPersonFilterMount: NSViewRepresentable {
  let selection: TranscriptPersonFilter
  let people: [NativeNamedTranscriptSpeaker]
  let onSelect: (TranscriptPersonFilter) -> Void

  func makeNSView(context: Context) -> TranscriptPersonFilterControl {
    let view = TranscriptPersonFilterControl()
    view.bind(selection: selection, people: people, onSelect: onSelect)
    return view
  }

  func updateNSView(_ view: TranscriptPersonFilterControl, context: Context) {
    view.bind(selection: selection, people: people, onSelect: onSelect)
  }
}

private final class TranscriptPersonFilterControl: NSView {
  private let popup = NSPopUpButton()
  private var onSelect: ((TranscriptPersonFilter) -> Void)?
  private var selection = TranscriptPersonFilter.all
  private var signature = ""

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    popup.target = self
    popup.action = #selector(choose)
    popup.setAccessibilityLabel(ConversationControlLabels.filterByPerson)
    popup.setAccessibilityIdentifier(ConversationControlLabels.filterByPerson)
    popup.translatesAutoresizingMaskIntoConstraints = false
    addSubview(popup)
    NSLayoutConstraint.activate([
      popup.leadingAnchor.constraint(equalTo: leadingAnchor),
      popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      popup.topAnchor.constraint(equalTo: topAnchor),
      popup.bottomAnchor.constraint(equalTo: bottomAnchor),
      popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 24)
  }

  func bind(
    selection: TranscriptPersonFilter, people: [NativeNamedTranscriptSpeaker],
    onSelect: @escaping (TranscriptPersonFilter) -> Void
  ) {
    self.onSelect = onSelect
    let nextSignature = people.map { "\($0.id)\n\($0.label)\n\($0.selectedTurns)" }.joined(
      separator: "\u{1e}")
    if nextSignature != signature {
      signature = nextSignature
      popup.removeAllItems()
      addItem(title: "All speakers", token: "all")
      addItem(title: "Unassigned passages", token: "unassigned")
      for person in people {
        addItem(
          title: "\(person.label) · \(person.selectedTurns) passages",
          token: "person:\(person.id)")
      }
    }
    self.selection = selection
    let token = Self.token(selection)
    if let index = (0..<popup.numberOfItems).first(where: {
      popup.item(at: $0)?.representedObject as? String == token
    }), popup.indexOfSelectedItem != index {
      popup.selectItem(at: index)
    }
    popup.setAccessibilityValue(popup.titleOfSelectedItem)
  }

  @objc private func choose() {
    guard let token = popup.selectedItem?.representedObject as? String,
      let next = Self.filter(token), next != selection
    else { return }
    selection = next
    popup.setAccessibilityValue(popup.titleOfSelectedItem)
    onSelect?(next)
  }

  private func addItem(title: String, token: String) {
    popup.addItem(withTitle: title)
    popup.lastItem?.representedObject = token
  }

  private static func token(_ filter: TranscriptPersonFilter) -> String {
    switch filter {
    case .all: "all"
    case .unassigned: "unassigned"
    case .person(let id): "person:\(id)"
    }
  }

  private static func filter(_ token: String) -> TranscriptPersonFilter? {
    switch token {
    case "all": return .all
    case "unassigned": return .unassigned
    default:
      guard token.hasPrefix("person:") else { return nil }
      let id = String(token.dropFirst("person:".count))
      guard !id.isEmpty else { return nil }
      return .person(id)
    }
  }
}

/// One paragraph of the interview: a Final passage, or consecutive Draft
/// passages by the same voice. The speaker's name runs in only where the
/// voice changes, as a published interview sets it.
struct TranscriptParagraph: Identifiable, Equatable {
  let segments: [NativeTranscriptSegment]
  let startsTurn: Bool

  var id: String { segments[0].id }
  var lead: NativeTranscriptSegment { segments[0] }
  var isDraft: Bool { lead.finality == "draft" }
  var speaker: String { lead.speakerLabel }
  var text: String {
    segments.map { $0.effectiveText.trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: " ")
  }

  /// Timeline order across tracks. Draft windows of one voice join into one
  /// paragraph; each Final passage keeps its own timestamp and actions.
  static func build(_ segments: [NativeTranscriptSegment]) -> [TranscriptParagraph] {
    let ordered = segments.sorted {
      ($0.startNanoseconds, $0.trackId, $0.sequence) < ($1.startNanoseconds, $1.trackId, $1.sequence)
    }
    var result: [TranscriptParagraph] = []
    for segment in ordered
    where !segment.effectiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let previous = result.last?.lead
      let sameVoice =
        previous.map {
          $0.speakerLabel == segment.speakerLabel && $0.namedSpeakerId == segment.namedSpeakerId
        } ?? false
      if sameVoice, let last = result.last, last.isDraft, segment.finality == "draft",
        last.segments.count < 8
      {
        result[result.count - 1] = TranscriptParagraph(
          segments: last.segments + [segment], startsTurn: last.startsTurn)
      } else {
        result.append(TranscriptParagraph(segments: [segment], startsTurn: !sameVoice))
      }
    }
    return result
  }
}

/// The transcript typeset as an interview: run-in speaker names in small
/// caps, New York text at a readable measure, and timestamps in the left
/// shoulder that play from that moment. Find and the person menu sit above
/// the text; naming and correction open in the review tray.
struct TranscriptReader: View {
  let sessionId: String
  @ObservedObject var transcripts: TranscriptLibraryModel
  let canSeek: Bool
  let isPlaybackActive: Bool
  let playbackPosition: () -> TranscriptPlaybackPosition?
  let onSeek: (Int64) -> Void
  let onFollowPlayback: (String) -> Void
  var speakerActions: SpeakerActionController?
  var correctionActions: CorrectionActionController?
  @State private var filter: TranscriptPersonFilter = .all
  @State private var followsPlayback = true
  @State private var query = ""
  @State private var findFocused = false
  @State private var findClearGeneration = 0
  @AppStorage(TranscriptTextScale.storageKey) private var storedTranscriptTextScale =
    TranscriptTextScale.standard.rawValue

  private var scale: TranscriptTextScale {
    TranscriptTextScale.resolve(storedTranscriptTextScale)
  }

  private var speakerSegments: [NativeTranscriptSegment] {
    transcripts.segments.filter { segment in
      switch filter {
      case .all: true
      case .unassigned: segment.namedSpeakerId == nil
      case .person(let id): segment.namedSpeakerId == id
      }
    }
  }

  var body: some View {
    let segments = TranscriptSearch.matching(speakerSegments, query: query)
    let index = TranscriptPlaybackIndex(
      segments.map {
        TranscriptPlaybackRange(id: $0.id, start: $0.startNanoseconds, end: $0.endNanoseconds)
      })
    VStack(alignment: .leading, spacing: 0) {
      readingTools(resultCount: segments.count)
        .padding(.bottom, 26)
      let readingIdentity = Self.readingIdentity(query: query, filter: filter)
      if isPlaybackActive {
        // Only the active reader ticks. No library-wide publisher, frame
        // callback, ASR work, or file decoding runs on this display timer.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
          document(segments, index: index, position: playbackPosition())
        }
        .id(readingIdentity)
      } else {
        document(segments, index: index, position: nil)
          .id(readingIdentity)
      }
    }
    .onAppear {
      transcripts.setReadingPerson(filter)
      transcripts.setReadingQuery(query)
    }
    .onChange(of: transcripts.namedSpeakers) { people in
      if case .person(let id) = filter, !people.contains(where: { $0.id == id }) {
        filter = .all
        transcripts.setReadingPerson(.all)
      }
    }
    .onChange(of: query) { value in
      if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        followsPlayback = false
      }
    }
    .onChange(of: transcripts.claimHighlightSegmentId) { id in
      if transcripts.claimEvidenceOpen, let id {
        followsPlayback = false
        onFollowPlayback(id)
      }
    }
  }

  // MARK: Reading tools

  private func readingTools(resultCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        HStack(spacing: 4) {
          FindShortcutMount { findFocused = true }
            .frame(width: 22, height: 22)
          TranscriptFindFieldMount(
            query: query, focused: findFocused, clearGeneration: findClearGeneration
          ) { next in
            query = next
            transcripts.setReadingQuery(next)
          }
          .frame(maxWidth: .infinity, minHeight: 20)
          TranscriptFindClearMount(visible: !query.isEmpty) {
            query = ""
            transcripts.setReadingQuery("")
            findClearGeneration += 1
            findFocused = true
          }
          .frame(width: query.isEmpty ? 0 : 18, height: 18)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minWidth: 180, maxWidth: 280)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Interview.rule)
        )
        Spacer(minLength: 8)
        if !transcripts.namedSpeakers.isEmpty {
          TranscriptPersonFilterMount(
            selection: filter, people: transcripts.namedSpeakers
          ) { next in
            filter = next
            transcripts.setReadingPerson(next)
          }
          .frame(width: 230, height: 24)
        }
        if isPlaybackActive {
          Toggle("Follow playback", isOn: $followsPlayback)
            .toggleStyle(.checkbox)
            .font(Interview.meta)
            .foregroundStyle(Interview.quiet)
            .help("Keep the passage that is playing in view. Turn off to read freely.")
        }
      }
      TranscriptSearchCountMount(text: Self.searchCount(resultCount, query: query))
        .frame(maxWidth: .infinity, minHeight: query.isEmpty ? 0 : 16, alignment: .leading)
    }
    .padding(.leading, Interview.shoulder)
    .frame(maxWidth: Interview.documentWidth, alignment: .leading)
  }

  private static func searchCount(_ resultCount: Int, query: String) -> String {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return "" }
    return "\(resultCount) matching \(resultCount == 1 ? "passage" : "passages"). Play a timestamp to check the audio."
  }

  private static func readingIdentity(query: String, filter: TranscriptPersonFilter) -> String {
    let person: String
    switch filter {
    case .all: person = "all"
    case .unassigned: person = "unassigned"
    case .person(let id): person = "person:\(id)"
    }
    return "\(query)\u{1f}\(person)"
  }

  private static func emptyReading(segmentCount: Int, query: String) -> String {
    guard segmentCount == 0 else { return "" }
    return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "No passages are assigned to this person in the selected transcript."
      : "No passages match. Try different words, clear the search, or choose all speakers."
  }

  // MARK: Document

  private func document(
    _ segments: [NativeTranscriptSegment], index: TranscriptPlaybackIndex,
    position: TranscriptPlaybackPosition?
  ) -> some View {
    let activeIds = Set(
      position.flatMap { $0.sessionId == sessionId ? $0.nanoseconds : nil }
        .map { index.activeTurnIds(at: $0) } ?? [])
    let paragraphs = TranscriptParagraph.build(segments)
    let marksDrafts =
      transcripts.segments.contains { $0.finality == "draft" }
      && transcripts.segments.contains { $0.finality != "draft" }
    let firstActive = paragraphs.first { paragraph in
      paragraph.segments.contains { activeIds.contains($0.id) }
    }?.id
    return VStack(alignment: .leading, spacing: 0) {
      TranscriptReadingEmptyMount(text: Self.emptyReading(segmentCount: segments.count, query: query))
        .frame(maxWidth: .infinity, minHeight: segments.isEmpty ? 16 : 0, alignment: .leading)
        .padding(.leading, Interview.shoulder)
      ForEach(paragraphs) { paragraph in
        TranscriptParagraphRow(
          paragraph: paragraph, transcripts: transcripts, query: query, scale: scale,
          marksDrafts: marksDrafts, canSeek: canSeek,
          isPlaying: paragraph.segments.contains { activeIds.contains($0.id) },
          speakerActions: speakerActions, correctionActions: correctionActions,
          onSeek: onSeek
        )
        .padding(.top, paragraph.startsTurn ? Interview.turnSpacing : 8)
        .id("transcript-\(paragraph.id)")
      }
    }
    .onAppear {
      if followsPlayback, let firstActive { onFollowPlayback(firstActive) }
    }
    .onChange(of: firstActive) { id in
      if followsPlayback, let id { onFollowPlayback(id) }
    }
    .onChange(of: followsPlayback) { follows in
      if follows, let firstActive { onFollowPlayback(firstActive) }
    }
  }

  static func passageStateWord(finality: String, corrected: Bool) -> String {
    if finality == "draft" { return ConversationControlLabels.draftState }
    if corrected { return "Corrected" }
    if finality == "final" { return "Final" }
    return finality
  }
}

/// One paragraph: the shoulder timestamp, the run-in name and text, and the
/// passage's Name and Correct controls, which show on hover and stay in the
/// keyboard and VoiceOver order.
private struct TranscriptParagraphRow: View {
  let paragraph: TranscriptParagraph
  @ObservedObject var transcripts: TranscriptLibraryModel
  let query: String
  let scale: TranscriptTextScale
  let marksDrafts: Bool
  let canSeek: Bool
  let isPlaying: Bool
  let speakerActions: SpeakerActionController?
  let correctionActions: CorrectionActionController?
  let onSeek: (Int64) -> Void
  @State private var hovering = false

  private var lead: NativeTranscriptSegment { paragraph.lead }
  private var stamp: String { TranscriptSection.timestamp(lead.startNanoseconds) }
  private var corrected: Bool { paragraph.segments.contains(where: \.corrected) }
  private var isCited: Bool {
    !paragraph.isDraft && transcripts.claimEvidenceOpen
      && paragraph.segments.contains { $0.id == transcripts.claimHighlightSegmentId }
  }
  private var isEditing: Bool {
    speakerActions?.passageId == lead.id || correctionActions?.segmentId == lead.id
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      PassageSeekMount(
        stamp: stamp,
        canSeek: canSeek,
        startNanoseconds: lead.startNanoseconds,
        stateWord: TranscriptReader.passageStateWord(
          finality: lead.finality, corrected: corrected),
        isPlaying: isPlaying,
        onSeek: onSeek
      )
      .frame(width: Interview.shoulder - 12, height: 18, alignment: .trailing)
      .padding(.trailing, 12)
      .padding(.top, 3 * scale.multiplier)
      VStack(alignment: .leading, spacing: 4) {
        Text(attributed)
          .lineSpacing(Interview.speechLineSpacing)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          // Selectable AppKit text otherwise retains its pre-correction value.
          .accessibilityElement(children: .ignore)
          .accessibilityAddTraits(.isStaticText)
          .accessibilityLabel(spoken)
        if corrected, paragraph.segments.count == 1 {
          MachineReadingMount(available: true, verbatim: lead.verbatimText)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        }
      }
      .frame(maxWidth: Interview.measure, alignment: .leading)
      .padding(.vertical, isPlaying || isCited ? 6 : 0)
      .padding(.horizontal, isPlaying || isCited ? 8 : 0)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isCited ? Interview.accent.opacity(0.14) : isPlaying ? Interview.wash : .clear)
      )
      .padding(.horizontal, isPlaying || isCited ? -8 : 0)
      if !paragraph.isDraft, let speakerActions, let correctionActions {
        PassageActionsMount(
          segmentId: lead.id, stamp: stamp, speaker: lead.speakerLabel,
          revealed: hovering || isEditing,
          onName: { speakerActions.beginPassage(lead.id) },
          onCorrect: {
            speakerActions.close()
            correctionActions.begin(lead.id)
          }
        )
        .frame(width: 52, height: 20)
        .padding(.leading, 8)
        .padding(.top, 2)
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
  }

  private var spoken: String {
    var label = ConversationControlLabels.passageAccessibility(
      speaker: paragraph.speaker, text: paragraph.text, finality: lead.finality,
      corrected: corrected, isPlaying: isPlaying, isCited: isCited,
      matches: TranscriptSearch.ranges(in: paragraph.text, query: query).map {
        String(paragraph.text[$0])
      })
    label = "\(stamp). " + label
    return label
  }

  private var attributed: AttributedString {
    var result = AttributedString()
    if paragraph.startsTurn {
      var name = AttributedString(paragraph.speaker.uppercased() + "  ")
      name.font = .system(size: 12 * scale.multiplier, weight: .bold)
      name.foregroundColor = Interview.ink
      name.kern = 0.6
      result += name
    }
    let draftInk = paragraph.isDraft && marksDrafts
    var body = AttributedString(paragraph.text)
    body.font = Interview.speech(scale)
    body.foregroundColor = draftInk ? Interview.quiet : Interview.ink
    if draftInk { body.underlineStyle = Text.LineStyle(pattern: .dot, color: Interview.quiet) }
    for match in TranscriptSearch.ranges(in: paragraph.text, query: query) {
      guard let range = Range(match, in: body) else { continue }
      body[range].backgroundColor = Interview.wash
      body[range].underlineStyle = Text.LineStyle.single
      body[range].font = .system(size: 17 * scale.multiplier, weight: .semibold, design: .serif)
    }
    result += body
    return result
  }
}

/// The passage or person currently being named. The review controls subscribe
/// to this directly, so opening one does not wait for a later SwiftUI pass.
@MainActor
final class SpeakerActionController: ObservableObject {
  @Published var passageId: String?
  @Published var personId: String?

  func beginPassage(_ id: String) {
    personId = nil
    passageId = id
  }

  func beginPerson(_ id: String) {
    passageId = nil
    personId = id
  }

  func close() {
    passageId = nil
    personId = nil
  }
}

/// The passage whose text is being corrected. The editor subscribes to this
/// directly, so opening it does not wait for a later SwiftUI sheet.
@MainActor
final class CorrectionActionController: ObservableObject {
  @Published var segmentId: String?

  func begin(_ id: String) {
    segmentId = id
  }

  func close() {
    segmentId = nil
  }
}

/// The timestamp beside one passage. It is created with that passage so a
/// click seeks this hosting view without waiting for a later SwiftUI pass.
/// The state word (Draft, Final, Corrected) is spoken, not printed.
private struct PassageSeekMount: NSViewRepresentable {
  let stamp: String
  let canSeek: Bool
  let startNanoseconds: Int64
  let stateWord: String
  var isPlaying = false
  let onSeek: (Int64) -> Void

  func makeNSView(context: Context) -> PassageSeekControl {
    let view = PassageSeekControl()
    view.bind(
      stamp: stamp, canSeek: canSeek, startNanoseconds: startNanoseconds,
      stateWord: stateWord, isPlaying: isPlaying, onSeek: onSeek)
    return view
  }

  func updateNSView(_ view: PassageSeekControl, context: Context) {
    view.bind(
      stamp: stamp, canSeek: canSeek, startNanoseconds: startNanoseconds,
      stateWord: stateWord, isPlaying: isPlaying, onSeek: onSeek)
  }
}

private final class PassageSeekControl: NSView {
  private let button = NSButton(title: "", target: nil, action: nil)
  private var startNanoseconds: Int64 = 0
  private var onSeek: (@MainActor (Int64) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .inline
    button.isBordered = false
    button.alignment = .right
    button.target = self
    button.action = #selector(seek)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 18)
  }

  func bind(
    stamp: String,
    canSeek: Bool,
    startNanoseconds: Int64,
    stateWord: String,
    isPlaying: Bool,
    onSeek: @escaping @MainActor (Int64) -> Void
  ) {
    self.startNanoseconds = startNanoseconds
    self.onSeek = onSeek
    let color: NSColor =
      isPlaying ? NSColor(Interview.accent) : canSeek ? .secondaryLabelColor : .tertiaryLabelColor
    button.title = stamp
    button.attributedTitle = NSAttributedString(
      string: stamp,
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(
          ofSize: 11, weight: isPlaying ? .semibold : .regular),
        .foregroundColor: color,
      ])
    button.isEnabled = canSeek
    button.toolTip = canSeek ? "Play from \(stamp)" : nil
    let seek = ConversationControlLabels.seekAccessibility(stamp: stamp, canSeek: canSeek)
    button.setAccessibilityLabel(canSeek ? "\(seek), \(stateWord)" : seek)
  }

  @objc private func seek() {
    let start = startNanoseconds
    let onSeek = onSeek
    Task { @MainActor in onSeek?(start) }
  }
}

/// Name and Correct for one Final passage. The buttons fade in on hover but
/// never leave the view tree, so keyboard, VoiceOver, and hosted proofs reach
/// the same controls a pointer does.
private struct PassageActionsMount: NSViewRepresentable {
  let segmentId: String
  let stamp: String
  let speaker: String
  let revealed: Bool
  let onName: () -> Void
  let onCorrect: () -> Void

  func makeNSView(context: Context) -> PassageActionsControl {
    let view = PassageActionsControl()
    view.bind(self)
    return view
  }

  func updateNSView(_ view: PassageActionsControl, context: Context) {
    view.bind(self)
  }
}

private final class PassageActionsControl: NSView {
  private let nameButton = NSButton(title: "Name", target: nil, action: nil)
  private let correctButton = NSButton(title: "Correct", target: nil, action: nil)
  private var onName: (() -> Void)?
  private var onCorrect: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    for (button, symbol, tip) in [
      (nameButton, "person.crop.circle.badge.plus", "Name who is speaking"),
      (correctButton, "pencil", "Correct this passage"),
    ] {
      button.isBordered = false
      button.bezelStyle = .smallSquare
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
      button.imagePosition = .imageOnly
      button.contentTintColor = .secondaryLabelColor
      button.toolTip = tip
      button.target = self
      button.translatesAutoresizingMaskIntoConstraints = false
      addSubview(button)
    }
    nameButton.action = #selector(name)
    correctButton.action = #selector(correct)
    NSLayoutConstraint.activate([
      nameButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      nameButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      nameButton.widthAnchor.constraint(equalToConstant: 22),
      nameButton.heightAnchor.constraint(equalToConstant: 20),
      correctButton.leadingAnchor.constraint(equalTo: nameButton.trailingAnchor, constant: 4),
      correctButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      correctButton.widthAnchor.constraint(equalToConstant: 22),
      correctButton.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func bind(_ mount: PassageActionsMount) {
    onName = mount.onName
    onCorrect = mount.onCorrect
    nameButton.setAccessibilityLabel(
      ConversationControlLabels.nameSpeakerAccessibility(stamp: mount.stamp, label: mount.speaker))
    correctButton.setAccessibilityLabel(
      ConversationControlLabels.correctAccessibility(stamp: mount.stamp))
    nameButton.identifier = NSUserInterfaceItemIdentifier(mount.segmentId)
    correctButton.identifier = NSUserInterfaceItemIdentifier(mount.segmentId)
    let alpha: CGFloat = mount.revealed ? 1 : 0
    if nameButton.alphaValue != alpha {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
        nameButton.animator().alphaValue = alpha
        correctButton.animator().alphaValue = alpha
      }
    }
  }

  @objc private func name() {
    let onName = onName
    Task { @MainActor in onName?() }
  }

  @objc private func correct() {
    let onCorrect = onCorrect
    Task { @MainActor in onCorrect?() }
  }
}

/// An editable name whose programmatic value enables Save or Split immediately.
private final class SpeakerReviewField: NSTextField {
  var onValue: (() -> Void)?

  override var stringValue: String {
    get { super.stringValue }
    set {
      super.stringValue = newValue
      onValue?()
    }
  }
}

/// Merge menu whose programmatic selection enables Merge on the same turn.
private final class SpeakerMergePopup: NSPopUpButton {
  var onSelection: (() -> Void)?

  override func selectItem(at index: Int) {
    super.selectItem(at: index)
    onSelection?()
  }

  override func selectItem(withTitle title: String) {
    super.selectItem(withTitle: title)
    onSelection?()
  }
}

private final class SpeakerActionBanner: NSView, NSTextFieldDelegate {
  private let hint = NSTextField(labelWithString: "Select a speaker label to name that person.")
  private let nameField = SpeakerReviewField(string: "")
  private let saveButton = NSButton(title: "Save", target: nil, action: nil)
  private let sourceButton = NSButton(title: "Use audio source label", target: nil, action: nil)
  private let renameRow = NSStackView()
  private let mergePopup = SpeakerMergePopup()
  private let mergeButton = NSButton(title: "Merge speakers", target: nil, action: nil)
  private let splitField = SpeakerReviewField(string: "")
  private let splitButton = NSButton(title: "Split this passage", target: nil, action: nil)
  private let heading = NSTextField(labelWithString: "Who is speaking?")
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let suggestionRow = NSStackView()
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var actions: SpeakerActionController?
  private var sessionId = ""
  private var suggestions: [String] = []
  private var suggestionSignature: [String] = []
  private var appliedNameTarget: String?
  private var appliedSplitTarget: String?
  private var renameSignature: [String] = []
  private var mergeSignature: [String] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Speaker review")
    hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    hint.textColor = .secondaryLabelColor
    hint.setAccessibilityLabel("Select a speaker label to name that person.")
    nameField.placeholderString = "Name"
    nameField.setAccessibilityLabel("Person's name")
    nameField.isEditable = true
    nameField.isBezeled = true
    nameField.bezelStyle = .roundedBezel
    nameField.delegate = self
    nameField.onValue = { [weak self] in self?.refreshEnabled() }
    splitField.placeholderString = "Name for the split passage"
    splitField.setAccessibilityLabel("Name for the split passage")
    splitField.isEditable = true
    splitField.isBezeled = true
    splitField.bezelStyle = .roundedBezel
    splitField.delegate = self
    splitField.onValue = { [weak self] in self?.refreshEnabled() }
    saveButton.setAccessibilityLabel("Save speaker")
    sourceButton.setAccessibilityLabel("Use audio source label")
    mergeButton.setAccessibilityLabel("Merge speakers")
    splitButton.setAccessibilityLabel("Split this passage")
    mergePopup.setAccessibilityLabel("Merge into")
    mergePopup.setAccessibilityIdentifier("Merge into")
    mergePopup.onSelection = { [weak self] in self?.refreshEnabled() }
    for button in [saveButton, sourceButton, mergeButton, splitButton] {
      button.bezelStyle = .rounded
      button.target = self
    }
    saveButton.action = #selector(saveSpeaker)
    sourceButton.action = #selector(useSourceLabel)
    mergeButton.action = #selector(mergeSpeakers)
    splitButton.action = #selector(splitPassage)
    renameRow.orientation = .horizontal
    renameRow.alignment = .centerY
    renameRow.spacing = ScribeSpacing.related
    suggestionRow.orientation = .horizontal
    suggestionRow.alignment = .centerY
    suggestionRow.spacing = 6
    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    heading.setAccessibilityRole(.staticText)
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.setAccessibilityLabel("Cancel naming")
    cancelButton.target = self
    cancelButton.action = #selector(cancelNaming)
    saveButton.keyEquivalent = "\r"
    func row(_ views: [NSView]) -> NSStackView {
      let row = NSStackView(views: views)
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = ScribeSpacing.related
      row.detachesHiddenViews = true
      return row
    }
    let nameRow = row([nameField, saveButton, cancelButton, sourceButton])
    let splitRow = row([splitField, splitButton])
    let mergeRow = row([mergePopup, mergeButton])
    let column = NSStackView(views: [
      heading, hint, nameRow, suggestionRow, splitRow, mergeRow, renameRow,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.related
    column.detachesHiddenViews = true
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(equalTo: bottomAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      splitField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      mergePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    for control in [
      hint, nameField, saveButton, sourceButton, mergePopup, mergeButton, splitField, splitButton,
    ] {
      control.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(
    transcripts: TranscriptLibraryModel, actions: SpeakerActionController, sessionId: String,
    suggestions: [String] = []
  ) {
    let same =
      self.transcripts === transcripts && self.actions === actions && self.sessionId == sessionId
    self.transcripts = transcripts
    self.actions = actions
    self.sessionId = sessionId
    self.suggestions = suggestions
    if !same {
      let triggers: [AnyPublisher<Void, Never>] = [
        transcripts.$segments.map { _ in () }.eraseToAnyPublisher(),
        transcripts.$namedSpeakers.map { _ in () }.eraseToAnyPublisher(),
        transcripts.$namedSpeakerTurnHistory.map { _ in () }.eraseToAnyPublisher(),
        transcripts.$isEditing.map { _ in () }.eraseToAnyPublisher(),
        actions.$passageId.map { _ in () }.eraseToAnyPublisher(),
        actions.$personId.map { _ in () }.eraseToAnyPublisher(),
      ]
      subscription = Publishers.MergeMany(triggers).sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard let hit, hit !== self else { return nil }
    if hit is NSButton || hit is NSTextField { return hit }
    return nil
  }

  func controlTextDidChange(_ obj: Notification) {
    refreshEnabled()
  }

  private func apply() {
    guard let transcripts, let actions else { return }
    let people = transcripts.namedSpeakers
    syncRenameButtons(people)
    if let passageId = actions.passageId,
      let passage = transcripts.segments.first(where: { $0.id == passageId })
    {
      showPassage(passage, people: people)
    } else if let personId = actions.personId,
      let person = people.first(where: { $0.id == personId })
    {
      showPerson(person, others: people.filter { $0.id != person.id })
    } else if actions.passageId == nil && actions.personId == nil {
      showIdle(hasPeople: !people.isEmpty)
    }
    syncSuggestions(visible: actions.passageId != nil || actions.personId != nil)
    refreshEnabled()
    layoutSubtreeIfNeeded()
  }

  /// Names heard in the conversation, offered as one-click choices. They
  /// only fill the field; nothing is stored until Save.
  private func syncSuggestions(visible: Bool) {
    let current = Set((transcripts?.namedSpeakers ?? []).map { $0.label.lowercased() })
    let names = visible ? suggestions.filter { !current.contains($0.lowercased()) } : []
    suggestionRow.isHidden = names.isEmpty
    guard names != suggestionSignature else { return }
    suggestionSignature = names
    for view in suggestionRow.arrangedSubviews {
      suggestionRow.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    guard !names.isEmpty else { return }
    let label = NSTextField(labelWithString: "Heard:")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    suggestionRow.addArrangedSubview(label)
    for name in names.prefix(6) {
      let button = NSButton(title: name, target: self, action: #selector(useSuggestion(_:)))
      button.bezelStyle = .recessed
      button.controlSize = .small
      button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      button.setAccessibilityLabel("Use the name \(name)")
      suggestionRow.addArrangedSubview(button)
    }
  }

  @objc private func useSuggestion(_ sender: NSButton) {
    nameField.stringValue = sender.title
    window?.makeFirstResponder(nameField)
  }

  @objc private func cancelNaming() {
    let actions = actions
    Task { @MainActor in actions?.close() }
  }

  private func showPassage(
    _ passage: NativeTranscriptSegment, people: [NativeNamedTranscriptSpeaker]
  ) {
    let target = "passage:\(passage.id)"
    revealName(target: target, value: "")
    heading.stringValue = "Who is speaking at \(TranscriptSection.timestamp(passage.startNanoseconds))?"
    heading.isHidden = false
    cancelButton.isHidden = false
    if appliedSplitTarget != target {
      // A later publish must not erase a split name the reader just typed.
      splitField.stringValue = ""
      appliedSplitTarget = target
    }
    saveButton.isHidden = false
    sourceButton.isHidden = passage.namedSpeakerId == nil
    let turns =
      passage.namedSpeakerId.flatMap { id in people.first { $0.id == id }?.selectedTurns } ?? 0
    let showSplit = turns > 1
    splitField.isHidden = !showSplit
    splitButton.isHidden = !showSplit
    mergePopup.isHidden = true
    mergeButton.isHidden = true
    hint.isHidden = true
  }

  private func showPerson(_ person: NativeNamedTranscriptSpeaker, others: [NativeNamedTranscriptSpeaker]) {
    revealName(target: "person:\(person.id)", value: person.label)
    heading.stringValue = "Rename \(person.label)"
    heading.isHidden = false
    cancelButton.isHidden = false
    saveButton.isHidden = false
    sourceButton.isHidden = true
    splitField.isHidden = true
    splitButton.isHidden = true
    let showMerge = !others.isEmpty
    mergePopup.isHidden = !showMerge
    mergeButton.isHidden = !showMerge
    if showMerge { syncMergePopup(others) }
    hint.isHidden = true
  }

  private func showIdle(hasPeople: Bool) {
    heading.isHidden = true
    cancelButton.isHidden = true
    nameField.isHidden = true
    saveButton.isHidden = true
    sourceButton.isHidden = true
    splitField.isHidden = true
    splitButton.isHidden = true
    mergePopup.isHidden = true
    mergeButton.isHidden = true
    hint.isHidden = hasPeople
    appliedNameTarget = nil
    appliedSplitTarget = nil
  }

  /// Writes the field only when the open passage or person changes.
  private func revealName(target: String, value: String) {
    if appliedNameTarget != target {
      nameField.stringValue = value
      appliedNameTarget = target
    }
    nameField.isHidden = false
  }

  private func syncRenameButtons(_ people: [NativeNamedTranscriptSpeaker]) {
    let signature = people.map { "\($0.id)\n\($0.label)" }
    renameRow.isHidden = people.isEmpty
    guard signature != renameSignature else { return }
    renameSignature = signature
    for view in renameRow.arrangedSubviews {
      renameRow.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for person in people {
      let button = NSButton(
        title: "Rename \(person.label)", target: self, action: #selector(beginRename(_:)))
      button.bezelStyle = .rounded
      button.setAccessibilityLabel("Rename \(person.label)")
      button.identifier = NSUserInterfaceItemIdentifier(person.id)
      button.setContentCompressionResistancePriority(.required, for: .vertical)
      renameRow.addArrangedSubview(button)
    }
  }

  private func syncMergePopup(_ others: [NativeNamedTranscriptSpeaker]) {
    let signature = others.map { "\($0.id)\n\($0.label)" }
    guard signature != mergeSignature else { return }
    mergeSignature = signature
    mergePopup.removeAllItems()
    mergePopup.addItem(withTitle: "Choose a person")
    mergePopup.item(at: 0)?.representedObject = ""
    for person in others {
      mergePopup.addItem(withTitle: person.label)
      mergePopup.lastItem?.representedObject = person.id
    }
    mergePopup.selectItem(at: 0)
  }

  private func refreshEnabled() {
    let sessionMatches = transcripts?.sessionId == sessionId
    let editing = transcripts?.isEditing ?? true
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    saveButton.isEnabled =
      !nameField.isHidden && sessionMatches && !editing && Self.acceptable(name)
    let split = splitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    splitButton.isEnabled =
      !splitButton.isHidden && sessionMatches && !editing && Self.acceptable(split)
    let keep = mergePopup.selectedItem?.representedObject as? String ?? ""
    mergeButton.isEnabled = !mergeButton.isHidden && sessionMatches && !editing && !keep.isEmpty
    sourceButton.isEnabled = !sourceButton.isHidden && sessionMatches && !editing
  }

  private static func acceptable(_ label: String) -> Bool {
    !label.isEmpty && label.utf8.count <= 128
      && !label.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }

  @objc private func saveSpeaker() {
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.acceptable(name) else { return }
    let transcripts = transcripts
    let actions = actions
    let sessionId = sessionId
    Task { @MainActor in
      guard let transcripts, let actions, transcripts.sessionId == sessionId,
        !transcripts.isEditing
      else { return }
      let saved: Bool
      if let personId = actions.personId {
        saved = await transcripts.renameNamedSpeaker(
          sessionId: sessionId, speakerId: personId, label: name)
      } else if let passageId = actions.passageId,
        let segment = transcripts.segments.first(where: { $0.id == passageId })
      {
        saved = await transcripts.assignSpeaker(
          sessionId: sessionId, segment: segment, assignment: .new(label: name))
      } else {
        return
      }
      if saved { actions.close() }
    }
  }

  @objc private func useSourceLabel() {
    let transcripts = transcripts
    let actions = actions
    let sessionId = sessionId
    Task { @MainActor in
      guard let transcripts, let actions, transcripts.sessionId == sessionId,
        !transcripts.isEditing, let passageId = actions.passageId,
        let segment = transcripts.segments.first(where: { $0.id == passageId }),
        segment.namedSpeakerId != nil
      else { return }
      let saved = await transcripts.assignSpeaker(
        sessionId: sessionId, segment: segment, assignment: .source)
      if saved { actions.close() }
    }
  }

  @objc private func mergeSpeakers() {
    let keepId = mergePopup.selectedItem?.representedObject as? String ?? ""
    guard !keepId.isEmpty else { return }
    let transcripts = transcripts
    let actions = actions
    let sessionId = sessionId
    Task { @MainActor in
      guard let transcripts, let actions, let absorbId = actions.personId,
        transcripts.sessionId == sessionId, !transcripts.isEditing
      else { return }
      let saved = await transcripts.mergeNamedSpeakers(
        sessionId: sessionId, keepId: keepId, absorbId: absorbId)
      if saved { actions.close() }
    }
  }

  @objc private func splitPassage() {
    let label = splitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.acceptable(label) else { return }
    let transcripts = transcripts
    let actions = actions
    let sessionId = sessionId
    Task { @MainActor in
      guard let transcripts, let actions, transcripts.sessionId == sessionId,
        !transcripts.isEditing, let passageId = actions.passageId,
        let segment = transcripts.segments.first(where: { $0.id == passageId }),
        let speakerId = segment.namedSpeakerId
      else { return }
      let saved = await transcripts.splitNamedSpeaker(
        sessionId: sessionId, speakerId: speakerId, segment: segment, label: label)
      if saved { actions.close() }
    }
  }

  @objc private func beginRename(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    let actions = actions
    Task { @MainActor in actions?.beginPerson(id) }
  }
}

/// Correct, cancel, or restore one passage. The controls exist before the
/// pencil is clicked; a click only fills this hosting view.
private final class CorrectionActionBanner: NSView, NSTextFieldDelegate {
  private let title = NSTextField(labelWithString: "Correct Transcript Text")
  private let machine = NSTextField(labelWithString: "")
  private let field = SpeakerReviewField(string: "")
  private let saveButton = NSButton(title: "Save", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let restoreButton = NSButton(title: "Restore Machine Reading", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var actions: CorrectionActionController?
  private var sessionId = ""
  private var appliedTarget: String?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Correct transcript text")
    title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    title.setAccessibilityLabel("Correct Transcript Text")
    machine.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    machine.textColor = .secondaryLabelColor
    machine.lineBreakMode = .byTruncatingTail
    machine.setAccessibilityLabel("Machine reading")
    field.placeholderString = "Corrected text"
    field.setAccessibilityLabel("Corrected text")
    field.isEditable = true
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.delegate = self
    field.onValue = { [weak self] in self?.refreshEnabled() }
    saveButton.setAccessibilityLabel("Save correction")
    cancelButton.setAccessibilityLabel("Cancel correction")
    restoreButton.setAccessibilityLabel("Restore Machine Reading")
    for button in [saveButton, cancelButton, restoreButton] {
      button.bezelStyle = .rounded
      button.target = self
    }
    saveButton.action = #selector(saveCorrection)
    cancelButton.action = #selector(cancelCorrection)
    restoreButton.action = #selector(restoreMachineReading)
    saveButton.keyEquivalent = "\r"
    cancelButton.keyEquivalent = "\u{1b}"
    machine.maximumNumberOfLines = 2
    machine.lineBreakMode = .byWordWrapping
    machine.preferredMaxLayoutWidth = 560
    let buttons = NSStackView(views: [saveButton, cancelButton, restoreButton])
    buttons.orientation = .horizontal
    buttons.spacing = ScribeSpacing.related
    buttons.detachesHiddenViews = true
    let column = NSStackView(views: [title, machine, field, buttons])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.related
    column.detachesHiddenViews = true
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(equalTo: bottomAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
    ])
    for control in [title, machine, field, saveButton, cancelButton, restoreButton] {
      control.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(
    transcripts: TranscriptLibraryModel, actions: CorrectionActionController, sessionId: String
  ) {
    let same =
      self.transcripts === transcripts && self.actions === actions && self.sessionId == sessionId
    self.transcripts = transcripts
    self.actions = actions
    self.sessionId = sessionId
    if !same {
      let triggers: [AnyPublisher<Void, Never>] = [
        transcripts.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        actions.$segmentId.map { _ in () }.eraseToAnyPublisher(),
      ]
      subscription = Publishers.MergeMany(triggers).sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard let hit, hit !== self else { return nil }
    if hit is NSPopUpButton { return nil }
    if hit is NSButton || hit is NSTextField { return hit }
    return nil
  }

  func controlTextDidChange(_ obj: Notification) {
    refreshEnabled()
  }

  private func apply() {
    guard let transcripts, let actions else { return }
    guard let segmentId = actions.segmentId,
      let segment = transcripts.segments.first(where: { $0.id == segmentId }),
      transcripts.sessionId == sessionId
    else {
      hideEditor()
      return
    }
    if appliedTarget != segment.id {
      field.stringValue = segment.effectiveText
      appliedTarget = segment.id
    }
    title.isHidden = false
    machine.isHidden = false
    machine.stringValue = "Machine reading: \(segment.verbatimText)"
    field.isHidden = false
    saveButton.isHidden = false
    cancelButton.isHidden = false
    restoreButton.isHidden = !segment.corrected
    refreshEnabled()
    layoutSubtreeIfNeeded()
  }

  private func hideEditor() {
    title.isHidden = true
    machine.isHidden = true
    field.isHidden = true
    saveButton.isHidden = true
    cancelButton.isHidden = true
    restoreButton.isHidden = true
    appliedTarget = nil
    layoutSubtreeIfNeeded()
  }

  private func refreshEnabled() {
    let sessionMatches = transcripts?.sessionId == sessionId
    let editing = transcripts?.isEditing ?? true
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    saveButton.isEnabled = !saveButton.isHidden && sessionMatches && !editing && !text.isEmpty
    cancelButton.isEnabled = !cancelButton.isHidden && sessionMatches && !editing
    restoreButton.isEnabled = !restoreButton.isHidden && sessionMatches && !editing
  }

  @objc private func saveCorrection() {
    let text = field.stringValue
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let transcripts = transcripts
    let actions = actions
    let sessionId = sessionId
    let segmentId = actions?.segmentId
    Task { @MainActor in
      guard let transcripts, let actions, transcripts.sessionId == sessionId,
        !transcripts.isEditing,
        let segmentId,
        let segment = transcripts.segments.first(where: { $0.id == segmentId })
      else { return }
      let saved = await transcripts.correct(segment, text: text, in: sessionId)
      if saved { actions.close() }
    }
  }

  @objc private func cancelCorrection() {
    let actions = actions
    Task { @MainActor in actions?.close() }
  }

  @objc private func restoreMachineReading() {
    let transcripts = transcripts
    let actions = actions
    let sessionId = sessionId
    let segmentId = actions?.segmentId
    Task { @MainActor in
      guard let transcripts, let actions, transcripts.sessionId == sessionId,
        !transcripts.isEditing,
        let segmentId,
        let segment = transcripts.segments.first(where: { $0.id == segmentId }),
        segment.corrected
      else { return }
      let saved = await transcripts.correct(segment, text: nil, in: sessionId)
      if saved { actions.close() }
    }
  }
}

/// The review tray: naming a speaker or correcting a passage, docked under
/// the document while one of those actions is open. The tray appears only
/// while a passage's Name or Correct is active and closes when it saves.
struct ReviewTrayMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speakerActions: SpeakerActionController
  @ObservedObject var correctionActions: CorrectionActionController
  let sessionId: String
  var suggestedNames: [String] = []

  static func isOpen(
    speakerActions: SpeakerActionController, correctionActions: CorrectionActionController
  ) -> Bool {
    speakerActions.passageId != nil || speakerActions.personId != nil
      || correctionActions.segmentId != nil
  }

  func makeNSView(context: Context) -> ReviewTrayControl {
    let view = ReviewTrayControl()
    view.bind(self)
    return view
  }

  func updateNSView(_ view: ReviewTrayControl, context: Context) {
    view.bind(self)
  }
}

final class ReviewTrayControl: NSView {
  private let speakerBanner = SpeakerActionBanner()
  private let correctionBanner = CorrectionActionBanner()
  private let stack = NSStackView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Review tray")
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = ScribeSpacing.related
    stack.detachesHiddenViews = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(speakerBanner)
    stack.addArrangedSubview(correctionBanner)
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: max(1, stack.fittingSize.height))
  }

  func bind(_ mount: ReviewTrayMount) {
    speakerBanner.bind(
      transcripts: mount.transcripts, actions: mount.speakerActions, sessionId: mount.sessionId,
      suggestions: mount.suggestedNames)
    correctionBanner.bind(
      transcripts: mount.transcripts, actions: mount.correctionActions, sessionId: mount.sessionId)
    let speaking = mount.speakerActions.passageId != nil || mount.speakerActions.personId != nil
    speakerBanner.isHidden = !speaking
    correctionBanner.isHidden = speaking || mount.correctionActions.segmentId == nil
    invalidateIntrinsicContentSize()
  }
}
