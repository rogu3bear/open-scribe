@preconcurrency import AVFoundation
import Darwin
import Foundation

enum ValidatedMixdownError: Error {
  case invalidTimeline
  case destinationExists
  case invalidOutput
}

/// Runs after the source tracks are sealed. Its AAC file is derived from the
/// Rust-validated timeline; Rust checks the file and journals the coarse
/// decode receipt before any caller presents it as a verified mix.
enum ValidatedMixdownBuilder {
  private static let buildLock = NSLock()

  static func buildIfNeeded(
    preparation: NativeRecordingPreparationProtocol, sessionId: String,
    storagePath: String
  ) throws -> NativeValidatedMixdown {
    try buildLock.withLock {
      try build(preparation: preparation, sessionId: sessionId, storagePath: storagePath)
    }
  }

  private static func build(
    preparation: NativeRecordingPreparationProtocol, sessionId: String,
    storagePath: String
  ) throws -> NativeValidatedMixdown {
    if let existing = try preparation.validatedMixdown(sessionId: sessionId) {
      return existing
    }
    let plan = try preparation.playbackTimeline(sessionId: sessionId)
    let authorization = try preparation.authorizeMixdown(
      sessionId: sessionId,
      availableBytes: RecorderStorage.availableBytes(at: storagePath))
    let reader = try TimelinePCMReader(segments: plan)
    defer { reader.close() }
    let plannedFrames = reader.totalFrames > 0 ? UInt64(reader.totalFrames) : 0
    let planDifference =
      plannedFrames > authorization.expectedFrameCount
      ? plannedFrames - authorization.expectedFrameCount
      : authorization.expectedFrameCount - plannedFrames
    guard plannedFrames > 0, planDifference <= 1
    else { throw ValidatedMixdownError.invalidTimeline }

    let outputURL = URL(fileURLWithPath: authorization.absolutePath, isDirectory: false)
    let descriptor = Darwin.open(
      outputURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      if errno == EEXIST { throw ValidatedMixdownError.destinationExists }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    Darwin.close(descriptor)
    var accepted = false
    var writer: AVAudioFile?
    defer {
      writer = nil
      if !accepted { try? FileManager.default.removeItem(at: outputURL) }
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: TimelinePCMReader.sampleRate,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 192_000,
    ]
    writer = try AVAudioFile(
      forWriting: outputURL, settings: settings,
      commonFormat: .pcmFormatFloat32, interleaved: false)
    var writtenFrames: UInt64 = 0
    var lastStorageCheckFrame: UInt64 = 0
    while let buffer = try reader.read(maximumFrames: 16_384) {
      try writer?.write(from: buffer)
      writtenFrames += UInt64(buffer.frameLength)
      if writtenFrames - lastStorageCheckFrame >= 5 * 48_000 {
        guard try RecorderStorage.availableBytes(at: storagePath) >= authorization.writeFloorBytes
        else { throw ManagedCAFWriterError.storagePressure }
        lastStorageCheckFrame = writtenFrames
      }
    }
    writer = nil
    guard try RecorderStorage.availableBytes(at: storagePath) >= authorization.writeFloorBytes
    else { throw ManagedCAFWriterError.storagePressure }
    let handle = try FileHandle(forUpdating: outputURL)
    try handle.synchronize()
    try handle.close()

    let decoded = try AVAudioFile(forReading: outputURL)
    let format = decoded.fileFormat.streamDescription.pointee
    let decodedFrames = decoded.length > 0 ? UInt64(decoded.length) : 0
    let frameDifference =
      decodedFrames > authorization.expectedFrameCount
      ? decodedFrames - authorization.expectedFrameCount
      : authorization.expectedFrameCount - decodedFrames
    guard format.mFormatID == kAudioFormatMPEG4AAC,
      format.mSampleRate == TimelinePCMReader.sampleRate,
      format.mChannelsPerFrame == 2,
      decodedFrames > 0, frameDifference <= 1_024,
      let probe = AVAudioPCMBuffer(
        pcmFormat: decoded.processingFormat, frameCapacity: 16_384)
    else { throw ValidatedMixdownError.invalidOutput }
    var verifiedFrames: UInt64 = 0
    while verifiedFrames < decodedFrames {
      try decoded.read(into: probe, frameCount: 16_384)
      guard probe.frameLength > 0 else { throw ValidatedMixdownError.invalidOutput }
      verifiedFrames += UInt64(probe.frameLength)
    }
    guard verifiedFrames == decodedFrames else { throw ValidatedMixdownError.invalidOutput }

    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
    guard let size = attributes[.size] as? NSNumber, size.uint64Value >= 32 else {
      throw ValidatedMixdownError.invalidOutput
    }
    let evidence = try preparation.acceptMixdown(
      receipt: NativeMixdownReceipt(
        sessionId: sessionId,
        relativePath: authorization.relativePath,
        byteLength: size.uint64Value,
        decodedFrameCount: decodedFrames,
        sampleRateHz: 48_000,
        channels: 2,
        codec: "aac",
        boundaryFramesReadable: true
      ))
    accepted = true
    return evidence
  }
}

// Preparation-only test doubles do not own derived-media authorization.
extension NativeRecordingPreparationProtocol {
  func authorizeMixdown(sessionId: String, availableBytes: UInt64) throws
    -> NativeMixdownAuthorization
  {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }

  func acceptMixdown(receipt: NativeMixdownReceipt) throws -> NativeValidatedMixdown {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }

  func validatedMixdown(sessionId: String) throws -> NativeValidatedMixdown? {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }

  func leaseValidatedMixdown(sessionId: String) throws -> NativeImportedPlaybackLease? {
    throw ManagedCAFWriterError.unsupportedAuthorization
  }
}
