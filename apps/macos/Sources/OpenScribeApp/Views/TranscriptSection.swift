import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The transcript's record in Details: availability, model provenance,
/// speaker assignment, local transcription and reprocessing, audio-source
/// labels, and the less common exports. The text itself is the document.
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

  @State private var showingModels = false

  /// The reader is part of the document only after this model is bound to
  /// this session and has passages. The view task performs that binding.
  static func showsReader(
    session: RuntimeSessionPresentation, transcripts: TranscriptLibraryModel
  ) -> Bool {
    session.transcriptionUnavailableReason == nil
      && transcripts.sessionId == session.sessionId && !transcripts.segments.isEmpty
  }

  /// The source-label editor is created with the section. Its height grows
  /// only when this conversation has a track, so an empty document does not
  /// reserve the row.
  static func sourceLabelHeight(
    _ transcripts: TranscriptLibraryModel, sessionId: String
  ) -> CGFloat {
    guard transcripts.sessionId == sessionId, !transcripts.speakers.isEmpty else { return 0 }
    return CGFloat(80 + transcripts.speakers.count * 150)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) {
          heading
          Spacer()
          transcriptionMenu
          exportMenu
        }
        VStack(alignment: .leading, spacing: ScribeSpacing.related) {
          heading
          transcriptionMenu
          exportMenu
        }
      }
      if transcripts.isLoading {
        ProgressView("Loading conversation…").controlSize(.small)
      } else {
        Text(session.transcriptionUnavailableReason ?? availabilityText)
          .font(.callout)
          .foregroundStyle(.secondary)
        if session.transcriptionUnavailableReason == nil,
          let diarization = transcripts.speakerDiarizationText
        {
          Text(diarization)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      ProvenanceReadout(
        label: "Model provenance",
        text: session.transcriptionUnavailableReason == nil ? transcripts.provenanceText : nil
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      ProvenanceReadout(
        label: "Speaker assignment",
        text: TranscriptLibraryModel.speakerAssignmentText(
          diarization: session.transcriptionUnavailableReason == nil
            ? transcripts.speakerDiarizationText : nil,
          history: session.transcriptionUnavailableReason == nil
            ? transcripts.speakerLabelHistory : [])
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      ProvenanceReadout(
        label: "Derived item provenance",
        text: session.transcriptionUnavailableReason == nil
          ? TranscriptLibraryModel.derivedItemProvenanceText(for: transcripts.derivedClaims) : nil
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      if showsTranscriptionControls {
        transcriptionControls
      }
      if !showingModels, session.transcriptionUnavailableReason == nil {
        outcomeNote
      }
      if session.transcript.documentAvailability == .final
        || session.transcript.replacementResumable
      {
        ReprocessMount(sessionId: session.sessionId, scheduler: scheduler)
          .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
      }
      AudioSourceLabelMount(transcripts: transcripts, sessionId: session.sessionId)
        .frame(
          maxWidth: .infinity,
          minHeight: Self.sourceLabelHeight(transcripts, sessionId: session.sessionId),
          alignment: .topLeading)
    }
    // Rust's transcript posture is part of the identity: launch recovery or a
    // finished run changes it, and the document rereads itself.
    .task(
      id: session.sessionId
        + (session.transcriptionUnavailableReason == nil ? ":timed" : ":untimed")
        + ":\(session.transcript.state.rawValue):\(session.transcript.documentVersion)"
    ) {
      await transcripts.load(session: session)
    }
    .sheet(isPresented: $showingModels) {
      SpeechModelSheet(speech: speech) { showingModels = false }
    }
  }

  var showsTranscriptionControls: Bool {
    session.transcript.documentAvailability != .final
      || scheduler.runningSessionId == session.sessionId
      || hasQueuedWork
  }

  private var heading: some View {
    Text("Transcript")
      .scribeSectionHeading(.title2.weight(.semibold))
  }

  @ViewBuilder
  private var transcriptionMenu: some View {
    Menu("Transcription") {
      Button("Speech Models…") {
        speech.dismissMessage()
        showingModels = true
      }
      if speech.installedModel == nil, session.transcriptionUnavailableReason == nil,
        speech.transcribingSessionId != session.sessionId,
        scheduler.state(for: session.sessionId) != .running
      {
        Button("Rebuild from Saved Parts") {
          scheduler.request(sessionId: session.sessionId, intent: .reconcileRetained)
        }
      }
      if session.transcript.replacementResumable {
        Button("Resume Replacement") {
          scheduler.resumeReplacement(sessionId: session.sessionId)
        }
      }
    }
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

  /// Opens the speech-model sheet. Shown when the catalog has no installed model.
  static let installSpeechModelTitle = "Set Up Transcription…"

  /// Opening a playable conversation with no installed model. Playback and
  /// conversation management stay available; this line is the transcript status.
  static let speechModelUnavailableStatus =
    "Transcription is unavailable until a speech model is installed on this Mac."

  /// The catalog has been read and none of its models are installed.
  static func showsInstallSpeechModel(
    session: RuntimeSessionPresentation, speech: SpeechTranscriptionModel
  ) -> Bool {
    session.transcriptionUnavailableReason == nil
      && speech.catalogWarning == nil
      && !speech.isRefreshing
      && speech.installedModel == nil
      && speech.models.contains { !$0.installed }
  }

  /// What the transcript line says: the library's committed state, with the
  /// plain-words reason when the latest run ended without a transcript.
  static func statusLine(
    session: RuntimeSessionPresentation,
    transcripts: TranscriptLibraryModel,
    speech: SpeechTranscriptionModel
  ) -> String {
    if session.transcript.state == .final, session.transcript.attempt == .failed {
      return "The reviewed transcript remains selected. Replacement transcription failed. "
        + RuntimeTranscriptPresentation.failureText(session.transcript.attemptFailure)
    }
    if transcripts.availability == .failed {
      return "Transcription failed. "
        + RuntimeTranscriptPresentation.failureText(session.transcript.failureClass)
        + " The recorded audio is unaffected."
    }
    if showsInstallSpeechModel(session: session, speech: speech),
      transcripts.availability == .unavailable
    {
      return speechModelUnavailableStatus
    }
    return transcripts.availabilityText
  }

  private var availabilityText: String {
    Self.statusLine(session: session, transcripts: transcripts, speech: speech)
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
      VStack(alignment: .leading, spacing: ScribeSpacing.related) {
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
          HStack(spacing: ScribeSpacing.compact) {
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
          HStack(spacing: ScribeSpacing.compact) {
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
            HStack(spacing: ScribeSpacing.compact) {
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
          Button(Self.installSpeechModelTitle) {
            speech.dismissMessage()
            showingModels = true
          }
        }
      }
    }
  }

  private var exportMenu: some View {
    HStack(spacing: ScribeSpacing.related) {
      if transcripts.isExporting {
        ProgressView().controlSize(.small)
        Text("Exporting…").font(.caption).foregroundStyle(.secondary)
      }
      Menu("Other Exports") {
        Section("Transcript") {
          Group {
            Button("Plain Text…") { export(.plainText, type: .plainText) }
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
            .disabled(
              session.transcriptionUnavailableReason != nil || packageUnavailableReason != nil
            )
            .help(packageUnavailableReason ?? "Export a portable conversation package")
        }
      }
      .fixedSize()
      .disabled(transcripts.isExporting || transcripts.sessionId != session.sessionId)
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

  private func export(_ format: NativeTranscriptExportFormat, type: UTType) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(ConversationIdentityPresentation.title(for: session), type: type)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await transcripts.export(format: format, to: url, from: session.sessionId) }
  }

  private func exportConversation(
    _ kind: TranscriptLibraryModel.ConversationExport, type: UTType, suffix: String = ""
  ) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(ConversationIdentityPresentation.title(for: session) + suffix, type: type)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await transcripts.export(kind, to: url, from: session.sessionId) }
  }

  /// A `.openscribe` package is a directory; the name always keeps its extension.
  private var hasTurnSpeakerNames: Bool {
    transcripts.sessionId == session.sessionId
      && transcripts.segments.contains { $0.namedSpeakerId != nil }
  }

  private var packageUnavailableReason: String? {
    Self.packageRefusal(
      hasTurnSpeakerNames: hasTurnSpeakerNames,
      originalExtension: loadedAudioOptions?.originalExtension)
  }

  /// Passage-level names have no portable representation. A compressed M4A
  /// import is copied with the package and restores as that file.
  static func packageRefusal(hasTurnSpeakerNames: Bool, originalExtension: String?) -> String? {
    if hasTurnSpeakerNames {
      return
        "This package format cannot retain passage-level names. Export the transcript and audio separately."
    }
    _ = originalExtension
    return nil
  }

  private func exportPackage() {
    let packageType = UTType(filenameExtension: "openscribe", conformingTo: .package) ?? .package
    let panel = NSSavePanel()
    panel.allowedContentTypes = [packageType]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(ConversationIdentityPresentation.title(for: session), type: packageType)
    panel.message =
      "This format carries supported PCM audio, a compressed M4A import, selected transcripts, speaker labels, and markers. Context evidence is omitted; failed transcript status restores as pending. Passage-level names are not included."
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension != "openscribe" { url.appendPathExtension("openscribe") }
    Task { await transcripts.export(.portablePackage, to: url, from: session.sessionId) }
  }

  static func fileName(_ title: String, type: UTType) -> String {
    let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(
      separator: "-"
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = safe.isEmpty || safe.hasPrefix(".") ? "Transcript" : safe
    return type.preferredFilenameExtension.map { "\(stem).\($0)" } ?? stem
  }

  nonisolated static func timestamp(_ nanoseconds: Int64) -> String {
    let seconds = max(0, nanoseconds) / 1_000_000_000
    let (hours, minutes, remainder) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    let pad = { (value: Int64) in value < 10 ? "0\(value)" : "\(value)" }
    return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(remainder))" : "\(minutes):\(pad(remainder))"
  }
}

/// Interpretation while local intelligence is disabled. The field is created
/// with the section and says intelligence is off. It adds no claims.
struct InterpretationSection: View {
  @ObservedObject var transcripts: TranscriptLibraryModel

  var body: some View {
    let refusal = transcripts.refuseLocalIntelligence()
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      ProvenanceReadout(label: "Interpretation", text: refusal.readout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      ProvenanceReadout(
        label: "Structured memory",
        text: StructuredMemory.text(for: transcripts.derivedClaims)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// One effective claim and the actions that open its evidence or return to it.
struct ClaimReviewSection: View {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let canSeek: Bool
  let onSeek: (Int64) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.related) {
      Text("Claims")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ForEach(transcripts.derivedClaims) { claim in
        claimRow(claim)
          .id("claim-\(claim.claimId)")
      }
    }
  }

  private func claimRow(_ claim: DerivedClaimSummary) -> some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      Text(claim.text)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityLabel(spokenSummary(claim))
      ClaimActionMount(
        transcripts: transcripts,
        claimId: claim.claimId,
        canSeek: canSeek,
        onSeek: onSeek
      )
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }
    .padding(.vertical, ScribeSpacing.tight)
    .accessibilityElement(children: .contain)
  }

  private func spokenSummary(_ claim: DerivedClaimSummary) -> String {
    var parts = [
      ClaimReviewSpeech.words(claim.kind),
      ClaimReviewSpeech.words(claim.status),
      "\(claim.supportingCount) supporting",
    ]
    if claim.contradictingCount > 0 {
      parts.append("\(claim.contradictingCount) contradicting")
    }
    if let adjudication = claim.adjudication {
      parts.append(ClaimReviewSpeech.words(adjudication))
    } else {
      parts.append("Not confirmed")
    }
    parts.append(claim.text)
    return parts.joined(separator: ". ")
  }
}

/// Track names for unassigned passages. The control is created with the
/// transcript section and fills when that conversation's speakers arrive, so
/// a hosted window can rename the source without opening a disclosure.
private struct AudioSourceLabelMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let sessionId: String

  func makeNSView(context: Context) -> AudioSourceLabelControl {
    let view = AudioSourceLabelControl()
    view.bind(transcripts: transcripts, sessionId: sessionId)
    return view
  }

  func updateNSView(_ view: AudioSourceLabelControl, context: Context) {
    view.bind(transcripts: transcripts, sessionId: sessionId)
  }
}

/// An editable source name whose programmatic value enables Rename immediately.
private final class AudioSourceNameField: NSTextField {
  var onValue: (() -> Void)?

  override var stringValue: String {
    get { super.stringValue }
    set {
      super.stringValue = newValue
      onValue?()
    }
  }
}

private final class AudioSourceLabelControl: NSView, NSTextFieldDelegate {
  static let headingText = "Audio source labels"
  static let explanationText =
    "Source labels apply to every unassigned passage on that audio track. This does not identify individual voices."

  private let heading = NSTextField(labelWithString: AudioSourceLabelControl.headingText)
  private let explanation = NSTextField(wrappingLabelWithString: "")
  private let failure = NSTextField(wrappingLabelWithString: "")
  private let column = NSStackView()
  private var transcripts: TranscriptLibraryModel?
  private var sessionId: String?
  private var signature: [String] = []
  private var fields: [String: AudioSourceNameField] = [:]
  private var renameButtons: [String: NSButton] = [:]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier(Self.headingText)
    heading.font = .preferredFont(forTextStyle: .headline)
    heading.setAccessibilityLabel(Self.headingText)
    heading.setAccessibilityIdentifier(Self.headingText)
    explanation.stringValue = Self.explanationText
    explanation.font = .preferredFont(forTextStyle: .caption1)
    explanation.textColor = .secondaryLabelColor
    explanation.maximumNumberOfLines = 3
    explanation.lineBreakMode = .byWordWrapping
    explanation.preferredMaxLayoutWidth = 640
    explanation.setAccessibilityLabel(Self.explanationText)
    failure.font = .preferredFont(forTextStyle: .callout)
    failure.textColor = .systemRed
    failure.maximumNumberOfLines = 3
    failure.lineBreakMode = .byWordWrapping
    failure.preferredMaxLayoutWidth = 640
    failure.setAccessibilityLabel("Audio source label")
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.related
    column.detachesHiddenViews = false
    let stack = NSStackView(views: [heading, explanation, failure, column])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = ScribeSpacing.tight
    stack.translatesAutoresizingMaskIntoConstraints = false
    explanation.translatesAutoresizingMaskIntoConstraints = false
    failure.translatesAutoresizingMaskIntoConstraints = false
    explanation.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
    failure.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
    applyVisibility(hasSpeakers: false)
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    let count = column.arrangedSubviews.count
    let height: CGFloat = isHidden || count == 0 ? 0 : 80 + CGFloat(count) * 150
    return NSSize(width: NSView.noIntrinsicMetric, height: height)
  }

  func bind(transcripts: TranscriptLibraryModel, sessionId: String) {
    self.transcripts = transcripts
    self.sessionId = sessionId
    let speakers = transcripts.sessionId == sessionId ? transcripts.speakers : []
    let next = speakers.map { speaker -> String in
      let history = transcripts.speakerLabelHistory.first { $0.trackId == speaker.trackId }
      let historyText = history.map { TranscriptLibraryModel.speakerLabelHistoryText(for: $0) } ?? ""
      return "\(speaker.trackId)\n\(speaker.label)\n\(speaker.namedByUser)\n\(historyText)"
    }
    applyVisibility(hasSpeakers: !speakers.isEmpty)
    guard next != signature else {
      refreshChrome()
      return
    }
    signature = next
    fields = [:]
    renameButtons = [:]
    for view in column.arrangedSubviews {
      column.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for speaker in speakers {
      column.addArrangedSubview(row(for: speaker, transcripts: transcripts))
    }
    refreshChrome()
    invalidateIntrinsicContentSize()
  }

  private func applyVisibility(hasSpeakers: Bool) {
    isHidden = !hasSpeakers
    heading.isHidden = !hasSpeakers
    explanation.isHidden = !hasSpeakers
    column.isHidden = !hasSpeakers
    if !hasSpeakers {
      failure.isHidden = true
      failure.stringValue = ""
    }
  }

  private func refreshChrome() {
    let message = transcripts?.editingFailureMessage
    if isHidden || message == nil || message?.isEmpty == true {
      failure.isHidden = true
      failure.stringValue = ""
    } else if let message {
      failure.isHidden = false
      failure.stringValue = message
      failure.setAccessibilityLabel("Audio source label")
    }
    let busy = transcripts?.isEditing == true
    for (trackId, button) in renameButtons {
      let name = fields[trackId]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      button.isEnabled = !busy && !name.isEmpty
    }
    invalidateIntrinsicContentSize()
  }

  private func row(
    for speaker: NativeSessionSpeaker, transcripts: TranscriptLibraryModel
  ) -> NSView {
    let history = transcripts.speakerLabelHistory.first { $0.trackId == speaker.trackId }
    let historyText = history.map { TranscriptLibraryModel.speakerLabelHistoryText(for: $0) } ?? ""
    let name = NSTextField(labelWithString: speaker.label)
    name.font = .preferredFont(forTextStyle: .body)
    name.setAccessibilityLabel("Current audio source, \(speaker.label)")
    let historyField = NSTextField(wrappingLabelWithString: historyText)
    historyField.font = .preferredFont(forTextStyle: .caption1)
    historyField.textColor = .secondaryLabelColor
    historyField.maximumNumberOfLines = 6
    historyField.preferredMaxLayoutWidth = 640
    historyField.setAccessibilityLabel("Name history for \(speaker.label)")
    historyField.isHidden = historyText.isEmpty
    if historyText.isEmpty { historyField.stringValue = "" }
    let field = AudioSourceNameField(string: "")
    field.placeholderString = "Name"
    field.setAccessibilityLabel("Name for \(speaker.label)")
    field.isEditable = true
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.delegate = self
    field.identifier = NSUserInterfaceItemIdentifier(speaker.trackId)
    field.onValue = { [weak self] in self?.refreshChrome() }
    let rename = NSButton(title: "Rename", target: self, action: #selector(renameSource(_:)))
    rename.bezelStyle = .rounded
    rename.identifier = NSUserInterfaceItemIdentifier(speaker.trackId)
    rename.setAccessibilityLabel("Rename speaker \(speaker.label)")
    rename.isEnabled = false
    var actions: [NSView] = [field, rename]
    if speaker.namedByUser {
      let restore = NSButton(
        title: "Use Source Name", target: self, action: #selector(restoreSource(_:)))
      restore.bezelStyle = .rounded
      restore.identifier = NSUserInterfaceItemIdentifier(speaker.trackId)
      restore.setAccessibilityLabel("Use source name for \(speaker.label)")
      restore.isEnabled = transcripts.isEditing == false
      actions.append(restore)
    }
    let actionRow = NSStackView(views: actions)
    actionRow.orientation = .horizontal
    actionRow.alignment = .centerY
    actionRow.spacing = ScribeSpacing.related
    let row = NSStackView(views: [name, historyField, actionRow])
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = ScribeSpacing.tight
    field.translatesAutoresizingMaskIntoConstraints = false
    historyField.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
      rename.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
      historyField.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
    ])
    fields[speaker.trackId] = field
    renameButtons[speaker.trackId] = rename
    return row
  }

  func controlTextDidChange(_ notification: Notification) {
    refreshChrome()
  }

  @objc private func renameSource(_ sender: NSButton) {
    guard let trackId = sender.identifier?.rawValue,
      let field = fields[trackId],
      let transcripts,
      let sessionId
    else { return }
    let label = field.stringValue
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sender.isEnabled else {
      return
    }
    Task { @MainActor in
      transcripts.dismissMessage()
      await transcripts.renameSpeaker(trackId: trackId, label: label, in: sessionId)
    }
  }

  @objc private func restoreSource(_ sender: NSButton) {
    guard let trackId = sender.identifier?.rawValue,
      let transcripts,
      let sessionId,
      sender.isEnabled
    else { return }
    Task { @MainActor in
      transcripts.dismissMessage()
      await transcripts.renameSpeaker(trackId: trackId, label: nil, in: sessionId)
    }
  }
}

/// Replacement processing for a transcript that is already final. The request
/// and its confirmation are AppKit controls so the hosted window can read and
/// click them. One control starts the replacement; the menu does not repeat it.
private struct ReprocessMount: NSViewRepresentable {
  let sessionId: String
  @ObservedObject var scheduler: TranscriptionScheduler

  func makeNSView(context: Context) -> ReprocessControl {
    let view = ReprocessControl()
    view.bind(sessionId: sessionId, scheduler: scheduler)
    return view
  }

  func updateNSView(_ view: ReprocessControl, context: Context) {
    view.bind(sessionId: sessionId, scheduler: scheduler)
  }
}

private final class ReprocessControl: NSView {
  static let requestLabel = "Reprocess All Tracks…"
  static let confirmLabel = "Reprocess All Tracks"
  static let explanation =
    "This creates replacement revisions, reusing compatible saved recognition when available. A replacement becomes selected only if its review selection and edits have not changed since this request. Earlier revisions and their corrections remain in history."

  private let requestButton = NSButton(title: ReprocessControl.requestLabel, target: nil, action: nil)
  private let explanationField = NSTextField(wrappingLabelWithString: "")
  private let confirmButton = NSButton(title: ReprocessControl.confirmLabel, target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var subscription: AnyCancellable?
  private var sessionId: String?
  private var scheduler: TranscriptionScheduler?
  private var showingConfirmation = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Reprocess transcript")
    requestButton.bezelStyle = .rounded
    requestButton.setAccessibilityLabel(Self.requestLabel)
    requestButton.target = self
    requestButton.action = #selector(ask)
    explanationField.stringValue = Self.explanation
    explanationField.font = .preferredFont(forTextStyle: .callout)
    explanationField.textColor = .secondaryLabelColor
    explanationField.maximumNumberOfLines = 4
    explanationField.lineBreakMode = .byWordWrapping
    explanationField.setAccessibilityLabel("Replacement revisions")
    confirmButton.bezelStyle = .rounded
    confirmButton.setAccessibilityLabel(Self.confirmLabel)
    confirmButton.target = self
    confirmButton.action = #selector(confirm)
    cancelButton.bezelStyle = .rounded
    cancelButton.setAccessibilityLabel("Cancel reprocess")
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    let actions = NSStackView(views: [confirmButton, cancelButton])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = ScribeSpacing.related
    let column = NSStackView(views: [requestButton, explanationField, actions])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.compact
    column.translatesAutoresizingMaskIntoConstraints = false
    explanationField.translatesAutoresizingMaskIntoConstraints = false
    explanationField.widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
    apply()
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: showingConfirmation ? 96 : 32)
  }

  func bind(sessionId: String, scheduler: TranscriptionScheduler) {
    let same = self.sessionId == sessionId && self.scheduler === scheduler
    self.sessionId = sessionId
    self.scheduler = scheduler
    if !same {
      subscription = scheduler.objectWillChange.sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    apply()
  }

  private func apply() {
    let busy = isBusy
    requestButton.isHidden = showingConfirmation
    requestButton.isEnabled = !busy
    explanationField.isHidden = !showingConfirmation
    confirmButton.isHidden = !showingConfirmation
    cancelButton.isHidden = !showingConfirmation
    confirmButton.isEnabled = showingConfirmation && !busy
    invalidateIntrinsicContentSize()
  }

  private var isBusy: Bool {
    guard let sessionId, let scheduler else { return false }
    if scheduler.runningSessionId == sessionId { return true }
    if case .queued = scheduler.state(for: sessionId) { return true }
    return false
  }

  @objc private func ask() {
    guard !isBusy else { return }
    showingConfirmation = true
    apply()
  }

  @objc private func cancel() {
    showingConfirmation = false
    apply()
  }

  @objc private func confirm() {
    guard let sessionId, let scheduler, !isBusy else { return }
    showingConfirmation = false
    apply()
    scheduler.request(sessionId: sessionId, intent: .reprocessAll)
  }
}

/// The stored run, shown with the transcript section. The field exists on the
/// first layout and fills when the section loads provenance.
private struct ProvenanceReadout: NSViewRepresentable {
  let label: String
  let text: String?

  func makeNSView(context: Context) -> ProvenanceReadoutControl {
    let view = ProvenanceReadoutControl()
    view.apply(label: label, text: text)
    return view
  }

  func updateNSView(_ view: ProvenanceReadoutControl, context: Context) {
    view.apply(label: label, text: text)
  }
}

private final class ProvenanceReadoutControl: NSView {
  private let field = NSTextField(wrappingLabelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    field.font = .preferredFont(forTextStyle: .callout)
    field.textColor = .secondaryLabelColor
    field.setAccessibilityRole(.staticText)
    field.isSelectable = true
    field.maximumNumberOfLines = 0
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: leadingAnchor),
      field.trailingAnchor.constraint(equalTo: trailingAnchor),
      field.topAnchor.constraint(equalTo: topAnchor),
      field.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    guard !field.isHidden else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
    field.preferredMaxLayoutWidth = 680
    let height = max(field.intrinsicContentSize.height, 28)
    return NSSize(width: NSView.noIntrinsicMetric, height: height)
  }

  func apply(label: String, text: String?) {
    let shown = text ?? ""
    field.stringValue = shown
    field.setAccessibilityLabel(label)
    field.isHidden = shown.isEmpty
    field.preferredMaxLayoutWidth = 680
    invalidateIntrinsicContentSize()
  }
}

/// Evidence and review controls for one claim. They are created with the claim
/// row. Return stays hidden until evidence is open, then this view shows it
/// without waiting for a later SwiftUI pass.
private struct ClaimActionMount: NSViewRepresentable {
  @ObservedObject var transcripts: TranscriptLibraryModel
  let claimId: String
  let canSeek: Bool
  let onSeek: (Int64) -> Void

  func makeNSView(context: Context) -> ClaimActionBanner {
    let view = ClaimActionBanner()
    view.bind(transcripts: transcripts, claimId: claimId, canSeek: canSeek, onSeek: onSeek)
    return view
  }

  func updateNSView(_ view: ClaimActionBanner, context: Context) {
    view.bind(transcripts: transcripts, claimId: claimId, canSeek: canSeek, onSeek: onSeek)
  }
}

private final class ClaimActionBanner: NSView {
  private let supporting = NSButton(title: "Supporting evidence", target: nil, action: nil)
  private let contradicting = NSButton(title: "Contradicting evidence", target: nil, action: nil)
  private let returnButton = NSButton(title: "Return to claim", target: nil, action: nil)
  private let confirmButton = NSButton(title: "Confirm", target: nil, action: nil)
  private let correctButton = NSButton(title: "Correct", target: nil, action: nil)
  private let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
  private let correctionField = NSTextField(string: "")
  private var subscription: AnyCancellable?
  private var transcripts: TranscriptLibraryModel?
  private var claimId = ""
  private var canSeek = false
  private var onSeek: (@MainActor (Int64) -> Void)?
  private var appliedClaimText: String?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityIdentifier("Claim actions")
    correctionField.placeholderString = "Correct this claim"
    correctionField.setAccessibilityLabel("Corrected claim text")
    correctionField.lineBreakMode = .byTruncatingTail
    returnButton.setAccessibilityLabel("Return to claim")
    confirmButton.setAccessibilityLabel("Confirm claim")
    correctButton.setAccessibilityLabel("Correct claim")
    rejectButton.setAccessibilityLabel("Reject claim")
    let buttons = [
      supporting, contradicting, returnButton, confirmButton, correctButton, rejectButton,
    ]
    for button in buttons {
      button.bezelStyle = .rounded
      button.target = self
    }
    supporting.action = #selector(openSupporting)
    contradicting.action = #selector(openContradicting)
    returnButton.action = #selector(returnToClaim)
    confirmButton.action = #selector(confirmClaim)
    correctButton.action = #selector(correctClaim)
    rejectButton.action = #selector(rejectClaim)
    let evidence = NSStackView(views: [supporting, contradicting, returnButton])
    evidence.orientation = .horizontal
    evidence.alignment = .centerY
    evidence.spacing = ScribeSpacing.related
    let review = NSStackView(views: [confirmButton, correctButton, rejectButton])
    review.orientation = .horizontal
    review.alignment = .centerY
    review.spacing = ScribeSpacing.related
    let column = NSStackView(views: [evidence, correctionField, review])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = ScribeSpacing.compact
    column.translatesAutoresizingMaskIntoConstraints = false
    correctionField.translatesAutoresizingMaskIntoConstraints = false
    correctionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
    ])
    apply()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 120)
  }

  func bind(
    transcripts: TranscriptLibraryModel,
    claimId: String,
    canSeek: Bool,
    onSeek: @escaping @MainActor (Int64) -> Void
  ) {
    self.canSeek = canSeek
    self.onSeek = onSeek
    let same = self.transcripts === transcripts && self.claimId == claimId
    self.transcripts = transcripts
    self.claimId = claimId
    if !same {
      subscription = Publishers.Merge3(
        transcripts.$claimEvidenceOpen.map { _ in () },
        transcripts.$focusedClaim.map { _ in () },
        transcripts.$derivedClaims.map { _ in () }
      ).sink { [weak self] _ in
        DispatchQueue.main.async { self?.apply() }
      }
    }
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }

  private func apply() {
    guard let transcripts,
      let claim = transcripts.derivedClaims.first(where: { $0.claimId == claimId })
    else {
      isHidden = true
      return
    }
    isHidden = false
    let returning =
      transcripts.claimEvidenceOpen && transcripts.focusedClaim?.claimId == claim.claimId
    supporting.isHidden = claim.supportingCount == 0
    supporting.isEnabled = canSeek
    supporting.setAccessibilityLabel("Supporting evidence, \(claim.supportingCount)")
    contradicting.isHidden = claim.contradictingCount == 0
    contradicting.isEnabled = canSeek
    contradicting.setAccessibilityLabel("Contradicting evidence, \(claim.contradictingCount)")
    returnButton.isHidden = !returning
    if correctionField.currentEditor() == nil, appliedClaimText != claim.text {
      correctionField.stringValue = claim.text
      appliedClaimText = claim.text
    }
    let trimmed = correctionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    confirmButton.isEnabled = true
    correctButton.isEnabled = !trimmed.isEmpty
    rejectButton.isEnabled = true
    layoutSubtreeIfNeeded()
  }

  @objc private func openSupporting() { openEvidence("supporting") }
  @objc private func openContradicting() { openEvidence("contradicting") }

  private func openEvidence(_ side: String) {
    let transcripts = transcripts
    let claimId = claimId
    let onSeek = onSeek
    Task { @MainActor in
      if let start = await transcripts?.openClaimEvidence(claimId: claimId, side: side) {
        onSeek?(start)
      }
    }
  }

  @objc private func returnToClaim() {
    let transcripts = transcripts
    Task { @MainActor in transcripts?.returnToClaim() }
  }

  @objc private func confirmClaim() { review("accepted", text: nil) }
  @objc private func rejectClaim() { review("rejected", text: nil) }

  @objc private func correctClaim() {
    review("corrected", text: correctionField.stringValue)
  }

  private func review(_ action: String, text: String?) {
    let transcripts = transcripts
    let claimId = claimId
    confirmButton.isEnabled = false
    correctButton.isEnabled = false
    rejectButton.isEnabled = false
    Task { @MainActor in
      _ = await transcripts?.adjudicateClaim(claimId: claimId, action: action, text: text)
    }
  }
}

enum ClaimReviewSpeech {
  static func words(_ token: String) -> String {
    switch token {
    case "decision": "Decision"
    case "commitment": "Commitment"
    case "fact": "Fact"
    case "question": "Question"
    case "open_loop": "Open loop"
    case "loose_end": "Loose end"
    case "topic": "Topic"
    case "number_or_term": "Number or term"
    case "summary_statement": "Summary"
    case "mentioned": "Mentioned"
    case "proposed": "Proposed"
    case "agreed": "Agreed"
    case "assigned": "Assigned"
    case "accepted": "Accepted"
    case "completed": "Completed"
    case "contradicted": "Contradicted"
    case "superseded": "Superseded"
    case "unresolved": "Unresolved"
    case "unknown": "Unknown"
    case "open": "Open"
    case "answered": "Answered"
    case "closed": "Closed"
    case "corrected": "Corrected"
    case "rejected": "Rejected"
    default: token
    }
  }
}
