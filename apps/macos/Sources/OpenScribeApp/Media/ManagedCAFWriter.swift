@preconcurrency import AVFoundation
import Darwin
import Foundation

enum ManagedCAFWriterError: Error, Equatable {
  case unsupportedAuthorization
  case pathAlreadyExists
  case bufferAllocationFailed
  case mediaAttributesUnavailable
  case conversionFailed
}

private final class SingleBufferConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(_ inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard !supplied else {
      inputStatus.pointee = .noDataNow
      return nil
    }
    supplied = true
    inputStatus.pointee = .haveData
    return buffer
  }
}

/// Swift-owned source-media writer. Audio buffers stay on the dedicated Swift
/// writer queue and never cross UniFFI; Rust receives only coarse durable
/// boundary receipts.
protocol CapturedAudioWriting: AnyObject, Sendable {
  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount
  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws
    -> NativeFirstSampleReceipt
}

final class ManagedCAFWriter: CapturedAudioWriting, @unchecked Sendable {
  let authorization: NativeMediaOpenAuthorization

  private let file: AVAudioFile
  private let fileURL: URL
  private var converters: [String: AVAudioConverter] = [:]

  init(authorization: NativeMediaOpenAuthorization) throws {
    guard authorization.writerGeneration == 1 else {
      throw ManagedCAFWriterError.unsupportedAuthorization
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
        throw ManagedCAFWriterError.pathAlreadyExists
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
      throw ManagedCAFWriterError.bufferAllocationFailed
    }

    buffer.frameLength = frameCount
    for index in 0..<Int(frameCount) {
      let phase = Int16(index % 256)
      samples[index] = (phase - 128) * 128
    }
    try file.write(from: buffer)
    try synchronize()
  }

  @discardableResult
  func writeCapturedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
    guard input.frameLength > 0 else { return 0 }
    let output: AVAudioPCMBuffer
    if input.format == file.processingFormat {
      output = input
    } else {
      let key = "\(input.format)-to-\(file.processingFormat)"
      let converter: AVAudioConverter
      if let existing = converters[key] {
        converter = existing
      } else if let created = AVAudioConverter(from: input.format, to: file.processingFormat) {
        converters[key] = created
        converter = created
      } else {
        throw ManagedCAFWriterError.conversionFailed
      }
      let ratio = file.processingFormat.sampleRate / input.format.sampleRate
      let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
      guard
        let converted = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: capacity
        )
      else {
        throw ManagedCAFWriterError.bufferAllocationFailed
      }
      let provider = SingleBufferConverterInput(buffer: input)
      var conversionError: NSError?
      let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
        provider.next(inputStatus)
      }
      guard status == .haveData || status == .inputRanDry, conversionError == nil else {
        throw conversionError ?? ManagedCAFWriterError.conversionFailed
      }
      output = converted
    }
    guard output.frameLength > 0 else {
      throw ManagedCAFWriterError.conversionFailed
    }
    try file.write(from: output)
    try synchronize()
    return output.frameLength
  }

  func receipt() throws -> NativeMediaOpenReceipt {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let byteLength = attributes[.size] as? NSNumber else {
      throw ManagedCAFWriterError.mediaAttributesUnavailable
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

  func firstSampleReceipt(hostTime: UInt64, frameCount: UInt64) throws
    -> NativeFirstSampleReceipt
  {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    guard let byteLength = attributes[.size] as? NSNumber else {
      throw ManagedCAFWriterError.mediaAttributesUnavailable
    }
    return NativeFirstSampleReceipt(
      sessionId: authorization.sessionId,
      trackId: authorization.trackId,
      segmentId: authorization.segmentId,
      openToken: authorization.openToken,
      writerGeneration: authorization.writerGeneration,
      relativePath: authorization.relativePath,
      firstSampleHostTime: hostTime,
      firstSampleFrameCount: frameCount,
      observedByteLength: byteLength.uint64Value
    )
  }

  private func synchronize() throws {
    let handle = try FileHandle(forUpdating: fileURL)
    try handle.synchronize()
    try handle.close()
  }
}
