import AVFoundation
import Darwin
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

  /// F11: first-sample receipts must name the segment that holds the sample.
  /// After a rotation the receipt for the later host time belongs to segment 1.
  func testSegmentedWriterFirstSampleReceiptsAreSegmentSpecificAfterRotation() throws {
    let (_, writer, first) = try makeSegmentedWriter(confirmRecording: true)
    let second = first + AVAudioTime.hostTime(forSeconds: 2)
    _ = try writer.writeCapturedBuffer(
      TimelineRuntimeProof.buffer(frames: 480, value: 8192), hostTime: second)
    XCTAssertEqual(
      writer.authorization.writerGeneration, 2, "a host-time gap rotated into a second segment")

    let late = try writer.firstSampleReceipt(hostTime: second, frameCount: 480)
    XCTAssertEqual(late.writerGeneration, 2)
    XCTAssertEqual(late.segmentId, writer.authorization.segmentId)
    XCTAssertEqual(late.firstSampleHostTime, second)
    let early = try writer.firstSampleReceipt(hostTime: first, frameCount: 480)
    XCTAssertEqual(early.writerGeneration, 1)
    XCTAssertEqual(early.firstSampleHostTime, first)
  }

  /// F8: the main actor reads `authorization` (storage watch, health observations)
  /// while the writer queue rotates segments. The assertions cannot observe an
  /// unsynchronized swap deterministically; ThreadSanitizer reports it.
  func testSegmentedWriterAuthorizationIsReadableWhileRotating() throws {
    let (_, writer, first) = try makeSegmentedWriter(confirmRecording: true)
    let reader = ConcurrentAuthorizationReader(writer: writer)
    reader.start()
    var hostTime = first
    for _ in 0..<12 {
      hostTime += AVAudioTime.hostTime(forSeconds: 2)
      _ = try writer.writeCapturedBuffer(
        TimelineRuntimeProof.buffer(frames: 480, value: 8192), hostTime: hostTime)
    }
    let observed = reader.stop()
    XCTAssertEqual(writer.authorization.writerGeneration, 13)
    XCTAssertFalse(observed.isEmpty)
    XCTAssertTrue(
      observed.isSubset(of: Set(1...13)), "every published generation names a real segment")
  }

  private func makeController() throws -> (NativeRecordingPreparation, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-media-open-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    managedRoots.append(root)
    return (try NativeRecordingPreparation.open(managedRoot: root.path), root)
  }

  /// One microphone session with a calibrated clock and an open segmented writer
  /// holding its first accepted sample at `first`. Rust admits rotations only
  /// while Recording, so callers choose whether Recording is confirmed.
  private func makeSegmentedWriter(confirmRecording: Bool) throws
    -> (NativeRecordingPreparation, SegmentedCAFWriter, UInt64)
  {
    let (controller, _) = try makeController()
    let prepared = try controller.prepareSession(title: "Segmented writer proof")
    let anchor = mach_absolute_time()
    try SegmentedCAFWriter.anchor(
      preparation: controller, sessionId: prepared.sessionId, hostAnchor: anchor)
    let authorization = try controller.authorizeInitialMedia(
      sessionId: prepared.sessionId, sourceKind: .microphone,
      sourceDisplayName: "Synthetic microphone")
    let file = try ManagedCAFWriter(authorization: authorization)
    _ = try controller.acceptMediaOpen(receipt: file.receipt())
    let writer = SegmentedCAFWriter(current: file, preparation: controller)
    let first = anchor + AVAudioTime.hostTime(forSeconds: 1)
    _ = try writer.writeCapturedBuffer(
      TimelineRuntimeProof.buffer(frames: 480, value: 8192), hostTime: first)
    if confirmRecording {
      _ = try controller.confirmRecording(sessionId: prepared.sessionId)
    }
    return (controller, writer, first)
  }
}

/// Reads the writer's published authorization from another thread until stopped.
private final class ConcurrentAuthorizationReader: @unchecked Sendable {
  private let writer: SegmentedCAFWriter
  private let lock = NSLock()
  private var running = false
  private var generations: Set<UInt64> = []
  private let finished = DispatchGroup()

  init(writer: SegmentedCAFWriter) { self.writer = writer }

  func start() {
    lock.withLock { running = true }
    DispatchQueue.global(qos: .userInitiated).async(group: finished) { [self] in
      while lock.withLock({ running }) {
        let generation = writer.authorization.writerGeneration
        lock.withLock { _ = generations.insert(generation) }
      }
    }
  }

  func stop() -> Set<UInt64> {
    lock.withLock { running = false }
    finished.wait()
    return lock.withLock { generations }
  }
}
