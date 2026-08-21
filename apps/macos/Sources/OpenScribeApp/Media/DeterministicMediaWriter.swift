import AVFoundation
import Darwin
import Foundation

enum DeterministicMediaWriterError: Error, Equatable {
  case unsupportedAuthorization
  case pathAlreadyExists
  case bufferAllocationFailed
  case mediaAttributesUnavailable
}

/// A Swift-owned writer harness for proving the media-open boundary before capture exists.
/// Audio buffers remain entirely in Swift and are never serialized through UniFFI.
final class DeterministicMediaWriter {
  let authorization: NativeMediaOpenAuthorization

  private let file: AVAudioFile
  private let fileURL: URL

  init(authorization: NativeMediaOpenAuthorization) throws {
    guard authorization.writerGeneration == 1 else {
      throw DeterministicMediaWriterError.unsupportedAuthorization
    }

    self.authorization = authorization
    fileURL = URL(fileURLWithPath: authorization.absolutePath, isDirectory: false)
    let descriptor = Darwin.open(
      fileURL.path,
      O_WRONLY | O_CREAT | O_EXCL,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw DeterministicMediaWriterError.pathAlreadyExists
      }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    Darwin.close(descriptor)

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: true,
    ]
    file = try AVAudioFile(
      forWriting: fileURL,
      settings: settings,
      commonFormat: .pcmFormatInt16,
      interleaved: false
    )
  }

  func writeDeterministicFrames(_ frameCount: AVAudioFrameCount) throws {
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCount
      ),
      let samples = buffer.int16ChannelData?[0]
    else {
      throw DeterministicMediaWriterError.bufferAllocationFailed
    }

    buffer.frameLength = frameCount
    for index in 0..<Int(frameCount) {
      let phase = Int16(index % 256)
      samples[index] = (phase - 128) * 128
    }
    try file.write(from: buffer)
    try synchronize()
  }

  func receipt() throws -> NativeMediaOpenReceipt {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let byteLength = attributes[.size] as? NSNumber else {
      throw DeterministicMediaWriterError.mediaAttributesUnavailable
    }
    return NativeMediaOpenReceipt(
      sessionId: authorization.sessionId,
      trackId: authorization.trackId,
      segmentId: authorization.segmentId,
      openToken: authorization.openToken,
      writerGeneration: authorization.writerGeneration,
      relativePath: authorization.relativePath,
      initialByteLength: byteLength.uint64Value
    )
  }

  private func synchronize() throws {
    let handle = try FileHandle(forUpdating: fileURL)
    try handle.synchronize()
    try handle.close()
  }
}
