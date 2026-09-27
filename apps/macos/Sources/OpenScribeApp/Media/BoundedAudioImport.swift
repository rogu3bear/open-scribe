@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

enum BoundedAudioImportError: Error, Equatable {
  case invalidSource
  case sourceTooLarge(actual: UInt64, maximum: UInt64)
  case decodedTooLarge(maximum: UInt64)
  case durationTooLong(maximumNanoseconds: UInt64)
  case unsupportedFormat
  case unsupportedChannels
  case decodeFailed
}

struct PreparedAudioImport {
  let cafURL: URL
  let original: NativeOriginalImportMetadata?
  let temporaryDirectory: URL?

  func removeTemporaryCopy() {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }
}

/// The original stays under the user's security scope. Only a bounded CAF is
/// handed to Rust, which independently validates and publishes the managed copy.
enum BoundedAudioImport {
  static func prepare(sourceURL: URL, policy: NativeImportPolicy) throws -> PreparedAudioImport {
    let values = try sourceURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard sourceURL.isFileURL, values.isRegularFile == true,
      values.isSymbolicLink != true, let length = values.fileSize, length > 0
    else {
      throw BoundedAudioImportError.invalidSource
    }
    let sourceBytes = UInt64(length)
    guard sourceBytes <= policy.maximumSourceBytes else {
      throw BoundedAudioImportError.sourceTooLarge(
        actual: sourceBytes, maximum: policy.maximumSourceBytes
      )
    }

    switch sourceURL.pathExtension.lowercased() {
    case "caf":
      return PreparedAudioImport(cafURL: sourceURL, original: nil, temporaryDirectory: nil)
    case "m4a":
      return try normalizeM4A(sourceURL, sourceBytes: sourceBytes, policy: policy)
    default:
      throw BoundedAudioImportError.unsupportedFormat
    }
  }

  private static func normalizeM4A(
    _ sourceURL: URL,
    sourceBytes: UInt64,
    policy: NativeImportPolicy
  ) throws -> PreparedAudioImport {
    var source: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(sourceURL as CFURL, &source) == noErr, let source else {
      throw BoundedAudioImportError.unsupportedFormat
    }
    defer { ExtAudioFileDispose(source) }

    var fileFormat = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard
      ExtAudioFileGetProperty(
        source, kExtAudioFileProperty_FileDataFormat, &formatSize, &fileFormat
      ) == noErr
    else {
      throw BoundedAudioImportError.unsupportedFormat
    }
    guard
      fileFormat.mFormatID == kAudioFormatMPEG4AAC
        || fileFormat.mFormatID == kAudioFormatAppleLossless
    else {
      throw BoundedAudioImportError.unsupportedFormat
    }
    guard fileFormat.mChannelsPerFrame == 1 else {
      throw BoundedAudioImportError.unsupportedChannels
    }
    guard fileFormat.mSampleRate.isFinite, fileFormat.mSampleRate > 0,
      fileFormat.mSampleRate <= Double(UInt32.max)
    else {
      throw BoundedAudioImportError.invalidSource
    }

    var sourceFrames: Int64 = 0
    var frameSize = UInt32(MemoryLayout<Int64>.size)
    guard
      ExtAudioFileGetProperty(
        source, kExtAudioFileProperty_FileLengthFrames, &frameSize, &sourceFrames
      ) == noErr, sourceFrames > 0
    else {
      throw BoundedAudioImportError.invalidSource
    }
    let seconds = Double(sourceFrames) / fileFormat.mSampleRate
    let duration = seconds * 1_000_000_000
    guard duration.isFinite, duration > 0, duration < Double(UInt64.max) else {
      throw BoundedAudioImportError.invalidSource
    }
    guard duration <= Double(policy.maximumDurationNanoseconds) else {
      throw BoundedAudioImportError.durationTooLong(
        maximumNanoseconds: policy.maximumDurationNanoseconds
      )
    }
    let projectedFrames = ceil(seconds * 48_000)
    // CAF headers are small, but reserve a full page and reject a boundary
    // estimate rather than risk publishing media the bounded player cannot open.
    guard policy.maximumManagedBytes > 4_096,
      projectedFrames.isFinite,
      projectedFrames <= Double((policy.maximumManagedBytes - 4_096) / 2),
      projectedFrames <= Double(policy.maximumManagedSamples)
    else {
      throw BoundedAudioImportError.decodedTooLarge(maximum: policy.maximumManagedBytes)
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-scribe-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      let cafURL = directory.appendingPathComponent("normalized.caf")
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
      ]
      var totalFrames: UInt64 = 0
      do {
        let output = try AVAudioFile(
          forWriting: cafURL,
          settings: settings,
          commonFormat: .pcmFormatInt16,
          interleaved: false
        )
        var clientFormat = output.processingFormat.streamDescription.pointee
        guard
          ExtAudioFileSetProperty(
            source, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
          ) == noErr
        else {
          throw BoundedAudioImportError.unsupportedFormat
        }
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat, frameCapacity: 4_096
          )
        else {
          throw BoundedAudioImportError.decodeFailed
        }
        while true {
          try Task<Never, Never>.checkCancellation()
          var frames: UInt32 = 4_096
          buffer.frameLength = frames
          guard ExtAudioFileRead(source, &frames, buffer.mutableAudioBufferList) == noErr else {
            throw BoundedAudioImportError.decodeFailed
          }
          if frames == 0 { break }
          totalFrames += UInt64(frames)
          guard totalFrames <= policy.maximumManagedSamples,
            totalFrames <= (policy.maximumManagedBytes - 4_096) / 2
          else {
            throw BoundedAudioImportError.decodedTooLarge(maximum: policy.maximumManagedBytes)
          }
          buffer.frameLength = frames
          try output.write(from: buffer)
        }
      }
      guard totalFrames > 0 else { throw BoundedAudioImportError.invalidSource }
      let handle = try FileHandle(forUpdating: cafURL)
      try handle.synchronize()
      try handle.close()
      let normalizedValues = try cafURL.resourceValues(forKeys: [.fileSizeKey])
      guard let normalizedLength = normalizedValues.fileSize,
        normalizedLength > 0,
        UInt64(normalizedLength) <= policy.maximumManagedBytes
      else {
        throw BoundedAudioImportError.decodedTooLarge(maximum: policy.maximumManagedBytes)
      }
      return PreparedAudioImport(
        cafURL: cafURL,
        original: NativeOriginalImportMetadata(
          displayName: sourceURL.lastPathComponent,
          byteLength: sourceBytes,
          durationNanoseconds: UInt64(duration.rounded()),
          sampleRateHz: UInt32(fileFormat.mSampleRate.rounded()),
          channelCount: fileFormat.mChannelsPerFrame,
          mediaFormat: "m4a"
        ),
        temporaryDirectory: directory
      )
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
