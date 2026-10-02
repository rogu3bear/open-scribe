import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import OpenScribeApp

@MainActor
final class TranscriptLibraryModelTests: XCTestCase {
  private func session(
    _ id: String, calibrated: Bool, sources: [NativeMediaSourceKind], recovered: Bool = false
  ) -> RuntimeSessionPresentation {
    RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: id, title: id, lifecycle: "ready_for_review", health: "healthy",
        elapsedSeconds: 1, journalDurable: true, mediaFilesOpen: false,
        interruptionReason: nil, recovered: recovered, hasCaptureTimeline: calibrated,
        sources: sources.map {
          NativeRuntimeSourceSnapshot(kind: $0, displayName: "Fixture", lifecycle: "sealed")
        }, playableMedia: nil))
  }

  func testMissingCaptureTimingDoesNotBlockImportsOrCalibratedCaptures() {
    XCTAssertNil(session("import", calibrated: false, sources: []).transcriptionUnavailableReason)
    XCTAssertNil(
      session("capture", calibrated: true, sources: [.microphone, .systemAudio])
        .transcriptionUnavailableReason)
    XCTAssertNil(
      session("restored", calibrated: true, sources: [.microphone], recovered: true)
        .transcriptionUnavailableReason)
    XCTAssertNotNil(
      session("single-source", calibrated: false, sources: [.microphone])
        .transcriptionUnavailableReason)
    XCTAssertNotNil(
      session("two-source", calibrated: false, sources: [.microphone, .systemAudio])
        .transcriptionUnavailableReason)
  }

  func testMissingTimingClearsPriorTranscriptAndRetainsAvailableMetadata() {
    let library = TranscriptTimingLibraryFake()
    let model = TranscriptLibraryModel(library: library)
    let valid = session("valid", calibrated: false, sources: [])
    let historical = session("historical", calibrated: false, sources: [.microphone])
    model.load(session: valid)
    model.search("fixture")
    XCTAssertEqual(model.availability, .final)
    XCTAssertEqual(model.segments.first?.trackId, "valid")
    XCTAssertFalse(model.searchResults.isEmpty)
    XCTAssertEqual(model.audioOptions?.originalExtension, "caf")
    XCTAssertEqual(library.transcriptReads, 2)

    model.load(session: historical)
    XCTAssertEqual(model.sessionId, "historical")
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertTrue(model.segments.isEmpty)
    XCTAssertTrue(model.searchResults.isEmpty)
    XCTAssertEqual(model.availabilityText, historical.transcriptionUnavailableReason)
    XCTAssertNil(model.message)
    XCTAssertFalse(model.messageIsFailure)
    XCTAssertEqual(model.speakers.first?.trackId, "historical")
    XCTAssertEqual(model.audioOptions?.pcmTracks, ["historical"])
    XCTAssertNil(model.audioOptions?.originalExtension)
    XCTAssertEqual(library.transcriptReads, 2, "missing timing must not invoke transcript collection")

    XCTAssertTrue(model.renameSpeaker(trackId: "historical", label: "Fixture"))
    XCTAssertEqual(model.availabilityText, historical.transcriptionUnavailableReason)
    XCTAssertEqual(library.transcriptReads, 2, "same-session edit reload retains the timing gate")

    model.load(session: valid)
    XCTAssertNil(model.transcriptionUnavailableReason)
    XCTAssertEqual(model.availabilityText, "Final transcript")
    XCTAssertEqual(model.segments.first?.trackId, "valid")
    XCTAssertEqual(library.transcriptReads, 4)

    // Calibration can become available without changing the selected ID.
    model.load(session: historical)
    model.load(session: session("historical", calibrated: true, sources: [.microphone]))
    XCTAssertNil(model.transcriptionUnavailableReason)
    XCTAssertEqual(model.availability, .final)
    XCTAssertEqual(library.transcriptReads, 6)

    // Current untimed capture inventories cannot supply export options.
    // An unsuccessful metadata read must not keep the prior import's options.
    let limited = TranscriptLibraryModel(
      library: TranscriptTimingLibraryFake(rejectsHistoricalAudioOptions: true))
    limited.load(session: valid)
    XCTAssertNotNil(limited.audioOptions)
    limited.load(session: historical)
    XCTAssertNil(limited.audioOptions)
    XCTAssertNil(limited.message)
  }

  private func capturedSession() throws -> (
    root: URL, sessionId: String, capture: TimelineRuntimeProof.Capture
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let capture = try TimelineRuntimeProof.capture(root: root)
    _ = try TimelineRuntimeProof.verify(root: root, sessionId: capture.sessionId)
    return (root, capture.sessionId, capture)
  }

  func testSavedRecordingReportsNoInventedTranscriptAndNamesSpeakersFromSources() throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = TranscriptLibraryModel(managedRoot: root)
    model.load(sessionId: sessionId)
    XCTAssertEqual(model.availability, .unavailable)
    XCTAssertTrue(model.segments.isEmpty)
    XCTAssertEqual(
      model.availabilityText,
      "No transcript yet.")
    XCTAssertFalse(model.speakers.isEmpty)
    XCTAssertTrue(model.speakers.allSatisfy { !$0.namedByUser })
    let track = try XCTUnwrap(model.speakers.first)

    model.renameSpeaker(trackId: track.trackId, label: "  Dana ")
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }?.label, "Dana")
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }?.namedByUser, true)
    model.renameSpeaker(trackId: track.trackId, label: nil)
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }, track)
    XCTAssertFalse(model.renameSpeaker(trackId: track.trackId, label: ""))
    XCTAssertNotNil(model.message)
    XCTAssertTrue(model.messageIsFailure, "a failed rename is reported as a failure")
    model.dismissMessage()
    XCTAssertNil(model.message)
    XCTAssertFalse(model.messageIsFailure)

    model.search("anything")
    XCTAssertTrue(model.searchResults.isEmpty)
    withExtendedLifetime(capture) {}
  }

  func testDeletionStatesItsScopeAndOnlyCompletesAfterTrash() throws {
    let (root, sessionId, capture) = try capturedSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try NativeTranscriptLibrary.open(managedRoot: root.path)

    let failing = TranscriptLibraryModel(library: library) { _ in
      throw CocoaError(.fileWriteNoPermission)
    }
    failing.requestDeletion(sessionId: sessionId)
    let inventory = try XCTUnwrap(failing.pendingDeletion)
    XCTAssertEqual(inventory.mediaFiles, 4)
    XCTAssertGreaterThan(inventory.mediaBytes, 0)
    XCTAssertTrue(SessionDeletionSummary.text(inventory).contains("4 audio files"))
    XCTAssertTrue(SessionDeletionSummary.text(inventory).contains("Files you exported elsewhere"))
    XCTAssertFalse(failing.confirmDeletion())
    XCTAssertEqual(
      failing.message, "The conversation could not be moved to Trash, so nothing was deleted.")
    XCTAssertTrue(failing.messageIsFailure)
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    XCTAssertTrue(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })

    let trash = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: trash) }
    let model = TranscriptLibraryModel(library: library) { directory in
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let destination = trash.appendingPathComponent(directory.lastPathComponent)
      try FileManager.default.moveItem(at: directory, to: destination)
      return destination
    }
    model.requestDeletion(sessionId: sessionId)
    XCTAssertTrue(model.confirmDeletion())
    XCTAssertFalse(model.messageIsFailure)
    XCTAssertFalse(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trash.appendingPathComponent(sessionId).path),
      "the audio remains recoverable from Trash")
    withExtendedLifetime(capture) {}
  }

  private func segment(
    _ sequence: UInt32, _ start: Int64, _ speaker: String, named: Bool, _ text: String,
    machine: String? = nil
  ) -> NativeTranscriptSegment {
    NativeTranscriptSegment(
      revisionId: "revision", trackId: named ? "system" : "microphone", sequence: sequence,
      startNanoseconds: start, endNanoseconds: start + 3_000_000_000,
      verbatimText: machine ?? text, effectiveText: text, corrected: machine != nil,
      speakerLabel: speaker, speakerNamedByUser: named)
  }

  /// Renders the real view through AppKit at the full document width and at
  /// the narrowest detail width the 760-point minimum window allows. Set
  /// OPEN_SCRIBE_RENDER_DIR (TEST_RUNNER_ prefix under xcodebuild) to keep PNGs.
  func testTranscriptSectionRendersInsideTheDocumentMeasure() throws {
    let session = RuntimeSessionPresentation(
      native: NativeRuntimeSessionSnapshot(
        sessionId: "session", title: "Weekly planning", lifecycle: "ready_for_review",
        health: "healthy", elapsedSeconds: 3_900, journalDurable: true, mediaFilesOpen: false,
        interruptionReason: nil, recovered: false, hasCaptureTimeline: true, sources: [],
        playableMedia: nil))
    let segments = [
      segment(
        0, 4_200_000_000, "Local user", named: false,
        "Thanks for joining. Let's start with the release checklist, then cover the open questions from last week's review."
      ),
      segment(
        1, 12_800_000_000, "Dana", named: true,
        "The signing identity is still waiting on legal review.",
        machine: "The signing identity is still waiting on legal few."),
      segment(2, 3_725_000_000_000, "Dana", named: true, "Agreed."),
    ]
    let speakers = [
      NativeSessionSpeaker(
        trackId: "microphone", sourceKind: "microphone", label: "Local user", namedByUser: false),
      NativeSessionSpeaker(
        trackId: "system", sourceKind: "application_audio", label: "Dana", namedByUser: true),
    ]
    let cases: [(String, NativeTranscriptAvailability, [NativeTranscriptSegment], CGFloat)] = [
      ("transcript-final-760", .final, segments, 760),
      ("transcript-final-480", .final, segments, 480),
      ("transcript-unavailable-760", .unavailable, [], 760),
    ]
    for (name, availability, rows, width) in cases {
      let model = TranscriptLibraryModel(
        preview: availability, segments: rows, speakers: rows.isEmpty ? [] : speakers)
      let view = TranscriptSection(
        session: session, transcripts: model, speech: SpeechTranscriptionModel(speech: nil),
        canSeek: true, onSeek: { _ in }
      )
      .padding(32)
      .frame(width: width)
      .background(Color(nsColor: .windowBackgroundColor))
      let host = NSHostingView(rootView: view)
      let size = host.fittingSize
      XCTAssertLessThanOrEqual(size.width, width + 1, name)
      XCTAssertGreaterThan(size.height, rows.isEmpty ? 60 : 200, name)
      guard let directory = ProcessInfo.processInfo.environment["OPEN_SCRIBE_RENDER_DIR"] else {
        continue
      }
      // ImageRenderer draws SwiftUI text; AppKit-hosted controls may render
      // as placeholders.
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      let image = try XCTUnwrap(renderer.cgImage)
      let png = try XCTUnwrap(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
  }

  func testTimestampsAndExportNamesAreStable() {
    XCTAssertEqual(TranscriptSection.timestamp(0), "0:00")
    XCTAssertEqual(TranscriptSection.timestamp(65_400_000_000), "1:05")
    XCTAssertEqual(TranscriptSection.timestamp(3_725_000_000_000), "1:02:05")
    XCTAssertEqual(TranscriptSection.fileName("Team: sync/notes", type: .json), "Team- sync-notes.json")
    XCTAssertEqual(TranscriptSection.fileName(" .hidden", type: .plainText), "Transcript.txt")
  }
}

/// No Rust handle or media access: exercises the model's selection and
/// capability handling, including reads that must not run for untimed capture.
private final class TranscriptTimingLibraryFake: NativeTranscriptLibrary, @unchecked Sendable {
  private let lock = NSLock()
  private let rejectsHistoricalAudioOptions: Bool
  private var reads = 0
  var transcriptReads: Int { lock.withLock { reads } }

  init(rejectsHistoricalAudioOptions: Bool = false) {
    self.rejectsHistoricalAudioOptions = rejectsHistoricalAudioOptions
    super.init(noHandle: NoHandle())
  }
  required init(unsafeFromHandle handle: UInt64) {
    rejectsHistoricalAudioOptions = false
    super.init(unsafeFromHandle: handle)
  }

  override func availability(sessionId: String) throws -> NativeTranscriptAvailability {
    lock.withLock { reads += 1 }
    return .final
  }

  override func document(sessionId: String) throws -> [NativeTranscriptSegment] {
    lock.withLock { reads += 1 }
    return [
      NativeTranscriptSegment(
        revisionId: "fixture", trackId: sessionId, sequence: 0, startNanoseconds: 0,
        endNanoseconds: 1_000_000_000, verbatimText: "Fixture", effectiveText: "Fixture",
        corrected: false, speakerLabel: "Fixture", speakerNamedByUser: false)
    ]
  }

  override func speakers(sessionId: String) throws -> [NativeSessionSpeaker] {
    [NativeSessionSpeaker(
      trackId: sessionId, sourceKind: "microphone", label: "Fixture", namedByUser: false)]
  }

  override func audioExportOptions(sessionId: String) throws -> NativeAudioExportOptions {
    if rejectsHistoricalAudioOptions, sessionId == "historical" {
      throw NativeStorageError.InvalidState
    }
    return NativeAudioExportOptions(
      hasValidatedMix: false, originalExtension: sessionId == "valid" ? "caf" : nil,
      pcmTracks: [sessionId])
  }

  override func contextDetail(sessionId: String) throws -> NativeContextDetail {
    throw NativeStorageError.InvalidState
  }

  override func contextEvents(sessionId: String) throws -> [NativeContextEvent] { [] }
  override func renameSpeaker(sessionId: String, trackId: String, label: String?) throws {}

  override func search(query: String, sessionId: String?, limit: UInt32) throws
    -> [NativeTranscriptSearchHit]
  {
    [NativeTranscriptSearchHit(
      sessionId: "valid", sessionTitle: "Fixture", revisionId: "fixture", trackId: "valid",
      sequence: 0, startNanoseconds: 0, endNanoseconds: 1_000_000_000, effectiveText: "Fixture")]
  }
}
