import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The saved conversation's transcript: selected Final text on the session
/// timeline, with human corrections beside the machine reading, source-aware
/// speaker names, click-to-play, and export.
struct TranscriptSection: View {
  let session: RuntimeSessionPresentation
  @ObservedObject var transcripts: TranscriptLibraryModel
  /// Captured recordings play from any timeline position; imported audio
  /// has no capture timeline to seek.
  let canSeek: Bool
  let onSeek: (Int64) -> Void

  @State private var editing: NativeTranscriptSegment?
  @State private var draftText = ""
  @State private var renaming: NativeSessionSpeaker?
  @State private var draftLabel = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Transcript")
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        exportMenu
      }
      Text(transcripts.availabilityText)
        .font(.callout)
        .foregroundStyle(.secondary)
      if !transcripts.segments.isEmpty {
        speakerList
        ForEach(transcripts.segments) { segment in
          segmentRow(segment)
        }
      }
    }
    .task(id: session.sessionId) {
      transcripts.load(sessionId: session.sessionId)
    }
    .sheet(item: $editing) { segment in
      correctionSheet(segment)
    }
    .sheet(item: $renaming) { speaker in
      renameSheet(speaker)
    }
  }

  private var speakerList: some View {
    HStack(spacing: 12) {
      ForEach(transcripts.speakers) { speaker in
        Button {
          draftLabel = speaker.namedByUser ? speaker.label : ""
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
      .monospacedDigit()
      .disabled(!canSeek)
      .help(canSeek ? "Play from \(stamp)" : "Imported audio cannot be played from a position yet")
      .accessibilityLabel(canSeek ? "Play from \(stamp)" : stamp)
      VStack(alignment: .leading, spacing: 2) {
        Text(segment.speakerLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(segment.effectiveText)
          .textSelection(.enabled)
        if segment.corrected {
          Text("Corrected. Machine reading: \(segment.verbatimText)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 8)
      Button("Correct…") {
        draftText = segment.effectiveText
        editing = segment
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Correct the text at \(stamp)")
    }
    .accessibilityElement(children: .contain)
  }

  private var exportMenu: some View {
    Menu("Export") {
      Button("Plain Text…") { export(.plainText, type: .plainText) }
      Button("Markdown…") { export(.markdown, type: UTType(filenameExtension: "md") ?? .plainText) }
      Button("WebVTT Subtitles…") { export(.webVtt, type: UTType(filenameExtension: "vtt") ?? .plainText) }
      Button("SubRip Subtitles…") { export(.subRip, type: UTType(filenameExtension: "srt") ?? .plainText) }
      Button("Transcript JSON…") { export(.transcriptJson, type: .json) }
    }
    .fixedSize()
    .disabled(transcripts.segments.isEmpty)
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
      HStack {
        if segment.corrected {
          Button("Restore Machine Reading") {
            transcripts.correct(segment, text: nil)
            editing = nil
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { editing = nil }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          transcripts.correct(segment, text: draftText)
          editing = nil
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
      HStack {
        if speaker.namedByUser {
          Button("Use Source Name") {
            transcripts.renameSpeaker(trackId: speaker.trackId, label: nil)
            renaming = nil
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { renaming = nil }
          .keyboardShortcut(.cancelAction)
        Button("Rename") {
          transcripts.renameSpeaker(trackId: speaker.trackId, label: draftLabel)
          renaming = nil
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
