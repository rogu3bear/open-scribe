import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A saved or interrupted conversation, typeset as an interview. The first
/// viewport answers what it was, who spoke, and how to take it elsewhere:
/// the title, one line of facts, Copy, Play, and the text. The record behind
/// it (sources, provenance, exports, events) lives in Details.
struct ConversationWorkspaceView: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var playbackController: RecoveredSessionController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  let reference: String?
  let audioReviewRequest: MainWorkspaceNavigation.AudioReviewRequest?
  let canStartNewRecording: Bool
  let newRecordingUnavailableReason: String
  let onStartNewRecording: () -> Void
  let loadRecorderEvents: @MainActor (String) -> [NativeRecorderEvent]
  @ObservedObject var suggestions: ConversationSuggestionModel = .inert
  /// Markdown and the other transcript formats ask for a destination. The
  /// panel is the shipped default; a hosted proof supplies a file URL.
  var exportDestination: @MainActor (String) -> URL? = ConversationExportPanel.choose
  /// The window's own notices, set in this document's notice position.
  var windowNotices: WindowNotices = .none

  @AppStorage(ConversationWorkspaceView.detailsDefaultsKey) private var showsDetails = false
  @StateObject private var speakerActions = SpeakerActionController()
  @StateObject private var correctionActions = CorrectionActionController()
  @State private var recorderEvents: [NativeRecorderEvent] = []
  @State private var editingDetails: ConversationMetadataPresentation?
  @State private var contextSeek: ContextSeekRequest?
  @State private var copyNote: String?

  static let detailsDefaultsKey = "OpenScribeShowsConversationDetails"

  private var title: String { ConversationIdentityPresentation.title(for: session) }
  /// This conversation's document, once the model holds it.
  private var loaded: LoadedConversation? { transcripts.loaded(session.sessionId) }
  private var actions: ConversationActions {
    ConversationActions(
      store: store, transcripts: transcripts, playback: playbackController,
      recorderIdle: canStartNewRecording)
  }
  private var canSeek: Bool {
    session.hasCaptureTimeline || session.playableMedia?.isPlayable == true
  }
  private var hasPreservedAudio: Bool {
    session.hasVerifiedPreservedAudio(from: playbackController.sessions)
  }

  var body: some View {
    HStack(spacing: 0) {
      document
      if showsDetails {
        Divider()
        ConversationDetailsPanel(
          session: session, store: store, playbackController: playbackController,
          transcripts: transcripts, speech: speech, scheduler: scheduler,
          recorderEvents: recorderEvents, reference: reference,
          onEditDetails: {
            store.dismissEditMessage()
            editingDetails = ConversationMetadataPresentation(session: session)
          },
          onSeek: seek,
          onContextSeek: { event in
            contextSeek = ContextSeekRequest(sessionId: session.sessionId, event: event)
          }
        )
        .frame(width: 340)
        .transition(.move(edge: .trailing))
      }
    }
    .navigationTitle(title)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Toggle(isOn: $showsDetails.animation(.easeOut(duration: 0.2))) {
          Label("Details", systemImage: "sidebar.right")
        }
        .help(showsDetails ? "Hide Details" : "Show Details: sources, provenance, and exports")
        .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }
    // One read per document identity; Details reads the same document.
    .task(id: TranscriptLibraryModel.documentIdentity(session)) {
      await transcripts.open(session)
      suggestions.considerOpen(session)
    }
    .task(id: "\(session.sessionId)|\(contextSeek?.id.uuidString ?? "")") {
      guard let request = contextSeek, request.sessionId == session.sessionId else { return }
      // The view task is cancelled on replacement or disappearance, including
      // navigation to a live/interrupted view that does not load a transcript.
      if let start = await transcripts.contextEvidenceStart(request.event, in: request.sessionId),
        !Task.isCancelled, contextSeek?.id == request.id
      {
        playbackController.playSynchronized(sessionId: request.sessionId, startNanoseconds: start)
      }
    }
    .task(id: "\(session.sessionId)|\(session.lifecycle)") {
      recorderEvents = loadRecorderEvents(session.sessionId)
    }
    .task(id: audioReviewRequest) {
      guard audioReviewRequest?.sessionId == session.sessionId, hasPreservedAudio else { return }
      showsDetails = true
    }
    .onChange(of: transcripts.claimFocusGeneration) { _ in
      if transcripts.focusedClaim != nil { showsDetails = true }
    }
    .sheet(item: $editingDetails) { presentation in
      ConversationDetailsSheet(
        session: presentation.session,
        declaration: transcripts.loaded(presentation.session.sessionId)?.contextDetail?
          .declaration,
        store: store,
        onSaved: {
          Task { await transcripts.reloadAfterDetailsSave(session: presentation.session) }
        },
        onClose: { presentation.close(&editingDetails) })
    }
    .speechModelSheet(speech, in: .conversation)
  }

  // MARK: Document

  private var document: some View {
    ScrollViewReader { proxy in
      ScrollView {
        InterviewColumn {
          VStack(alignment: .leading, spacing: 0) {
            header
              .padding(.top, 36)
            notices
              .padding(.top, 16)
            markers
            if session.needsAttention, !session.didNotRecord {
              keptAudio
                .padding(.top, 18)
            }
            InterviewRule()
              .padding(.top, 24)
              .padding(.bottom, 22)
            transcript(proxy: proxy)
          }
          .padding(.bottom, 72)
        }
      }
      .background(Interview.paper)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if ReviewTrayMount.isOpen(
          speakerActions: speakerActions, correctionActions: correctionActions)
        {
          reviewTray
        }
      }
    }
    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
  }

  private var reviewTray: some View {
    VStack(spacing: 0) {
      InterviewRule()
      ReviewTrayMount(
        transcripts: transcripts, speakerActions: speakerActions,
        correctionActions: correctionActions, sessionId: session.sessionId,
        suggestedNames: suggestions.suggestions[session.sessionId]?.people ?? []
      )
      .frame(maxWidth: Interview.measure, alignment: .leading)
      .padding(.horizontal, Interview.pageMargin)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(.regularMaterial)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HostedText(
        text: title, label: "Conversation name", font: .interviewTitle(30),
        color: NSColor(Interview.ink), maximumLines: 3, isSelectable: true,
        help: "Double-click to rename", onDoubleClick: { actions.rename(session) })
      InterviewFacts(items: facts)
      if session.titleSource == .suggested {
        HStack(spacing: 10) {
          Text("Title suggested from the conversation.")
            .font(.system(size: 12))
            .foregroundStyle(Interview.quiet)
          Button("Keep") { actions.keepTitle(session) }
            .help("Keep this title. Open Scribe will not change it again.")
          Button("Rename…") { actions.rename(session) }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
      }
      actionRow
        .padding(.top, 10)
    }
  }

  private var facts: [String] {
    var items: [String] = []
    if let created = session.createdAt {
      items.append(created.formatted(date: .abbreviated, time: .shortened))
    }
    if let length = session.lengthText { items.append(length) }
    if let people = loaded?.people, !people.isEmpty {
      items.append(ListFormatter.localizedString(byJoining: people))
    }
    if session.playableMedia != nil, !session.hasCaptureTimeline { items.append("Imported") }
    if let reference { items.append(reference) }
    return items
  }

  // MARK: Actions

  private var actionRow: some View {
    HStack(spacing: 10) {
      copyButton
      if session.hasCaptureTimeline || session.playableMedia != nil {
        let play = actions.playback(for: session)
        HostedButton(
          title: play.action.title, symbol: play.action == .play ? "play.fill" : "stop.fill",
          identifier: "Conversation playback",
          label: ConversationControlLabels.playConversationAudio(play.action), style: .large,
          isEnabled: play.isEnabled, isHidden: !play.isAvailable
        ) { actions.togglePlayback(session) }
      }
      if let copyNote {
        Label(copyNote, systemImage: "checkmark")
          .font(Interview.meta)
          .foregroundStyle(Interview.quiet)
          .transition(.opacity)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 12)
      HostedButton(
        title: "Export…", label: ConversationControlLabels.exportTranscript,
        help: "Save the transcript as Markdown, plain text, subtitles, or JSON", style: .large,
        isEnabled: actions.canExport(session), isHidden: loaded?.segments.isEmpty ?? true
      ) { actions.export(session, choose: exportDestination) }
    }
  }

  private var copyButton: some View {
    HStack(spacing: 1) {
      Button {
        copy(timestamps: true)
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
          .padding(.horizontal, 4)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .help("Copy the conversation with names and times, ready to paste (⇧⌘C)")
      .accessibilityLabel("Copy conversation")
      Menu {
        Button("Copy with Timestamps") { copy(timestamps: true) }
        Button("Copy Text Only") { copy(timestamps: false) }
          .keyboardShortcut("c", modifiers: [.command, .option, .shift])
      } label: {
        Image(systemName: "chevron.down")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .padding(.leading, 4)
      .accessibilityLabel("Copy options")
    }
    .disabled(!actions.canCopy(session))
  }

  private func copy(timestamps: Bool) {
    let session = session
    Task {
      guard let note = await actions.copy(session, timestamps: timestamps) else {
        withAnimation { copyNote = "Could not copy" }
        return
      }
      withAnimation(.easeOut(duration: 0.15)) { copyNote = note }
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      withAnimation(.easeOut(duration: 0.4)) {
        if copyNote == note { copyNote = nil }
      }
    }
  }

  // MARK: Notices

  /// The window's notices first, then this conversation's own.
  private var notices: some View {
    VStack(alignment: .leading, spacing: 0) {
      WindowNoticeList(notices: windowNotices)
      conversationNotices
    }
  }

  private var conversationNotices: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let attention = session.interruptionText {
        InterviewNotice(
          message: attention,
          isProblem: !session.didNotRecord,
          actions: session.lifecycle == .interrupted && canStartNewRecording
            ? [("Start New Recording", onStartNewRecording)] : [])
      }
      if playbackController.errorSessionId == session.sessionId,
        playbackController.errorRecoveredMediaIdentity == nil,
        let message = playbackController.errorMessage
      {
        InterviewNotice(message: message, isProblem: true)
      } else if playbackController.activePlaybackSessionId == session.sessionId,
        playbackController.playingSessionId != session.sessionId
      {
        InterviewNotice(message: "Checking the local audio before it plays…")
      } else if let media = session.playableMedia, !media.isPlayable {
        InterviewNotice(message: media.statusText)
      }
      if session.lifecycle == .readyForReview {
        TranscriptStatusNotice(
          session: session, transcripts: transcripts, speech: speech, scheduler: scheduler,
          onSetUp: { speech.showModels(in: .conversation) })
        nameSuggestion
      }
    }
  }

  /// Computer audio carries the other participants (founding PRD 11.3).
  private static func carriesOthers(_ kind: NativeTrackSourceKind) -> Bool {
    switch kind {
    case .systemAudio, .applicationAudio: true
    case .microphone, .importedAudio: false
    }
  }

  @ViewBuilder private var nameSuggestion: some View {
    if let loaded, !suggestions.dismissedNames.contains(session.sessionId),
      let suggestion = suggestions.suggestions[session.sessionId],
      let name = suggestion.othersName,
      let others = loaded.speakers.first(where: {
        Self.carriesOthers($0.sourceKind) && !$0.namedByUser && $0.label != name
      })
    {
      InterviewNotice(
        message: "“\(others.label)” sounds like \(name).",
        actions: [
          (
            "Use “\(name)”",
            {
              let sessionId = session.sessionId
              Task {
                _ = await transcripts.renameSpeaker(
                  trackId: others.trackId, label: name, in: sessionId)
              }
            }
          ),
          ("Not Now", { suggestions.dismissNames(sessionId: session.sessionId) }),
        ])
    }
  }

  /// The audio a stopped recording kept, on its page while it needs attention.
  @ViewBuilder private var keptAudio: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Audio")
        .font(Interview.sectionLabel)
        .foregroundStyle(Interview.quiet)
        .accessibilityAddTraits(.isHeader)
      ConversationAudioList(
        session: session, playbackController: playbackController, showsMix: false)
      if session.lifecycle == .interrupted, !hasPreservedAudio {
        Text(
          playbackController.phase == .scanning
            ? "Looking for the saved audio…"
            : playbackController.phase == .failed
              ? "Open Scribe couldn't look for the saved audio. Try again after restarting Open Scribe."
              : "The saved audio plays after Open Scribe restarts and recovers it."
        )
        .font(Interview.meta)
        .foregroundStyle(Interview.quiet)
        .fixedSize(horizontal: false, vertical: true)
      }
      if session.lifecycle == .interrupted, !canStartNewRecording {
        Text(newRecordingUnavailableReason)
          .font(Interview.meta)
          .foregroundStyle(Interview.quiet)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Transcript

  @ViewBuilder private func transcript(proxy: ScrollViewProxy) -> some View {
    if session.lifecycle != .readyForReview {
      EmptyView()
    } else if TranscriptSection.showsReader(session: session, transcripts: transcripts) {
      TranscriptReader(
        sessionId: session.sessionId, transcripts: transcripts, canSeek: canSeek,
        isPlaybackActive: playbackController.canFollowTranscriptPlayback(
          sessionId: session.sessionId),
        playbackPosition: {
          playbackController.transcriptPlaybackPosition(sessionId: session.sessionId)
        },
        onSeek: seek,
        onFollowPlayback: { id in
          withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo("transcript-\(id)", anchor: .center)
          }
        },
        speakerActions: speakerActions,
        correctionActions: correctionActions
      )
      .id(session.sessionId)
    } else if loaded == nil || transcripts.isLoading {
      ProgressView()
        .controlSize(.small)
    } else {
      Text(
        session.transcriptionUnavailableReason
          ?? "The transcript will appear here when it is ready."
      )
      .font(Interview.speech())
      .foregroundStyle(Interview.quiet)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func seek(_ position: Int64) {
    // Captures seek on the shared timeline; imports within their media.
    if session.hasCaptureTimeline {
      playbackController.playSynchronized(sessionId: session.sessionId, startNanoseconds: position)
    } else {
      playbackController.play(session, startNanoseconds: position)
    }
  }

  /// Saved markers. Each plays from its moment when the conversation has
  /// playable audio.
  private var markers: some View {
    let markers = recorderEvents.filter { $0.kind == .markerAdded }
    let positions = Dictionary(
      markers.map { ($0.id, $0.sessionNanoseconds) }, uniquingKeysWith: { first, _ in first })
    return HostedList(
      heading: "Markers", identifier: "Markers",
      rows: markers.map { marker in
        let stamp = TranscriptSection.timestamp(marker.sessionNanoseconds)
        return HostedListRow(
          id: marker.id, lead: stamp, detail: marker.label.isEmpty ? "Marker" : marker.label,
          label: ConversationControlLabels.markerAccessibility(
            stamp: stamp, label: marker.label, canSeek: canSeek),
          isEnabled: canSeek)
      },
      lead: .stampButton,
      onSelect: { id in if let start = positions[id] { seek(start) } }
    )
    .padding(.top, markers.isEmpty ? 0 : 18)
  }
}

extension ConversationSuggestionModel {
  /// A model that never suggests, for documents shown outside the library.
  @MainActor static let inert = ConversationSuggestionModel(
    library: { throw NativeStorageError.InvalidState }, suspended: true)
}

/// What the transcript is waiting for, in one line, with the one useful action.
struct TranscriptStatusNotice: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  let onSetUp: () -> Void

  var body: some View {
    let job = scheduler.state(for: session.sessionId)
    let context = TranscriptStatusPresentation.Context(
      job: job, isTranscribingHere: speech.transcribingSessionId == session.sessionId,
      loaded: transcripts.loaded(session.sessionId)?.availability,
      modelInstalled: speech.installedModel != nil, modelChecking: speech.isRefreshing,
      automatic: scheduler.isAutomatic, paused: scheduler.isPaused,
      canPrioritize: scheduler.canPrioritize(sessionId: session.sessionId))
    if let notice = TranscriptStatusPresentation.notice(session: session, context: context) {
      if notice.showsProgress {
        HStack(spacing: 10) {
          ProgressView(value: speech.progressFraction ?? 0)
            .progressViewStyle(.linear)
            .frame(width: 120)
          Text(notice.message)
            .font(Interview.meta)
            .foregroundStyle(Interview.quiet)
          if let action = notice.action {
            Button(action.title) { perform(action) }
              .buttonStyle(.link)
              .font(Interview.meta)
          }
        }
        .accessibilityElement(children: .combine)
      } else {
        InterviewNotice(
          message: notice.message, isProblem: notice.isProblem,
          actions: notice.action.map { action in [(action.title, { perform(action) })] } ?? [])
      }
    }
  }

  private func perform(_ action: TranscriptStatusPresentation.Action) {
    switch action {
    case .cancel: scheduler.cancel(sessionId: session.sessionId)
    case .transcribeNow, .transcribe, .tryAgain: scheduler.request(sessionId: session.sessionId)
    case .setUp: onSetUp()
    }
  }
}

/// The transcript export dialog: one save panel whose format menu picks
/// Markdown, plain text, subtitles, or JSON. The chosen file's extension
/// decides the format, so a hosted proof can pass a `.md` URL directly.
enum ConversationExportPanel {
  static let formats: [(title: String, ext: String, format: NativeTranscriptExportFormat)] = [
    ("Markdown", "md", .markdown),
    ("Plain Text", "txt", .plainText),
    ("SubRip Subtitles", "srt", .subRip),
    ("WebVTT Subtitles", "vtt", .webVtt),
    ("Transcript JSON", "json", .transcriptJson),
  ]

  static func format(for url: URL) -> NativeTranscriptExportFormat {
    formats.first { $0.ext == url.pathExtension.lowercased() }?.format ?? .markdown
  }

  @MainActor static func choose(_ suggestedName: String) -> URL? {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: formats.map(\.title))
    let selector = ExportFormatSelector(panel: panel)
    popup.target = selector
    popup.action = #selector(ExportFormatSelector.choose(_:))
    let label = NSTextField(labelWithString: "Format:")
    let row = NSStackView(views: [label, popup])
    row.orientation = .horizontal
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    panel.accessoryView = row
    let response = withExtendedLifetime(selector) { panel.runModal() }
    return response == .OK ? panel.url : nil
  }
}

@MainActor private final class ExportFormatSelector: NSObject {
  weak var panel: NSSavePanel?

  init(panel: NSSavePanel) {
    self.panel = panel
  }

  @objc func choose(_ sender: NSPopUpButton) {
    guard let panel, ConversationExportPanel.formats.indices.contains(sender.indexOfSelectedItem)
    else { return }
    let ext = ConversationExportPanel.formats[sender.indexOfSelectedItem].ext
    panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
    let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
    panel.nameFieldStringValue = "\(stem).\(ext)"
  }
}

private struct ContextSeekRequest {
  let id = UUID()
  let sessionId: String
  let event: NativeContextEvent
}
