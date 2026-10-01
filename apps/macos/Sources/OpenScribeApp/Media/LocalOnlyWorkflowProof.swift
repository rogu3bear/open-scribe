import AppKit
import Foundation

/// Explicit process proof that Open Scribe stays useful with networking
/// denied (ADR 0013 Proof; M4 local-only). The harness launches this
/// process under a sandbox profile that refuses every IP connection and
/// listener, then runs the whole local workflow: record, declare, add
/// context, recover, play back, mix, transcribe with an installed model,
/// correct, search, export, and delete. The report holds identifiers and
/// counts only; the harness then searches every diagnostic surface for the
/// sentinel strings below, which must never appear there.
enum LocalOnlyWorkflowProof {
  static let title = "LocalOnlyTitleSentinel7f3a"
  static let participant = "LocalOnlyParticipantSentinel51c2"
  static let topic = "LocalOnlyTopicSentinel88d0"
  static let contextText = "LocalOnlyContextSentinele41d"
  static let correction = "LocalOnlyCorrectionSentinel2b6e"

  enum ProofError: Error {
    case missingInput(String)
    case step(String)
  }

  @MainActor
  static func run(root: URL) async {
    do {
      let report = try await perform(root: root)
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        .write(to: root.appendingPathComponent("local-only-verified.json"), options: .atomic)
    } catch {
      // Error descriptions carry step names and platform codes, never content.
      try? String(describing: error).write(
        to: root.appendingPathComponent("proof-error"), atomically: true, encoding: .utf8)
    }
    NSApp.terminate(nil)
  }

  @MainActor
  private static func perform(root: URL) async throws -> [String: Any] {
    let environment = ProcessInfo.processInfo.environment
    guard let modelPath = environment["OPEN_SCRIBE_LOCAL_PROOF_MODEL"] else {
      throw ProofError.missingInput("OPEN_SCRIBE_LOCAL_PROOF_MODEL")
    }
    guard let speechPath = environment["OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF"] else {
      throw ProofError.missingInput("OPEN_SCRIBE_LOCAL_PROOF_SPEECH_CAF")
    }
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let exports = root.appendingPathComponent("Exports", isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    var report: [String: Any] = [:]

    // Record: a synthetic two-source capture on the real recording writer.
    let capture = try TimelineRuntimeProof.capture(root: library)
    let session = capture.sessionId
    _ = try capture.preparation.declareSession(
      sessionId: session,
      declaration: NativeSessionDeclaration(participants: [participant], topic: topic))

    // Context: one real frame reduced in memory (its text is only counted),
    // then one reduced event through Rust under an explicit display scope.
    let permission = ScreenCapturePermission.current()
    report["screen_recording_permission"] = permission == .granted ? "granted" : "not_granted"
    if permission == .granted {
      let displays = ContextTopology.current()
      guard let main = displays.first(where: \.isMain) ?? displays.first else {
        throw ProofError.step("topology")
      }
      let image = try await ScreenContextFrameSource().captureFrame(.display(main.id, region: nil))
      _ = try ContextReducer.fingerprint(image)
      report["context_frame_pixels"] = image.width * image.height
      report["context_frame_text_blocks"] = try ContextReducer.recognize(image).count
      let names = ContextTopology.uniqueNames(displays)
      let detail = try capture.preparation.contextAction(
        sessionId: session,
        action: .authorize(
          request: NativeContextScopeRequest(
            mode: .watchDisplay,
            targets: [
              NativeContextTarget(
                kind: .display, platformId: String(main.id), name: names[main.id] ?? main.name,
                application: nil, description: ContextTopology.describe(main, in: displays))
            ],
            bounds: nil, topology: ContextTopology.native(displays),
            exclusions: ContextScopeModel.exclusions(for: .watchDisplay), permission: permission,
            retention: .noPixels)))
      guard let scope = detail.scopes.last else { throw ProofError.step("context scope") }
      let host = mach_absolute_time()
      let decision = try capture.preparation.proposeContextEvent(
        sessionId: session,
        proposal: NativeContextProposal(
          scopeId: scope.scopeId, epoch: scope.epoch, reason: .fixedScopeChange,
          startHostTime: host, endHostTime: host,
          observedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
          source: NativeContextSource(platformId: String(main.id), name: main.name, application: nil),
          bounds: nil, reducerRevision: ContextReducer.revision,
          visionRevision: ContextReducer.visionRevision, languages: ContextReducer.languages,
          blocks: [NativeContextTextBlock(text: contextText, x: 0.1, y: 0.1, width: 0.4, height: 0.05)]))
      guard case .accepted = decision else { throw ProofError.step("context event") }
      report["context_events_accepted"] = 1
    }

    // Recover and render playback, then build and verify the mix.
    let verified = try TimelineRuntimeProof.verify(root: library, sessionId: session)
    report["recovered_segments"] = verified["segments"]
    report["rendered_frames"] = verified["rendered_frames"]
    let mix = try ValidatedMixdownBuilder.buildIfNeeded(
      preparation: capture.preparation, sessionId: session, storagePath: library.path)
    report["validated_mix_bytes"] = mix.byteLength

    // Transcribe a spoken import with a locally installed model.
    let spoken = try capture.preparation.importRecoverableCaf(title: title, sourcePath: speechPath)
      .sessionId
    let speech = SpeechTranscriptionModel(managedRoot: library)
    guard let model = speech.models.first,
      await speech.install(model, from: URL(fileURLWithPath: modelPath))
    else { throw ProofError.step("model install") }
    guard await speech.transcribe(sessionId: spoken) else { throw ProofError.step("transcribe") }

    // Review: correct, search, and export.
    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let review = TranscriptLibraryModel(
      library: try NativeTranscriptLibrary.open(managedRoot: library.path),
      moveToTrash: { url in
        let destination = trash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
      },
      timeline: { [preparation = capture.preparation] id in
        try preparation.playbackTimeline(sessionId: id)
      })
    review.load(sessionId: spoken)
    guard review.availability == .final, let first = review.segments.first else {
      throw ProofError.step("final transcript")
    }
    report["transcript_segments"] = review.segments.count
    guard review.export(format: .plainText, to: exports.appendingPathComponent("verbatim.txt")) else {
      throw ProofError.step("verbatim export")
    }
    guard review.correct(first, text: correction) else { throw ProofError.step("correction") }
    review.search(correction)
    report["correction_search_hits"] = review.searchResults.count
    guard review.export(format: .transcriptJson, to: exports.appendingPathComponent("transcript.json"))
    else { throw ProofError.step("transcript export") }

    review.load(sessionId: session)
    guard await review.export(.sessionManifest, to: exports.appendingPathComponent("manifest.json")),
      await review.export(.mixWAV, to: exports.appendingPathComponent("mix.wav"))
    else { throw ProofError.step("conversation export") }
    let package = exports.appendingPathComponent("Conversation.openscribe")
    guard await review.export(.portablePackage, to: package) else {
      throw ProofError.step("package export")
    }
    report["package_files"] = try verifyPortablePackage(packagePath: package.path).files
    // Open the package as another Mac would: a second library, verified first.
    let otherRoot = root.appendingPathComponent("OtherMac", isDirectory: true)
    let opened = try NativeTranscriptLibrary.open(managedRoot: otherRoot.path)
      .importPortablePackage(packagePath: package.path)
    report["restored_package_media_files"] = Int(opened.mediaFiles)
    report["restored_timeline_segments"] = try NativeRecordingPreparation.open(
      managedRoot: otherRoot.path
    ).playbackTimeline(sessionId: opened.sessionId).count
    report["saved_context_events"] = review.contextEvents.count
    report["declared_participants"] = review.contextDetail?.declaration.participants.count ?? 0

    // Delete the spoken conversation through both phases.
    review.requestDeletion(sessionId: spoken)
    guard review.pendingDeletion != nil, review.confirmDeletion() else {
      throw ProofError.step("deletion")
    }
    report["deleted_sessions"] = 1
    withExtendedLifetime(capture) {}
    return report
  }
}
