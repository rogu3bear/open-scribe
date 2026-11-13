import SwiftUI

/// The library: search across every transcript, the recording in progress,
/// conversations that need attention, then saved conversations grouped by
/// day. Rows lead with the title; one quiet line carries length and state.
struct LibrarySidebar: View {
  @ObservedObject var store: RuntimeLibraryStore
  @ObservedObject var importedMediaAuthority: ImportedMediaAuthorityAdapter
  @ObservedObject var liveRecording: LiveMicrophoneRecordingController
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  @ObservedObject var pressure: SystemPressureMonitor
  @ObservedObject var navigation: MainWorkspaceNavigation
  @ObservedObject var search: LibrarySearchState
  let onOpenSearchHit: (NativeTranscriptSearchHit) -> Void
  let onRequestDeletion: (RuntimeSessionPresentation) -> Void
  let onCopy: (RuntimeSessionPresentation) -> Void

  private var selection: Binding<String?> {
    Binding(get: { navigation.selectedSessionId }, set: { navigation.select($0) })
  }

  private var references: [String: String] {
    ConversationIdentityPresentation.references(
      for: store.savedSessions + (store.currentSession.map { [$0] } ?? []))
  }

  var body: some View {
    VStack(spacing: 0) {
      // The field and match rows exist before a query. A later search only
      // fills this hosting view; it does not wait for a new SwiftUI row.
      LibrarySearchMount { text in
        search.query = text
        Task { await transcripts.search(text) }
      }
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 4)
      SearchResultMount(transcripts: transcripts, store: store, search: search) { hit in
        onOpenSearchHit(hit)
      }
      .frame(
        maxWidth: .infinity, minHeight: search.query.isEmpty ? 0 : 120,
        maxHeight: search.query.isEmpty ? 0 : 260, alignment: .topLeading)
      conversationList
      LibraryActivityFooter(
        scheduler: scheduler, speech: speech, pressure: pressure,
        titles: Dictionary(
          uniqueKeysWithValues: store.savedSessions.map {
            ($0.sessionId, ConversationIdentityPresentation.title(for: $0))
          }))
      bottomBar
    }
    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
  }

  private var bottomBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 2) {
        AudioFileImportMount(authority: importedMediaAuthority, recording: liveRecording)
          .frame(width: 28, height: 24)
        Spacer(minLength: 0)
        RenameRequestMount(
          store: store, liveRecording: liveRecording, navigation: navigation
        ) { session in
          store.beginRename(session)
        }
        .frame(width: 28, height: 24)
        DeletionRequestMount(
          store: store, liveRecording: liveRecording, navigation: navigation
        ) { session in
          onRequestDeletion(session)
        }
        .frame(width: 28, height: 24)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
  }

  private var conversationList: some View {
    let references = references
    let saved = LibraryConversationLists.saved(store.savedSessions)
    let groups = LibraryConversationLists.dayGroups(saved, now: Date())
    let interrupted = LibraryConversationLists.interrupted(store.savedSessions)
    return List(selection: selection) {
      if let current = store.currentSession {
        Section(current.lifecycle == "interrupted" ? "Needs Attention" : "Now") {
          row(current, references: references, menu: current.lifecycle == "interrupted")
        }
      }
      if !interrupted.isEmpty {
        Section("Needs Attention") {
          ForEach(interrupted) { session in
            row(session, references: references, menu: true)
          }
        }
      }
      if saved.isEmpty, store.currentSession == nil, interrupted.isEmpty {
        Text("Recordings and imported audio appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ForEach(groups, id: \.title) { group in
        Section(group.title) {
          ForEach(group.sessions) { session in
            row(session, references: references, menu: true)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .onDeleteCommand {
      // Delete (or Edit > Delete) moves the selected saved conversation to
      // Trash through the same confirmation as the context menu.
      guard liveRecording.canStart,
        let session = store.savedSessions.first(where: {
          $0.sessionId == navigation.selectedSessionId
        })
      else { return }
      onRequestDeletion(session)
    }
    .navigationTitle("Open Scribe")
  }

  @ViewBuilder
  private func row(
    _ session: RuntimeSessionPresentation, references: [String: String], menu: Bool
  ) -> some View {
    let view = ConversationSidebarRow(
      session: session, reference: references[session.sessionId],
      isSelected: navigation.selectedSessionId == session.sessionId,
      transcription: scheduler.state(for: session.sessionId)
    )
    .tag(session.sessionId)
    if menu {
      view.contextMenu {
        Button("Copy Transcript") { onCopy(session) }
          .disabled(
            session.lifecycle != "ready_for_review"
              || (session.transcript.documentAvailability == .unavailable
                && !session.transcript.hasDraftText))
        Divider()
        Button("Rename…") { store.beginRename(session) }
        Button("Move to Trash…", role: .destructive) { onRequestDeletion(session) }
          .disabled(!liveRecording.canStart || session.deletionUnavailableReason != nil)
          .help(session.deletionUnavailableReason ?? "Move this conversation to Trash.")
      }
    } else {
      view
    }
  }
}

struct ConversationSidebarRow: View {
  let session: RuntimeSessionPresentation
  let reference: String?
  let isSelected: Bool
  var transcription: TranscriptionJobState?

  private var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

  private var secondaryText: Color { isSelected ? selectedText.opacity(0.85) : .secondary }

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

  /// The quiet line under the title. A finished, transcribed conversation
  /// shows only its time and length; anything still happening says so.
  private var subtitle: String {
    var parts: [String] = []
    if let created = session.createdAt, session.lifecycle == "ready_for_review" {
      parts.append(created.formatted(date: .omitted, time: .shortened))
    }
    parts.append(
      session.elapsedSeconds > 0
        ? InterviewTime.length(seconds: session.elapsedSeconds) : session.timerText)
    let status = detailStatusText
    if status != "Transcript ready" { parts.append(status) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    let title = ConversationIdentityPresentation.title(for: session)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let symbolName = statusSymbolName {
        Image(systemName: symbolName)
          .foregroundStyle(
            isSelected ? selectedText : session.isRecording ? Color.red : Color.orange)
          .font(.system(size: 11))
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(
              ConversationIdentityPresentation.isPlaceholder(session.displayTitle) && !isSelected
                ? Color.secondary : isSelected ? selectedText : Color.primary)
          if let reference {
            Text(reference)
              .font(.caption.monospaced())
              .foregroundStyle(secondaryText)
              .fixedSize()
          }
        }
        Text(subtitle)
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(secondaryText)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .help(title)
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
              Image(systemName: scheduler.runningSessionId != nil ? "waveform" : "clock")
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
