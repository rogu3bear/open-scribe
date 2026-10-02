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

/// The original stays under the user's security scope. Rust admits bounded PCM
/// or the exact compressed bytes of a platform-probed private staging copy.
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
      guard sourceBytes <= policy.maximumManagedBytes else {
        throw BoundedAudioImportError.sourceTooLarge(
          actual: sourceBytes, maximum: policy.maximumManagedBytes
        )
      }
      return PreparedAudioImport(
        cafURL: sourceURL, original: nil, compressed: nil, temporaryDirectory: nil)
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
    try requireSingleAudioTrack(source)

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
    guard (1...2).contains(fileFormat.mChannelsPerFrame) else {
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
    let frameCount = UInt64(sourceFrames)
    let projectedFrames = ceil(seconds * 48_000)
    let exceedsPCM =
      policy.maximumManagedBytes <= 4_096
      || projectedFrames > Double((policy.maximumManagedBytes - 4_096) / 2)
    if fileFormat.mChannelsPerFrame == 2
      || (fileFormat.mSampleRate == 48_000
        && (sourceBytes > policy.maximumManagedBytes || exceedsPCM))
    {
      guard fileFormat.mSampleRate == 48_000,
        frameCount <= policy.maximumManagedSamples
      else {
        throw BoundedAudioImportError.unsupportedFormat
      }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-scribe-import-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
      )
      do {
        let stagedURL = directory.appendingPathComponent("staged.m4a")
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        let stagedValues = try stagedURL.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard stagedValues.isRegularFile == true, stagedValues.isSymbolicLink != true,
          stagedValues.fileSize == Int(sourceBytes)
        else { throw BoundedAudioImportError.invalidSource }
        let stagedHandle = try FileHandle(forUpdating: stagedURL)
        try stagedHandle.synchronize()
        try stagedHandle.close()
        try Task<Never, Never>.checkCancellation()
        var stagedSource: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(stagedURL as CFURL, &stagedSource) == noErr, let stagedSource
        else { throw BoundedAudioImportError.decodeFailed }
        defer { ExtAudioFileDispose(stagedSource) }
        try requireSingleAudioTrack(stagedSource)
        var stagedFormat = AudioStreamBasicDescription()
        var stagedFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var stagedFrames: Int64 = 0
        var stagedFrameSize = UInt32(MemoryLayout<Int64>.size)
        guard
          ExtAudioFileGetProperty(
            stagedSource, kExtAudioFileProperty_FileDataFormat, &stagedFormatSize, &stagedFormat)
            == noErr,
          ExtAudioFileGetProperty(
            stagedSource, kExtAudioFileProperty_FileLengthFrames, &stagedFrameSize, &stagedFrames)
            == noErr,
          stagedFormat.mFormatID == fileFormat.mFormatID,
          stagedFormat.mSampleRate == fileFormat.mSampleRate,
          stagedFormat.mChannelsPerFrame == fileFormat.mChannelsPerFrame,
          stagedFrames == sourceFrames
        else { throw BoundedAudioImportError.invalidSource }
        guard
          let client = AVAudioFormat(
            standardFormatWithSampleRate: fileFormat.mSampleRate,
            channels: fileFormat.mChannelsPerFrame
          ), let probeBuffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: 4_096)
        else { throw BoundedAudioImportError.unsupportedFormat }
        var clientFormat = client.streamDescription.pointee
        guard
          ExtAudioFileSetProperty(
            stagedSource, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
          ) == noErr
        else { throw BoundedAudioImportError.unsupportedFormat }
        var probeFrames: UInt32 = 4_096
        probeBuffer.frameLength = probeFrames
        guard
          ExtAudioFileRead(stagedSource, &probeFrames, probeBuffer.mutableAudioBufferList) == noErr,
          probeFrames > 0
        else { throw BoundedAudioImportError.decodeFailed }
        let digest = try sha256(stagedURL)
        let original = NativeOriginalImportMetadata(
          displayName: sourceURL.lastPathComponent,
          byteLength: sourceBytes,
          durationNanoseconds: UInt64(duration.rounded()),
          sampleRateHz: 48_000,
          channelCount: fileFormat.mChannelsPerFrame,
          mediaFormat: "m4a"
        )
        return PreparedAudioImport(
          cafURL: stagedURL,
          original: nil,
          compressed: NativeCompressedImportMetadata(
            original: original, sampleCount: frameCount, digestSha256: digest
          ),
          temporaryDirectory: directory
        )
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    }
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
        compressed: nil,
        temporaryDirectory: directory
      )
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
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
      ExtAudioFileGetProperty(source, kExtAudioFileProperty_AudioFile, &propertySize, &audioFile)
        == noErr,
      let audioFile
    else { throw BoundedAudioImportError.unsupportedFormat }
    var tracks: UInt32 = 0
    propertySize = UInt32(MemoryLayout<UInt32>.size)
    guard
      AudioFileGetProperty(audioFile, kAudioFilePropertyAudioTrackCount, &propertySize, &tracks)
        == noErr,
      tracks == 1
    else { throw BoundedAudioImportError.unsupportedTracks }
  }
}
