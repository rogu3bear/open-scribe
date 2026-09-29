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
    XCTAssertEqual(model.availabilityText, "No transcript. Local transcription is not available in this build.")
    XCTAssertFalse(model.speakers.isEmpty)
    XCTAssertTrue(model.speakers.allSatisfy { !$0.namedByUser })
    let track = try XCTUnwrap(model.speakers.first)

    model.renameSpeaker(trackId: track.trackId, label: "  Dana ")
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }?.label, "Dana")
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }?.namedByUser, true)
    model.renameSpeaker(trackId: track.trackId, label: nil)
    XCTAssertEqual(model.speakers.first { $0.trackId == track.trackId }, track)
    model.renameSpeaker(trackId: track.trackId, label: "")
    XCTAssertNotNil(model.message)

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
    XCTAssertFalse(
      try preparation.runtimeLibrarySnapshot().savedSessions.contains { $0.sessionId == sessionId })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trash.appendingPathComponent(sessionId).path),
      "the audio remains recoverable from Trash")
    withExtendedLifetime(capture) {}
  }

  func testTimestampsAndExportNamesAreStable() {
    XCTAssertEqual(TranscriptSection.timestamp(0), "0:00")
    XCTAssertEqual(TranscriptSection.timestamp(65_400_000_000), "1:05")
    XCTAssertEqual(TranscriptSection.timestamp(3_725_000_000_000), "1:02:05")
    XCTAssertEqual(TranscriptSection.fileName("Team: sync/notes", type: .json), "Team- sync-notes.json")
    XCTAssertEqual(TranscriptSection.fileName(" .hidden", type: .plainText), "Transcript.txt")
  }
}
