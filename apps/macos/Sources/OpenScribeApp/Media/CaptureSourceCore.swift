@preconcurrency import AVFoundation
import Foundation

/// The step every capture source runs on its own serial writer queue: write
/// one buffer, hand the written audio to live captions, remember the last
/// written host time, and produce the source's first-sample receipt once per
/// start. Lifecycle, failure reporting and the queue itself stay with the
/// adapter, because each platform API needs its own. A stop reads
/// `lastWrittenHostTime` only after draining the writer queue.
final class CaptureSourceCore: @unchecked Sendable {
  let writer: CapturedAudioWriting
  /// Live captions listen to audio after it is written; see `LiveAudioListening`.
  let liveAudio = LiveAudioListenerSlot()
  private let lock = NSLock()
  private var lastHostTime: UInt64?
  private var firstSampleReported = false

  init(writer: CapturedAudioWriting) {
    self.writer = writer
  }

  /// Forgets the previous start's host time and first-sample report.
  func reset() {
    lock.withLock {
      lastHostTime = nil
      firstSampleReported = false
    }
  }

  var lastWrittenHostTime: UInt64? { lock.withLock { lastHostTime } }

  /// Writes `buffer` captured at `hostTime`. `onWritten` sees the written frame
  /// count before live captions do. The receipt is returned for the first
  /// written buffer that `admitsFirstSample` allows, and never again.
  func write(
    _ buffer: AVAudioPCMBuffer,
    hostTime: UInt64,
    onWritten: (AVAudioFrameCount) -> Void = { _ in },
    admitsFirstSample: @autoclosure () -> Bool = true
  ) throws -> (frames: AVAudioFrameCount, firstSample: NativeFirstSampleReceipt?) {
    let written = try writer.writeCapturedBuffer(buffer, hostTime: hostTime)
    guard written > 0 else { return (0, nil) }
    onWritten(written)
    liveAudio.deliver(buffer, writtenFrames: written, hostTime: hostTime)
    let admitted = admitsFirstSample()
    let reports = lock.withLock { () -> Bool in
      lastHostTime = hostTime
      guard admitted, !firstSampleReported else { return false }
      firstSampleReported = true
      return true
    }
    guard reports else { return (written, nil) }
    let receipt = try writer.firstSampleReceipt(hostTime: hostTime, frameCount: UInt64(written))
    return (written, receipt)
  }
}
