@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

enum BoundedAudioImportError: Error, Equatable {
  case invalidSource
  case sourceTooLarge(actual: UInt64, maximum: UInt64)
  case decodedTooLarge(maximum: UInt64)
  case durationTooLong(maximumNanoseconds: UInt64)
  case unsupportedFormat
  case unsupportedChannels
  case unsupportedTracks
  case decodeFailed
}

struct PreparedAudioImport {
  let cafURL: URL
  let original: NativeOriginalImportMetadata?
  let compressed: NativeCompressedImportMetadata?
  let temporaryDirectory: URL?

  func removeTemporaryCopy() {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }
}

/// M4A always uses Rust's original-preserving compressed import path. Derived
/// transcription audio is produced later from the verified managed original.
enum BoundedAudioImport {
  static func prepare(sourceURL: URL, policy: NativeImportPolicy) throws -> PreparedAudioImport {
    let values = try sourceURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard sourceURL.isFileURL, values.isRegularFile == true,
      values.isSymbolicLink != true, let length = values.fileSize, length > 0
    else { throw BoundedAudioImportError.invalidSource }
    let sourceBytes = UInt64(length)
    guard sourceBytes <= policy.maximumSourceBytes else {
      throw BoundedAudioImportError.sourceTooLarge(
        actual: sourceBytes, maximum: policy.maximumSourceBytes)
    }
    switch sourceURL.pathExtension.lowercased() {
    case "caf":
      guard sourceBytes <= policy.maximumManagedBytes else {
        throw BoundedAudioImportError.sourceTooLarge(
          actual: sourceBytes, maximum: policy.maximumManagedBytes)
      }
      return PreparedAudioImport(
        cafURL: sourceURL, original: nil, compressed: nil, temporaryDirectory: nil)
    case "m4a":
      return try prepareM4A(sourceURL, sourceBytes: sourceBytes, policy: policy)
    default:
      throw BoundedAudioImportError.unsupportedFormat
    }
  }

  private static func prepareM4A(
    _ sourceURL: URL, sourceBytes: UInt64, policy: NativeImportPolicy
  ) throws -> PreparedAudioImport {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      // Probe the same staging bytes whose digest Rust will validate.
      let stagedURL = directory.appendingPathComponent("staged.m4a")
      try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
      let values = try stagedURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.fileSize == Int(sourceBytes)
      else { throw BoundedAudioImportError.invalidSource }
      let handle = try FileHandle(forUpdating: stagedURL)
      try handle.synchronize()
      try handle.close()
      try Task<Never, Never>.checkCancellation()

      var opened: ExtAudioFileRef?
      guard ExtAudioFileOpenURL(stagedURL as CFURL, &opened) == noErr, let source = opened
      else { throw BoundedAudioImportError.unsupportedFormat }
      defer { ExtAudioFileDispose(source) }
      try requireSingleAudioTrack(source)
      var format = AudioStreamBasicDescription()
      var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      guard
        ExtAudioFileGetProperty(
          source, kExtAudioFileProperty_FileDataFormat, &formatSize, &format) == noErr,
        format.mFormatID == kAudioFormatMPEG4AAC
          || format.mFormatID == kAudioFormatAppleLossless
      else { throw BoundedAudioImportError.unsupportedFormat }
      guard (1...2).contains(format.mChannelsPerFrame) else {
        throw BoundedAudioImportError.unsupportedChannels
      }
      guard format.mSampleRate.isFinite, format.mSampleRate >= 1,
        format.mSampleRate <= Double(UInt32.max)
      else { throw BoundedAudioImportError.invalidSource }
      var frames: Int64 = 0
      var frameSize = UInt32(MemoryLayout<Int64>.size)
      guard
        ExtAudioFileGetProperty(
          source, kExtAudioFileProperty_FileLengthFrames, &frameSize, &frames) == noErr,
        frames > 0
      else { throw BoundedAudioImportError.invalidSource }
      let duration = Double(frames) / format.mSampleRate * 1_000_000_000
      guard duration.isFinite, duration > 0, duration < Double(UInt64.max) else {
        throw BoundedAudioImportError.invalidSource
      }
      guard duration <= Double(policy.maximumDurationNanoseconds) else {
        throw BoundedAudioImportError.durationTooLong(
          maximumNanoseconds: policy.maximumDurationNanoseconds)
      }
      let sampleCount = try probeTranscriptionFrames(
        source, format: format, frames: UInt64(frames), policy: policy)
      let metadata = NativeOriginalImportMetadata(
        displayName: sourceURL.lastPathComponent, byteLength: sourceBytes,
        durationNanoseconds: UInt64(duration.rounded()),
        sampleRateHz: UInt32(format.mSampleRate.rounded()),
        channelCount: format.mChannelsPerFrame, mediaFormat: "m4a")
      return PreparedAudioImport(
        cafURL: stagedURL, original: nil,
        compressed: NativeCompressedImportMetadata(
          original: metadata, sampleCount: sampleCount, digestSha256: try sha256(stagedURL)),
        temporaryDirectory: directory)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Count resampled frames with the same AudioToolbox conversion used for the
  /// later 48 kHz companion, without storing a second permanent recording.
  private static func probeTranscriptionFrames(
    _ source: ExtAudioFileRef, format: AudioStreamBasicDescription, frames: UInt64,
    policy: NativeImportPolicy
  ) throws -> UInt64 {
    guard
      let client = AVAudioFormat(
        standardFormatWithSampleRate: 48_000, channels: format.mChannelsPerFrame),
      let buffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: 16_384)
    else { throw BoundedAudioImportError.unsupportedFormat }
    var clientFormat = client.streamDescription.pointee
    guard
      ExtAudioFileSetProperty(
        source, kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat) == noErr
    else { throw BoundedAudioImportError.unsupportedFormat }
    var total: UInt64 = 0
    repeat {
      try Task<Never, Never>.checkCancellation()
      var count: UInt32 = 16_384
      buffer.frameLength = count
      guard ExtAudioFileRead(source, &count, buffer.mutableAudioBufferList) == noErr else {
        throw BoundedAudioImportError.decodeFailed
      }
      if count == 0 { break }
      total += UInt64(count)
      guard total <= policy.maximumManagedSamples else {
        throw BoundedAudioImportError.durationTooLong(
          maximumNanoseconds: policy.maximumDurationNanoseconds)
      }
      // Same-rate files already have an exact frame count. Preserve bounded
      // streaming admission for long recordings instead of decoding them all.
      if format.mSampleRate == 48_000 {
        guard frames <= policy.maximumManagedSamples else {
          throw BoundedAudioImportError.durationTooLong(
            maximumNanoseconds: policy.maximumDurationNanoseconds)
        }
        return frames
      }
    } while true
    guard total > 0 else { throw BoundedAudioImportError.decodeFailed }
    return total
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      try Task<Never, Never>.checkCancellation()
      let hasMore = try autoreleasepool {
        guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { return false }
        hasher.update(data: data)
        return true
      }
      if !hasMore { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func requireSingleAudioTrack(_ source: ExtAudioFileRef) throws {
    var audioFile: AudioFileID?
    var propertySize = UInt32(MemoryLayout<AudioFileID>.size)
    guard
      ExtAudioFileGetProperty(
        source, kExtAudioFileProperty_AudioFile, &propertySize, &audioFile) == noErr,
      let audioFile
    else { throw BoundedAudioImportError.unsupportedFormat }
    var tracks: UInt32 = 0
    propertySize = UInt32(MemoryLayout<UInt32>.size)
    guard
      AudioFileGetProperty(
        audioFile, kAudioFilePropertyAudioTrackCount, &propertySize, &tracks) == noErr, tracks == 1
    else { throw BoundedAudioImportError.unsupportedTracks }
  }
}
