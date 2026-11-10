import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Environment(\.isSceneVerification) private var isSceneVerification
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var recoveredSessions: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var pressure: SystemPressureMonitor
  @ObservedObject var context: ContextScopeModel
  @ObservedObject var navigation: MainWorkspaceNavigation
  /// Markdown export asks for a destination. The panel is the shipped default.
  /// A hosted proof can supply a file URL and still press the export button.
  var exportTranscriptDestination: (String) -> URL? = { suggestedName in
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedName
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
  @StateObject private var librarySearch = LibrarySearchState()
  @StateObject private var speakerActions = SpeakerActionController()
  @StateObject private var correctionActions = CorrectionActionController()

  private var selectedSessionId: String? {
    navigation.selectedSessionId
  }

  private var selectedSessionBinding: Binding<String?> {
    Binding(
      get: { navigation.selectedSessionId },
      set: { selectedSessionId in
        navigation.select(selectedSessionId)
      }
    )
  }

  private var selectedSession: RuntimeSessionPresentation? {
    if store.currentSession?.sessionId == selectedSessionId {
      return store.currentSession
    }
    return store.savedSessions.first { $0.sessionId == selectedSessionId }
  }

  private var conversationReferences: [String: String] {
    ConversationIdentityPresentation.references(
      for: store.savedSessions + (store.currentSession.map { [$0] } ?? [])
    )
  }

  var body: some View {
    NavigationSplitView {
      conversationSidebar
    } detail: {
      selectedWorkspace
    }
    .navigationSplitViewStyle(.balanced)
    .background {
      AudioDropMount { urls in
        importedMediaAuthority.stageDroppedAudio(urls)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        captureButton
        RecorderControls(recorder: liveRecording, store: store)
        importButton
      }
    }
    .onAppear {
      store.refresh()
      AppTelemetry.runtimeSceneAppeared("primary", session: store.currentSession)
      // Selection is published state. Applying it on the next turn keeps the
      // first library layout from redrawing inside its own appearance pass.
      Task { @MainActor in
        synchronizeSelection(preferCurrentSession: navigation.selectedSessionId == nil)
      }
    }
    .onChange(of: store.currentSession?.sessionId) { _ in
      synchronizeSelection(preferCurrentSession: false)
    }
    .onChange(of: store.savedSessions.map(\.sessionId)) { _ in
      navigation.synchronize(
        currentSessionId: store.currentSession?.sessionId,
        savedSessionIds: store.savedSessions.map(\.sessionId),
        preferCurrentSession: false
      )
    }
    .onChange(of: importedMediaAuthority.importedSessionId) { importedSessionId in
      navigation.acceptImportedConversation(
        importedSessionId,
        savedSessionIds: store.savedSessions.map(\.sessionId)
      )
    }
    .task(id: librarySearch.query) {
      await transcripts.search(librarySearch.query)
    }
    .onChange(of: selectedSessionId) { selectedSessionId in
      if MainWorkspaceSelection.shouldStopDetachedPlayback(
        activePlaybackSessionId: recoveredSessions.activePlaybackSessionId,
        selectedSessionId: selectedSessionId
      ) {
        recoveredSessions.stopPlayback()
      }
    }
    .background {
      #if DEBUG
        if isSceneVerification { VerificationSettingsTrigger() }
      #endif
    }
  }

  private var conversationSidebar: some View {
    VStack(spacing: 0) {
      // The field and match rows exist before a query. A later search only
      // fills this hosting view; it does not wait for a new SwiftUI row.
      LibrarySearchMount { text in
        librarySearch.query = text
        Task { await transcripts.search(text) }
      }
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .padding(.horizontal, ScribeSpacing.related)
      .padding(.top, ScribeSpacing.related)
      SearchResultMount(transcripts: transcripts, store: store, search: librarySearch) { hit in
        openSearchHit(hit)
      }
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
      DeletionRequestMount(
        store: store, liveRecording: liveRecording, navigation: navigation
      ) { session in
        requestDeletion(session)
      }
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .padding(.horizontal, ScribeSpacing.related)
      RenameRequestMount(
        store: store, liveRecording: liveRecording, navigation: navigation
      ) { session in
        store.beginRename(session)
      }
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .padding(.horizontal, ScribeSpacing.related)
      AudioFileImportMount(authority: importedMediaAuthority, recording: liveRecording)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, ScribeSpacing.related)
      conversationList
      LibraryActivityFooter(
        scheduler: scheduler, speech: speech, pressure: pressure,
        titles: Dictionary(
          uniqueKeysWithValues: store.savedSessions.map {
            ($0.sessionId, ConversationIdentityPresentation.title($0.title))
          }))
    }
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
  }

  private var conversationList: some View {
    let references = conversationReferences
    return List(selection: selectedSessionBinding) {
      if let current = store.currentSession {
        Section("Now") {
          if current.lifecycle == "interrupted" {
            ConversationSidebarRow(
              session: current, reference: references[current.sessionId],
              isSelected: selectedSessionId == current.sessionId,
              transcription: scheduler.state(for: current.sessionId)
            )
            .tag(current.sessionId)
            .contextMenu {
              Button("Rename…") {
                store.beginRename(current)
              }
              Button("Move to Trash…", role: .destructive) {
                requestDeletion(current)
              }
              .disabled(!liveRecording.canStart || current.deletionUnavailableReason != nil)
              .help(current.deletionUnavailableReason ?? "Move this conversation to Trash.")
            }
          } else {
            ConversationSidebarRow(
              session: current, reference: references[current.sessionId],
              isSelected: selectedSessionId == current.sessionId,
              transcription: scheduler.state(for: current.sessionId)
            )
            .tag(current.sessionId)
          }
        }
      }

      if !LibraryConversationLists.interrupted(store.savedSessions).isEmpty {
        Section("Interrupted") {
          ForEach(LibraryConversationLists.interrupted(store.savedSessions)) { session in
            ConversationSidebarRow(
              session: session, reference: references[session.sessionId],
              isSelected: selectedSessionId == session.sessionId,
              transcription: scheduler.state(for: session.sessionId)
            )
            .tag(session.sessionId)
            .contextMenu {
              Button("Rename…") {
                store.beginRename(session)
              }
              Button("Move to Trash…", role: .destructive) {
                requestDeletion(session)
              }
              .disabled(!liveRecording.canStart || session.deletionUnavailableReason != nil)
              .help(session.deletionUnavailableReason ?? "Move this conversation to Trash.")
            }
          }
        }
      }

      Section("Conversations") {
        let saved = LibraryConversationLists.saved(store.savedSessions)
        if saved.isEmpty {
          Text("No saved conversations yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(saved) { session in
            ConversationSidebarRow(
              session: session, reference: references[session.sessionId],
              isSelected: selectedSessionId == session.sessionId,
              transcription: scheduler.state(for: session.sessionId)
            )
            .tag(session.sessionId)
            .contextMenu {
              Button("Rename…") {
                store.beginRename(session)
              }
              Button("Move to Trash…", role: .destructive) {
                requestDeletion(session)
              }
              .disabled(!liveRecording.canStart || session.deletionUnavailableReason != nil)
              .help(session.deletionUnavailableReason ?? "Move this conversation to Trash.")
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onDeleteCommand {
      // Delete (or Edit > Delete) moves the selected saved conversation to
      // Trash through the same confirmation as the context menu.
      guard liveRecording.canStart,
        let session = store.savedSessions.first(where: { $0.sessionId == selectedSessionId })
      else { return }
      requestDeletion(session)
    }
    .navigationTitle("Library")
  }

  @ViewBuilder
  private var selectedWorkspace: some View {
    VStack(spacing: 0) {
      statusBanner
      if let selectedSession {
        if selectedSession.sessionId == store.currentSession?.sessionId,
          selectedSession.lifecycle != "interrupted"
        {
          CompactLiveView(store: store, liveRecording: liveRecording, context: context)
        } else {
          ConversationWorkspaceView(
            session: selectedSession,
            store: store,
            playbackController: recoveredSessions,
            transcripts: transcripts,
            speech: speech,
            scheduler: scheduler,
            reference: conversationReferences[selectedSession.sessionId],
            audioReviewRequest: navigation.audioReviewRequest,
            canStartNewRecording: MainWorkspaceActions.canRecord(
              liveCanStart: liveRecording.canStart, importIsBusy: importedMediaAuthority.isBusy
            ),
            newRecordingUnavailableReason: importedMediaAuthority.isBusy
              ? "Wait for the current import to finish before starting a new recording."
              : liveRecording.isLaunchRecoveryPending()
                ? liveRecording.readinessText
                : "Finish the current recording action before starting a new recording.",
            onStartNewRecording: startRecording,
            loadRecorderEvents: { (try? liveRecording.detail(sessionId: $0).events) ?? [] }
          )
          .id(selectedSession.sessionId)
        }
      } else {
        EmptyConversationWorkspace(
          canRecord: MainWorkspaceActions.canRecord(
            liveCanStart: liveRecording.canStart,
            importIsBusy: importedMediaAuthority.isBusy
          ),
          canImport: canImport,
          onRecord: startRecording,
          onOpenPackage: openPackageAction
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay(alignment: .top) {
      dropConfirmation
    }
    .overlay(alignment: .bottom) {
      VStack(spacing: 0) {
        importedReview
        importedPlayback
        renameConfirmation
        deletionConfirmation
      }
    }
  }

  /// Speaker review, correction, and export are created with the first layout.
  /// The workspace that would hold them appears only after a session is selected.
  private var importedReview: some View {
    ImportedReviewMount(
      store: store,
      navigation: navigation,
      transcripts: transcripts,
      scheduler: scheduler,
      speakerActions: speakerActions,
      correctionActions: correctionActions,
      exportDestination: exportTranscriptDestination
    )
    .frame(maxWidth: .infinity)
    .frame(height: 420)
  }

  /// The imported Play control is created with the first layout. The workspace
  /// that would hold it appears only after a confirmed drop selects a session.
  private var importedPlayback: some View {
    ImportedPlaybackMount(
      store: store, navigation: navigation, playback: recoveredSessions
    )
    .frame(maxWidth: .infinity)
    .frame(height: 44)
  }

  /// Pending deletion is published after the first layout. A SwiftUI
  /// confirmation sheet from that change does not appear in the hosting view
  /// that is already on screen. This strip is created with the first layout.
  /// The title field is created with the first layout. A SwiftUI sheet opened
  /// after that layout does not appear in the hosting view already on screen.
  private var renameConfirmation: some View {
    RenameConfirmationMount(store: store)
      .frame(maxWidth: .infinity)
      .frame(height: 112)
  }

  private var deletionConfirmation: some View {
    DeletionConfirmationMount(transcripts: transcripts) {
      store.refresh()
    }
    .frame(maxWidth: .infinity)
    .frame(height: 96)
  }

  private var dropConfirmation: some View {
    DropConfirmationMount(authority: importedMediaAuthority)
      .frame(maxWidth: .infinity)
      .frame(height: 44)
  }

  @ViewBuilder
  private var statusBanner: some View {
    if !workspaceNotices.isEmpty {
      VStack(spacing: 0) {
        ForEach(workspaceNotices) { notice in
          HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.related) {
            Image(systemName: notice.isFailure ? "exclamationmark.triangle" : "checkmark.circle")
              .foregroundStyle(notice.isFailure ? Color.red : Color.secondary)
            Text(notice.message)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.callout)
          .foregroundStyle(notice.isFailure ? Color.primary : Color.secondary)
          .padding(.horizontal, ScribeSpacing.standard)
          .padding(.vertical, ScribeSpacing.related)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(notice.isFailure ? "Problem" : "Status"): \(notice.message)"
          )
        }
      }
      .background(.bar)
    }
  }

  private var captureButton: some View {
    Group {
      if liveRecording.canStop {
        ToolbarStopMount(
          onStop: {
            Task {
              await liveRecording.stop()
              store.refresh()
            }
          }
        )
        .frame(width: 180, height: 32)
      } else {
        ToolbarRecordMount(
          enabled: MainWorkspaceActions.canRecord(
            liveCanStart: liveRecording.canStart,
            importIsBusy: importedMediaAuthority.isBusy),
          help: "Record \(liveRecording.captureSelection.recordedAudio)",
          onRecord: startRecording
        )
        .frame(width: 120, height: 32)
      }
    }
  }

  @ViewBuilder
  private var importButton: some View {
    if importedMediaAuthority.hasPendingAudioImports
      || !importedMediaAuthority.failedImports.isEmpty
    {
      ImportBatchStatus(imports: importedMediaAuthority, canResume: liveRecording.canStart)
    }
    if !importedMediaAuthority.hasPendingAudioImports, importedMediaAuthority.canOpenPackages {
      Menu(
        importedMediaAuthority.isBusy ? "Importing…" : "Import",
        systemImage: "square.and.arrow.down"
      ) {
        openPackageButton
      }
      .disabled(!canImport)
      .help(
        canImport
          ? ImportedMediaAuthorityAdapter.importLimitHelp
          : liveRecording.isLaunchRecoveryPending()
            ? "Wait for the check of recordings from the last session to finish before importing audio"
            : "Wait for the current recording action to finish before importing audio"
      )
    }
  }

  private var openPackageAction: (() -> Void)? {
    guard importedMediaAuthority.canOpenPackages else { return nil }
    let authority = importedMediaAuthority
    return { authority.chooseAndOpenPackage() }
  }

  private var openPackageButton: some View {
    Button("Open Portable Package…", systemImage: "shippingbox") {
      importedMediaAuthority.chooseAndOpenPackage()
    }
    .keyboardShortcut("o", modifiers: .command)
    .disabled(!canImport)
    .help(
      canImport
        ? "Open a .openscribe package exported on another Mac as a new conversation"
        : "Wait for the current recording or import to finish before opening a package"
    )
  }

  private var canImport: Bool {
    liveRecording.canStart && !importedMediaAuthority.isBusy
      && !importedMediaAuthority.hasPendingAudioImports
  }

  private var workspaceNotices: [WorkspaceNotice] {
    var notices = [WorkspaceNotice]()
    if let message = liveRecording.errorMessage {
      notices.append(.init(id: "recording", message: message, isFailure: true))
    }
    if let message = store.errorMessage {
      notices.append(.init(id: "library", message: message, isFailure: true))
    }
    if let message = recoveredSessions.errorMessage,
      MainWorkspacePlaybackNotice.shouldPresent(
        errorSessionId: recoveredSessions.errorSessionId,
        selectedSessionId: selectedSessionId
      )
    {
      notices.append(.init(id: "playback", message: message, isFailure: true))
    }
    if importedMediaAuthority.phase == .failed,
      let message = importedMediaAuthority.statusMessage
    {
      notices.append(.init(id: "import", message: message, isFailure: true))
    } else if notices.isEmpty, importedMediaAuthority.pendingAudioImport == nil,
      let message = importedMediaAuthority.statusMessage
    {
      notices.append(.init(id: "import", message: message, isFailure: false))
    }
    if let message = transcripts.message {
      notices.append(
        .init(id: "transcripts", message: message, isFailure: transcripts.messageIsFailure))
    }
    if let message = store.editMessage, store.pendingRename == nil {
      notices.append(.init(id: "edit", message: message, isFailure: store.editMessageIsFailure))
    }
    if notices.isEmpty, liveRecording.phase == .saved,
      selectedSessionId == liveRecording.lastSavedSessionId,
      let message = liveRecording.mixdownStatus
    {
      notices.append(.init(id: "mixdown", message: message, isFailure: false))
    }
    return notices
  }

  private func startRecording() {
    Task {
      await liveRecording.start()
      store.refresh()
      synchronizeSelection(preferCurrentSession: true)
    }
  }

  private func openSearchHit(_ hit: NativeTranscriptSearchHit) {
    navigation.select(hit.sessionId)
    if let session = store.savedSessions.first(where: {
      $0.sessionId == hit.sessionId
    }) {
      recoveredSessions.playTranscriptSearchHit(hit, in: session)
    }
  }

  private func requestDeletion(_ session: RuntimeSessionPresentation) {
    guard session.deletionUnavailableReason == nil else { return }
    if recoveredSessions.activePlaybackSessionId == session.sessionId {
      recoveredSessions.stopPlayback()
    }
    Task { await transcripts.requestDeletion(sessionId: session.sessionId) }
  }

  private func synchronizeSelection(preferCurrentSession: Bool) {
    navigation.synchronize(
      currentSessionId: store.currentSession?.sessionId,
      savedSessionIds: store.savedSessions.map(\.sessionId),
      preferCurrentSession: preferCurrentSession
    )
  }
}

/// The library drop sets `pendingAudioImport` while AppKit is still laying out
/// the destination. A SwiftUI banner computed in that pass does not appear in
/// the hosting view that received the drop. This strip is created with the
/// first layout and reveals its own buttons when the pending file changes.
/// The library drop target. It reads the file URL and filename list a Finder
/// drag puts on the pasteboard, then stages those files for confirmation.
private struct AudioDropMount: NSViewRepresentable {
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

private final class AudioDropControl: NSView {
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

private struct DropConfirmationMount: NSViewRepresentable {
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

private final class DropConfirmationBannerView: NSView {
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
/// so an empty library drop does not depend on a later workspace body.
private struct ImportedPlaybackMount: NSViewRepresentable {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var navigation: MainWorkspaceNavigation
  @ObservedObject var playback: RecoveredSessionController

  func makeNSView(context: Context) -> ImportedPlaybackControl {
    let view = ImportedPlaybackControl()
    view.bind(store: store, navigation: navigation, playback: playback)
    return view
  }

  func updateNSView(_ view: ImportedPlaybackControl, context: Context) {
    view.bind(store: store, navigation: navigation, playback: playback)
  }
}

private final class ImportedPlaybackControl: NSView {
  private let message = NSTextField(labelWithString: "")
  private let playButton = NSButton(title: "Play", target: nil, action: nil)
  private var subscriptions: [AnyCancellable] = []
  private var store: RuntimeLibraryStore?
  private var navigation: MainWorkspaceNavigation?
  private var playback: RecoveredSessionController?
  private var showsPlayback = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Imported playback")
    message.lineBreakMode = .byTruncatingMiddle
    message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    message.font = .preferredFont(forTextStyle: .callout)
    playButton.bezelStyle = .rounded
    playButton.setAccessibilityLabel(ConversationControlLabels.playConversationAudio(.play))
    playButton.target = self
    playButton.action = #selector(togglePlayback)
    for item in [message, playButton] {
      item.translatesAutoresizingMaskIntoConstraints = false
      addSubview(item)
    }
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ScribeSpacing.standard),
      message.centerYAnchor.constraint(equalTo: centerYAnchor),
      playButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -ScribeSpacing.standard),
      playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      message.trailingAnchor.constraint(
        lessThanOrEqualTo: playButton.leadingAnchor, constant: -ScribeSpacing.related),
    ])
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(
    store: RuntimeLibraryStore,
    navigation: MainWorkspaceNavigation,
    playback: RecoveredSessionController
  ) {
    guard self.store !== store || self.navigation !== navigation || self.playback !== playback
    else { return }
    self.store = store
    self.navigation = navigation
    self.playback = playback
    subscriptions.removeAll()
    store.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.apply() }
    }.store(in: &subscriptions)
    navigation.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.apply() }
    }.store(in: &subscriptions)
    playback.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.apply() }
    }.store(in: &subscriptions)
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard showsPlayback else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  override func draw(_ dirtyRect: NSRect) {
    guard showsPlayback else { return }
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }

  private func selectedSession() -> RuntimeSessionPresentation? {
    guard let store, let selectedSessionId = navigation?.selectedSessionId else { return nil }
    if store.currentSession?.sessionId == selectedSessionId {
      return store.currentSession
    }
    return store.savedSessions.first { $0.sessionId == selectedSessionId }
  }

  private func showsImportedPlayback(_ session: RuntimeSessionPresentation) -> Bool {
    if session.lifecycle == "ready_for_review", session.hasCaptureTimeline { return false }
    return session.playableMedia != nil
  }

  private func apply() {
    let session = selectedSession()
    let visible = session.map { self.showsImportedPlayback($0) } ?? false
    showsPlayback = visible
    message.isHidden = !visible
    playButton.isHidden = !visible
    guard let session, visible, let playback else {
      message.stringValue = ""
      playButton.isEnabled = false
      needsDisplay = true
      return
    }
    let canPlay = session.playableMedia.map(ImportedPlaybackEligibility.canPlay) ?? false
    let isPlaying = playback.playingSessionId == session.sessionId
    let isPending = playback.activePlaybackSessionId == session.sessionId && !isPlaying
    let action = PlaybackControlAction.resolve(isPending: isPending, isPlaying: isPlaying)
    playButton.title = action.title
    playButton.setAccessibilityLabel(ConversationControlLabels.playConversationAudio(action))
    playButton.isEnabled =
      action != .play
      || (canPlay
        && action.isEnabled(hasActivePlayback: playback.activePlaybackSessionId != nil))
    if isPending {
      message.stringValue = "Verifying local audio…"
    } else if playback.errorSessionId == session.sessionId,
      playback.errorRecoveredMediaIdentity == nil,
      let error = playback.errorMessage
    {
      message.stringValue = error
    } else if let media = session.playableMedia, !canPlay {
      message.stringValue = ImportedPlaybackEligibility.status(media)
    } else {
      message.stringValue =
        session.playableMedia?.sourceDisplayName ?? "Playback uses the imported local audio file."
    }
    needsDisplay = true
    layoutSubtreeIfNeeded()
  }

  @objc private func togglePlayback() {
    guard let playback, let session = selectedSession(), showsImportedPlayback(session) else {
      return
    }
    let activeSessionId = playback.activePlaybackSessionId
    Task { @MainActor in
      if activeSessionId == session.sessionId {
        playback.stopPlayback()
      } else {
        playback.play(session)
      }
    }
  }
}

private struct WorkspaceNotice: Identifiable {
  let id: String
  let message: String
  let isFailure: Bool
}

@MainActor
final class MainWorkspaceNavigation: ObservableObject {
  struct AudioReviewRequest: Equatable {
    let sessionId: String
    let id = UUID()
  }

  @Published private(set) var selectedSessionId: String?
  @Published private(set) var audioReviewRequest: AudioReviewRequest?
  private(set) var pendingImportedSessionId: String?

  func select(_ sessionId: String?) {
    guard selectedSessionId != sessionId else { return }
    selectedSessionId = sessionId
    audioReviewRequest = nil
  }

  func reviewPreservedAudio(sessionId: String) {
    select(sessionId)
    audioReviewRequest = AudioReviewRequest(sessionId: sessionId)
  }

  func synchronize(
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) {
    let resolved = MainWorkspaceSelection.resolve(
      selectedSessionId: selectedSessionId,
      currentSessionId: currentSessionId,
      savedSessionIds: savedSessionIds,
      preferCurrentSession: preferCurrentSession
    )
    select(resolved)
    reconcileImportedConversation(savedSessionIds: savedSessionIds)
  }

  func acceptImportedConversation(_ sessionId: String?, savedSessionIds: [String]) {
    pendingImportedSessionId = sessionId
    reconcileImportedConversation(savedSessionIds: savedSessionIds)
  }

  private func reconcileImportedConversation(savedSessionIds: [String]) {
    let resolution = MainWorkspaceSelection.reconcileImportedConversation(
      pendingImportedSessionId: pendingImportedSessionId,
      selectedSessionId: selectedSessionId,
      savedSessionIds: savedSessionIds
    )
    select(resolution.selectedSessionId)
    pendingImportedSessionId = resolution.pendingImportedSessionId
  }
}

enum MainWorkspaceSelection {
  struct ImportedConversationResolution: Equatable {
    let selectedSessionId: String?
    let pendingImportedSessionId: String?
  }

  static func resolve(
    selectedSessionId: String?,
    currentSessionId: String?,
    savedSessionIds: [String],
    preferCurrentSession: Bool
  ) -> String? {
    if preferCurrentSession, let currentSessionId {
      return currentSessionId
    }

    let availableSessionIds = Set(savedSessionIds + [currentSessionId].compactMap { $0 })
    if let selectedSessionId, availableSessionIds.contains(selectedSessionId) {
      return selectedSessionId
    }
    return currentSessionId ?? savedSessionIds.first
  }

  static func shouldStopDetachedPlayback(
    activePlaybackSessionId: String?,
    selectedSessionId: String?
  ) -> Bool {
    guard let activePlaybackSessionId else { return false }
    return activePlaybackSessionId != selectedSessionId
  }

  static func reconcileImportedConversation(
    pendingImportedSessionId: String?,
    selectedSessionId: String?,
    savedSessionIds: [String]
  ) -> ImportedConversationResolution {
    guard let pendingImportedSessionId else {
      return ImportedConversationResolution(
        selectedSessionId: selectedSessionId,
        pendingImportedSessionId: nil
      )
    }
    guard savedSessionIds.contains(pendingImportedSessionId) else {
      return ImportedConversationResolution(
        selectedSessionId: selectedSessionId,
        pendingImportedSessionId: pendingImportedSessionId
      )
    }
    return ImportedConversationResolution(
      selectedSessionId: pendingImportedSessionId,
      pendingImportedSessionId: nil
    )
  }
}

enum MainWorkspaceActions {
  static func canRecord(liveCanStart: Bool, importIsBusy: Bool) -> Bool {
    liveCanStart && !importIsBusy
  }
}

enum MainWorkspacePlaybackNotice {
  static func shouldPresent(errorSessionId: String?, selectedSessionId: String?) -> Bool {
    errorSessionId == nil || errorSessionId == selectedSessionId
  }
}

enum PlaybackControlAction: Equatable, Sendable {
  case play
  case cancel
  case stop

  static func resolve(isPending: Bool, isPlaying: Bool) -> Self {
    if isPlaying { return .stop }
    if isPending { return .cancel }
    return .play
  }

  var title: String {
    switch self {
    case .play: "Play"
    case .cancel: "Cancel"
    case .stop: "Stop"
    }
  }

  func isEnabled(hasActivePlayback: Bool) -> Bool {
    self != .play || !hasActivePlayback
  }
}

enum ImportedPlaybackEligibility {
  static func canPlay(_ media: RuntimePlayableMediaPresentation) -> Bool {
    media.isPlayable
  }

  static func status(_ media: RuntimePlayableMediaPresentation) -> String {
    return media.statusText
  }
}

enum LibraryConversationLists {
  static func saved(_ sessions: [RuntimeSessionPresentation]) -> [RuntimeSessionPresentation] {
    sessions.filter { $0.lifecycle == "ready_for_review" }
  }

  static func interrupted(_ sessions: [RuntimeSessionPresentation]) -> [RuntimeSessionPresentation]
  {
    sessions.filter { $0.lifecycle == "interrupted" || $0.captureRecoveryIsolated }
  }
}

struct ConversationSidebarRow: View {
  let session: RuntimeSessionPresentation
  let reference: String?
  let isSelected: Bool
  var transcription: TranscriptionJobState?

  private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

  private var secondaryText: Color { isSelected ? selectedText : .secondary }

  private var hasMediaWarning: Bool { session.playableMedia.map { !$0.isPlayable } ?? false }

  var statusSymbolName: String? {
    if session.isRecording { return "record.circle.fill" }
    if session.needsAttention || hasMediaWarning { return "exclamationmark.triangle" }
    if transcriptLine?.symbol == "exclamationmark.circle" { return "exclamationmark.circle" }
    return nil
  }

  /// Transcript posture for saved conversations only: the store's committed
  /// state, or the scheduler's position for work that has not started.
  private var transcriptLine: (symbol: String, text: String)? {
    guard session.lifecycle == "ready_for_review", session.transcriptionUnavailableReason == nil,
      session.transcript.hasTranscribableAudio
    else { return nil }
    return session.transcript.line(for: transcription)
  }

  var detailStatusText: String {
    if let transcriptLine, !session.needsAttention, !hasMediaWarning { return transcriptLine.text }
    return session.statusText
  }

  var body: some View {
    let title = ConversationIdentityPresentation.title(session.title)
    HStack(alignment: .firstTextBaseline, spacing: ScribeSpacing.related) {
      if let symbolName = statusSymbolName {
        if isSelected {
          Image(systemName: symbolName)
        } else {
          Image(systemName: symbolName)
            .foregroundStyle(session.isRecording ? Color.red : Color.orange)
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: ScribeSpacing.related) {
          Text(title)
            .lineLimit(1)
            .truncationMode(.middle)
          if let reference {
            Text(reference)
              .font(.caption.monospaced())
              .foregroundStyle(secondaryText)
              .fixedSize()
          }
        }
        HStack(spacing: 6) {
          Text(session.timerText).monospacedDigit()
          Text("·")
          Text(detailStatusText)
        }
        .font(.caption)
        .foregroundStyle(secondaryText)
        .lineLimit(1)
      }
    }
    .padding(.vertical, 6)
    .foregroundStyle(isSelected ? selectedText : .primary)
    .accessibilityElement(children: .combine)
    .help(session.title)
    .accessibilityLabel(
      "\(title), \(session.timerText), \(session.statusText)"
        + (transcriptLine.map { ", \($0.text)" } ?? "")
        + (reference.map { ", reference \($0)" } ?? "")
    )
  }
}

/// What the app is doing for the library right now and what the Mac has to
/// give it. Every figure is a macOS measurement; the line is silent when
/// nothing is queued and nothing is scarce.
struct LibraryActivityFooter: View {
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var pressure: SystemPressureMonitor
  let titles: [String: String]

  private var activityText: String? {
    scheduler.summaryText(titles: titles, progress: speech.progressFraction)
  }

  private var pressureText: String {
    var parts: [String] = []
    if pressure.reading.diskIsLow { parts.append(pressure.reading.diskText) }
    if pressure.reading.memoryPressure != .normal {
      parts.append(pressure.reading.memoryText)
    }
    if pressure.reading.thermalState != .nominal {
      parts.append(pressure.reading.thermalText)
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    if activityText != nil || !pressureText.isEmpty {
      VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
        Divider()
        VStack(alignment: .leading, spacing: ScribeSpacing.tight) {
          if let activityText {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Image(systemName: scheduler.runningSessionId != nil ? "ellipsis.circle" : "clock")
              Text(activityText)
                .fixedSize(horizontal: false, vertical: true)
            }
            if scheduler.runningSessionId != nil, let fraction = speech.progressFraction {
              ProgressView(value: fraction)
                .controlSize(.small)
                .accessibilityLabel("Transcription progress")
            }
          }
          if !pressureText.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Image(systemName: "exclamationmark.triangle")
              Text(pressureText)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .font(.caption)
        .foregroundStyle(!pressureText.isEmpty ? .primary : .secondary)
        .padding(.horizontal, ScribeSpacing.standard)
        .padding(.vertical, ScribeSpacing.related)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Library activity. " + (activityText.map { "\($0). " } ?? "") + pressureText)
    }
  }
}

private struct EmptyConversationWorkspace: View {
  let canRecord: Bool
  let canImport: Bool
  let onRecord: () -> Void
  let onOpenPackage: (() -> Void)?

  var body: some View {
    VStack(spacing: ScribeSpacing.standard) {
      Text("No conversation is open")
        .font(.title.weight(.bold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "Record a conversation, choose Audio Files, or drop a CAF or M4A file and confirm it. Your recordings stay on this Mac."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 440)
      HStack {
        RecordStartMount(enabled: canRecord, onRecord: onRecord)
          .frame(width: 120, height: 32)
        if let onOpenPackage {
          Button("Portable Package…", action: onOpenPackage)
            .disabled(!canImport)
        }
      }
      .controlSize(.large)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}

/// The toolbar's Stop and Save control. The button is created with the first
/// layout and calls the same stop the menu uses.
private struct ToolbarStopMount: NSViewRepresentable {
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

private final class ToolbarStopControl: NSView {
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
private struct ToolbarRecordMount: NSViewRepresentable {
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

private final class ToolbarRecordControl: NSView {
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

/// The empty library's Record control. The button is created with the first
/// layout and calls the same start the toolbar uses.
private struct RecordStartMount: NSViewRepresentable {
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

private final class RecordStartControl: NSView {
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
private final class LibrarySearchState: ObservableObject {
  @Published var query = ""
}

/// Search field created with the sidebar. Assigning `stringValue` delivers the
/// query on that turn; AppKit does not send `controlTextDidChange` for it.
private struct LibrarySearchMount: NSViewRepresentable {
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

private final class LibrarySearchField: NSSearchField, NSSearchFieldDelegate {
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
private struct SearchResultMount: NSViewRepresentable {
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

private final class SearchResultBanner: NSView {
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
    let next = hits.map { hit -> String in
      let reference = references[hit.sessionId] ?? ""
      return "\(hit.sessionId)#\(hit.sequence)\n\(hit.sessionTitle)\n\(reference)\n\(hit.effectiveText)"
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
      let title = ConversationIdentityPresentation.title(hit.sessionTitle)
      let reference = references[hit.sessionId]
      let key = "\(hit.sessionId)#\(hit.sequence)"
      let button = NSButton(title: hit.effectiveText, target: self, action: #selector(openHit(_:)))
      button.bezelStyle = .rounded
      button.alignment = .left
      button.lineBreakMode = .byTruncatingTail
      button.setAccessibilityLabel(
        "\(title)\(reference.map { ", reference \($0)" } ?? ""): \(hit.effectiveText)"
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
private struct DeletionRequestMount: NSViewRepresentable {
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

private final class DeletionRequestControl: NSView {
  private let button = NSButton(title: "Move to Trash…", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var store: RuntimeLibraryStore?
  private var liveRecording: LiveMicrophoneRecordingController?
  private var navigation: MainWorkspaceNavigation?
  private var onRequest: ((RuntimeSessionPresentation) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Delete conversation")
    button.bezelStyle = .rounded
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
private struct DeletionConfirmationMount: NSViewRepresentable {
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

private final class DeletionConfirmationBanner: NSView {
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
private struct AudioFileImportMount: NSViewRepresentable {
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

private final class AudioFileImportControl: NSView {
  private let chooseButton = NSButton(
    title: ConversationControlLabels.audioFiles, target: nil, action: nil)
  private var subscriptions: [AnyCancellable] = []
  private var authority: ImportedMediaAuthorityAdapter?
  private var recording: LiveMicrophoneRecordingController?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Audio file import")
    chooseButton.bezelStyle = .rounded
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
private struct RenameRequestMount: NSViewRepresentable {
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

private final class RenameRequestControl: NSView {
  private let button = NSButton(title: "Rename…", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var store: RuntimeLibraryStore?
  private var liveRecording: LiveMicrophoneRecordingController?
  private var navigation: MainWorkspaceNavigation?
  private var onRequest: ((RuntimeSessionPresentation) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Rename conversation")
    button.bezelStyle = .rounded
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
private struct RenameConfirmationMount: NSViewRepresentable {
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

private final class RenameConfirmationBanner: NSView, NSTextFieldDelegate {
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
      titleField.stringValue = ConversationIdentityPresentation.title(pending.title)
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
