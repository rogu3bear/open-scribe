import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The saved conversation's transcript: selected Final text on the session
/// timeline, with human corrections beside the machine reading, source-aware
/// speaker names, click-to-play, export, and local transcription.
struct TranscriptSection: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var transcripts: TranscriptLibraryModel
  @ObservedObject var speech: SpeechTranscriptionModel
  @ObservedObject var scheduler: TranscriptionScheduler
  /// Captured recordings play from any timeline position and imported audio
  /// from any media position; without playable audio nothing can seek.
  let canSeek: Bool
  let onSeek: (Int64) -> Void
  var isPlaybackActive = false
  var playbackPosition: () -> TranscriptPlaybackPosition? = { nil }
  var onFollowPlayback: (String) -> Void = { _ in }

  @State private var editing: NativeTranscriptSegment?
  @State private var draftText = ""
  @State private var renaming: NativeSessionSpeaker?
  @State private var draftLabel = ""
  @State private var showingModels = false
  @State private var showingReprocessConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Transcript")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if session.transcript.documentAvailability == .final
          || session.transcript.replacementResumable
        {
          Menu("Transcription") {
            if session.transcript.replacementResumable {
              Button("Resume Replacement") {
                scheduler.resumeReplacement(sessionId: session.sessionId)
              }
            }
            Button("Reprocess All Tracks…") { showingReprocessConfirmation = true }
          }
        }
        exportMenu
      }
      Text(session.transcriptionUnavailableReason ?? availabilityText)
        .font(.callout)
        .foregroundStyle(.secondary)
      if showsTranscriptionControls {
        transcriptionControls
      }
      if !showingModels, session.transcriptionUnavailableReason == nil {
        outcomeNote
      }
      if session.transcriptionUnavailableReason == nil,
        transcripts.sessionId == session.sessionId, !transcripts.segments.isEmpty
      {
        TranscriptReader(
          sessionId: session.sessionId, transcripts: transcripts, canSeek: canSeek,
          isPlaybackActive: isPlaybackActive, playbackPosition: playbackPosition,
          onSeek: onSeek,
          onCorrect: { segment in
            draftText = segment.effectiveText
            transcripts.dismissMessage()
            editing = segment
          }, onFollowPlayback: onFollowPlayback
        )
        .id(session.sessionId)
        DisclosureGroup("Audio source labels") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Source labels apply to every unassigned passage on that audio track.")
              .font(.caption)
              .foregroundStyle(.secondary)
            speakerList
          }
          .padding(.top, 8)
        }
      }
    }
    // Rust's transcript posture is part of the identity: launch recovery or a
    // finished run changes it, and the document rereads itself.
    .task(
      id: session.sessionId
        + (session.transcriptionUnavailableReason == nil ? ":timed" : ":untimed")
        + ":\(session.transcript.state.rawValue):\(session.transcript.documentVersion)"
    ) {
      transcripts.load(session: session)
    }
    .sheet(item: $editing) { segment in
      correctionSheet(segment)
    }
    .sheet(item: $renaming) { speaker in
      renameSheet(speaker)
    }
    .sheet(isPresented: $showingModels) {
      SpeechModelSheet(speech: speech) { showingModels = false }
    }
    .confirmationDialog("Reprocess all audio tracks?", isPresented: $showingReprocessConfirmation) {
      Button("Reprocess All Tracks") {
        scheduler.request(sessionId: session.sessionId, intent: .reprocessAll)
      }
    } message: {
      Text(
        "This creates replacement revisions, reusing compatible saved recognition when available. A replacement becomes selected only if its review selection and edits have not changed since this request. Earlier revisions and their corrections remain in history."
      )
    }
  }

  var showsTranscriptionControls: Bool {
    session.transcript.documentAvailability != .final
      || scheduler.runningSessionId == session.sessionId
      || hasQueuedWork
  }

  private var hasQueuedWork: Bool {
    if case .queued = scheduler.state(for: session.sessionId) { return true }
    return false
  }

  /// The last thing the scheduler did for this conversation, in the speech
  /// model's own words, until the next request replaces it.
  @ViewBuilder
  private var outcomeNote: some View {
    switch scheduler.state(for: session.sessionId) {
    case .finished(let message):
      Label(message, systemImage: "checkmark.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .failed(let message):
      CaptureIssueLabel(message: message, isFailure: true).font(.callout)
    case .cancelled:
      Text("Transcription was cancelled. The recorded audio is unchanged.")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .preempted:
      Text("Transcription yielded to capture. Finished parts are kept.").font(.callout)
        .foregroundStyle(.secondary)
    case .deferred:
      Text("Transcription is waiting to start.").font(.callout).foregroundStyle(.secondary)
    case .incomplete:
      Text("Saved parts were checked. Some tracks still need transcription.")
        .font(.callout).foregroundStyle(.secondary)
    default:
      EmptyView()
    }
  }

  /// What the transcript line says: the library's committed state, with the
  /// plain-words reason when the latest run ended without a transcript.
  private var availabilityText: String {
    if session.transcript.state == .final, session.transcript.attempt == .failed {
      return "The reviewed transcript remains selected. Replacement transcription failed. "
        + RuntimeTranscriptPresentation.failureText(session.transcript.attemptFailure)
    }
    if transcripts.availability == .failed {
      return "Transcription failed. "
        + RuntimeTranscriptPresentation.failureText(session.transcript.failureClass)
        + " The recorded audio is unaffected."
    }
    return transcripts.availabilityText
  }

  /// Transcription runs on this Mac only after a verified model is installed.
  /// The queue position, the hold that keeps it waiting, progress, and the
  /// way to retry or cancel all stay beside the transcript they produce.
  @ViewBuilder
  private var transcriptionControls: some View {
    let job = scheduler.state(for: session.sessionId)
    if speech.transcribingSessionId == session.sessionId || job == .running {
      VStack(alignment: .leading, spacing: 6) {
        if let fraction = speech.progressFraction {
          ProgressView(value: fraction) { Text(speech.progressText) }
        } else {
          ProgressView { Text(speech.progressText) }
        }
        Button("Cancel Transcription") { scheduler.cancel(sessionId: session.sessionId) }
      }
      .frame(maxWidth: 420, alignment: .leading)
    } else if session.transcriptionUnavailableReason == nil || hasQueuedWork {
      VStack(alignment: .leading, spacing: 8) {
        if case .queued(let position, let hold) = job {
          Label(
            position == 1
              ? "Queued next for transcription." : "Queued for transcription, \(position) in line.",
            systemImage: "clock"
          )
          .font(.callout)
          if let hold {
            Text(hold.text)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: 12) {
            if (position > 1 || hold == .pausedByUser)
              && scheduler.canPrioritize(sessionId: session.sessionId)
            {
              Button("Prioritize Transcription") { scheduler.request(sessionId: session.sessionId) }
                .help(
                  "Request transcription ahead of automatic work. Earlier requests keep their place."
                )
            }
            Button("Remove from Queue") { scheduler.cancel(sessionId: session.sessionId) }
          }
        } else if speech.installedModel != nil {
          HStack(spacing: 12) {
            Button(
              transcripts.availability == .failed || job == .cancelled
                || session.transcript.state == .failed || session.transcript.state == .cancelled
                ? "Retry Transcription" : "Transcribe on This Mac"
            ) {
              scheduler.request(sessionId: session.sessionId)
            }
            .help(
              "Resume incomplete tracks. Compatible selected Final transcripts and their corrections stay selected."
            )
          }
          if scheduler.isPaused {
            HStack(spacing: 12) {
              Text("Automatic transcription is paused.")
                .font(.callout)
                .foregroundStyle(.secondary)
              Button("Resume") { scheduler.isPaused = false }
                .buttonStyle(.link)
            }
          } else if !scheduler.isAutomatic {
            Text(
              "Automatic transcription is off. Turn it on in Settings to transcribe new recordings as they are saved."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          Text("Transcription needs a verified local speech model.")
            .font(.callout)
        }
        if session.transcriptionUnavailableReason == nil {
          HStack(spacing: 12) {
            Button("Speech Model…") {
              speech.dismissMessage()
              showingModels = true
            }
            if speech.installedModel == nil {
              Button("Rebuild from Saved Parts") {
                scheduler.request(sessionId: session.sessionId, intent: .reconcileRetained)
              }
            }
          }
        }
      }
    }
  }

  private var speakerList: some View {
    HStack(spacing: 12) {
      ForEach(transcripts.speakers) { speaker in
        Button {
          draftLabel = speaker.namedByUser ? speaker.label : ""
          transcripts.dismissMessage()
          renaming = speaker
        } label: {
          HStack(spacing: 4) {
            Label(speaker.label, systemImage: "person.wave.2")
            Image(systemName: "pencil")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
        }
        .buttonStyle(.borderless)
        .help(
          (speaker.namedByUser ? "Named by you. " : "Named from the capture source. ")
            + "Click to rename"
        )
        .accessibilityLabel("Rename speaker \(speaker.label)")
      }
    }
    .font(.callout)
  }

  /// A failed save keeps the sheet and its text open and says why.
  @ViewBuilder
  private var sheetFailure: some View {
    if let message = transcripts.editingFailureMessage {
      CaptureIssueLabel(message: message, isFailure: true).font(.callout)
    }
  }

  private var exportMenu: some View {
    HStack(spacing: 8) {
      if transcripts.isExporting {
        ProgressView().controlSize(.small)
        Text("Exporting…").font(.caption).foregroundStyle(.secondary)
      }
      Menu("Export") {
        Section("Transcript") {
          Group {
            Button("Plain Text…") { export(.plainText, type: .plainText) }
            Button("Markdown…") {
              export(.markdown, type: UTType(filenameExtension: "md") ?? .plainText)
            }
            Button("WebVTT Subtitles…") {
              export(.webVtt, type: UTType(filenameExtension: "vtt") ?? .plainText)
            }
            Button("SubRip Subtitles…") {
              export(.subRip, type: UTType(filenameExtension: "srt") ?? .plainText)
            }
            Button("Transcript JSON…") { export(.transcriptJson, type: .json) }
          }
          .disabled(session.transcriptionUnavailableReason != nil || transcripts.segments.isEmpty)
        }
        Section("Audio") { audioExports }
        Section("Conversation") {
          Button("Session Manifest (JSON)…") {
            exportConversation(.sessionManifest, type: .json, suffix: " manifest")
          }
          .disabled(session.transcriptionUnavailableReason != nil)
          Button("Portable Package…") { exportPackage() }
            .disabled(session.transcriptionUnavailableReason != nil || hasTurnSpeakerNames)
            .help(
              hasTurnSpeakerNames
                ? "Portable v1 cannot restore passage-level names. Export the transcript and audio separately."
                : "Export a portable conversation package")
        }
      }
      .fixedSize()
      .disabled(transcripts.isExporting)
      .help("Export the transcript, audio, or a portable package of this conversation")
    }
  }

  /// Only exports the session can honestly produce are offered.
  private var loadedAudioOptions: NativeAudioExportOptions? {
    transcripts.sessionId == session.sessionId ? transcripts.audioOptions : nil
  }

  @ViewBuilder
  private var audioExports: some View {
    if loadedAudioOptions?.hasValidatedMix == true {
      Button("Verified Mix (M4A)…") { exportConversation(.validatedMix, type: .mpeg4Audio) }
    }
    if session.hasCaptureTimeline {
      Button("Lossless Mix (WAV)…") { exportConversation(.mixWAV, type: .wav) }
    }
    ForEach(loadedAudioOptions?.pcmTracks ?? [], id: \.self) { track in
      let label = transcripts.speakers.first { $0.trackId == track }?.label ?? "Track"
      Button("\(label) Track (WAV)…") {
        exportConversation(.track(track), type: .wav, suffix: " - \(label)")
      }
    }
    if let fileExtension = loadedAudioOptions?.originalExtension {
      Button("Original Audio…") {
        exportConversation(
          .original, type: UTType(filenameExtension: fileExtension) ?? .audio)
      }
    }
  }

  private func correctionSheet(_ segment: NativeTranscriptSegment) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Correct Transcript Text")
        .font(.headline)
      Text("The machine reading is kept. Your correction is shown and searched instead.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("Machine reading: \(segment.verbatimText)")
        .font(.callout)
        .textSelection(.enabled)
      TextEditor(text: $draftText)
        .frame(minHeight: 90)
        .accessibilityLabel("Corrected text")
      sheetFailure
      HStack {
        if segment.corrected {
          Button("Restore Machine Reading") {
            if transcripts.correct(segment, text: nil) { editing = nil }
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { editing = nil }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          if transcripts.correct(segment, text: draftText) { editing = nil }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .frame(width: 460)
  }

  private func renameSheet(_ speaker: NativeSessionSpeaker) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename Speaker")
        .font(.headline)
      Text("This names everyone heard on this source. It does not identify individual voices.")
        .font(.callout)
        .foregroundStyle(.secondary)
      TextField("Name", text: $draftLabel)
        .textFieldStyle(.roundedBorder)
      sheetFailure
      HStack {
        if speaker.namedByUser {
          Button("Use Source Name") {
            if transcripts.renameSpeaker(trackId: speaker.trackId, label: nil) { renaming = nil }
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { renaming = nil }
          .keyboardShortcut(.cancelAction)
        Button("Rename") {
          if transcripts.renameSpeaker(trackId: speaker.trackId, label: draftLabel) {
            renaming = nil
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draftLabel.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(16)
    .frame(width: 400)
  }

  private func export(_ format: NativeTranscriptExportFormat, type: UTType) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(session.title, type: type)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    transcripts.export(format: format, to: url)
  }

  private func exportConversation(
    _ kind: TranscriptLibraryModel.ConversationExport, type: UTType, suffix: String = ""
  ) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(session.title + suffix, type: type)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await transcripts.export(kind, to: url) }
  }

  /// A `.openscribe` package is a directory; the name always keeps its extension.
  private var hasTurnSpeakerNames: Bool {
    transcripts.sessionId == session.sessionId
      && transcripts.segments.contains { $0.namedSpeakerId != nil }
  }

  private func exportPackage() {
    let packageType = UTType(filenameExtension: "openscribe", conformingTo: .package) ?? .package
    let panel = NSSavePanel()
    panel.allowedContentTypes = [packageType]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(session.title, type: packageType)
    panel.message =
      "This format carries supported PCM audio, selected transcripts, speaker labels, and markers. Context evidence is omitted; failed transcript status restores as pending. Compressed imports are not a supported portable round-trip."
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension != "openscribe" { url.appendPathExtension("openscribe") }
    Task { await transcripts.export(.portablePackage, to: url) }
  }

  static func fileName(_ title: String, type: UTType) -> String {
    let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(
      separator: "-"
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = safe.isEmpty || safe.hasPrefix(".") ? "Transcript" : safe
    return type.preferredFilenameExtension.map { "\(stem).\($0)" } ?? stem
  }

  static func timestamp(_ nanoseconds: Int64) -> String {
    let seconds = max(0, nanoseconds) / 1_000_000_000
    let (hours, minutes, remainder) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    let pad = { (value: Int64) in value < 10 ? "0\(value)" : "\(value)" }
    return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(remainder))" : "\(minutes):\(pad(remainder))"
  }
}
