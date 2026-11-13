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

  @AppStorage(ConversationWorkspaceView.detailsDefaultsKey) private var showsDetails = false
  @StateObject private var speakerActions = SpeakerActionController()
  @StateObject private var correctionActions = CorrectionActionController()
  @State private var recorderEvents: [NativeRecorderEvent] = []
  @State private var editingDetails: ConversationMetadataPresentation?
  @State private var contextSeek: ContextSeekRequest?
  @State private var copyNote: String?
  @State private var showingModels = false

  static let detailsDefaultsKey = "OpenScribeShowsConversationDetails"

  private var title: String { ConversationIdentityPresentation.title(for: session) }
  private var isLoaded: Bool { transcripts.sessionId == session.sessionId }
  private var canSeek: Bool {
    session.hasCaptureTimeline || session.playableMedia?.isPlayable == true
  }
  private var hasText: Bool { isLoaded && !transcripts.segments.isEmpty }
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
    .task(id: loadIdentity) {
      await transcripts.load(session: session)
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
        declaration: transcripts.sessionId == presentation.session.sessionId
          ? transcripts.contextDetail?.declaration : nil,
        store: store,
        onSaved: {
          Task { await transcripts.reloadAfterDetailsSave(session: presentation.session) }
        },
        onClose: { presentation.close(&editingDetails) })
    }
    .sheet(isPresented: $showingModels) {
      SpeechModelSheet(speech: speech) { showingModels = false }
    }
  }

  /// Launch recovery, a finished run, a correction, or new Draft windows
  /// change the document, and it rereads itself.
  private var loadIdentity: String {
    session.sessionId
      + (session.transcriptionUnavailableReason == nil ? ":timed" : ":untimed")
      + ":\(session.transcript.state.rawValue):\(session.transcript.documentVersion)"
      + ":\(session.transcript.draftWindows)"
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
              .padding(.leading, Interview.shoulder)
              .padding(.top, 16)
            MarkerListMount(
              events: recorderEvents, canSeek: canSeek, onSeek: seek
            )
            .frame(
              maxWidth: .infinity,
              minHeight: Self.markerListHeight(recorderEvents),
              alignment: .topLeading
            )
            .padding(.leading, Interview.shoulder)
            .padding(.top, recorderEvents.contains { $0.kind == "marker_added" } ? 18 : 0)
            if session.needsAttention {
              preservedAudio
                .padding(.leading, Interview.shoulder)
                .padding(.top, 18)
            }
            InterviewRule()
              .padding(.leading, Interview.shoulder)
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
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: Interview.documentWidth, alignment: .leading)
      .padding(.leading, Interview.shoulder)
      .padding(.horizontal, 28)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(.regularMaterial)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      ConversationTitleLabel(title: title) {
        store.beginRename(session)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      InterviewFacts(items: facts)
      if session.titleSource == "suggested" {
        HStack(spacing: 10) {
          Text("Title suggested from the conversation.")
            .font(.system(size: 12))
            .foregroundStyle(Interview.quiet)
          Button("Keep") {
            Task { await store.rename(sessionId: session.sessionId, title: session.displayTitle) }
          }
          .help("Keep this title. Open Scribe will not change it again.")
          Button("Rename…") { store.beginRename(session) }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
      }
      actionRow
        .padding(.top, 10)
    }
    .padding(.leading, Interview.shoulder)
  }

  private var facts: [String] {
    var items: [String] = []
    if let created = session.createdAt {
      items.append(created.formatted(date: .abbreviated, time: .shortened))
    }
    if session.elapsedSeconds > 0 {
      items.append(InterviewTime.length(seconds: session.elapsedSeconds))
    }
    if isLoaded {
      let people = peopleNames
      if !people.isEmpty { items.append(ListFormatter.localizedString(byJoining: people)) }
    }
    if session.playableMedia != nil, !session.hasCaptureTimeline { items.append("Imported") }
    if let reference { items.append(reference) }
    return items
  }

  private var peopleNames: [String] {
    var names: [String] = []
    for segment in transcripts.segments where !names.contains(segment.speakerLabel) {
      names.append(segment.speakerLabel)
    }
    return names
  }

  // MARK: Actions

  private var actionRow: some View {
    HStack(spacing: 10) {
      copyButton
      if session.hasCaptureTimeline || session.playableMedia != nil {
        ConversationPlayMount(session: session, playback: playbackController)
          .frame(width: 92, height: 30)
      }
      if let copyNote {
        Label(copyNote, systemImage: "checkmark")
          .font(Interview.meta)
          .foregroundStyle(Interview.quiet)
          .transition(.opacity)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 12)
      ExportTranscriptMount(
        enabled: hasText && !transcripts.isExporting,
        visible: hasText,
        onExport: exportTranscript
      )
      .frame(width: 92, height: 30)
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
    .disabled(!hasText)
  }

  private func copy(timestamps: Bool) {
    let sessionId = session.sessionId
    let title = title
    Task {
      do {
        let copied = try await transcripts.clipboardText(
          sessionId: sessionId, title: title,
          options: ConversationClipboard.Options(timestamps: timestamps))
        ConversationClipboard.copy(copied.text)
        let turns = copied.turns == 1 ? "1 turn" : "\(copied.turns) turns"
        let note = copied.hasDraft ? "Copied \(turns) · Draft" : "Copied \(turns)"
        AccessibilityAnnouncer.post(note)
        withAnimation(.easeOut(duration: 0.15)) { copyNote = note }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation(.easeOut(duration: 0.4)) {
          if copyNote == note { copyNote = nil }
        }
      } catch {
        withAnimation { copyNote = "Could not copy" }
        AccessibilityAnnouncer.post("The conversation could not be copied.")
      }
    }
  }

  private func exportTranscript() {
    guard hasText, !transcripts.isExporting else { return }
    let suggested = TranscriptSection.fileName(
      title, type: UTType(filenameExtension: "md") ?? .plainText)
    guard let destination = exportDestination(suggested) else { return }
    let format = ConversationExportPanel.format(for: destination)
    let sessionId = session.sessionId
    Task { await transcripts.export(format: format, to: destination, from: sessionId) }
  }

  // MARK: Notices

  private var notices: some View {
    VStack(alignment: .leading, spacing: 10) {
      if session.needsAttention {
        InterviewNotice(
          message: session.interruptionText
            ?? "Open Scribe kept the audio it could verify. Each source is listed below.",
          isProblem: true,
          actions: session.lifecycle == "interrupted" && canStartNewRecording
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
        InterviewNotice(message: ImportedPlaybackEligibility.status(media))
      }
      if session.lifecycle == "ready_for_review" {
        TranscriptStatusNotice(
          session: session, transcripts: transcripts, speech: speech, scheduler: scheduler,
          onSetUp: {
            speech.dismissMessage()
            showingModels = true
          })
        nameSuggestion
      }
    }
  }

  @ViewBuilder private var nameSuggestion: some View {
    if isLoaded, !suggestions.dismissedNames.contains(session.sessionId),
      let suggestion = suggestions.suggestions[session.sessionId],
      let name = suggestion.othersName,
      let others = transcripts.speakers.first(where: {
        ($0.sourceKind == "system_audio" || $0.sourceKind == "application_audio")
          && !$0.namedByUser && $0.label != name
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

  @ViewBuilder private var preservedAudio: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Preserved audio")
        .font(Interview.sectionLabel)
        .foregroundStyle(Interview.quiet)
        .accessibilityAddTraits(.isHeader)
      ConversationAudioList(
        session: session, playbackController: playbackController, showsMix: false)
      if session.lifecycle == "interrupted", !hasPreservedAudio {
        Text(
          playbackController.phase == .scanning
            ? "Checking for preserved local audio…"
            : playbackController.phase == .failed
              ? "Preserved audio could not be checked. Review the recovery error before continuing."
              : "No verified playable audio is available for this conversation."
        )
        .font(Interview.meta)
        .foregroundStyle(Interview.quiet)
        .fixedSize(horizontal: false, vertical: true)
      }
      if session.lifecycle == "interrupted", !canStartNewRecording {
        Text(newRecordingUnavailableReason)
          .font(Interview.meta)
          .foregroundStyle(Interview.quiet)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Transcript

  @ViewBuilder private func transcript(proxy: ScrollViewProxy) -> some View {
    if session.lifecycle != "ready_for_review" {
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
    } else if !isLoaded || transcripts.isLoading {
      ProgressView()
        .controlSize(.small)
        .padding(.leading, Interview.shoulder)
    } else {
      Text(
        session.transcriptionUnavailableReason
          ?? "The transcript will appear here when it is ready."
      )
      .font(Interview.speech())
      .foregroundStyle(Interview.quiet)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.leading, Interview.shoulder)
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

  /// The marker list is created with the document. Its height grows only when
  /// a saved marker exists, so an empty conversation does not reserve a row.
  static func markerListHeight(_ events: [NativeRecorderEvent]) -> CGFloat {
    let count = events.filter { $0.kind == "marker_added" }.count
    return count == 0 ? 0 : CGFloat(22 + count * 24)
  }
}

extension ConversationSuggestionModel {
  /// A model that never suggests, for documents shown outside the library.
  @MainActor static let inert = ConversationSuggestionModel(
    library: { throw NativeStorageError.InvalidState }, suggest: { _ in nil })
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
    let hasDraft = session.transcript.hasDraftText
    let isFinal = session.transcript.documentAvailability == .final
    if session.transcriptionUnavailableReason == nil, session.transcript.hasTranscribableAudio {
      if speech.transcribingSessionId == session.sessionId || job == .running {
        HStack(spacing: 10) {
          ProgressView(value: speech.progressFraction ?? 0)
            .progressViewStyle(.linear)
            .frame(width: 120)
          Text(hasDraft ? "Making the final transcript on this Mac…" : "Transcribing on this Mac…")
            .font(Interview.meta)
            .foregroundStyle(Interview.quiet)
          Button("Cancel") { scheduler.cancel(sessionId: session.sessionId) }
            .buttonStyle(.link)
            .font(Interview.meta)
        }
        .accessibilityElement(children: .combine)
      } else if case .queued(let position, let hold) = job {
        InterviewNotice(
          message: hold.map { "Waiting to transcribe. \($0.text)" }
            ?? (position == 1 ? "Transcribing next." : "Waiting to transcribe, \(position) in line."),
          actions: scheduler.canPrioritize(sessionId: session.sessionId)
            ? [("Transcribe Now", { scheduler.request(sessionId: session.sessionId) })] : [])
      } else if transcripts.sessionId == session.sessionId, transcripts.availability == .failed {
        InterviewNotice(
          message: "Transcription failed. "
            + RuntimeTranscriptPresentation.failureText(session.transcript.failureClass)
            + " The audio is unchanged.",
          isProblem: true,
          actions: speech.installedModel == nil
            ? [(TranscriptSection.installSpeechModelTitle, onSetUp)]
            : [("Try Again", { scheduler.request(sessionId: session.sessionId) })])
      } else if case .failed(let message) = job {
        InterviewNotice(
          message: message, isProblem: true,
          actions: [("Try Again", { scheduler.request(sessionId: session.sessionId) })])
      } else if !isFinal, speech.installedModel == nil, !speech.isRefreshing {
        InterviewNotice(
          message: hasDraft
            ? "This is the live draft. Add a speech model to make a more accurate transcript on this Mac."
            : "No transcript yet. Add a speech model to transcribe this recording on this Mac.",
          actions: [(TranscriptSection.installSpeechModelTitle, onSetUp)])
      } else if !isFinal, speech.installedModel != nil, !scheduler.isAutomatic || scheduler.isPaused
      {
        InterviewNotice(
          message: hasDraft
            ? "This is the live draft. The final transcript has not been made yet."
            : "Not transcribed yet.",
          actions: [("Transcribe", { scheduler.request(sessionId: session.sessionId) })])
      } else if hasDraft, !isFinal {
        InterviewNotice(message: "This is the live draft. Some words may be misheard.")
      }
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

/// The conversation name, set in New York. It is an AppKit label created
/// with the document, so a later title change updates this field. Double-click
/// opens the title editor.
private struct ConversationTitleLabel: NSViewRepresentable {
  let title: String
  let onRename: () -> Void

  func makeNSView(context: Context) -> TitleField {
    let field = TitleField(labelWithString: title)
    let base = NSFont.systemFont(ofSize: 30, weight: .semibold)
    field.font =
      base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 30) } ?? base
    field.textColor = NSColor(Interview.ink)
    field.isSelectable = true
    field.lineBreakMode = .byWordWrapping
    field.setAccessibilityLabel("Conversation name")
    field.setAccessibilityRole(.staticText)
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.maximumNumberOfLines = 3
    field.toolTip = "Double-click to rename"
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.onRename = onRename
    return field
  }

  func updateNSView(_ field: TitleField, context: Context) {
    field.stringValue = title
    field.onRename = onRename
    field.setAccessibilityLabel("Conversation name")
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleField, context: Context) -> CGSize?
  {
    let width = proposal.width ?? Interview.measure
    nsView.preferredMaxLayoutWidth = width
    let height = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400))
      .height ?? 40
    return CGSize(width: width, height: ceil(height))
  }

  final class TitleField: NSTextField {
    var onRename: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2 {
        onRename?()
      } else {
        super.mouseDown(with: event)
      }
    }
  }
}

/// Play and Stop for the whole conversation: the verified mix for a capture,
/// the imported file for an import. Recovered single tracks stay in Details.
private struct ConversationPlayMount: NSViewRepresentable {
  let session: RuntimeSessionPresentation
  @ObservedObject var playback: RecoveredSessionController

  func makeNSView(context: Context) -> ConversationPlayControl {
    let view = ConversationPlayControl()
    view.bind(session: session, playback: playback)
    return view
  }

  func updateNSView(_ view: ConversationPlayControl, context: Context) {
    view.bind(session: session, playback: playback)
  }
}

private final class ConversationPlayControl: NSView {
  private let button = NSButton(title: "Play", target: nil, action: nil)
  private var session: RuntimeSessionPresentation?
  private weak var playback: RecoveredSessionController?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Conversation playback")
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.imagePosition = .imageLeading
    button.target = self
    button.action = #selector(toggle)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private var isMix: Bool {
    guard let session else { return false }
    return session.lifecycle == "ready_for_review" && session.hasCaptureTimeline
  }

  func bind(session: RuntimeSessionPresentation, playback: RecoveredSessionController) {
    self.session = session
    self.playback = playback
    let active = playback.activePlaybackSessionId == session.sessionId
    let isPlaying = playback.playingSessionId == session.sessionId
    let action = PlaybackControlAction.resolve(isPending: active && !isPlaying, isPlaying: isPlaying)
    let canPlay =
      isMix || (session.playableMedia.map(ImportedPlaybackEligibility.canPlay) ?? false)
    button.title = action.title
    button.image = NSImage(
      systemSymbolName: action == .play ? "play.fill" : "stop.fill",
      accessibilityDescription: nil)
    button.setAccessibilityLabel(ConversationControlLabels.playConversationAudio(action))
    button.isEnabled =
      action != .play
      || (canPlay && action.isEnabled(hasActivePlayback: playback.activePlaybackSessionId != nil))
    let mixReady = session.lifecycle == "ready_for_review" || session.playableMedia != nil
    isHidden = !mixReady
  }

  @objc private func toggle() {
    guard let playback, let session, button.isEnabled else { return }
    let active = playback.activePlaybackSessionId == session.sessionId
    let isMix = isMix
    Task { @MainActor in
      if active {
        playback.stopPlayback()
      } else if isMix {
        playback.playMixdown(sessionId: session.sessionId)
      } else {
        playback.play(session)
      }
    }
  }
}

/// Export for the transcript. One button opens one panel; the panel's format
/// menu chooses the file type.
private struct ExportTranscriptMount: NSViewRepresentable {
  let enabled: Bool
  let visible: Bool
  let onExport: () -> Void

  func makeNSView(context: Context) -> ExportTranscriptControl {
    let view = ExportTranscriptControl()
    view.bind(enabled: enabled, visible: visible, onExport: onExport)
    return view
  }

  func updateNSView(_ view: ExportTranscriptControl, context: Context) {
    view.bind(enabled: enabled, visible: visible, onExport: onExport)
  }
}

private final class ExportTranscriptControl: NSView {
  private let button = NSButton(title: "Export…", target: nil, action: nil)
  private var onExport: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.setAccessibilityLabel(ConversationControlLabels.exportTranscript)
    button.toolTip = "Save the transcript as Markdown, plain text, subtitles, or JSON"
    button.target = self
    button.action = #selector(export)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func bind(enabled: Bool, visible: Bool, onExport: @escaping () -> Void) {
    self.onExport = onExport
    button.isHidden = !visible
    button.isEnabled = enabled
  }

  @objc private func export() {
    guard button.isEnabled else { return }
    let onExport = onExport
    Task { @MainActor in onExport?() }
  }
}

/// Saved markers for one conversation. The control is created with the
/// document and fills in when the journal events arrive, so a hosted window
/// can play from a marker without inserting a new SwiftUI row.
private struct MarkerListMount: NSViewRepresentable {
  let events: [NativeRecorderEvent]
  let canSeek: Bool
  let onSeek: (Int64) -> Void

  func makeNSView(context: Context) -> MarkerListControl {
    let view = MarkerListControl()
    view.bind(events: events, canSeek: canSeek, onSeek: onSeek)
    return view
  }

  func updateNSView(_ view: MarkerListControl, context: Context) {
    view.bind(events: events, canSeek: canSeek, onSeek: onSeek)
  }
}

private final class MarkerListControl: NSView {
  private let heading = NSTextField(labelWithString: "Markers")
  private let column = NSStackView()
  private var onSeek: ((Int64) -> Void)?
  private var positions: [String: Int64] = [:]
  private var signature: [String] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Markers")
    heading.font = .systemFont(ofSize: 11, weight: .semibold)
    heading.textColor = .secondaryLabelColor
    heading.setAccessibilityLabel("Markers")
    heading.setAccessibilityIdentifier("Markers")
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
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
      column.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  func bind(events: [NativeRecorderEvent], canSeek: Bool, onSeek: @escaping (Int64) -> Void) {
    self.onSeek = onSeek
    let markers = events.filter { $0.kind == "marker_added" }
    let next = markers.map { "\($0.id)\n\($0.label)\n\($0.sessionNanoseconds)\n\(canSeek)" }
    isHidden = markers.isEmpty
    heading.isHidden = markers.isEmpty
    column.isHidden = markers.isEmpty
    guard next != signature else { return }
    signature = next
    positions = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0.sessionNanoseconds) })
    for view in column.arrangedSubviews {
      column.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for marker in markers {
      let stamp = TranscriptSection.timestamp(marker.sessionNanoseconds)
      let row = NSStackView()
      row.orientation = .horizontal
      row.alignment = .firstBaseline
      row.spacing = ScribeSpacing.related
      let button = NSButton(title: stamp, target: self, action: #selector(playMarker(_:)))
      button.bezelStyle = .inline
      button.isBordered = false
      button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      button.contentTintColor = NSColor(Interview.accent)
      button.isEnabled = canSeek
      button.identifier = NSUserInterfaceItemIdentifier(marker.id)
      button.setAccessibilityLabel(
        ConversationControlLabels.markerAccessibility(
          stamp: stamp, label: marker.label, canSeek: canSeek))
      let name = NSTextField(labelWithString: marker.label.isEmpty ? "Marker" : marker.label)
      name.font = .systemFont(ofSize: 13)
      name.textColor = .labelColor
      name.setAccessibilityLabel(marker.label.isEmpty ? "Marker" : marker.label)
      for item in [button, name] {
        item.setContentCompressionResistancePriority(.required, for: .horizontal)
        item.setContentCompressionResistancePriority(.required, for: .vertical)
        row.addArrangedSubview(item)
      }
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
      column.addArrangedSubview(row)
    }
  }

  @objc private func playMarker(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue, let start = positions[id], sender.isEnabled else {
      return
    }
    let onSeek = onSeek
    Task { @MainActor in onSeek?(start) }
  }
}
