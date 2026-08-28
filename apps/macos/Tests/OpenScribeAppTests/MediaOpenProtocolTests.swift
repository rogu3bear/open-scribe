import AVFoundation
import XCTest

@testable import OpenScribeApp

final class MediaOpenProtocolTests: XCTestCase {
  private var managedRoots: [URL] = []

  override func tearDownWithError() throws {
    for root in managedRoots {
      try? FileManager.default.removeItem(at: root)
    }
    managedRoots.removeAll()
    try super.tearDownWithError()
  }

  func testSwiftCAFWriterRoundTripsCoarseEvidenceWithoutRecording() throws {
    let (controller, root) = try makeController()
    let prepared = try controller.prepareSession(title: "Deterministic media-open proof")
    XCTAssertTrue(prepared.journalDurable)
    XCTAssertFalse(prepared.mediaFilesOpen)
    XCTAssertFalse(prepared.recordingStarted)

    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: authorization.absolutePath))

    let writer = try ManagedCAFWriter(authorization: authorization)
    try writer.writeDeterministicFrames(4_800)
    let evidence = try controller.acceptMediaOpen(receipt: writer.receipt())
    XCTAssertTrue(evidence.journalDurable)
    XCTAssertTrue(evidence.mediaFilesOpen)
    XCTAssertFalse(evidence.recordingStarted)
    XCTAssertEqual(evidence.lastJournalSequence, 4)

    try writer.writeDeterministicFrames(480)
    let firstSampleReceipt = try writer.firstSampleReceipt(hostTime: 42_000, frameCount: 480)
    let firstSample = try controller.acceptFirstSample(
      receipt: firstSampleReceipt
    )
    XCTAssertTrue(firstSample.firstSampleDurable)
    XCTAssertEqual(firstSample.firstSampleSessionNanoseconds, 0)
    XCTAssertFalse(firstSample.recordingStarted)
    XCTAssertEqual(firstSample.lastJournalSequence, 5)

    let sealReceipt = try writer.sealSegmentReceipt(finalSampleHostTime: 52_000)
    let sealed = try controller.sealSegment(receipt: sealReceipt)
    XCTAssertTrue(sealed.segmentSealed)
    XCTAssertFalse(sealed.recordingStarted)
    XCTAssertEqual(sealed.finalSampleCount, 5_280)
    XCTAssertEqual(sealed.finalByteLength, firstSampleReceipt.observedByteLength)
    XCTAssertEqual(sealed.digestSha256.count, 64)
    XCTAssertEqual(sealed.lastJournalSequence, 6)
    let replayedReceipt = try writer.sealSegmentReceipt(finalSampleHostTime: 52_000)
    XCTAssertEqual(replayedReceipt.finalByteLength, sealReceipt.finalByteLength)
    XCTAssertEqual(try controller.sealSegment(receipt: replayedReceipt), sealed)
    XCTAssertThrowsError(try writer.sealSegmentReceipt(finalSampleHostTime: 52_001)) { error in
      XCTAssertEqual(error as? ManagedCAFWriterError, .alreadySealed)
    }
    XCTAssertThrowsError(try writer.writeDeterministicFrames(1)) { error in
      XCTAssertEqual(error as? ManagedCAFWriterError, .alreadySealed)
    }

    let media = try AVAudioFile(
      forReading: URL(fileURLWithPath: authorization.absolutePath)
    )
    XCTAssertEqual(media.processingFormat.sampleRate, 48_000)
    XCTAssertEqual(media.processingFormat.channelCount, 1)
    XCTAssertEqual(media.length, 5_280)

    let journal = try String(
      contentsOf:
        root
        .appendingPathComponent("Sessions")
        .appendingPathComponent(prepared.sessionId)
        .appendingPathComponent("recovery.jsonl"),
      encoding: .utf8
    )
    XCTAssertTrue(journal.contains("segment_open_intent"))
    XCTAssertTrue(journal.contains("segment_opened"))
    XCTAssertTrue(journal.contains("segment_sealed"))
    XCTAssertFalse(journal.contains("Deterministic media-open proof"))
  }

  func testWriterUsesCreateNewAndRustRejectsStaleToken() throws {
    let (controller, _) = try makeController()
    let prepared = try controller.prepareSession(title: "Exclusive writer proof")
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId,
      sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone"
    )
    let writer = try ManagedCAFWriter(authorization: authorization)
    XCTAssertThrowsError(try ManagedCAFWriter(authorization: authorization)) { error in
      XCTAssertEqual(error as? ManagedCAFWriterError, .pathAlreadyExists)
    }

    try writer.writeDeterministicFrames(480)
    let valid = try writer.receipt()
    let stale = NativeMediaOpenReceipt(
      sessionId: valid.sessionId,
      trackId: valid.trackId,
      segmentId: valid.segmentId,
      openToken: UUID().uuidString.lowercased(),
      writerGeneration: valid.writerGeneration,
      relativePath: valid.relativePath,
      initialByteLength: valid.initialByteLength
    )
    XCTAssertThrowsError(try controller.acceptMediaOpen(receipt: stale)) { error in
      XCTAssertEqual(error as? NativeStorageError, .IntegrityMismatch)
    }
    let accepted = try controller.acceptMediaOpen(receipt: valid)
    XCTAssertFalse(accepted.recordingStarted)
  }

  private func makeController() throws -> (NativeRecordingPreparation, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-media-open-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    managedRoots.append(root)
    return (try NativeRecordingPreparation.open(managedRoot: root.path), root)
  }
}
