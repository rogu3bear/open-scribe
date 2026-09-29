import AVFoundation
import XCTest

@testable import OpenScribeApp

final class TimelineWorkflowTests: XCTestCase {
  func testTwoSegmentTracksRecoverAndRenderAtTheirOriginalOffsets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = try TimelineRuntimeProof.capture(root: root)
    let report = try TimelineRuntimeProof.verify(root: root, sessionId: capture.sessionId)
    XCTAssertEqual(report["segments"], 4)
    XCTAssertEqual(report["rendered_frames"], 1_548_000)
    XCTAssertEqual(
      try TimelineRuntimeProof.verify(root: root, sessionId: capture.sessionId), report)
    withExtendedLifetime(capture) {}
  }

  func testTimelineRejectsTimestampFreeCapture() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = try TimelineRuntimeProof.capture(root: root)
    XCTAssertThrowsError(
      try capture.writers[0].writeCapturedBuffer(TimelineRuntimeProof.buffer(frames: 10, value: 1)))
  }

  func testRecoveredSourcesProduceAValidatedStereoMixWithoutReplacingTracks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = try TimelineRuntimeProof.capture(root: root)
    _ = try TimelineRuntimeProof.verify(root: root, sessionId: capture.sessionId)
    let preparation = try NativeRecordingPreparation.open(managedRoot: root.path)
    let mix = try ValidatedMixdownBuilder.buildIfNeeded(
      preparation: preparation, sessionId: capture.sessionId, storagePath: root.path)
    XCTAssertEqual(mix.expectedFrameCount, 1_548_000)
    XCTAssertEqual(mix.digestSha256.count, 64)
    let reopened = try NativeRecordingPreparation.open(managedRoot: root.path)
    XCTAssertEqual(
      try reopened.validatedMixdown(sessionId: capture.sessionId)?.digestSha256,
      mix.digestSha256)
    let lease = try XCTUnwrap(
      try reopened.leaseValidatedMixdown(sessionId: capture.sessionId))
    XCTAssertTrue(lease.playbackPath().hasPrefix("v3;"))
    let descriptor = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    let source = try VerifiedDescriptorPlaybackSource.prepare(receipt: descriptor)
    let leasedDecoder = try CallbackCAFDecoder(
      source: source, fileTypeHint: descriptor.fileTypeHint, onClose: {})
    defer { leasedDecoder.close() }
    XCTAssertEqual(try leasedDecoder.read(maximumFrames: 1_024)?.format.channelCount, 2)
    XCTAssertEqual(
      try reopened.playbackTimeline(sessionId: capture.sessionId).count, 4)
    let decoded = try AVAudioFile(
      forReading: root.appendingPathComponent("Sessions")
        .appendingPathComponent(capture.sessionId)
        .appendingPathComponent(mix.relativePath))
    XCTAssertEqual(decoded.fileFormat.channelCount, 2)
    decoded.framePosition = 62_400
    let probe = try XCTUnwrap(AVAudioPCMBuffer(
      pcmFormat: decoded.processingFormat, frameCapacity: 1_024))
    try decoded.read(into: probe, frameCount: 1_024)
    XCTAssertEqual(probe.frameLength, 1_024)
    let samples = try XCTUnwrap(probe.floatChannelData)
    XCTAssertGreaterThan(samples[0][512] - samples[1][512], 0.15)
    withExtendedLifetime(capture) {}
  }

  func testSourceDiscontinuityIsARealGapInRecoveredPlayback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = try TimelineRuntimeProof.capture(root: root)
    for (index, writer) in capture.writers.enumerated() {
      let first = try writer.firstSampleReceipt(hostTime: 0, frameCount: 0)
      _ = try writer.writeCapturedBuffer(
        TimelineRuntimeProof.buffer(
          frames: 4_800, value: index == 0 ? 8192 : 16384,
          channels: writer.authorization.channels, rightValue: index == 1 ? -8192 : nil),
        hostTime: first.firstSampleHostTime + AVAudioTime.hostTime(forSeconds: 32)
      )
    }
    let reopened = try NativeRecordingPreparation.open(managedRoot: root.path)
    XCTAssertEqual(try reopened.recoverPlayableSessions().count, 6)
    let plan = try reopened.playbackTimeline(sessionId: capture.sessionId)
    XCTAssertEqual(plan.filter { $0.gapNanoseconds > 900_000_000 }.count, 2)
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    var position: Int64 = 0
    let gapFrame: Int64 = 1_560_000  // 32.5s: both sources have stopped; neither has resumed.
    var checked = false
    while let buffer = try reader.read(maximumFrames: 16_384) {
      if gapFrame >= position && gapFrame < position + Int64(buffer.frameLength) {
        XCTAssertEqual(buffer.floatChannelData![0][Int(gapFrame - position)], 0)
        checked = true
      }
      position += Int64(buffer.frameLength)
    }
    XCTAssertTrue(checked)
    withExtendedLifetime(capture) {}
  }
}
