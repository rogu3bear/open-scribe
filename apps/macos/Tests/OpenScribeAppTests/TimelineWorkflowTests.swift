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

  func testSourceDiscontinuityIsARealGapInRecoveredPlayback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = try TimelineRuntimeProof.capture(root: root)
    for (index, writer) in capture.writers.enumerated() {
      let first = try writer.firstSampleReceipt(hostTime: 0, frameCount: 0)
      _ = try writer.writeCapturedBuffer(
        TimelineRuntimeProof.buffer(frames: 4_800, value: index == 0 ? 8192 : 16384),
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
