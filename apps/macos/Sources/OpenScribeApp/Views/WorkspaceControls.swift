import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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

/// The staged drop, confirmed or cancelled at the top of the detail column.
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

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: DropConfirmationBannerView, context: Context
  ) -> CGSize? {
    nsView.hostedSize(width: proposal.width)
  }
}

final class DropConfirmationBannerView: HostedPanel {
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
    message.setContentHuggingPriority(.defaultLow, for: .horizontal)
    message.font = .preferredFont(forTextStyle: .callout)
    importButton.bezelStyle = .rounded
    importButton.setAccessibilityLabel("Confirm audio import")
    importButton.target = self
    importButton.action = #selector(confirmImport)
    cancelButton.bezelStyle = .rounded
    cancelButton.setAccessibilityLabel("Cancel audio import")
    cancelButton.target = self
    cancelButton.action = #selector(cancelImport)
    content.orientation = .horizontal
    content.alignment = .centerY
    content.edgeInsets = NSEdgeInsets(
      top: ScribeSpacing.related, left: ScribeSpacing.standard, bottom: ScribeSpacing.related,
      right: ScribeSpacing.standard)
    for item in [message, importButton, cancelButton] {
      content.addArrangedSubview(item)
    }
    apply(nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var isShowingContent: Bool { showsConfirmation }

  func bind(_ authority: ImportedMediaAuthorityAdapter) {
    if self.authority !== authority {
      self.authority = authority
      subscription = authority.$pendingAudioImport.sink { [weak self] pending in
        DispatchQueue.main.async { self?.apply(pending) }
      }
    }
    apply(authority.pendingAudioImport)
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
    invalidateIntrinsicContentSize()
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

/// A notice the window shows about its library, playback, import or edit.
struct WorkspaceNotice: Identifiable, Equatable {
  let id: String
  let message: String
  let isFailure: Bool
}

/// The window's own notices. Whichever document is showing sets them in its
/// notice position, so they never take a band of the window's height.
struct WindowNotices: Equatable {
  /// Why the last recording stopped or could not start.
  var recordingProblem: String?
  /// The library edit result: a rename or another library change.
  var edit: WorkspaceNotice?
  var others: [WorkspaceNotice] = []

  static let none = WindowNotices()
}

/// The recording problem and the library edit notice are AppKit text a hosted
/// proof reads; the other notices are set in the document's own voice.
struct WindowNoticeList: View {
  let notices: WindowNotices

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        if notices.recordingProblem != nil { problemSymbol }
        HostedText(
          text: notices.recordingProblem, identifier: "Recording problem",
          label: notices.recordingProblem.map { "Problem: \($0)" } ?? "Recording problem",
          font: .systemFont(ofSize: 13), maximumLines: 4)
      }
      .padding(.bottom, notices.recordingProblem == nil ? 0 : 10)
      HStack(alignment: .top, spacing: 10) {
        if notices.edit?.isFailure == true { problemSymbol }
        HostedText(
          text: notices.edit?.message, identifier: "Library notice",
          label: notices.edit.map { "\($0.isFailure ? "Problem" : "Status"): \($0.message)" },
          font: .systemFont(ofSize: 13),
          color: notices.edit?.isFailure == true ? .labelColor : NSColor(Interview.quiet),
          maximumLines: 4)
      }
      .padding(.bottom, notices.edit == nil ? 0 : 10)
      ForEach(notices.others) { notice in
        InterviewNotice(message: notice.message, isProblem: notice.isFailure)
          .padding(.bottom, 10)
      }
    }
  }

  private var problemSymbol: some View {
    Image(systemName: "exclamationmark.triangle.fill")
      .font(Interview.meta)
      .foregroundStyle(Color(nsColor: .systemOrange))
      .accessibilityHidden(true)
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

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: LibrarySearchField, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 220, height: nsView.intrinsicContentSize.height)
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

/// States the deletion inventory and asks for an explicit move or cancel.
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

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: DeletionConfirmationBanner, context: Context
  ) -> CGSize? {
    nsView.hostedSize(width: proposal.width)
  }
}

final class DeletionConfirmationBanner: HostedPanel {
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
    message.setContentHuggingPriority(.defaultLow, for: .horizontal)
    confirmButton.bezelStyle = .rounded
    confirmButton.setAccessibilityLabel("Confirm move to Trash")
    confirmButton.target = self
    confirmButton.action = #selector(confirmMove)
    cancelButton.bezelStyle = .rounded
    cancelButton.setAccessibilityLabel("Cancel deletion")
    cancelButton.target = self
    cancelButton.action = #selector(cancelMove)
    content.orientation = .horizontal
    content.alignment = .centerY
    content.edgeInsets = NSEdgeInsets(
      top: ScribeSpacing.related, left: ScribeSpacing.standard, bottom: ScribeSpacing.related,
      right: ScribeSpacing.standard)
    for item in [message, confirmButton, cancelButton] {
      content.addArrangedSubview(item)
    }
    apply(nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var isShowingContent: Bool { showsConfirmation }

  override func prepareLayout(width: CGFloat) {
    let buttons = confirmButton.fittingSize.width + cancelButton.fittingSize.width
    message.preferredMaxLayoutWidth = max(
      120, width - buttons - 2 * ScribeSpacing.standard - 2 * content.spacing)
  }

  func bind(_ transcripts: TranscriptLibraryModel, onConfirmed: @escaping () -> Void) {
    self.onConfirmed = onConfirmed
    if self.transcripts !== transcripts {
      self.transcripts = transcripts
      subscription = transcripts.$pendingDeletion.sink { [weak self] inventory in
        DispatchQueue.main.async { self?.apply(inventory) }
      }
    }
    apply(transcripts.pendingDeletion)
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
    invalidateIntrinsicContentSize()
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

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: RenameConfirmationBanner, context: Context
  ) -> CGSize? {
    nsView.hostedSize(width: proposal.width)
  }
}

final class RenameConfirmationBanner: HostedPanel, NSTextFieldDelegate {
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
    titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
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
    column.detachesHiddenViews = true
    column.setContentHuggingPriority(.defaultLow, for: .horizontal)
    content.orientation = .horizontal
    content.alignment = .centerY
    content.edgeInsets = NSEdgeInsets(
      top: ScribeSpacing.related, left: ScribeSpacing.standard, bottom: ScribeSpacing.related,
      right: ScribeSpacing.standard)
    for item in [column, confirmButton, cancelButton] {
      content.addArrangedSubview(item)
    }
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var isShowingContent: Bool { showsEditor }

  override func prepareLayout(width: CGFloat) {
    let buttons = confirmButton.fittingSize.width + cancelButton.fittingSize.width
    message.preferredMaxLayoutWidth = max(
      240, width - buttons - 2 * ScribeSpacing.standard - 2 * content.spacing)
  }

  func bind(_ store: RuntimeLibraryStore) {
    if self.store !== store {
      self.store = store
      subscription = store.objectWillChange.sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
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
    invalidateIntrinsicContentSize()
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
