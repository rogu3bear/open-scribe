import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The library drop sets `pendingAudioImport` while AppKit is still laying out
/// the destination. A SwiftUI banner computed in that pass does not appear in
/// the hosting view that received the drop. This strip is created with the
/// first layout and reveals its own buttons when the pending file changes.
/// The library drop target. It reads the file URL and filename list a Finder
/// drag puts on the pasteboard, then stages those files for confirmation.
struct AudioDropMount: NSViewRepresentable {
  let onDrop: ([URL]) -> Void

  func makeNSView(context: Context) -> AudioDropControl {
    let view = AudioDropControl()
    view.bind(onDrop: onDrop)
    return view
  }

  func updateNSView(_ view: AudioDropControl, context: Context) {
    view.bind(onDrop: onDrop)
  }
}

final class AudioDropControl: NSView {
  private var onDrop: (([URL]) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Audio drop")
    registerForDraggedTypes([
      .fileURL,
      NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(onDrop: @escaping ([URL]) -> Void) {
    self.onDrop = onDrop
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    fileURLs(on: sender.draggingPasteboard).isEmpty ? [] : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !fileURLs(on: sender.draggingPasteboard).isEmpty
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = fileURLs(on: sender.draggingPasteboard)
    guard !urls.isEmpty else { return false }
    onDrop?(urls)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

  override func draggingEnded(_ sender: NSDraggingInfo?) {}

  private func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
    var urls: [URL] = []
    if let objects = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] {
      urls.append(contentsOf: objects)
    }
    if let value = pasteboard.string(forType: .fileURL),
      let url = URL(string: value), url.isFileURL
    {
      urls.append(url)
    }
    let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    if let paths = pasteboard.propertyList(forType: filenames) as? [String] {
      urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
    }
    var seen: [String] = []
    return urls.filter { url in
      let path = url.standardizedFileURL.path
      guard !seen.contains(path) else { return false }
      seen.append(path)
      return true
    }
  }
}

struct DropConfirmationMount: NSViewRepresentable {
  @ObservedObject var authority: ImportedMediaAuthorityAdapter

  func makeNSView(context: Context) -> DropConfirmationBannerView {
    let view = DropConfirmationBannerView()
    view.bind(authority)
    return view
  }

  func updateNSView(_ view: DropConfirmationBannerView, context: Context) {
    view.bind(authority)
  }
}

final class DropConfirmationBannerView: NSView {
  private let message = NSTextField(labelWithString: "")
  private let importButton = NSButton(title: "Import", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var authority: ImportedMediaAuthorityAdapter?
  private var showsConfirmation = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Drop confirmation")
    message.lineBreakMode = .byTruncatingMiddle
    message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    message.font = .preferredFont(forTextStyle: .callout)
    importButton.bezelStyle = .rounded
    importButton.setAccessibilityLabel("Confirm audio import")
    importButton.target = self
    importButton.action = #selector(confirmImport)
    cancelButton.bezelStyle = .rounded
    cancelButton.setAccessibilityLabel("Cancel audio import")
    cancelButton.target = self
    cancelButton.action = #selector(cancelImport)
    for item in [message, importButton, cancelButton] {
      item.translatesAutoresizingMaskIntoConstraints = false
      addSubview(item)
    }
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ScribeSpacing.standard),
      message.centerYAnchor.constraint(equalTo: centerYAnchor),
      cancelButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -ScribeSpacing.standard),
      cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      importButton.trailingAnchor.constraint(
        equalTo: cancelButton.leadingAnchor, constant: -ScribeSpacing.related),
      importButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      message.trailingAnchor.constraint(
        lessThanOrEqualTo: importButton.leadingAnchor, constant: -ScribeSpacing.related),
    ])
    apply(nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(_ authority: ImportedMediaAuthorityAdapter) {
    guard self.authority !== authority else { return }
    self.authority = authority
    subscription = authority.$pendingAudioImport.sink { [weak self] pending in
      DispatchQueue.main.async {
        self?.apply(pending)
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.apply(self?.authority?.pendingAudioImport)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard showsConfirmation else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func draw(_ dirtyRect: NSRect) {
    guard showsConfirmation else { return }
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }

  private func apply(_ pending: PendingAudioImport?) {
    showsConfirmation = pending != nil
    message.isHidden = pending == nil
    importButton.isHidden = pending == nil
    cancelButton.isHidden = pending == nil
    message.stringValue =
      pending.map { ImportedMediaAuthorityAdapter.dropConfirmationMessage(urls: $0.urls) } ?? ""
    needsDisplay = true
    layoutSubtreeIfNeeded()
  }

  @objc private func confirmImport() {
    let authority = authority
    Task { @MainActor in
      authority?.confirmPendingAudioImport()
    }
  }

  @objc private func cancelImport() {
    let authority = authority
    Task { @MainActor in
      authority?.cancelPendingAudioImport()
    }
  }
}

/// Plays the selected imported recording. Hidden until that recording exists,


/// A recording problem. The field is created with the window and fills when
/// capture stops, so the reserve sentence is an update rather than a new row.
struct RecordingProblemMount: NSViewRepresentable {
  let message: String?

  func makeNSView(context: Context) -> RecordingProblemControl {
    let view = RecordingProblemControl()
    view.bind(message: message)
    return view
  }

  func updateNSView(_ view: RecordingProblemControl, context: Context) {
    view.bind(message: message)
  }
}

final class RecordingProblemControl: NSView {
  private let field = NSTextField(wrappingLabelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Recording problem")
    field.font = .preferredFont(forTextStyle: .callout)
    field.textColor = .labelColor
    field.maximumNumberOfLines = 4
    field.lineBreakMode = .byWordWrapping
    field.preferredMaxLayoutWidth = 640
    field.setAccessibilityIdentifier("Recording problem")
    field.setAccessibilityRole(.staticText)
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ScribeSpacing.standard),
      field.topAnchor.constraint(equalTo: topAnchor, constant: ScribeSpacing.related),
      field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ScribeSpacing.standard),
      field.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -ScribeSpacing.related),
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
    ])
    bind(message: nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(message: String?) {
    let text = message ?? ""
    let shown = !text.isEmpty
    isHidden = !shown
    field.isHidden = !shown
    field.stringValue = shown ? text : ""
    field.setAccessibilityLabel(shown ? "Problem: \(text)" : "Recording problem")
  }
}

/// The library edit notice. SwiftUI text in this banner does not publish a
/// readable label in the hosted window, so the warning is an AppKit field.
struct LibraryNoticeMount: NSViewRepresentable {
  let message: String
  let isFailure: Bool

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(labelWithString: message)
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 4
    field.setAccessibilityIdentifier("Library notice")
    field.setAccessibilityLabel(Self.label(message, isFailure: isFailure))
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    field.stringValue = message
    field.setAccessibilityLabel(Self.label(message, isFailure: isFailure))
  }

  private static func label(_ message: String, isFailure: Bool) -> String {
    "\(isFailure ? "Problem" : "Status"): \(message)"
  }
}

struct WorkspaceNotice: Identifiable {
  let id: String
  let message: String
  let isFailure: Bool
}



/// The toolbar's Stop and Save control. The button is created with the first
/// layout and calls the same stop the menu uses.
struct ToolbarStopMount: NSViewRepresentable {
  let onStop: () -> Void

  func makeNSView(context: Context) -> ToolbarStopControl {
    let view = ToolbarStopControl()
    view.bind(onStop: onStop)
    return view
  }

  func updateNSView(_ view: ToolbarStopControl, context: Context) {
    view.bind(onStop: onStop)
  }
}

final class ToolbarStopControl: NSView {
  private let button = NSButton(
    title: ConversationControlLabels.stopAndSave, target: nil, action: nil)
  private var onStop: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Toolbar stop")
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(ConversationControlLabels.stopAndSave)
    button.setAccessibilityIdentifier("Toolbar stop")
    let shortcut = ConversationControlLabels.stopShortcut
    button.keyEquivalent = String(shortcut.key.character)
    button.keyEquivalentModifierMask = Self.modifierMask(shortcut.modifiers)
    button.target = self
    button.action = #selector(stop)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(onStop: @escaping () -> Void) {
    self.onStop = onStop
    button.isEnabled = true
  }

  @objc private func stop() {
    guard button.isEnabled else { return }
    onStop?()
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

/// The toolbar's Record control. The button is created with the first layout
/// and calls the same start the empty library uses.
struct ToolbarRecordMount: NSViewRepresentable {
  let enabled: Bool
  let help: String
  let onRecord: () -> Void

  func makeNSView(context: Context) -> ToolbarRecordControl {
    let view = ToolbarRecordControl()
    view.bind(enabled: enabled, help: help, onRecord: onRecord)
    return view
  }

  func updateNSView(_ view: ToolbarRecordControl, context: Context) {
    view.bind(enabled: enabled, help: help, onRecord: onRecord)
  }
}

final class ToolbarRecordControl: NSView {
  private let button = NSButton(
    title: ConversationControlLabels.record, target: nil, action: nil)
  private var onRecord: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Toolbar record")
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(ConversationControlLabels.record)
    button.setAccessibilityIdentifier("Toolbar record")
    let shortcut = ConversationControlLabels.recordShortcut
    button.keyEquivalent = String(shortcut.key.character)
    button.keyEquivalentModifierMask = Self.modifierMask(shortcut.modifiers)
    button.target = self
    button.action = #selector(record)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(enabled: Bool, help: String, onRecord: @escaping () -> Void) {
    self.onRecord = onRecord
    button.toolTip = help
    button.isEnabled = enabled
  }

  @objc private func record() {
    guard button.isEnabled else { return }
    onRecord?()
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

/// The empty library's package control. The button is created with the first
/// layout and calls the same opener the toolbar uses. The panel stays the
/// default chooser; this control does not open a second one.
struct PortablePackageOpenMount: NSViewRepresentable {
  let enabled: Bool
  let help: String
  let onOpen: () -> Void

  func makeNSView(context: Context) -> PortablePackageOpenControl {
    let view = PortablePackageOpenControl()
    view.bind(enabled: enabled, help: help, onOpen: onOpen)
    return view
  }

  func updateNSView(_ view: PortablePackageOpenControl, context: Context) {
    view.bind(enabled: enabled, help: help, onOpen: onOpen)
  }
}

final class PortablePackageOpenControl: NSView {
  private let button = NSButton(
    title: ConversationControlLabels.portablePackage, target: nil, action: nil)
  private var onOpen: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Open portable package")
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.setAccessibilityLabel(ConversationControlLabels.portablePackage)
    button.setAccessibilityIdentifier("Open portable package")
    button.target = self
    button.action = #selector(openPackage)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(enabled: Bool, help: String, onOpen: @escaping () -> Void) {
    self.onOpen = onOpen
    button.toolTip = help
    button.isEnabled = enabled
  }

  @objc private func openPackage() {
    guard button.isEnabled else { return }
    onOpen?()
  }
}

/// The empty library's Record control. The button is created with the first
/// layout and calls the same start the toolbar uses.
struct RecordStartMount: NSViewRepresentable {
  let enabled: Bool
  let onRecord: () -> Void

  func makeNSView(context: Context) -> RecordStartControl {
    let view = RecordStartControl()
    view.bind(enabled: enabled, onRecord: onRecord)
    return view
  }

  func updateNSView(_ view: RecordStartControl, context: Context) {
    view.bind(enabled: enabled, onRecord: onRecord)
  }
}

final class RecordStartControl: NSView {
  private let button = NSButton(
    title: ConversationControlLabels.record, target: nil, action: nil)
  private var onRecord: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Record conversation")
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.setAccessibilityLabel(ConversationControlLabels.record)
    button.setAccessibilityIdentifier("Record conversation")
    button.target = self
    button.action = #selector(record)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(enabled: Bool, onRecord: @escaping () -> Void) {
    self.onRecord = onRecord
    button.isEnabled = enabled
  }

  @objc private func record() {
    guard button.isEnabled else { return }
    onRecord?()
  }
}

/// The query the sidebar field last delivered. The field writes it; the result
/// strip reads it. A SwiftUI binding would publish the row only after the query.
@MainActor
final class LibrarySearchState: ObservableObject {
  @Published var query = ""
}

/// Search field created with the sidebar. Assigning `stringValue` delivers the
/// query on that turn; AppKit does not send `controlTextDidChange` for it.
struct LibrarySearchMount: NSViewRepresentable {
  var onQuery: (String) -> Void

  func makeNSView(context: Context) -> LibrarySearchField {
    let field = LibrarySearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
    field.onQuery = onQuery
    field.activate()
    return field
  }

  func updateNSView(_ field: LibrarySearchField, context: Context) {
    field.onQuery = onQuery
  }
}

final class LibrarySearchField: NSSearchField, NSSearchFieldDelegate {
  var onQuery: ((String) -> Void)?
  private var ready = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    placeholderString = ConversationControlLabels.searchTranscripts
    setAccessibilityLabel(ConversationControlLabels.searchTranscripts)
    setAccessibilityIdentifier(ConversationControlLabels.searchTranscripts)
    delegate = self
    target = self
    action = #selector(submitQuery)
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
      guard ready else { return }
      deliver()
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    guard ready else { return }
    deliver()
  }

  @objc private func submitQuery() {
    guard ready else { return }
    deliver()
  }

  private func deliver() {
    let text = stringValue
    let onQuery = onQuery
    Task { @MainActor in onQuery?(text) }
  }
}

/// Match rows created with the sidebar. A search replaces their titles inside
/// this view; it does not insert a SwiftUI button into the already-hosted list.
struct SearchResultMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var search: LibrarySearchState
  var onOpen: (NativeTranscriptSearchHit) -> Void

  func makeNSView(context: Context) -> SearchResultBanner {
    let view = SearchResultBanner()
    view.bind(transcripts: transcripts, store: store, search: search, onOpen: onOpen)
    return view
  }

  func updateNSView(_ view: SearchResultBanner, context: Context) {
    view.bind(transcripts: transcripts, store: store, search: search, onOpen: onOpen)
  }
}

final class SearchResultBanner: NSView {
  private let empty = NSTextField(labelWithString: "No matching transcript text")
  private let column = NSStackView()
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var store: RuntimeLibraryStore?
  private var search: LibrarySearchState?
  private var onOpen: ((NativeTranscriptSearchHit) -> Void)?
  private var signature: [String] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Transcript matches")
    empty.setAccessibilityLabel("No matching transcript text")
    empty.font = .preferredFont(forTextStyle: .callout)
    empty.textColor = .secondaryLabelColor
    empty.lineBreakMode = .byWordWrapping
    empty.maximumNumberOfLines = 2
    empty.isHidden = true
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.related
    column.translatesAutoresizingMaskIntoConstraints = false
    column.addArrangedSubview(empty)
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    setContentCompressionResistancePriority(.required, for: .vertical)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 120)
  }

  func bind(
    transcripts: TranscriptLibraryModel,
    store: RuntimeLibraryStore,
    search: LibrarySearchState,
    onOpen: @escaping (NativeTranscriptSearchHit) -> Void
  ) {
    self.onOpen = onOpen
    let same = self.transcripts === transcripts && self.store === store && self.search === search
    self.transcripts = transcripts
    self.store = store
    self.search = search
    if !same {
      let triggers: [AnyPublisher<Void, Never>] = [
        transcripts.$searchResults.map { _ in () }.eraseToAnyPublisher(),
        transcripts.$isSearching.map { _ in () }.eraseToAnyPublisher(),
        store.$savedSessions.map { _ in () }.eraseToAnyPublisher(),
        search.$query.map { _ in () }.eraseToAnyPublisher(),
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

  private func apply() {
    guard let transcripts, let store, let search else { return }
    let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let hits = query.isEmpty ? [] : transcripts.searchResults
    let showEmpty = !query.isEmpty && hits.isEmpty && !transcripts.isSearching
    empty.isHidden = !showEmpty
    let sessions = store.savedSessions + (store.currentSession.map { [$0] } ?? [])
    let references = ConversationIdentityPresentation.references(for: sessions)
    // Search stores the capture title; show the resolved one the library shows.
    let titles = Dictionary(
      sessions.map { ($0.sessionId, ConversationIdentityPresentation.title(for: $0)) }
    ) { first, _ in first }
    func title(_ hit: NativeTranscriptSearchHit) -> String {
      titles[hit.sessionId] ?? ConversationIdentityPresentation.title(hit.sessionTitle)
    }
    let next = hits.map { hit -> String in
      let reference = references[hit.sessionId] ?? ""
      return "\(hit.sessionId)#\(hit.sequence)\n\(title(hit))\n\(reference)\n\(hit.effectiveText)"
    }
    guard next != signature else {
      layoutSubtreeIfNeeded()
      return
    }
    signature = next
    for view in column.arrangedSubviews where view !== empty {
      column.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for hit in hits {
      let heading = title(hit)
      let reference = references[hit.sessionId]
      let key = "\(hit.sessionId)#\(hit.sequence)"
      let button = NSButton(title: hit.effectiveText, target: self, action: #selector(openHit(_:)))
      button.bezelStyle = .rounded
      button.alignment = .left
      button.lineBreakMode = .byTruncatingTail
      button.setAccessibilityLabel(
        "\(heading)\(reference.map { ", reference \($0)" } ?? ""): \(hit.effectiveText)"
      )
      button.identifier = NSUserInterfaceItemIdentifier(key)
      button.setAccessibilityIdentifier(key)
      button.setContentCompressionResistancePriority(.required, for: .vertical)
      column.addArrangedSubview(button)
    }
    layoutSubtreeIfNeeded()
  }

  @objc private func openHit(_ sender: NSButton) {
    let key = sender.identifier?.rawValue ?? ""
    let transcripts = transcripts
    let onOpen = onOpen
    Task { @MainActor in
      guard let hit = transcripts?.searchResults.first(where: {
        "\($0.sessionId)#\($0.sequence)" == key
      }) else { return }
      onOpen?(hit)
    }
  }
}

/// The selected saved conversation can be moved to Trash. The button exists
/// before a selection so a later library refresh only reveals it.
struct DeletionRequestMount: NSViewRepresentable {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var navigation: MainWorkspaceNavigation
  let onRequest: (RuntimeSessionPresentation) -> Void

  func makeNSView(context: Context) -> DeletionRequestControl {
    let view = DeletionRequestControl()
    view.bind(
      store: store, liveRecording: liveRecording, navigation: navigation, onRequest: onRequest)
    return view
  }

  func updateNSView(_ view: DeletionRequestControl, context: Context) {
    view.bind(
      store: store, liveRecording: liveRecording, navigation: navigation, onRequest: onRequest)
  }
}

final class DeletionRequestControl: NSView {
  private let button = NSButton(title: "Move to Trash…", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var store: RuntimeLibraryStore?
  private var liveRecording: LiveMicrophoneRecordingController?
  private var navigation: MainWorkspaceNavigation?
  private var onRequest: ((RuntimeSessionPresentation) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Delete conversation")
    SidebarBarButton.style(button, symbol: "trash", tip: "Move to Trash…")
    button.setAccessibilityLabel("Move the selected conversation to Trash")
    button.target = self
    button.action = #selector(requestDeletion)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isHidden = true
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(
    store: RuntimeLibraryStore, liveRecording: LiveMicrophoneRecordingController,
    navigation: MainWorkspaceNavigation, onRequest: @escaping (RuntimeSessionPresentation) -> Void
  ) {
    self.onRequest = onRequest
    let same =
      self.store === store && self.liveRecording === liveRecording && self.navigation === navigation
    self.store = store
    self.liveRecording = liveRecording
    self.navigation = navigation
    if !same {
      let triggers: [AnyPublisher<Void, Never>] = [
        store.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        liveRecording.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        navigation.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      ]
      subscription = Publishers.MergeMany(triggers).sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard button.isHidden == false else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  private func apply() {
    let available = selectedDeletableSession() != nil
    button.isHidden = !available
    button.isEnabled = available
    layoutSubtreeIfNeeded()
  }

  private func selectedDeletableSession() -> RuntimeSessionPresentation? {
    guard let liveRecording, liveRecording.canStart, let navigation, let store,
      let sessionId = navigation.selectedSessionId,
      let session = store.savedSessions.first(where: { $0.sessionId == sessionId }),
      session.deletionUnavailableReason == nil
    else { return nil }
    return session
  }

  @objc private func requestDeletion() {
    guard let session = selectedDeletableSession() else { return }
    let onRequest = onRequest
    Task { @MainActor in onRequest?(session) }
  }
}

/// States the deletion inventory and asks for an explicit move or cancel.
/// Both controls are created here so a later `pendingDeletion` only unhides them.
struct DeletionConfirmationMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let onConfirmed: () -> Void

  func makeNSView(context: Context) -> DeletionConfirmationBanner {
    let view = DeletionConfirmationBanner()
    view.bind(transcripts, onConfirmed: onConfirmed)
    return view
  }

  func updateNSView(_ view: DeletionConfirmationBanner, context: Context) {
    view.bind(transcripts, onConfirmed: onConfirmed)
  }
}

final class DeletionConfirmationBanner: NSView {
  private let message = NSTextField(wrappingLabelWithString: "")
  private let confirmButton = NSButton(title: "Move to Trash", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var onConfirmed: (() -> Void)?
  private var showsConfirmation = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Deletion confirmation")
    message.font = .preferredFont(forTextStyle: .callout)
    message.maximumNumberOfLines = 4
    message.lineBreakMode = .byWordWrapping
    message.cell?.truncatesLastVisibleLine = true
    message.setAccessibilityLabel("Deletion summary")
    message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    confirmButton.bezelStyle = .rounded
    confirmButton.setAccessibilityLabel("Confirm move to Trash")
    confirmButton.target = self
    confirmButton.action = #selector(confirmMove)
    cancelButton.bezelStyle = .rounded
    cancelButton.setAccessibilityLabel("Cancel deletion")
    cancelButton.target = self
    cancelButton.action = #selector(cancelMove)
    for item in [message, confirmButton, cancelButton] {
      item.translatesAutoresizingMaskIntoConstraints = false
      addSubview(item)
    }
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ScribeSpacing.standard),
      message.topAnchor.constraint(equalTo: topAnchor, constant: ScribeSpacing.related),
      message.bottomAnchor.constraint(
        lessThanOrEqualTo: bottomAnchor, constant: -ScribeSpacing.related),
      cancelButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -ScribeSpacing.standard),
      cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      confirmButton.trailingAnchor.constraint(
        equalTo: cancelButton.leadingAnchor, constant: -ScribeSpacing.related),
      confirmButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      message.trailingAnchor.constraint(
        lessThanOrEqualTo: confirmButton.leadingAnchor, constant: -ScribeSpacing.related),
    ])
    apply(nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 96)
  }

  func bind(_ transcripts: TranscriptLibraryModel, onConfirmed: @escaping () -> Void) {
    self.onConfirmed = onConfirmed
    guard self.transcripts !== transcripts else { return }
    self.transcripts = transcripts
    subscription = transcripts.$pendingDeletion.sink { [weak self] inventory in
      DispatchQueue.main.async { self?.apply(inventory) }
    }
    DispatchQueue.main.async { [weak self] in
      self?.apply(self?.transcripts?.pendingDeletion)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard showsConfirmation else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func draw(_ dirtyRect: NSRect) {
    guard showsConfirmation else { return }
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }

  private func apply(_ inventory: NativeSessionDeletionInventory?) {
    showsConfirmation = inventory != nil
    message.isHidden = inventory == nil
    confirmButton.isHidden = inventory == nil
    cancelButton.isHidden = inventory == nil
    message.stringValue = inventory.map { SessionDeletionSummary.text($0) } ?? ""
    needsDisplay = true
    layoutSubtreeIfNeeded()
  }

  @objc private func confirmMove() {
    let transcripts = transcripts
    let onConfirmed = onConfirmed
    Task { @MainActor in
      if await transcripts?.confirmDeletion() == true {
        onConfirmed?()
      }
    }
  }

  @objc private func cancelMove() {
    let transcripts = transcripts
    Task { @MainActor in
      await transcripts?.cancelDeletion()
    }
  }
}

/// Chooses local audio through the shipped importer. The button is created
/// with the first layout. The default chooser is the open panel.
struct AudioFileImportMount: NSViewRepresentable {
  @ObservedObject var authority: ImportedMediaAuthorityAdapter
  @ObservedObject var recording: LiveMicrophoneRecordingController

  func makeNSView(context: Context) -> AudioFileImportControl {
    let view = AudioFileImportControl()
    view.bind(authority: authority, recording: recording)
    return view
  }

  func updateNSView(_ view: AudioFileImportControl, context: Context) {
    view.bind(authority: authority, recording: recording)
  }
}

final class AudioFileImportControl: NSView {
  private let chooseButton = NSButton(
    title: ConversationControlLabels.audioFiles, target: nil, action: nil)
  private var subscriptions: [AnyCancellable] = []
  private var authority: ImportedMediaAuthorityAdapter?
  private var recording: LiveMicrophoneRecordingController?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Audio file import")
    SidebarBarButton.style(chooseButton, symbol: "plus", tip: "Import audio files…")
    chooseButton.setAccessibilityLabel(ConversationControlLabels.audioFiles)
    chooseButton.target = self
    chooseButton.action = #selector(chooseAudioFiles)
    chooseButton.translatesAutoresizingMaskIntoConstraints = false
    chooseButton.isHidden = true
    addSubview(chooseButton)
    NSLayoutConstraint.activate([
      chooseButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      chooseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      chooseButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(
    authority: ImportedMediaAuthorityAdapter, recording: LiveMicrophoneRecordingController
  ) {
    let same = self.authority === authority && self.recording === recording
    self.authority = authority
    self.recording = recording
    if !same {
      let triggers: [AnyPublisher<Void, Never>] = [
        authority.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        recording.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      ]
      subscriptions.removeAll()
      Publishers.MergeMany(triggers).sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }.store(in: &subscriptions)
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard chooseButton.isHidden == false else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  private var canChoose: Bool {
    guard let authority, let recording else { return false }
    return recording.canStart && !authority.isBusy && !authority.hasPendingAudioImports
  }

  private func apply() {
    let available = canChoose
    chooseButton.isHidden = !available
    chooseButton.isEnabled = available
    chooseButton.toolTip =
      available ? ImportedMediaAuthorityAdapter.importLimitHelp : nil
    layoutSubtreeIfNeeded()
  }

  @objc private func chooseAudioFiles() {
    guard canChoose else { return }
    authority?.chooseAndImport()
  }
}

/// The selected saved or interrupted conversation can be renamed. The button
/// exists before a selection so a later library refresh only reveals it.
struct RenameRequestMount: NSViewRepresentable {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var navigation: MainWorkspaceNavigation
  let onRequest: (RuntimeSessionPresentation) -> Void

  func makeNSView(context: Context) -> RenameRequestControl {
    let view = RenameRequestControl()
    view.bind(
      store: store, liveRecording: liveRecording, navigation: navigation, onRequest: onRequest)
    return view
  }

  func updateNSView(_ view: RenameRequestControl, context: Context) {
    view.bind(
      store: store, liveRecording: liveRecording, navigation: navigation, onRequest: onRequest)
  }
}

final class RenameRequestControl: NSView {
  private let button = NSButton(title: "Rename…", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var store: RuntimeLibraryStore?
  private var liveRecording: LiveMicrophoneRecordingController?
  private var navigation: MainWorkspaceNavigation?
  private var onRequest: ((RuntimeSessionPresentation) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Rename conversation")
    SidebarBarButton.style(button, symbol: "pencil", tip: "Rename…")
    button.setAccessibilityLabel("Rename the selected conversation")
    button.target = self
    button.action = #selector(requestRename)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isHidden = true
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(
    store: RuntimeLibraryStore, liveRecording: LiveMicrophoneRecordingController,
    navigation: MainWorkspaceNavigation, onRequest: @escaping (RuntimeSessionPresentation) -> Void
  ) {
    self.onRequest = onRequest
    let same =
      self.store === store && self.liveRecording === liveRecording && self.navigation === navigation
    self.store = store
    self.liveRecording = liveRecording
    self.navigation = navigation
    if !same {
      let triggers: [AnyPublisher<Void, Never>] = [
        store.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        liveRecording.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        navigation.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      ]
      subscription = Publishers.MergeMany(triggers).sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard button.isHidden == false else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  private func apply() {
    let available = selectedRenamableSession() != nil
    button.isHidden = !available
    button.isEnabled = available
    layoutSubtreeIfNeeded()
  }

  private func selectedRenamableSession() -> RuntimeSessionPresentation? {
    guard let liveRecording, liveRecording.canStart, let navigation, let store,
      let sessionId = navigation.selectedSessionId
    else { return nil }
    if let session = store.savedSessions.first(where: { $0.sessionId == sessionId }) {
      return session
    }
    if let current = store.currentSession, current.sessionId == sessionId,
      current.lifecycle == "interrupted"
    {
      return current
    }
    return nil
  }

  @objc private func requestRename() {
    guard let session = selectedRenamableSession() else { return }
    let onRequest = onRequest
    Task { @MainActor in onRequest?(session) }
  }
}

/// Asks for a new title before Rust stores it. The field and both buttons are
/// created here so a later `pendingRename` only unhides them.
struct RenameConfirmationMount: NSViewRepresentable {
  @ObservedObject var store: RuntimeLibraryStore

  func makeNSView(context: Context) -> RenameConfirmationBanner {
    let view = RenameConfirmationBanner()
    view.bind(store)
    return view
  }

  func updateNSView(_ view: RenameConfirmationBanner, context: Context) {
    view.bind(store)
  }
}

final class RenameConfirmationBanner: NSView, NSTextFieldDelegate {
  private let message = NSTextField(wrappingLabelWithString: "")
  private let titleField = NSTextField(string: "")
  private let confirmButton = NSButton(title: "Rename", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var store: RuntimeLibraryStore?
  private var showsEditor = false
  private var appliedGeneration = -1

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Rename confirmation")
    message.font = .preferredFont(forTextStyle: .callout)
    message.maximumNumberOfLines = 2
    message.lineBreakMode = .byWordWrapping
    message.cell?.truncatesLastVisibleLine = true
    message.setAccessibilityLabel("Rename summary")
    message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleField.placeholderString = "Title"
    titleField.delegate = self
    titleField.setAccessibilityLabel("Conversation title")
    titleField.lineBreakMode = .byTruncatingTail
    titleField.bezelStyle = .roundedBezel
    titleField.isBezeled = true
    confirmButton.bezelStyle = .rounded
    confirmButton.setAccessibilityLabel("Save conversation name")
    confirmButton.target = self
    confirmButton.action = #selector(confirmRename)
    cancelButton.bezelStyle = .rounded
    cancelButton.setAccessibilityLabel("Cancel rename")
    cancelButton.target = self
    cancelButton.action = #selector(cancelRename)
    let column = NSStackView(views: [message, titleField])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.tight
    column.translatesAutoresizingMaskIntoConstraints = false
    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    for item in [column, confirmButton, cancelButton] {
      item.translatesAutoresizingMaskIntoConstraints = false
      addSubview(item)
    }
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ScribeSpacing.standard),
      column.topAnchor.constraint(equalTo: topAnchor, constant: ScribeSpacing.related),
      column.bottomAnchor.constraint(
        lessThanOrEqualTo: bottomAnchor, constant: -ScribeSpacing.related),
      cancelButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -ScribeSpacing.standard),
      cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      confirmButton.trailingAnchor.constraint(
        equalTo: cancelButton.leadingAnchor, constant: -ScribeSpacing.related),
      confirmButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      column.trailingAnchor.constraint(
        lessThanOrEqualTo: confirmButton.leadingAnchor, constant: -ScribeSpacing.related),
    ])
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 112)
  }

  func bind(_ store: RuntimeLibraryStore) {
    guard self.store !== store else { return }
    self.store = store
    subscription = store.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.apply() }
    }
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard showsEditor else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func draw(_ dirtyRect: NSRect) {
    guard showsEditor else { return }
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }

  private func apply() {
    let pending = store?.pendingRename
    let generation = store?.pendingRenameGeneration ?? 0
    showsEditor = pending != nil
    message.isHidden = pending == nil
    titleField.isHidden = pending == nil
    confirmButton.isHidden = pending == nil
    cancelButton.isHidden = pending == nil
    if let pending, generation != appliedGeneration {
      // Start from the title the person sees, including a suggested one.
      titleField.stringValue = ConversationIdentityPresentation.title(for: pending)
      appliedGeneration = generation
    }
    if pending == nil {
      appliedGeneration = -1
      titleField.stringValue = ""
    }
    if let failure = store?.editMessage, store?.editMessageIsFailure == true {
      message.stringValue = failure
    } else {
      message.stringValue =
        "The new name is used in the library, exports, and portable packages. The recording and its transcript are unchanged."
    }
    let trimmed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    confirmButton.isEnabled = pending != nil && !trimmed.isEmpty
    needsDisplay = true
    layoutSubtreeIfNeeded()
  }

  func controlTextDidChange(_ obj: Notification) {
    guard showsEditor else { return }
    let trimmed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    confirmButton.isEnabled = !trimmed.isEmpty
  }

  @objc private func confirmRename() {
    guard let store, let session = store.pendingRename else { return }
    let title = titleField.stringValue
    confirmButton.isEnabled = false
    Task { @MainActor in
      _ = await store.rename(sessionId: session.sessionId, title: title)
    }
  }

  @objc private func cancelRename() {
    let store = store
    Task { @MainActor in store?.cancelRename() }
  }
}

/// The library's bottom bar: small borderless symbol buttons, as Finder and
/// Notes set them. The title stays on the button for menus and VoiceOver.
@MainActor
enum SidebarBarButton {
  static func style(_ button: NSButton, symbol: String, tip: String) {
    button.isBordered = false
    button.bezelStyle = .smallSquare
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = tip
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
  }
}
