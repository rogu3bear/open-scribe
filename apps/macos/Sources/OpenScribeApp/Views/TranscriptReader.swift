import AppKit
import Combine
import SwiftUI

private enum TranscriptPersonFilter: Hashable {
  case all
  case unassigned
  case person(String)
}

/// A chronological conversation document. Human names filter the reading;
/// the native renderer supplies the clock. Neither changes source evidence.
struct TranscriptReader: View {
  let sessionId: String
  @ObservedObject var transcripts: TranscriptLibraryModel
  let canSeek: Bool
  let isPlaybackActive: Bool
  let playbackPosition: () -> TranscriptPlaybackPosition?
  let onSeek: (Int64) -> Void
  let onFollowPlayback: (String) -> Void
  @State private var filter: TranscriptPersonFilter = .all
  @State private var followsPlayback = true
  @StateObject private var speakerActions = SpeakerActionController()
  @StateObject private var correctionActions = CorrectionActionController()
  @State private var query = ""
  @FocusState private var isSearchFocused: Bool
  @AppStorage(TranscriptTextScale.storageKey) private var storedTranscriptTextScale =
    TranscriptTextScale.standard.rawValue

  private var transcriptTextScale: TranscriptTextScale {
    TranscriptTextScale.resolve(storedTranscriptTextScale)
  }

  private var textScaleBinding: Binding<String> {
    Binding(
      get: { transcriptTextScale.rawValue },
      set: { storedTranscriptTextScale = TranscriptTextScale.resolve($0).rawValue })
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
    VStack(alignment: .leading, spacing: ScribeSpacing.standard) {
      searchControls(resultCount: segments.count)
      peopleControls
      SpeakerActionMount(
        transcripts: transcripts, actions: speakerActions, sessionId: sessionId
      )
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
      CorrectionActionMount(
        transcripts: transcripts, actions: correctionActions, sessionId: sessionId
      )
      .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
      if isPlaybackActive {
        // Only the active reader ticks. No library-wide publisher, frame
        // callback, ASR work, or file decoding runs on this display timer.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
          document(segments, index: index, position: playbackPosition())
        }
      } else {
        document(segments, index: index, position: nil)
      }
    }
    .onChange(of: transcripts.namedSpeakers) { people in
      if case .person(let id) = filter, !people.contains(where: { $0.id == id }) { filter = .all }
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

  private func searchControls(resultCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: ScribeSpacing.related) {
        Button {
          isSearchFocused = true
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(
          ConversationControlLabels.findShortcut.key,
          modifiers: ConversationControlLabels.findShortcut.modifiers)
        .accessibilityLabel(ConversationControlLabels.findInTranscript)
        TextField(ConversationControlLabels.findInTranscript, text: $query)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .accessibilityLabel(ConversationControlLabels.findInTranscript)
        if !query.isEmpty {
          Button {
            query = ""
            isSearchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityLabel(ConversationControlLabels.clearTranscriptSearch)
        }
      }
      .padding(10)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
      }
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(
          "\(resultCount) matching \(resultCount == 1 ? "passage" : "passages"). Play a timestamp to check the audio."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var peopleControls: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.compact) {
          personPicker
          Spacer(minLength: ScribeSpacing.compact)
          if isPlaybackActive { followControl }
        }
        VStack(alignment: .leading, spacing: ScribeSpacing.related) {
          personPicker
          if isPlaybackActive { followControl }
        }
      }
      Picker(TranscriptTextScale.controlLabel, selection: textScaleBinding) {
        ForEach(TranscriptTextScale.allCases) { scale in
          Text(scale.title).tag(scale.rawValue)
        }
      }
      .pickerStyle(.menu)
      .font(.caption)
      .frame(maxWidth: 280, alignment: .leading)
      .accessibilityLabel(TranscriptTextScale.controlLabel)
      .accessibilityValue(transcriptTextScale.spokenValue)
    }
  }

  private var personPicker: some View {
    Picker("Show", selection: $filter) {
      Text("All speakers").tag(TranscriptPersonFilter.all)
      Text("Unassigned passages").tag(TranscriptPersonFilter.unassigned)
      ForEach(transcripts.namedSpeakers, id: \.id) { person in
        Text("\(person.label) · \(person.selectedTurns) passages")
          .tag(TranscriptPersonFilter.person(person.id))
      }
    }
    .pickerStyle(.menu)
    .frame(maxWidth: 320, alignment: .leading)
    .lineLimit(1)
    .accessibilityLabel(ConversationControlLabels.filterByPerson)
  }

  private var followControl: some View {
    Toggle("Follow playback", isOn: $followsPlayback)
      .toggleStyle(.checkbox)
      .font(.caption)
      .help("Keep the currently playing passage in view. Turn off to read freely.")
  }

  private func document(
    _ segments: [NativeTranscriptSegment], index: TranscriptPlaybackIndex,
    position: TranscriptPlaybackPosition?
  ) -> some View {
    let activeIds =
      position.flatMap { $0.sessionId == sessionId ? $0.nanoseconds : nil }
      .map { index.activeTurnIds(at: $0) } ?? []
    // Every passage control is created with the document. A later update does
    // not mount a control that was absent from this hosting view's first layout.
    return VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      if segments.isEmpty {
        Text(
          query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No passages are assigned to this person in the selected transcript."
            : "No passages match. Try different words, clear the search, or choose all speakers."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      ForEach(segments) { segment in
        passage(segment, isPlaying: activeIds.contains(segment.id))
          .id("transcript-\(segment.id)")
      }
    }
    .onAppear {
      if followsPlayback, let id = activeIds.first { onFollowPlayback(id) }
    }
    .onChange(of: activeIds.first) { id in
      if followsPlayback, let id { onFollowPlayback(id) }
    }
    .onChange(of: followsPlayback) { follows in
      if follows, let id = activeIds.first { onFollowPlayback(id) }
    }
  }

  private func passage(_ segment: NativeTranscriptSegment, isPlaying: Bool) -> some View {
    let stamp = TranscriptSection.timestamp(segment.startNanoseconds)
    let isDraft = segment.finality == "draft"
    let isCited =
      !isDraft && transcripts.claimEvidenceOpen && transcripts.claimHighlightSegmentId == segment.id
    let presentation = TranscriptPassagePresentation.make(
      speaker: segment.speakerLabel, text: segment.effectiveText, finality: segment.finality,
      corrected: segment.corrected, isPlaying: isPlaying, isCited: isCited, query: query,
      scale: transcriptTextScale)
    return HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.compact) {
      PassageSeekMount(
        stamp: stamp,
        canSeek: canSeek,
        startNanoseconds: segment.startNanoseconds,
        stateWord: Self.passageStateWord(
          finality: segment.finality, corrected: segment.corrected),
        onSeek: onSeek
      )
      .frame(minWidth: 48, alignment: .leading)
      VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
        HStack(spacing: ScribeSpacing.related) {
          if isDraft {
            Text(segment.speakerLabel)
              .font(.subheadline.weight(.semibold))
          } else {
            PassageSpeakerMount(
              transcripts: transcripts,
              actions: speakerActions,
              revisionId: segment.revisionId,
              sequence: segment.sequence,
              stamp: stamp
            )
            .frame(minWidth: 160, minHeight: 18, alignment: .leading)
          }
          if isPlaying {
            Label("Playing", systemImage: "speaker.wave.2.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if isCited {
            Label("Cited", systemImage: "text.quote")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Cited evidence")
          }
        }
        VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
          Text(presentation.text)
            .font(transcriptTextScale.passageFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            // Selectable AppKit text otherwise retains its pre-correction value.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(presentation.spoken)
          if segment.corrected {
            DisclosureGroup("Corrected · Show machine reading") {
              Text(segment.verbatimText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .contain)
      }
      .frame(maxWidth: 500, alignment: .leading)
      Spacer(minLength: ScribeSpacing.related)
      if !isDraft {
        PassageCorrectionMount(
          actions: correctionActions,
          revisionId: segment.revisionId,
          sequence: segment.sequence,
          stamp: stamp
        ) {
          followsPlayback = false
          transcripts.dismissMessage()
        }
        .frame(minWidth: 72, minHeight: 18, alignment: .leading)
        .help("Correct text")
      }
    }
    .padding(.vertical, ScribeSpacing.tight)
    .frame(maxWidth: 660, alignment: .leading)
    .background(
      isCited
        ? Color.accentColor.opacity(0.16)
        : isPlaying ? Color.accentColor.opacity(0.08) : Color.clear)
    .accessibilityElement(children: .contain)
  }

  static func passageStateWord(finality: String, corrected: Bool) -> String {
    if finality == "draft" { return ConversationControlLabels.draftState }
    if corrected { return "Corrected" }
    if finality == "final" { return "Final" }
    return finality
  }

}

/// The passage or person currently being named. The review controls subscribe
/// to this directly, so opening one does not wait for a later SwiftUI pass.
@MainActor
private final class SpeakerActionController: ObservableObject {
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
private final class CorrectionActionController: ObservableObject {
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
private struct PassageSeekMount: NSViewRepresentable {
  let stamp: String
  let canSeek: Bool
  let startNanoseconds: Int64
  let stateWord: String
  let onSeek: (Int64) -> Void

  func makeNSView(context: Context) -> PassageSeekControl {
    let view = PassageSeekControl()
    view.bind(
      stamp: stamp, canSeek: canSeek, startNanoseconds: startNanoseconds,
      stateWord: stateWord, onSeek: onSeek)
    return view
  }

  func updateNSView(_ view: PassageSeekControl, context: Context) {
    view.bind(
      stamp: stamp, canSeek: canSeek, startNanoseconds: startNanoseconds,
      stateWord: stateWord, onSeek: onSeek)
  }
}

private final class PassageSeekControl: NSView {
  private let button = NSButton(title: "", target: nil, action: nil)
  private let stateField = NSTextField(labelWithString: "")
  private var startNanoseconds: Int64 = 0
  private var onSeek: (@MainActor (Int64) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    button.target = self
    button.action = #selector(seek)
    stateField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    stateField.textColor = .secondaryLabelColor
    let row = NSStackView(views: [button, stateField])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = ScribeSpacing.compact
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
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
    onSeek: @escaping @MainActor (Int64) -> Void
  ) {
    self.startNanoseconds = startNanoseconds
    self.onSeek = onSeek
    button.title = stamp
    button.isEnabled = canSeek
    let seek = ConversationControlLabels.seekAccessibility(stamp: stamp, canSeek: canSeek)
    button.setAccessibilityLabel(canSeek ? "\(seek), \(stateWord)" : seek)
    stateField.stringValue = stateWord
    stateField.setAccessibilityLabel(stateWord)
  }

  @objc private func seek() {
    let start = startNanoseconds
    let onSeek = onSeek
    Task { @MainActor in onSeek?(start) }
  }
}

/// The speaker review strip. It is created with the reader, then shows the
/// name, merge, and split controls inside this view. A sheet presented after
/// the click would not appear in the hosting view that already displayed.
private struct SpeakerActionMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let actions: SpeakerActionController
  let sessionId: String

  func makeNSView(context: Context) -> SpeakerActionBanner {
    let view = SpeakerActionBanner()
    view.bind(transcripts: transcripts, actions: actions, sessionId: sessionId)
    return view
  }

  func updateNSView(_ view: SpeakerActionBanner, context: Context) {
    view.bind(transcripts: transcripts, actions: actions, sessionId: sessionId)
  }
}

private struct PassageSpeakerMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let actions: SpeakerActionController
  let revisionId: String
  let sequence: UInt32
  let stamp: String

  func makeNSView(context: Context) -> PassageSpeakerControl {
    let view = PassageSpeakerControl()
    view.bind(
      transcripts: transcripts, actions: actions, revisionId: revisionId, sequence: sequence,
      stamp: stamp)
    return view
  }

  func updateNSView(_ view: PassageSpeakerControl, context: Context) {
    view.bind(
      transcripts: transcripts, actions: actions, revisionId: revisionId, sequence: sequence,
      stamp: stamp)
  }
}

/// The name on one passage. Its label follows that passage after a rename.
private final class PassageSpeakerControl: NSView {
  private let button = NSButton(title: "", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var actions: SpeakerActionController?
  private var revisionId = ""
  private var sequence: UInt32 = 0
  private var stamp = ""

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    button.lineBreakMode = .byTruncatingTail
    button.target = self
    button.action = #selector(nameSpeaker)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    let fitted = button.intrinsicContentSize
    return NSSize(width: max(160, fitted.width), height: max(18, fitted.height))
  }

  func bind(
    transcripts: TranscriptLibraryModel,
    actions: SpeakerActionController,
    revisionId: String,
    sequence: UInt32,
    stamp: String
  ) {
    self.stamp = stamp
    let same =
      self.transcripts === transcripts && self.actions === actions && self.revisionId == revisionId
      && self.sequence == sequence
    self.transcripts = transcripts
    self.actions = actions
    self.revisionId = revisionId
    self.sequence = sequence
    if !same {
      subscription = transcripts.$segments.sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
  }

  private func apply() {
    let passageId = "\(revisionId)#\(sequence)"
    guard let segment = transcripts?.segments.first(where: { $0.id == passageId }) else { return }
    button.title = segment.speakerLabel
    button.setAccessibilityLabel(
      ConversationControlLabels.nameSpeakerAccessibility(stamp: stamp, label: segment.speakerLabel)
    )
    invalidateIntrinsicContentSize()
  }

  @objc private func nameSpeaker() {
    let passageId = "\(revisionId)#\(sequence)"
    let actions = actions
    Task { @MainActor in actions?.beginPassage(passageId) }
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
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var actions: SpeakerActionController?
  private var sessionId = ""
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
    let column = NSStackView(views: [
      hint, nameField, saveButton, sourceButton, renameRow, mergePopup, mergeButton, splitField,
      splitButton,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.related
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
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

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 150)
  }

  func bind(
    transcripts: TranscriptLibraryModel, actions: SpeakerActionController, sessionId: String
  ) {
    let same =
      self.transcripts === transcripts && self.actions === actions && self.sessionId == sessionId
    self.transcripts = transcripts
    self.actions = actions
    self.sessionId = sessionId
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
    refreshEnabled()
    layoutSubtreeIfNeeded()
  }

  private func showPassage(
    _ passage: NativeTranscriptSegment, people: [NativeNamedTranscriptSpeaker]
  ) {
    let target = "passage:\(passage.id)"
    revealName(target: target, value: "")
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

/// The pencil beside one passage. It is created with that passage.
private struct PassageCorrectionMount: NSViewRepresentable {
  let actions: CorrectionActionController
  let revisionId: String
  let sequence: UInt32
  let stamp: String
  let onBegin: @MainActor () -> Void

  func makeNSView(context: Context) -> PassageCorrectionControl {
    let view = PassageCorrectionControl()
    view.bind(
      actions: actions, revisionId: revisionId, sequence: sequence, stamp: stamp, onBegin: onBegin)
    return view
  }

  func updateNSView(_ view: PassageCorrectionControl, context: Context) {
    view.bind(
      actions: actions, revisionId: revisionId, sequence: sequence, stamp: stamp, onBegin: onBegin)
  }
}

private final class PassageCorrectionControl: NSView {
  private let button = NSButton(title: "Correct", target: nil, action: nil)
  private var actions: CorrectionActionController?
  private var onBegin: (@MainActor () -> Void)?
  private var revisionId = ""
  private var sequence: UInt32 = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: NSFont.systemFontSize)
    button.target = self
    button.action = #selector(correct)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 72, height: 18)
  }

  func bind(
    actions: CorrectionActionController,
    revisionId: String,
    sequence: UInt32,
    stamp: String,
    onBegin: @escaping @MainActor () -> Void
  ) {
    self.actions = actions
    self.onBegin = onBegin
    self.revisionId = revisionId
    self.sequence = sequence
    button.setAccessibilityLabel(ConversationControlLabels.correctAccessibility(stamp: stamp))
    button.identifier = NSUserInterfaceItemIdentifier("\(revisionId)#\(sequence)")
  }

  @objc private func correct() {
    let id = "\(revisionId)#\(sequence)"
    let actions = actions
    let onBegin = onBegin
    Task { @MainActor in
      onBegin?()
      actions?.begin(id)
    }
  }
}

/// Correct, cancel, or restore one passage. The controls exist before the
/// pencil is clicked; a click only fills this hosting view.
private struct CorrectionActionMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let actions: CorrectionActionController
  let sessionId: String

  func makeNSView(context: Context) -> CorrectionActionBanner {
    let view = CorrectionActionBanner()
    view.bind(transcripts: transcripts, actions: actions, sessionId: sessionId)
    return view
  }

  func updateNSView(_ view: CorrectionActionBanner, context: Context) {
    view.bind(transcripts: transcripts, actions: actions, sessionId: sessionId)
  }
}

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
    let column = NSStackView(views: [
      title, machine, field, saveButton, cancelButton, restoreButton,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.related
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
    ])
    for control in [title, machine, field, saveButton, cancelButton, restoreButton] {
      control.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 140)
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
