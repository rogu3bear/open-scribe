import AppKit
import Combine
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

  @State private var renaming: NativeSessionSpeaker?
  @State private var draftLabel = ""
  @State private var renameRequest = UUID()
  @State private var showingModels = false
  @State private var showingReprocessConfirmation = false

  /// The reader is part of the document only after this model is bound to
  /// this session and has passages. The view task performs that binding.
  static func showsReader(
    session: RuntimeSessionPresentation, transcripts: TranscriptLibraryModel
  ) -> Bool {
    session.transcriptionUnavailableReason == nil
      && transcripts.sessionId == session.sessionId && !transcripts.segments.isEmpty
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
        text: session.transcriptionUnavailableReason == nil ? transcripts.provenanceText : nil
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      if showsTranscriptionControls {
        transcriptionControls
      }
      if !showingModels, session.transcriptionUnavailableReason == nil {
        outcomeNote
      }
      if Self.showsReader(session: session, transcripts: transcripts) {
        TranscriptReader(
          sessionId: session.sessionId, transcripts: transcripts, canSeek: canSeek,
          isPlaybackActive: isPlaybackActive, playbackPosition: playbackPosition,
          onSeek: onSeek, onFollowPlayback: onFollowPlayback
        )
        .id(session.sessionId)
        DisclosureGroup("Audio source labels") {
          VStack(alignment: .leading, spacing: ScribeSpacing.related) {
            Text("Source labels apply to every unassigned passage on that audio track.")
              .font(.caption)
              .foregroundStyle(.secondary)
            speakerList
          }
          .padding(.top, ScribeSpacing.related)
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
      await transcripts.load(session: session)
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
      if session.transcript.documentAvailability == .final
        || session.transcript.replacementResumable
      {
        if session.transcript.replacementResumable {
          Button("Resume Replacement") {
            scheduler.resumeReplacement(sessionId: session.sessionId)
          }
        }
        Button("Reprocess All Tracks…") { showingReprocessConfirmation = true }
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

  private var speakerList: some View {
    HStack(spacing: ScribeSpacing.compact) {
      ForEach(transcripts.speakers) { speaker in
        Button {
          draftLabel = speaker.namedByUser ? speaker.label : ""
          renameRequest = UUID()
          transcripts.dismissMessage()
          renaming = speaker
        } label: {
          HStack(spacing: ScribeSpacing.tight) {
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

  private func renameSheet(_ speaker: NativeSessionSpeaker) -> some View {
    VStack(alignment: .leading, spacing: ScribeSpacing.compact) {
      Text("Rename Speaker")
        .scribeSectionHeading(.title2.weight(.semibold))
      Text("This names everyone heard on this source. It does not identify individual voices.")
        .font(.callout)
        .foregroundStyle(.secondary)
      if let history = transcripts.speakerLabelHistory.first(where: {
        $0.trackId == speaker.trackId
      }) {
        Text("Name history")
          .font(.callout.weight(.semibold))
        Text(TranscriptLibraryModel.speakerLabelHistoryText(for: history))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      TextField("Name", text: $draftLabel)
        .textFieldStyle(.roundedBorder)
      sheetFailure
      HStack {
        if speaker.namedByUser {
          Button("Use Source Name") {
            saveSourceName(speaker, label: nil)
          }
          .disabled(transcripts.isEditing)
        }
        Spacer()
        SheetActionButtons(
          confirmTitle: "Rename",
          isConfirmationDisabled: transcripts.isEditing || transcripts.isLoading
            || draftLabel.trimmingCharacters(in: .whitespaces).isEmpty,
          cancel: { renaming = nil },
          confirm: {
            saveSourceName(speaker, label: draftLabel)
          })
      }
    }
    .padding(ScribeSpacing.standard)
    .frame(width: 400)
  }

  private func saveSourceName(_ speaker: NativeSessionSpeaker, label: String?) {
    let request = renameRequest
    Task {
      if await transcripts.renameSpeaker(
        trackId: speaker.trackId, label: label, in: session.sessionId),
        renameRequest == request
      {
        renaming = nil
      }
    }
  }

  private func export(_ format: NativeTranscriptExportFormat, type: UTType) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(session.title, type: type)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await transcripts.export(format: format, to: url, from: session.sessionId) }
  }

  private func exportConversation(
    _ kind: TranscriptLibraryModel.ConversationExport, type: UTType, suffix: String = ""
  ) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName(session.title + suffix, type: type)
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
    panel.nameFieldStringValue = Self.fileName(session.title, type: packageType)
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

  static func timestamp(_ nanoseconds: Int64) -> String {
    let seconds = max(0, nanoseconds) / 1_000_000_000
    let (hours, minutes, remainder) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
    let pad = { (value: Int64) in value < 10 ? "0\(value)" : "\(value)" }
    return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(remainder))" : "\(minutes):\(pad(remainder))"
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

/// The stored run, shown with the transcript section. The field exists on the
/// first layout and fills when the section loads provenance.
private struct ProvenanceReadout: NSViewRepresentable {
  let text: String?

  func makeNSView(context: Context) -> ProvenanceReadoutControl {
    let view = ProvenanceReadoutControl()
    view.apply(text)
    return view
  }

  func updateNSView(_ view: ProvenanceReadoutControl, context: Context) {
    view.apply(text)
  }
}

private final class ProvenanceReadoutControl: NSView {
  private let field = NSTextField(wrappingLabelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    field.font = .preferredFont(forTextStyle: .callout)
    field.textColor = .secondaryLabelColor
    field.setAccessibilityLabel("Model provenance")
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

  func apply(_ text: String?) {
    let shown = text ?? ""
    field.stringValue = shown
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
