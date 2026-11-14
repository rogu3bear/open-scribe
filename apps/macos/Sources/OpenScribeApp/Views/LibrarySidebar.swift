import SwiftUI

/// The library: search across every transcript, the recording in progress,
/// conversations that need attention, saved conversations grouped by day,
/// and last one quiet row for attempts that never recorded. Rows lead with
/// the title; one quiet line carries length and state.
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
  /// Copy, Rename and Move to Trash, as the document and the menu bar act.
  let actions: ConversationActions
  let onOpenSearchHit: (NativeTranscriptSearchHit) -> Void

  @State private var confirmingEmptyRemoval = false

  private var selection: Binding<String?> {
    Binding(get: { navigation.selectedSessionId }, set: { navigation.select($0) })
  }

  var body: some View {
    VStack(spacing: 0) {
      // The field and match rows exist before a query. A later search only
      // fills this hosting view; it does not wait for a new SwiftUI row.
      LibrarySearchMount { text in
        search.query = text
        Task { await transcripts.search(text) }
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 4)
      searchMatches
        .padding(.horizontal, 10)
      conversationList
      LibraryActivityFooter(
        scheduler: scheduler, speech: speech, pressure: pressure,
        titles: store.library.titles)
      bottomBar
    }
    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
  }

  /// Matching passages across every transcript, shown while there is a
  /// query. Each row opens its conversation at that passage.
  private var searchMatches: some View {
    let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let hits = query.isEmpty ? [] : transcripts.searchResults
    let references = store.library.references
    return HostedList(
      identifier: "Transcript matches",
      rows: hits.map { hit in
        let reference = references[hit.sessionId]
        return HostedListRow(
          id: Self.matchKey(hit), lead: hit.effectiveText,
          label:
            "\(ConversationIdentityPresentation.title(for: hit))\(reference.map { ", reference \($0)" } ?? ""): \(hit.effectiveText)"
        )
      },
      lead: .button,
      emptyText: !query.isEmpty && !transcripts.isSearching ? "No matching transcript text" : nil,
      maximumHeight: 260,
      onSelect: { key in
        if let hit = transcripts.searchResults.first(where: { Self.matchKey($0) == key }) {
          onOpenSearchHit(hit)
        }
      })
  }

  private static func matchKey(_ hit: NativeTranscriptSearchHit) -> String {
    "\(hit.sessionId)#\(hit.sequence)"
  }

  private var selectedSession: RuntimeSessionPresentation? {
    store.library.session(navigation.selectedSessionId)
  }

  private var canImportAudio: Bool {
    liveRecording.canStart && !importedMediaAuthority.isBusy
      && !importedMediaAuthority.hasPendingAudioImports
  }

  /// Import, Rename and Move to Trash. Each shows only while it can act on
  /// the selected conversation.
  private var bottomBar: some View {
    let renamable = selectedSession.flatMap { actions.canRename($0) ? $0 : nil }
    let trashable = selectedSession.flatMap { actions.trashUnavailableReason($0) == nil ? $0 : nil }
    return VStack(spacing: 0) {
      Divider()
      HStack(spacing: 2) {
        barButton(
          title: ConversationControlLabels.audioFiles, symbol: "plus",
          identifier: "Audio file import",
          help: canImportAudio ? ImportedMediaAuthorityAdapter.importLimitHelp : nil,
          isAvailable: canImportAudio
        ) { importedMediaAuthority.chooseAndImport() }
        Spacer(minLength: 0)
        barButton(
          title: "Rename…", label: "Rename the selected conversation", symbol: "pencil",
          identifier: "Rename conversation", help: "Rename…", isAvailable: renamable != nil
        ) { if let renamable { actions.rename(renamable) } }
        barButton(
          title: "Move to Trash…", label: "Move the selected conversation to Trash",
          symbol: "trash", identifier: "Delete conversation", help: "Move to Trash…",
          isAvailable: trashable != nil
        ) { if let trashable { actions.moveToTrash(trashable) } }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
  }

  private func barButton(
    title: String, label: String? = nil, symbol: String, identifier: String, help: String?,
    isAvailable: Bool, action: @escaping @MainActor () -> Void
  ) -> some View {
    HostedButton(
      title: title, symbol: symbol, identifier: identifier, label: label, help: help,
      style: .symbol(pointSize: 13), minimumSize: CGSize(width: 26, height: 22),
      isEnabled: isAvailable, isHidden: !isAvailable, action: action)
  }

  private var conversationList: some View {
    let library = store.library
    return List(selection: selection) {
      if let now = library.now {
        Section("Now") { row(now, references: library.references, menu: false) }
      }
      if !library.needsAttention.isEmpty {
        Section("Needs Attention") {
          ForEach(library.needsAttention) { session in
            row(session, references: library.references, menu: true)
          }
        }
      }
      if library.isEmpty {
        Text("Recordings and imported audio appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ForEach(library.days) { group in
        Section(group.title) {
          ForEach(group.sessions) { session in
            row(session, references: library.references, menu: true)
          }
        }
      }
      if !library.didNotRecord.isEmpty {
        Section { didNotRecordRow(library.didNotRecord) }
      }
    }
    .listStyle(.sidebar)
    .onDeleteCommand {
      // Delete (or Edit > Delete) moves the selected saved conversation to
      // Trash through the same confirmation as the context menu.
      guard let session = library.session(navigation.selectedSessionId) else { return }
      actions.moveToTrash(session)
    }
    .navigationTitle("Open Scribe")
  }

  /// Attempts that stopped before any audio was saved, folded into one quiet
  /// row. They hold nothing to review, so the row offers only removal.
  private func didNotRecordRow(_ attempts: [RuntimeSessionPresentation]) -> some View {
    let removable = attempts.filter(\.canMoveToTrash).map(\.sessionId)
    let canRemove =
      !removable.isEmpty && liveRecording.canStart && !transcripts.isDeleting
      && transcripts.pendingDeletion == nil
    let count = attempts.count
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "minus.circle")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
      Text("Didn't record (\(count))")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Button("Remove") { confirmingEmptyRemoval = true }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .disabled(!canRemove)
    }
    .padding(.vertical, 2)
    .help("Recordings that stopped before any audio was saved. They have no audio or transcript.")
    .contextMenu {
      Button("Remove…") { confirmingEmptyRemoval = true }
        .disabled(!canRemove)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      count == 1 ? "1 recording didn't record" : "\(count) recordings didn't record")
    .confirmationDialog(
      count == 1 ? "Remove 1 recording that didn't start?" : "Remove \(count) recordings that didn't start?",
      isPresented: $confirmingEmptyRemoval
    ) {
      Button("Remove", role: .destructive) {
        Task { await transcripts.removeEmptyAttempts(removable) }
      }
    } message: {
      Text("They have no audio. Their folders move to the Trash.")
    }
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
      let trashReason = actions.trashUnavailableReason(session)
      view.contextMenu {
        Button("Copy Transcript") { Task { await actions.copy(session) } }
          .disabled(!actions.canCopy(session))
        Divider()
        Button("Rename…") { actions.rename(session) }
          .disabled(!actions.canRename(session))
        Button("Move to Trash…", role: .destructive) { actions.moveToTrash(session) }
          .disabled(trashReason != nil)
          .help(trashReason ?? "Move this conversation to Trash.")
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

  private var status: CaptureStatusPresentation { session.captureStatus }

  /// A symbol only when something needs a look: recording, a problem with
  /// the capture or its audio, or a transcript that failed.
  var statusSymbolName: String? {
    if status.tint != .quiet { return status.symbolName }
    if transcriptLine?.symbol == "exclamationmark.circle" { return "exclamationmark.circle" }
    return nil
  }

  /// Transcript posture for saved conversations only: the store's committed
  /// state, or the scheduler's position for work that has not started.
  private var transcriptLine: (symbol: String, text: String)? {
    guard session.lifecycle == .readyForReview, session.transcriptionUnavailableReason == nil,
      session.transcript.hasTranscribableAudio
    else { return nil }
    return session.transcript.line(for: transcription)
  }

  var detailStatusText: String {
    if let transcriptLine, status.tint == .quiet { return transcriptLine.text }
    return status.text
  }

  /// The quiet line under the title. A finished, transcribed conversation
  /// shows only its time and length; anything still happening says so.
  private var subtitleParts: [String] {
    var parts: [String] = []
    if let created = session.createdAt, session.lifecycle == .readyForReview {
      parts.append(created.formatted(date: .omitted, time: .shortened))
    }
    if let length = status.timer ?? session.lengthText { parts.append(length) }
    let detail = detailStatusText
    if detail != "Transcript ready" { parts.append(detail) }
    return parts
  }

  var body: some View {
    let title = ConversationIdentityPresentation.title(for: session)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let symbolName = statusSymbolName {
        Image(systemName: symbolName)
          .foregroundStyle(
            isSelected ? selectedText : status.tint == .recording ? status.tint.color : .orange)
          .font(.system(size: 11))
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(
              session.titleSource == .placeholder && !isSelected
                ? Color.secondary : isSelected ? selectedText : Color.primary)
          if let reference {
            Text(reference)
              .font(.caption.monospaced())
              .foregroundStyle(secondaryText)
              .fixedSize()
          }
        }
        Text(subtitleParts.joined(separator: " · "))
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
      ([title, session.lengthText, status.accessibilityText].compactMap { $0 }
        + (transcriptLine.map { [$0.text] } ?? [])
        + (reference.map { ["reference \($0)"] } ?? [])).joined(separator: ", ")
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
