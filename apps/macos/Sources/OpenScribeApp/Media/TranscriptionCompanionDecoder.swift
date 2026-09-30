@preconcurrency import AVFoundation
import Foundation

/// Decodes a compressed import's Rust-verified bytes into the 48 kHz 16-bit
/// PCM CAF companion that Rust requires before it will transcribe the import.
/// The managed original is only read through its lease. Rust rehashes the
/// original and checks the companion's format and exact frame count, so this
/// adapter decides nothing about evidence.
enum TranscriptionCompanionDecoder {
  static func decode(
    lease: NativeImportedPlaybackLease, to destination: URL, isCancelled: () -> Bool
  ) throws {
    let receipt = try RecoveredPlaybackDescriptorReceipt(serialized: lease.playbackPath())
    let decoder = try CallbackCAFDecoder(
      source: try VerifiedDescriptorPlaybackSource.prepare(receipt: receipt),
      fileTypeHint: receipt.fileTypeHint, onClose: {})
    defer { decoder.close() }
    let format = decoder.processingFormat
    // The file closes, and its header is final, when it leaves this scope.
    do {
      let file = try AVAudioFile(
        forWriting: destination,
        settings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: format.sampleRate,
          AVNumberOfChannelsKey: format.channelCount,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ],
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved)
      while let buffer = try decoder.read(maximumFrames: 16_384) {
        if isCancelled() { throw CancellationError() }
        try file.write(from: buffer)
      }
    }
    withExtendedLifetime(lease) {}
  }
}
