@preconcurrency import AVFoundation
import Foundation

enum TimelineMixExportError: Error {
  case invalidOutput
}

/// Renders a captured session's Rust-validated timeline as a lossless 48 kHz
/// 16-bit stereo WAV mix, through the same reader that playback and the
/// validated AAC mix use. The file is written beside the destination, read
/// back, and only then moved into place.
enum TimelineMixExporter {
  @discardableResult
  static func exportWAV(plan: [NativeTimelineSegment], to destination: URL) throws -> UInt64 {
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    let expectedFrames = reader.totalFrames > 0 ? UInt64(reader.totalFrames) : 0
    guard expectedFrames > 0 else { throw TimelineMixExportError.invalidOutput }
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.deletingPathExtension().lastPathComponent).partial-\(UUID().uuidString).wav")
    do {
      // The file closes, and its header is final, when it leaves this scope.
      do {
        let file = try AVAudioFile(
          forWriting: staging,
          settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TimelinePCMReader.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
          ],
          commonFormat: .pcmFormatFloat32, interleaved: false)
        while let buffer = try reader.read(maximumFrames: 16_384) {
          try file.write(from: buffer)
        }
      }
      let handle = try FileHandle(forUpdating: staging)
      try handle.synchronize()
      try handle.close()
      let written = try AVAudioFile(forReading: staging)
      let frames = written.length > 0 ? UInt64(written.length) : 0
      guard written.fileFormat.channelCount == 2,
        written.fileFormat.sampleRate == TimelinePCMReader.sampleRate,
        (frames > expectedFrames ? frames - expectedFrames : expectedFrames - frames) <= 1
      else { throw TimelineMixExportError.invalidOutput }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
      } else {
        try FileManager.default.moveItem(at: staging, to: destination)
      }
      return frames
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }
}
