import AppKit
import UniformTypeIdentifiers

/// What a person can do to one conversation: Copy, Play, Export, Rename and
/// Move to Trash. The library, the menu bar, the document and the live page
/// all act through this one owner, so each action has one rule.
@MainActor
struct ConversationActions {
  let store: RuntimeLibraryStore
  let transcripts: TranscriptLibraryModel
  let playback: RecoveredSessionController
  /// Trash waits while a recording is open.
  let recorderIdle: Bool

  // MARK: Copy

  func canCopy(_ session: RuntimeSessionPresentation) -> Bool {
    LibraryPresentation.canCopy(session)
  }

  /// Copies the conversation and returns the note a caller may show, or nil
  /// when nothing was copied. The announcement is the same everywhere.
  @discardableResult
  func copy(_ session: RuntimeSessionPresentation, timestamps: Bool = true) async -> String? {
    await transcripts.copyConversation(
      session, options: ConversationClipboard.Options(timestamps: timestamps))
  }

  // MARK: Play

  /// Play for the whole conversation: the verified mix of a capture, or the
  /// imported file. Recovered single tracks play from Details.
  struct Playback: Equatable {
    let action: PlaybackControlAction
    let isEnabled: Bool
    let isAvailable: Bool
  }

  func playback(for session: RuntimeSessionPresentation) -> Playback {
    let active = playback.activePlaybackSessionId == session.sessionId
    let isPlaying = playback.playingSessionId == session.sessionId
    let action = PlaybackControlAction.resolve(isPending: active && !isPlaying, isPlaying: isPlaying)
    let canPlay = Self.playsMix(session) || (session.playableMedia?.isPlayable ?? false)
    return Playback(
      action: action,
      isEnabled: action != .play
        || (canPlay
          && action.isEnabled(hasActivePlayback: playback.activePlaybackSessionId != nil)),
      isAvailable: session.lifecycle == .readyForReview || session.playableMedia != nil)
  }

  func togglePlayback(_ session: RuntimeSessionPresentation) {
    if playback.activePlaybackSessionId == session.sessionId {
      playback.stopPlayback()
    } else if Self.playsMix(session) {
      playback.playMixdown(sessionId: session.sessionId)
    } else {
      playback.play(session)
    }
  }

  private static func playsMix(_ session: RuntimeSessionPresentation) -> Bool {
    session.lifecycle == .readyForReview && session.hasCaptureTimeline
  }

  // MARK: Export

  func canExport(_ session: RuntimeSessionPresentation) -> Bool {
    transcripts.loaded(session.sessionId)?.segments.isEmpty == false && !transcripts.isExporting
  }

  /// Saves the transcript where the person chooses. The chosen file's
  /// extension picks the format.
  func export(
    _ session: RuntimeSessionPresentation, choose: @MainActor (String) -> URL?
  ) {
    guard canExport(session) else { return }
    let suggested = TranscriptSection.fileName(
      ConversationIdentityPresentation.title(for: session),
      type: UTType(filenameExtension: "md") ?? .plainText)
    guard let destination = choose(suggested) else { return }
    let format = ConversationExportPanel.format(for: destination)
    let transcripts = transcripts
    let sessionId = session.sessionId
    Task { await transcripts.export(format: format, to: destination, from: sessionId) }
  }

  // MARK: Rename

  func canRename(_ session: RuntimeSessionPresentation) -> Bool {
    LibraryPresentation.canRename(session)
  }

  func rename(_ session: RuntimeSessionPresentation) {
    guard canRename(session) else { return }
    store.beginRename(session)
  }

  /// Keeps a suggested title, so Open Scribe does not change it again.
  func keepTitle(_ session: RuntimeSessionPresentation) {
    let store = store
    let sessionId = session.sessionId
    let title = session.displayTitle
    Task { _ = await store.rename(sessionId: sessionId, title: title) }
  }

  // MARK: Trash

  func trashUnavailableReason(_ session: RuntimeSessionPresentation) -> String? {
    LibraryPresentation.trashUnavailableReason(session, recorderIdle: recorderIdle)
  }

  /// Asks Rust for the deletion inventory; the confirmation strip shows it.
  func moveToTrash(_ session: RuntimeSessionPresentation) {
    guard trashUnavailableReason(session) == nil else { return }
    if playback.activePlaybackSessionId == session.sessionId {
      playback.stopPlayback()
    }
    let transcripts = transcripts
    let sessionId = session.sessionId
    Task { await transcripts.requestDeletion(sessionId: sessionId) }
  }
}
