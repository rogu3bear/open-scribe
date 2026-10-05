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
  /// Captured recordings play from any timeline position and imported audio
  /// from any media position; without playable audio nothing can seek.
  let canSeek: Bool
  let onSeek: (Int64) -> Void

  @State private var editing: NativeTranscriptSegment?
  @State private var draftText = ""
  @State private var renaming: NativeSessionSpeaker?
  @State private var draftLabel = ""
  @State private var showingModels = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Transcript")
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        exportMenu
      }
      Text(session.transcriptionUnavailableReason ?? transcripts.availabilityText)
        .font(.callout)
        .foregroundStyle(.secondary)
      if transcripts.availability != .final || speech.transcribingSessionId == session.sessionId {
        transcriptionControls
      }
      if let message = speech.message, !showingModels,
        session.transcriptionUnavailableReason == nil
          || speech.transcribingSessionId == session.sessionId
      {
        Label(
          message,
          systemImage: speech.messageIsFailure ? "exclamationmark.triangle" : "checkmark.circle"
        )
        .font(.callout)
        .foregroundStyle(speech.messageIsFailure ? Color.red : Color.secondary)
      }
      if session.transcriptionUnavailableReason == nil, !transcripts.segments.isEmpty {
        speakerList
        // Long sessions hold thousands of segments; build only visible rows.
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(transcripts.segments) { segment in
            segmentRow(segment)
          }
        }
      }
    }
    .task(
      id: session.sessionId
        + (session.transcriptionUnavailableReason == nil ? ":timed" : ":untimed")
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
  }

  /// Transcription runs on this Mac only after a verified model is installed;
  /// progress and Cancel stay beside the transcript they will produce.
  @ViewBuilder
  private var transcriptionControls: some View {
    if speech.transcribingSessionId == session.sessionId {
      VStack(alignment: .leading, spacing: 6) {
        if let fraction = speech.progressFraction {
          ProgressView(value: fraction) { Text(speech.progressText) }
        } else {
          ProgressView { Text(speech.progressText) }
        }
        Button("Cancel Transcription") { speech.cancel() }
      }
      .frame(maxWidth: 420, alignment: .leading)
    } else if session.transcriptionUnavailableReason == nil, speech.installedModel != nil {
      HStack(spacing: 12) {
        Button("Transcribe on This Mac") {
          Task {
            await speech.transcribe(sessionId: session.sessionId)
            transcripts.load(session: session)
          }
        }
        .disabled(speech.transcribingSessionId != nil)
        .help(
          speech.transcribingSessionId != nil
            ? "Another conversation is being transcribed"
            : "Transcribe every recorded track with the installed local model")
        Button("Speech Model…") {
          speech.dismissMessage()
          showingModels = true
        }
        .buttonStyle(.link)
      }
    } else if session.transcriptionUnavailableReason == nil {
      VStack(alignment: .leading, spacing: 6) {
        Text("Transcription needs a verified local speech model.")
          .font(.callout)
        Button("Install Speech Model…") {
          speech.dismissMessage()
          showingModels = true
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
          Label(speaker.label, systemImage: "person.wave.2")
        }
        .buttonStyle(.borderless)
        .help(speaker.namedByUser ? "Named by you" : "Named from the capture source")
        .accessibilityLabel("Rename speaker \(speaker.label)")
      }
    }
    .font(.callout)
  }

  private func segmentRow(_ segment: NativeTranscriptSegment) -> some View {
    let stamp = Self.timestamp(segment.startNanoseconds)
    return HStack(alignment: .firstTextBaseline, spacing: 12) {
      Button(stamp) {
        onSeek(segment.startNanoseconds)
      }
      .buttonStyle(.link)
      .font(.caption.monospacedDigit())
      // One column for every timestamp width keeps the text column aligned.
      .frame(minWidth: 48, alignment: .leading)
      .disabled(!canSeek)
      .help(canSeek ? "Play from \(stamp)" : "This conversation has no playable audio")
      .accessibilityLabel(canSeek ? "Play from \(stamp)" : stamp)
      VStack(alignment: .leading, spacing: 2) {
        Text(segment.speakerLabel)
          .font(.subheadline.weight(.semibold))
        Text(segment.effectiveText)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if segment.corrected {
          Text("Corrected. Machine reading: \(segment.verbatimText)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      // Keep transcript lines near the 60–85 character measure (DESIGN §10).
      .frame(maxWidth: 500, alignment: .leading)
      // Selectable Text can retain its initial AppKit accessibility value after
      // a correction. Project the current review text explicitly for readers.
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isStaticText)
      .accessibilityLabel(
        "\(segment.speakerLabel). \(segment.effectiveText)"
          + (segment.corrected ? " Corrected. Machine reading: \(segment.verbatimText)" : "")
      )
      Spacer(minLength: 8)
      Button("Correct…") {
        draftText = segment.effectiveText
        transcripts.dismissMessage()
        editing = segment
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Correct the text at \(stamp)")
    }
    // The row action stays beside its text instead of the far edge.
    .frame(maxWidth: 660, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  /// A failed save keeps the sheet and its text open and says why.
  @ViewBuilder
  private var sheetFailure: some View {
    if transcripts.messageIsFailure, let message = transcripts.message {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.red)
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
            Button("Markdown…") { export(.markdown, type: UTType(filenameExtension: "md") ?? .plainText) }
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
            .disabled(session.transcriptionUnavailableReason != nil)
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
        .border(Color.secondary.opacity(0.4))
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
    .padding(20)
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
    .padding(20)
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
  private func exportPackage() {
    let packageType = UTType(filenameExtension: "openscribe", conformingTo: .package) ?? .package
    let panel = NSSavePanel()
    panel.allowedContentTypes = [packageType]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(session.title, type: packageType)
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension != "openscribe" { url.appendPathExtension("openscribe") }
    Task { await transcripts.export(.portablePackage, to: url) }
  }

  static func fileName(_ title: String, type: UTType) -> String {
    let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
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
