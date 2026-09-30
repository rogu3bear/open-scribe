import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import OpenScribeApp

@MainActor
final class TranscriptLibraryModelTests: XCTestCase {
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
      "No transcript. This build cannot transcribe locally; the recorded audio above is complete.")
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
        session: session, transcripts: model, canSeek: true, onSeek: { _ in }
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
